// TODO: files can end up being considered to be in multiple projects.
//
// Files exist once in the Server, but if the projects change, they need to be
// re-analyzed.
//
// A library referenced via local_modules in multiple projects, but in each one
// the local_modules path is different, so the library's imports have different
// meanings.
//
// We also currently have a situation where a file can be a `root` in multiple
// projects, either deliberately or by discovery.
//
// A generic problem that comes up even in a single project is that different
// build configurations can change the meaning of the code, especially imports
// and #if conditions. Not to mention module parameters & #load
//
// In general it is not possible to have an editor handle multiple overlapping
// projects 100% precisely & accurately. So the trade-off is probably to go for 
// accuracy & take the union of information about a file across projects, e.g.
// show all possible destinations for go-to-definition across all import paths
// in all involved projects.
//
// Diagnostics are per-project, so you should run them for all projects & show
// the union of all projects.
//
// Almost certainly, the right thing to do is to handle the projects separately
// and then only amalgamate results as necessary for responses to the client.
//
// This implies that we save all File information inside each project.

VERSION :: "1.0.0";

MEMORY_DEBUG :: false;

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string;
}

User_Options :: struct {
    auto_insert_parentheses: bool;
}

Project_Config :: struct {
    local_modules: []string;
    roots: []string;
    build_root: string;
    intermediate_path: string;
    user_options: User_Options;

    project_root: string;
    config_loaded: bool;
    config_file_hash: u64;

    // Per-project allocator for all project-owned data
    allocator: Allocator;
    pool: Pool;
}

Server :: struct {
    quit := false;

    verbose: bool;
    profile: bool;

    jai_path: string;

    // Multi-project support
    workspace_folders: [..]string;
    projects: Table(string, Project_Config); // project_root -> config

    files: Table(string, *Program_File);
    files_to_be_analyzed: [..]*Program_File;

    memory_files_lock: Mutex;
    memory_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file

    previously_errored_file: string;

    diagnostics_metaprogram_path: string;
}

server: Server;

