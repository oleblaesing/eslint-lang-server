#ifndef ESLINT_H
#define ESLINT_H

#include <json-c/json.h>
#include <stdbool.h>

typedef struct {
    int line;
    int column;
    int end_line;
    int end_column;
    int severity; // 1 = warning, 2 = error
    char *message;
    char *rule_id;
    bool fixable;
} eslint_diagnostic_t;

typedef struct {
    char *file_path;
    eslint_diagnostic_t *diagnostics;
    int diagnostic_count;
    char *fixed_output;
} eslint_result_t;

void eslint_init(void);
eslint_result_t *eslint_lint_file(const char *file_path, const char *content);
eslint_result_t *eslint_fix_file(const char *file_path);
void eslint_free_result(eslint_result_t *result);
char *eslint_find_binary(const char *file_path);
char *eslint_find_workspace_root(const char *file_path);

#endif
