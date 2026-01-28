#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "eslint.h"
#include "util.h"
#include "workspace.h"

void eslint_init(void) {
    log_info("ESLint subsystem initialized");
}

char *eslint_find_binary(const char *file_path) {
    if (!file_path) {
        return str_dup("eslint");
    }
    
    char *workspace_root = workspace_get_root_for_file(file_path);
    
    if (!workspace_root) {
        return str_dup("eslint");
    }
    
    char *binary = workspace_find_eslint_binary(workspace_root);

    free(workspace_root);
    
    return binary;
}

char *eslint_find_workspace_root(const char *file_path) {
    return workspace_get_root_for_file(file_path);
}

static char *run_eslint_command(const char *eslint_bin, const char *file_path, 
                                 const char *working_dir, bool fix, const char *content) {
    int stdin_pipe[2];
    int stdout_pipe[2];

    if (pipe(stdin_pipe) == -1 || pipe(stdout_pipe) == -1) {
        log_error("Failed to create pipes");

        return NULL;
    }

    pid_t pid = fork();

    if (pid == -1) {
        log_error("Failed to fork process");

        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);

        return NULL;
    }

    if (pid == 0) {
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stdout_pipe[1], STDERR_FILENO);
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);

        if (working_dir) {
            chdir(working_dir);
        }

        if (content) {
            char stdin_filename_arg[4096];
            snprintf(stdin_filename_arg, sizeof(stdin_filename_arg), 
                     "--stdin-filename=%s", file_path);

            if (fix) {
                execlp(eslint_bin, eslint_bin, "--format", "json", "--fix", 
                       "--stdin", stdin_filename_arg, NULL);
            } else {
                execlp(eslint_bin, eslint_bin, "--format", "json", 
                       "--stdin", stdin_filename_arg, NULL);
            }
        } else {
            if (fix) {
                execlp(eslint_bin, eslint_bin, "--format", "json", "--fix", file_path, NULL);
            } else {
                execlp(eslint_bin, eslint_bin, "--format", "json", file_path, NULL);
            }
        }

        exit(1);
    }

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    if (content) {
        size_t content_len = strlen(content);
        ssize_t written = write(stdin_pipe[1], content, content_len);

        if (written != (ssize_t)content_len) {
            log_error("Failed to write all content to stdin");
        }
    }

    close(stdin_pipe[1]);

    size_t buffer_size = 4096;
    size_t total_size = 0;
    char *output = malloc(buffer_size);

    if (!output) {
        close(stdout_pipe[0]);

        return NULL;
    }

    ssize_t bytes_read;

    while ((bytes_read = read(stdout_pipe[0], output + total_size, buffer_size - total_size - 1)) > 0) {
        total_size += bytes_read;

        if (total_size + 1 >= buffer_size) {
            buffer_size *= 2;
            char *new_output = realloc(output, buffer_size);

            if (!new_output) {
                free(output);
                close(stdout_pipe[0]);

                return NULL;
            }

            output = new_output;
        }
    }

    output[total_size] = '\0';
    close(stdout_pipe[0]);
    int status;
    waitpid(pid, &status, 0);

    return output;
}