// @TODO: move this to somewhere else
is_hex_digit :: (c: u32) -> bool {
    return (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F") || (c >= #char "0" && c <= #char "9");
}

// @TODO: move this to somewhere else
decode_url :: (url: string) -> string {
    out_url := copy_string(url);

    i, j: int;
    hex: [2]u8 = .[#char "0", #char "0"];

    while i < out_url.count {

        defer {
            i += 1;
            j += 1;
        }

        if out_url[i] != #char "%" || out_url[i+1] == 0 {
            out_url[j] = out_url[i];
            continue;
        }

        if is_hex_digit(out_url[i+1]) && is_hex_digit(out_url[i+2]) {
            hex[0] = out_url[i+1];
            hex[1] = out_url[i+2];

            out_url[j] = xx string_to_int(xx hex, 16);
            i += 2;
        }


    }
    out_url.count = j;

    return out_url;
}

find_entry_file :: (root: string) -> string {

    contains_main_procedure :: (file: string) -> bool {
        content := read_entire_file(file);
        return contains(content, "main ::") || contains(content, "main::");
    }

    // @Fixme: This does not take the root into account!
    COMMON_MAIN_PATH :: string.["/src/main.jai", "main.jai"]; // Maybe build.jai ... etc?

    for path: COMMON_MAIN_PATH {
        if file_exists(join(root, path, separator = "/")) && contains_main_procedure(path) {
            return path;
        }
    }

    files := file_list(root, true);

    for file: files {
        if contains(file, "main.jai") && contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    for file: files {
        if contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    return ""; // TODO: What we gonna do when we do not find any?
}

find_jai_path :: (executable_name: string) -> string {
    result: Process_Result;
    raw_path: string;
    err: string;

    #if OS == .WINDOWS {
        result, raw_path, err = run_command("where.exe", executable_name, capture_and_return_output=true);
        path_overwrite_separators(raw_path, #char "/");
        raw_path = trim(raw_path);
    } else {
        #if OS == .MACOS {
            result, raw_path, err = run_command("whereis", "-q", executable_name, capture_and_return_output=true);
        } else { // Linux does not have the -q argument.
            result, raw_path, err = run_command("whereis", executable_name, capture_and_return_output=true);
        }

        raw_path = replace(raw_path, tprint("%: ", executable_name), "");
        raw_path = trim(raw_path);

        BUFFER_SIZE :: 4096;
        buf: [BUFFER_SIZE] u8;

        length := readlink(to_c_string(raw_path), buf.data, BUFFER_SIZE);
        if length > 0 {
            resolved_path := to_string(buf.data);
            if begins_with(resolved_path, "/") {
                raw_path = resolved_path;
            }
        }
    }

    if raw_path.count == 0 {
        #if OS == .MACOS || OS == .LINUX {
            if executable_name == "jai" return "";
            return find_jai_path("jai");
        }

        return "";
    }

    path := split(raw_path, "/");

    pop(*path); // jai.exe or jai
    pop(*path); // bin

    return join(..path, separator="/");
}

find_project_for_file :: (file_path: string) -> *Project_Config {
    longest_match_length := 0;
    best_project: *Project_Config = null;

    for * project: server.projects {
        if begins_with(file_path, project.project_root) {
            if project.project_root.count > longest_match_length {
                longest_match_length = project.project_root.count;
                best_project = project;
            }
        }
    }

    return best_project;
}

ensure_project_for_file :: (file_path: string) {
    // Fast-path: the file already belongs to a known project.
    if find_project_for_file(file_path) {
        return;
    }

    // Identify the containing workspace folder (if any).
    containing_workspace: string;
    for folder: server.workspace_folders {
        if begins_with(file_path, folder) {
            containing_workspace = folder;
            break;
        }
    }

    // It's a file outside of any workspace folder, so we'll use the file's
    // directory
    if !containing_workspace {
        containing_workspace = path_strip_filename(file_path);
    }

    // Walk upward from the file’s directory looking for jails.json,
    // but never leave the workspace folder boundary.
    dir := path_strip_filename(file_path);
    while true {
        if file_exists(join(dir, "/jails.json")) {
            initialize_project(dir);
            return;
        }

        if dir == containing_workspace  break;

        parent := path_strip_filename(dir);
        if parent == dir {
            break; // Reached filesystem root
        }
        dir = parent;
    }

    // Fallback – treat the workspace root itself as a project
    initialize_project(containing_workspace);
}

scan_workspace_for_configs :: (workspace_root: string) -> bool {
    found := false;

    visitor :: (info: *File_Visit_Info, found_ptr: *bool) {
        if info.is_directory  return;
        if info.short_name != "jails.json"  return;

        found_ptr.* = true;
        project_dir := path_strip_filename(info.full_name);
        initialize_project(project_dir);
    }

    visit_files(workspace_root, true, *found, visitor, true, false);

    return found;
}


init_project_config :: (project: *Project_Config) {
    project.* = .{};
    set_allocators(*project.pool, context.default_allocator);
    project.allocator = .{pool_allocator_proc, *project.pool};
}

load_config_for_project :: (project_root: string) -> *Project_Config {
    push_allocator(temp);
    auto_release_temp();

    project := table_find_pointer(*server.projects, project_root);

    config_path := join(project_root, "/jails.json");
    config_exists := file_exists(config_path);
    current_hash: u64 = 0;

    if config_exists {
        config_content := read_entire_file(config_path);
        current_hash = native_XXH64(config_content.data, xx config_content.count, 0);
    }

    // Check if we need to reload config
    if project && project.config_loaded {
        if current_hash != project.config_file_hash {
            log("Config file changed for project %, reloading...", project_root);
            release(*project.pool);
            init_project_config(project);
            project.config_loaded = false;
            project.config_file_hash = current_hash;
        } else {
            return project; // No changes, return existing config
        }
    }

    if !project {
        project = table_add(*server.projects, copy_string(project_root,, server.projects.allocator), .{});
        log("Adding new project: %", project_root);
        init_project_config(project);
        project.project_root = copy_string(project_root,, project.allocator);
    }

    if !config_exists {
        // Set defaults for projects without config
        project.config_loaded = true;
        project.local_modules = .["modules"];
        project.user_options.auto_insert_parentheses = true;
        return project;
    }

    config_content := read_entire_file(config_path);

    Config :: struct {
        local_modules: []string;
        roots: []string;
        build_root: string;
        jai_path: string;
        intermediate_path: string;
        auto_insert_parentheses := true;
    }

    ok, config := json_parse_string(config_content, Config);
    if !ok {
        log("Failed to parse config file at %!", config_path);
        project.config_loaded = true;
        return project;
    }
    log("Loaded config file @ %", config_path);

    // Use project allocator for all project-owned data
    push_allocator(project.allocator);

    // Copy local_modules array to project allocator
    local_modules: [..]string;
    for config.local_modules {
        array_add_if_unique(*local_modules, copy_string(it));
    }
    // Include default modules path
    array_add_if_unique(*local_modules, "modules");
    project.local_modules = local_modules;

    // Copy roots array to project allocator
    project.roots = NewArray(config.roots.count, string);
    for i: 0..config.roots.count-1 {
        project.roots[i] = copy_string(config.roots[i]);
    }

    project.build_root = copy_string(config.build_root);
    project.intermediate_path = copy_string(config.intermediate_path);

    project.user_options.auto_insert_parentheses = config.auto_insert_parentheses;
    project.config_loaded = true;

    if config.jai_path.count > 0 {
        server.jai_path = copy_string(config.jai_path);
    }

    return project;
}

initialize_project :: (project_root: string) {
    project := load_config_for_project(project_root);

    if project.build_root.count == 0 {
        project.build_root = find_entry_file(project_root);
    }

    if project.roots.count == 0 {
        project.roots = .[find_entry_file(project_root)];
    }

    log("Project % - local_modules: %", project_root, project.local_modules);
    log("Project % - roots: %", project_root, project.roots);
    log("Project % - intermediate_path: %", project_root, project.intermediate_path);

    for root: project.roots {
        absolute_path: string;
        if starts_with(root, "/") {
            absolute_path = root;
        } else {
            absolute_path = join(project_root, root, separator="/",, temp);
        }

        absolute_path = normalize_path(absolute_path,, temp);
        parse_file(absolute_path, true);
    }
}

create_diagnostics_metaprogram :: () {
    METAPROGRAM_SOURCE := #run -> string {
        project_dir := join(path_strip_filename(#file), "..");
        metaprogram_dir := tprint("%/metaprogram", project_dir);
        return read_entire_file(tprint("%/jails_diagnostics.jai", metaprogram_dir));
    };

    jails_exe_dir := trim_right(path_strip_filename(get_path_of_running_executable()), "/");
    metaprogram_dir := sprint("%/metaprogram", jails_exe_dir);
    if !make_directory_if_it_does_not_exist(metaprogram_dir) {
        log_error("Failed to create metaprogram directory!");
        return;
    }

    metaprogram_source_file_path := tprint("%/jails_diagnostics.jai", metaprogram_dir);

    if !write_entire_file(metaprogram_source_file_path, METAPROGRAM_SOURCE) {
        log_error("Failed to create metaprogram file!");
        return;
    }

    server.diagnostics_metaprogram_path = metaprogram_dir;
    log("Metaprogram file created! (%)", metaprogram_source_file_path);
}

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    // log("Got %", request.method);

    if request.method == {
        case "shutdown";
            server.quit = true;
            lsp_respond(request.id, null);
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize,, temp);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            create_diagnostics_metaprogram();

            // Handle workspace folders (modern LSP approach)
            if body.params.workspaceFolders {
                log("Initializing with % workspace folders", body.params.workspaceFolders.count);
                for folder: body.params.workspaceFolders.* {
                    folder_path := normalize_path(folder.uri,, temp);
                    log("Adding workspace folder: % (%)", folder.name, folder_path);

                    array_add(*server.workspace_folders, copy_string(folder_path));

                    found := scan_workspace_for_configs(folder_path);
                    if !found {
                        initialize_project(folder_path);
                    }
                }
            } else if body.params.rootPath && body.params.rootPath.* {
                // Fallback for older LSP clients
                log("Initializing with legacy rootPath: %", body.params.rootPath.*);
                root_path := copy_string(body.params.rootPath.*); // Use default allocator for server-owned data
                array_add(*server.workspace_folders, root_path);
                found := scan_workspace_for_configs(root_path);
                if !found {
                    initialize_project(root_path);
                }
            } else {
                log("No workspace folders provided - LSP will wait for workspace/didChangeWorkspaceFolders");
            }
            // Parse Runtime Support and Preload
            {
                parse_file(tprint("%/modules/Runtime_Support.jai", server.jai_path), true);
                parse_file(tprint("%/modules/Preload.jai", server.jai_path), true);
            }

            analyze_files();

            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition,, temp);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/divSave message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            ensure_project_for_file(file_path);

            parse_file(file_path, true);
            analyze_files();
            run_diagnostics(file_path);

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            ensure_project_for_file(file_path);

            content := body.params.textDocument.text;

            create_memory_file(file_path, content);

            parse_file(file_path);
            analyze_files();
            run_diagnostics(file_path);

            log("File_path: %", file_path);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            ensure_project_for_file(file_path);
            edit_memory_file(file_path, body.params.contentChanges);
            parse_file(file_path, true);
            analyze_files();

        case "textDocument/documentSymbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Document_Symbol);
            if !success {
                log_error("Unable to parse textDocument/documentSymbol message");
                return;
            }

            log("workspace/documentSymbol");

            handle_document_symbol(body);

        case "workspace/symbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Workspace_Symbol);
            if !success {
                log_error("Unable to parse workspace/symbol message");
                return;
            }

            log("workspace/symbol");

            handle_workspace_symbol(body);

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            remove_memory_file(file_path);

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_completitions(body);

        case "textDocument/signatureHelp";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Signature_Help,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_signature_help(body);

        case "textDocument/hover";
            // success, body := json_parse_string(raw_request, LSP_Request_Message_Hover,, temp);
            // if !success {
            //     log_error("Unable to parse textDocument/completion message");
            //     return;
            // }

            // handle_hover(body);

        case "workspace/didChangeWorkspaceFolders";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Workspace_Folders,, temp);
            if !success {
                log_error("Unable to parse workspace/didChangeWorkspaceFolders message");
                return;
            }

            handle_workspace_folders_change(body);
    }
}

