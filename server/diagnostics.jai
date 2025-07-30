// This file contains code for running compiler for getting errors and warning.

reset_diagnostics :: () {
    if server.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = server.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }
}

// Currently, parse only the first error (maybe parsing multiple errors is not that useful because Jai mostly report one error at a time)
// @TODO: Make it work with multiple errors
// @todo: add support for warnings
run_diagnostics :: (file_path: string = "") {
    project: *Project_Config;

    if file_path.count > 0 {
        project = find_project_for_file(file_path);
    }

    if !project {
        log("No project found for diagnostics - skipping");
        return;
    }

    if project.build_root.count == 0 {
        log("No build_root configured for project % - skipping diagnostics", project.project_root);
        return;
    }
    build_root_absolute := join(project.project_root, project.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics % for project %", build_root_absolute, project.project_root);

    command: [..] string;
    defer array_free(command);

    array_add(*command, server.jai_path);
    array_add(*command, build_root_absolute, "-quiet", "-no_color", "+jails_diagnostics");

    // Use fast x64 backend on supported CPUs.
    if CPU == .X64 {
        array_add(*command, "-x64");
    }

    for local_module_folder: project.local_modules {
        absolute_module_path := join(project.project_root, local_module_folder, separator="/",, temp);
        array_add(*command, "-import_dir", absolute_module_path);
    }

    if project.intermediate_path.count > 0 {
        joined := join(project.project_root, project.intermediate_path, "jails", separator="/",, temp);
        normalised := normalize_path(joined,, temp);
        array_add(*command, "-", tprint("-JAILS_INTERM_PATH=%", normalised));
    }

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    reset_diagnostics();

    result, _, error := run_command(..command, working_directory=project.project_root, capture_and_return_output=true, timeout_ms=2500);
    if result.exit_code == 0 {
        return;
    }

    lines := split(error, "\n");
    defer array_free(lines);

    file: string;
    diagnostic: LSP_Diagnostic;

    ERROR_MARKER :: ": Error:";
    // Get the first error
    for output_line: lines {
        if !contains(output_line, ERROR_MARKER) continue;

        message_index := find_index_from_right(output_line, ERROR_MARKER);
        message := slice(output_line, message_index + ERROR_MARKER.count, output_line.count - message_index);
        rest := slice(output_line, 0, message_index);

        ok: bool;
        location: string;
        ok, file, location = split_from_right(rest, ":");
        if !ok continue;

        line_and_character := split(location, ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        diagnostic.message = message;
        diagnostic.serverity = xx LSP_Diagnostic_Severity.ERROR;

        diagnostic.range.start.line = line-1;
        diagnostic.range.start.character = character-1;
    }

    highlight_found := false;
    highlighted_chars: u32;

    for line: lines {
        if highlight_found || !contains(line, #char "^") continue;

        for char: cast([]u8) line {
            if char != #char "^" continue;
            highlighted_chars += 1;
        }

        highlight_found = true;
    }

    diagnostic.range.end.line = diagnostic.range.start.line;
    diagnostic.range.end.character = diagnostic.range.start.character+highlighted_chars;

    diagnostics: [1]LSP_Diagnostic;
    diagnostics[0] = diagnostic;

    file = path_to_lsp_path(normalize_path(file,, temp)); // split_from_right and slice don't allocate memory so copy the file in case the string with compiler output is freed

    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = file,
            diagnostics = diagnostics
        }
    });

    if file != server.previously_errored_file {
        free(server.previously_errored_file);
    }

    server.previously_errored_file = file;
}
