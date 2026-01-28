#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "eslint.h"
#include "lsp.h"
#include "util.h"
#include "workspace.h"

static bool should_exit = false;
static struct {
    char *pending_uri;
    char *pending_file_path;
    char *pending_content;
    struct timeval last_change_time;
    bool has_pending;
} debounce_state = {0};
#define DEBOUNCE_MS 300

void lsp_init(void) {
    log_info("LSP server starting...");
    eslint_init();
}

void lsp_send_response(int id, json_object *result) {
    json_object *response = json_object_new_object();

    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", json_object_new_int(id));
    json_object_object_add(response, "result", result);
    
    const char *json_str = json_object_to_json_string(response);

    printf("Content-Length: %zu\r\n\r\n%s", strlen(json_str), json_str);
    fflush(stdout);
    
    json_object_put(response);
}

void lsp_send_notification(const char *method, json_object *params) {
    json_object *notification = json_object_new_object();

    json_object_object_add(notification, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(notification, "method", json_object_new_string(method));

    if (params) {
        json_object_object_add(notification, "params", params);
    }
    
    const char *json_str = json_object_to_json_string(notification);

    printf("Content-Length: %zu\r\n\r\n%s", strlen(json_str), json_str);
    fflush(stdout);
    
    json_object_put(notification);
}

void lsp_send_error(int id, int code, const char *message) {
    json_object *error = json_object_new_object();

    json_object_object_add(error, "code", json_object_new_int(code));
    json_object_object_add(error, "message", json_object_new_string(message));
    
    json_object *response = json_object_new_object();

    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", json_object_new_int(id));
    json_object_object_add(response, "error", error);
    
    const char *json_str = json_object_to_json_string(response);

    printf("Content-Length: %zu\r\n\r\n%s", strlen(json_str), json_str);
    fflush(stdout);
    
    json_object_put(response);
}

lsp_message_t *lsp_read_message(void) {
    char header[256];
    size_t content_length = 0;

    while (fgets(header, sizeof(header), stdin)) {
        if (strcmp(header, "\r\n") == 0) {
            break;
        }

        if (strncmp(header, "Content-Length: ", 16) == 0) {
            content_length = atoi(header + 16);
        }
    }

    if (content_length == 0) {
        return NULL;
    }

    char *content = malloc(content_length + 1);

    if (!content) {
        return NULL;
    }

    size_t read = fread(content, 1, content_length, stdin);

    content[read] = '\0';

    log_debug("Received message: %s", content);

    json_object *root = json_tokener_parse(content);

    free(content);

    if (!root) {
        return NULL;
    }

    lsp_message_t *msg = calloc(1, sizeof(lsp_message_t));

    if (!msg) {
        json_object_put(root);

        return NULL;
    }

    json_object *jsonrpc_obj, *id_obj, *method_obj, *params_obj;

    if (json_object_object_get_ex(root, "jsonrpc", &jsonrpc_obj)) {
        msg->jsonrpc = str_dup(json_object_get_string(jsonrpc_obj));
    }

    if (json_object_object_get_ex(root, "id", &id_obj)) {
        msg->id = json_object_get_int(id_obj);
    }

    if (json_object_object_get_ex(root, "method", &method_obj)) {
        msg->method = str_dup(json_object_get_string(method_obj));
    }

    if (json_object_object_get_ex(root, "params", &params_obj)) {
        msg->params = json_object_get(params_obj);
    }

    json_object_put(root);

    return msg;
}

void lsp_free_message(lsp_message_t *msg) {
    if (!msg) {
        return;
    }

    if (msg->jsonrpc) {
        free(msg->jsonrpc);
    }

    if (msg->method) {
        free(msg->method);
    }

    if (msg->params) {
        json_object_put(msg->params);
    }

    if (msg->result) {
        json_object_put(msg->result);
    }

    if (msg->error) {
        json_object_put(msg->error);
    }

    free(msg);
}

void lsp_handle_initialize(lsp_message_t *msg) {
    json_object *params = msg->params;
    json_object *root_uri_obj;

    if (json_object_object_get_ex(params, "rootUri", &root_uri_obj)) {
        const char *root_uri = json_object_get_string(root_uri_obj);

        workspace_init(root_uri);
    }

    json_object *result = json_object_new_object();
    json_object *capabilities = json_object_new_object();
    json_object *text_doc_sync = json_object_new_object();

    json_object_object_add(text_doc_sync, "openClose", json_object_new_boolean(true));
    json_object_object_add(text_doc_sync, "change", json_object_new_int(1));
    json_object_object_add(text_doc_sync, "save", json_object_new_boolean(true));
    json_object_object_add(capabilities, "textDocumentSync", text_doc_sync);

    json_object *code_action_provider = json_object_new_object();
    json_object *code_action_kinds = json_object_new_array();

    json_object_array_add(code_action_kinds, json_object_new_string("quickfix"));
    json_object_object_add(code_action_provider, "codeActionKinds", code_action_kinds);
    json_object_object_add(capabilities, "codeActionProvider", code_action_provider);
    json_object_object_add(result, "capabilities", capabilities);

    json_object *server_info = json_object_new_object();

    json_object_object_add(server_info, "name", json_object_new_string("eslint-lang-server"));
    json_object_object_add(server_info, "version", json_object_new_string("0.1.0"));
    json_object_object_add(result, "serverInfo", server_info);

    lsp_send_response(msg->id, result);
}

void lsp_handle_initialized(lsp_message_t *msg) {
    (void)msg;
    log_info("Client initialized");
}

void lsp_handle_shutdown(lsp_message_t *msg) {
    lsp_send_response(msg->id, json_object_new_null());
    should_exit = true;
}

void lsp_handle_exit(lsp_message_t *msg) {
    (void)msg;
    exit(0);
}

static void publish_diagnostics(const char *uri, eslint_result_t *result) {
    json_object *params = json_object_new_object();

    json_object_object_add(params, "uri", json_object_new_string(uri));

    json_object *diagnostics = json_object_new_array();

    if (result && result->diagnostics) {
        for (int i = 0; i < result->diagnostic_count; i++) {
            eslint_diagnostic_t *diag = &result->diagnostics[i];
            json_object *diagnostic = json_object_new_object();
            json_object *range = json_object_new_object();
            json_object *start = json_object_new_object();
            json_object *end = json_object_new_object();

            json_object_object_add(start, "line", json_object_new_int(diag->line - 1));
            json_object_object_add(start, "character", json_object_new_int(diag->column - 1));
            json_object_object_add(end, "line", json_object_new_int(diag->end_line - 1));
            json_object_object_add(end, "character", json_object_new_int(diag->end_column - 1));
            json_object_object_add(range, "start", start);
            json_object_object_add(range, "end", end);
            json_object_object_add(diagnostic, "range", range);

            int lsp_severity = diag->severity == 2 ? 1 : 2;

            json_object_object_add(diagnostic, "severity", json_object_new_int(lsp_severity));
            json_object_object_add(diagnostic, "message", 
                                   json_object_new_string(diag->message ? diag->message : ""));
            json_object_object_add(diagnostic, "source", json_object_new_string("eslint"));

            if (diag->rule_id) {
                json_object_object_add(diagnostic, "code", json_object_new_string(diag->rule_id));
            }

            json_object_array_add(diagnostics, diagnostic);
        }
    }

    json_object_object_add(params, "diagnostics", diagnostics);
    lsp_send_notification("textDocument/publishDiagnostics", params);
}

void lsp_handle_text_document_did_open(lsp_message_t *msg) {
    json_object *text_doc_obj;

    if (!json_object_object_get_ex(msg->params, "textDocument", &text_doc_obj)) {
        return;
    }
    
    json_object *uri_obj, *text_obj;

    if (!json_object_object_get_ex(text_doc_obj, "uri", &uri_obj)) {
        return;
    }
    
    const char *uri = json_object_get_string(uri_obj);
    char *file_path = uri_to_path(uri);
    const char *text = NULL;

    if (json_object_object_get_ex(text_doc_obj, "text", &text_obj)) {
        text = json_object_get_string(text_obj);
    }
    
    log_debug("Document opened: %s", file_path);
    
    eslint_result_t *result = eslint_lint_file(file_path, text);

    publish_diagnostics(uri, result);
    eslint_free_result(result);
    
    free(file_path);
}

static long long get_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void clear_debounce_state(void) {
    if (debounce_state.pending_uri) {
        free(debounce_state.pending_uri);
        debounce_state.pending_uri = NULL;
    }

    if (debounce_state.pending_file_path) {
        free(debounce_state.pending_file_path);
        debounce_state.pending_file_path = NULL;
    }

    if (debounce_state.pending_content) {
        free(debounce_state.pending_content);
        debounce_state.pending_content = NULL;
    }

    debounce_state.has_pending = false;
}

static void run_pending_lint(void) {
    if (!debounce_state.has_pending) {
        return;
    }
    
    log_debug("Running debounced lint for: %s", debounce_state.pending_file_path);
    
    eslint_result_t *result = eslint_lint_file(
        debounce_state.pending_file_path,
        debounce_state.pending_content
    );

    publish_diagnostics(debounce_state.pending_uri, result);
    eslint_free_result(result);
    
    clear_debounce_state();
}

void lsp_handle_text_document_did_change(lsp_message_t *msg) {
    json_object *text_doc_obj;

    if (!json_object_object_get_ex(msg->params, "textDocument", &text_doc_obj)) {
        return;
    }

    json_object *uri_obj;

    if (!json_object_object_get_ex(text_doc_obj, "uri", &uri_obj)) {
        return;
    }

    const char *uri = json_object_get_string(uri_obj);
    char *file_path = uri_to_path(uri);
    const char *content = NULL;
    json_object *content_changes_obj;

    if (json_object_object_get_ex(msg->params, "contentChanges", &content_changes_obj)) {
        if (json_object_is_type(content_changes_obj, json_type_array) &&
            json_object_array_length(content_changes_obj) > 0) {
            json_object *first_change = json_object_array_get_idx(content_changes_obj, 0);
            json_object *text_obj;

            if (json_object_object_get_ex(first_change, "text", &text_obj)) {
                content = json_object_get_string(text_obj);
            }
        }
    }

    clear_debounce_state();

    debounce_state.pending_uri = str_dup(uri);
    debounce_state.pending_file_path = file_path;
    debounce_state.pending_content = content ? str_dup(content) : NULL;

    gettimeofday(&debounce_state.last_change_time, NULL);

    debounce_state.has_pending = true;

    log_debug("Document changed: %s (debounced)", file_path);
}

void lsp_handle_text_document_did_save(lsp_message_t *msg) {
    json_object *text_doc_obj;

    if (!json_object_object_get_ex(msg->params, "textDocument", &text_doc_obj)) {
        return;
    }
    
    json_object *uri_obj;

    if (!json_object_object_get_ex(text_doc_obj, "uri", &uri_obj)) {
        return;
    }
    
    const char *uri = json_object_get_string(uri_obj);
    char *file_path = uri_to_path(uri);
    
    log_debug("Document saved: %s", file_path);
    
    eslint_result_t *result = eslint_lint_file(file_path, NULL);

    publish_diagnostics(uri, result);
    eslint_free_result(result);
    
    free(file_path);
}

void lsp_handle_text_document_did_close(lsp_message_t *msg) {
    json_object *text_doc_obj;

    if (!json_object_object_get_ex(msg->params, "textDocument", &text_doc_obj)) {
        return;
    }

    json_object *uri_obj;

    if (!json_object_object_get_ex(text_doc_obj, "uri", &uri_obj)) {
        return;
    }

    const char *uri = json_object_get_string(uri_obj);

    publish_diagnostics(uri, NULL);
}

void lsp_handle_text_document_code_action(lsp_message_t *msg) {
    json_object *text_doc_obj;

    if (!json_object_object_get_ex(msg->params, "textDocument", &text_doc_obj)) {
        lsp_send_response(msg->id, json_object_new_array());

        return;
    }

    json_object *uri_obj;

    if (!json_object_object_get_ex(text_doc_obj, "uri", &uri_obj)) {
        lsp_send_response(msg->id, json_object_new_array());

        return;
    }

    const char *uri = json_object_get_string(uri_obj);
    char *file_path = uri_to_path(uri);
    json_object *actions = json_object_new_array();
    json_object *fix_all = json_object_new_object();

    json_object_object_add(fix_all, "title", json_object_new_string("Fix all ESLint issues"));
    json_object_object_add(fix_all, "kind", json_object_new_string("source.fixAll.eslint"));

    json_object *command = json_object_new_object();

    json_object_object_add(command, "title", json_object_new_string("Fix all"));
    json_object_object_add(command, "command", json_object_new_string("eslint.fixAll"));

    json_object *args = json_object_new_array();

    json_object_array_add(args, json_object_new_string(uri));
    json_object_object_add(command, "arguments", args);
    json_object_object_add(fix_all, "command", command);
    json_object_array_add(actions, fix_all);

    free(file_path);

    lsp_send_response(msg->id, actions);
}

void lsp_run(void) {
    while (!should_exit) {
        if (debounce_state.has_pending) {
            long long now = get_time_ms();
            struct timeval last_tv = debounce_state.last_change_time;
            long long last_ms = (long long)last_tv.tv_sec * 1000 + last_tv.tv_usec / 1000;
            long long elapsed = now - last_ms;

            if (elapsed >= DEBOUNCE_MS) {
                run_pending_lint();
            }
        }

        fd_set readfds;

        FD_ZERO(&readfds);
        FD_SET(STDIN_FILENO, &readfds);

        struct timeval timeout;

        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;

        int ready = select(STDIN_FILENO + 1, &readfds, NULL, NULL, &timeout);

        if (ready <= 0) {
            continue;
        }

        lsp_message_t *msg = lsp_read_message();

        if (!msg) {
            continue;
        }

        log_debug("Handling method: %s", msg->method);

        if (msg->method) {
            if (strcmp(msg->method, "initialize") == 0) {
                lsp_handle_initialize(msg);
            } else if (strcmp(msg->method, "initialized") == 0) {
                lsp_handle_initialized(msg);
            } else if (strcmp(msg->method, "shutdown") == 0) {
                lsp_handle_shutdown(msg);
            } else if (strcmp(msg->method, "exit") == 0) {
                lsp_handle_exit(msg);
            } else if (strcmp(msg->method, "textDocument/didOpen") == 0) {
                lsp_handle_text_document_did_open(msg);
            } else if (strcmp(msg->method, "textDocument/didChange") == 0) {
                lsp_handle_text_document_did_change(msg);
            } else if (strcmp(msg->method, "textDocument/didSave") == 0) {
                lsp_handle_text_document_did_save(msg);
            } else if (strcmp(msg->method, "textDocument/didClose") == 0) {
                lsp_handle_text_document_did_close(msg);
            } else if (strcmp(msg->method, "textDocument/codeAction") == 0) {
                lsp_handle_text_document_code_action(msg);
            }
        }

        lsp_free_message(msg);
    }

    workspace_cleanup();
}