handle_workspace_folders_change :: (request: LSP_Did_Change_Workspace_Folders) {
    // Add new workspace folders
    for folder: request.params.event.added {
        folder_path := normalize_path(folder.uri,, temp);
        log("Adding workspace folder: %", folder_path);

        // Add to workspace folders if not already present
        found := false;
        for existing: server.workspace_folders {
            if existing == folder_path {
                found = true;
                break;
            }
        }

        if !found {
            // Use default allocator for server-owned workspace folders array
            array_add(*server.workspace_folders, copy_string(folder_path));

            found := scan_workspace_for_configs(folder_path);
            if !found {
                initialize_project(folder_path);
            }
        }
    }

    // Remove workspace folders
    for folder: request.params.event.removed {
        folder_path := normalize_path(folder.uri,, temp);
        log("Removing workspace folder: %", folder_path);

        // Remove from workspace folders
        i := server.workspace_folders.count - 1;
        while i >= 0 {
            if server.workspace_folders[i] == folder_path {
                free(server.workspace_folders[i]);
                array_ordered_remove_by_index(*server.workspace_folders, i);
                break;
            }
            i -= 1;
        }

        // Free project allocator before removing
        project := table_find_pointer(*server.projects, folder_path);
        if project {
            release(*project.pool);
        }

        // Remove project config (this also frees the key string)
        table_remove(*server.projects, folder_path);

        // Remove files belonging to this project
        files_to_remove: [..]*Program_File;
        for file: server.files {
            if begins_with(file.path, folder_path) {
                array_add(*files_to_remove, file);
            }
        }

        for file: files_to_remove {
            // Free the Program_File and its resources
            free(file.path);
            release(*file.ast_pool);
            release(*file.analysis_pool);
            free(file);
            table_remove(*server.files, file.path);
        }
    }

    analyze_files();
}

