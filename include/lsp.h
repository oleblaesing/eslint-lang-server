#ifndef LSP_H
#define LSP_H

#include <json-c/json.h>
#include <stdbool.h>

typedef struct {
    char *jsonrpc;
    int id;
    char *method;
    json_object *params;
    json_object *result;
    json_object *error;
} lsp_message_t;

void lsp_init(void);
void lsp_run(void);
void lsp_send_response(int id, json_object *result);
void lsp_send_notification(const char *method, json_object *params);
void lsp_send_error(int id, int code, const char *message);
lsp_message_t *lsp_read_message(void);
void lsp_free_message(lsp_message_t *msg);
void lsp_handle_initialize(lsp_message_t *msg);
void lsp_handle_initialized(lsp_message_t *msg);
void lsp_handle_shutdown(lsp_message_t *msg);
void lsp_handle_exit(lsp_message_t *msg);
void lsp_handle_text_document_did_open(lsp_message_t *msg);
void lsp_handle_text_document_did_change(lsp_message_t *msg);
void lsp_handle_text_document_did_save(lsp_message_t *msg);
void lsp_handle_text_document_did_close(lsp_message_t *msg);
void lsp_handle_text_document_code_action(lsp_message_t *msg);

#endif