static eslint_result_t *parse_eslint_output(const char *json_output, const char *file_path) {
    if (!json_output || !file_path) {
        return NULL;
    }
    
    json_object *root = json_tokener_parse(json_output);
    if (!root) {
        log_error("Failed to parse ESLint JSON output");

        return NULL;
    }
    
    if (!json_object_is_type(root, json_type_array)) {
        json_object_put(root);

        return NULL;
    }
    
    eslint_result_t *result = calloc(1, sizeof(eslint_result_t));
    if (!result) {
        json_object_put(root);

        return NULL;
    }
    
    result->file_path = str_dup(file_path);
    
    // ESLint returns an array with one element per file
    if (json_object_array_length(root) == 0) {
        json_object_put(root);

        return result;
    }
    
    json_object *file_result = json_object_array_get_idx(root, 0);
    json_object *messages_obj;
    
    if (!json_object_object_get_ex(file_result, "messages", &messages_obj)) {
        json_object_put(root);

        return result;
    }
    
    int message_count = json_object_array_length(messages_obj);

    if (message_count == 0) {
        json_object_put(root);

        return result;
    }
    
    result->diagnostics = calloc(message_count, sizeof(eslint_diagnostic_t));
    result->diagnostic_count = message_count;
    
    for (int i = 0; i < message_count; i++) {
        json_object *msg = json_object_array_get_idx(messages_obj, i);
        eslint_diagnostic_t *diag = &result->diagnostics[i];
        
        json_object *line_obj, *column_obj, *end_line_obj, *end_column_obj;
        json_object *severity_obj, *message_obj, *rule_id_obj, *fix_obj;
        
        if (json_object_object_get_ex(msg, "line", &line_obj)) {
            diag->line = json_object_get_int(line_obj);
        }
        
        if (json_object_object_get_ex(msg, "column", &column_obj)) {
            diag->column = json_object_get_int(column_obj);
        }
        
        if (json_object_object_get_ex(msg, "endLine", &end_line_obj)) {
            diag->end_line = json_object_get_int(end_line_obj);
        } else {
            diag->end_line = diag->line;
        }
        
        if (json_object_object_get_ex(msg, "endColumn", &end_column_obj)) {
            diag->end_column = json_object_get_int(end_column_obj);
        } else {
            diag->end_column = diag->column;
        }
        
        if (json_object_object_get_ex(msg, "severity", &severity_obj)) {
            diag->severity = json_object_get_int(severity_obj);
        }
        
        if (json_object_object_get_ex(msg, "message", &message_obj)) {
            diag->message = str_dup(json_object_get_string(message_obj));
        }
        
        if (json_object_object_get_ex(msg, "ruleId", &rule_id_obj)) {
            diag->rule_id = str_dup(json_object_get_string(rule_id_obj));
        }
        
        if (json_object_object_get_ex(msg, "fix", &fix_obj)) {
            diag->fixable = json_object_get_boolean(fix_obj);
        }
    }
    
    json_object_put(root);

    return result;
}

eslint_result_t *eslint_lint_file(const char *file_path, const char *content) {
    if (!file_path) {
        return NULL;
    }

    char *eslint_bin = eslint_find_binary(file_path);
    char *workspace_root = eslint_find_workspace_root(file_path);
    char *package_root = workspace_find_package_root(file_path);
    char *working_dir = package_root ? package_root : workspace_root;

    log_debug("Running ESLint: %s on %s (working dir: %s, stdin: %s)", 
              eslint_bin, file_path, working_dir ? working_dir : "none",
              content ? "yes" : "no");

    char *output = run_eslint_command(eslint_bin, file_path, working_dir, false, content);

    free(eslint_bin);
    free(workspace_root);

    if (package_root) {
        free(package_root);
    }

    if (!output) {
        log_error("ESLint command failed");

        return NULL;
    }

    eslint_result_t *result = parse_eslint_output(output, file_path);

    free(output);

    return result;
}

eslint_result_t *eslint_fix_file(const char *file_path) {
    if (!file_path) {
        return NULL;
    }

    char *eslint_bin = eslint_find_binary(file_path);
    char *workspace_root = eslint_find_workspace_root(file_path);
    char *package_root = workspace_find_package_root(file_path);
    char *working_dir = package_root ? package_root : workspace_root;

    log_debug("Running ESLint fix: %s on %s", eslint_bin, file_path);

    char *output = run_eslint_command(eslint_bin, file_path, working_dir, true, NULL);

    free(eslint_bin);
    free(workspace_root);

    if (package_root) {
        free(package_root);
    }

    if (!output) {
        log_error("ESLint fix command failed");

        return NULL;
    }

    eslint_result_t *result = parse_eslint_output(output, file_path);

    free(output);

    return result;
}

void eslint_free_result(eslint_result_t *result) {
    if (!result) {
        return;
    }
    
    if (result->file_path) {
        free(result->file_path);
    }
    
    if (result->diagnostics) {
        for (int i = 0; i < result->diagnostic_count; i++) {
            if (result->diagnostics[i].message) {
                free(result->diagnostics[i].message);
            }
            if (result->diagnostics[i].rule_id) {
                free(result->diagnostics[i].rule_id);
            }
        }
        free(result->diagnostics);
    }
    
    if (result->fixed_output) {
        free(result->fixed_output);
    }
    
    free(result);
}