main :: () {
    context.logger = lsp_log;

    success, args := parse_arguments(Args);
    if !success {
        log_error("Could not parse arguments");
        exit(1);
    }
    log("Args are %", args);

    server.jai_path = args.jai_path;
    server.verbose = args.verbose;
    server.profile = args.profile;

    if args.jai_path.count == 0 {
        jai_name: string;
        #if OS == .WINDOWS {
            jai_name = "jai";
        } else #if OS == .MACOS {
            jai_name = "jai-macos";
        } else #if OS == .LINUX {
            jai_name = "jai-linux";
        }

        server.jai_path = find_jai_path(jai_name);
        if !server.jai_path {
            log_error("Failed to resolve Jai path");
            // @TODO: Send this fatal error over LSP somehow?
        } else {
            log("Jai path: %", server.jai_path);
        }
    }

    init(*server.projects);
    defer deinit(*server.projects);

    init(*server.files);
    defer deinit(*server.files);

    server.files_to_be_analyzed.allocator = context.default_allocator;

    init_memory_files();
    defer deinit_memory_files();

    while !server.quit {
        body, success := read_message_from_stdin(,, temp);
        if !success {
            log("Failed to read message. Skipping.");
            continue;
        }

        parseOK, request := json_parse_string(body, LSP_Request_Message,, temp);
        if !parseOK {
            log_error("Unable to parse as json:\n%\n\n", body);
            continue;
        }

        handle_request(request, body);

        reset_temporary_storage();
        #if MEMORY_DEBUG report_memory_leaks();
    }

    log("Shutdown");
    exit(0);
}

#import "Compiler";
#import "Basic"()(MEMORY_DEBUGGER=MEMORY_DEBUG);
#import "Print_Vars";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "jason";
#import "unicode_utils";
#import "String";
#import "Shared_Memory_Channel";
#import "Hash_Table";
#import "Random";
#import "Process";
#import "Reflection";
#import "Thread";
#import "Pool";
#import "jai_parser";
#import "Default_Allocator";
#import "System";
#import "xxHash";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "diagnostics.jai";
#load "memory_files.jai";

#load "completition.jai";
#load "goto.jai";
#load "signature_help.jai";
#load "hover.jai";
#load "symbols.jai";
#load "utils.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
