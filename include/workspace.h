#ifndef WORKSPACE_H
#define WORKSPACE_H

#include <stdbool.h>

typedef struct {
    char *root_path;
    char **workspace_folders;
    int workspace_count;
    bool is_pnpm_workspace;
} workspace_t;

void workspace_init(const char *root_uri);
char *workspace_get_root_for_file(const char *file_path);
bool workspace_is_pnpm_workspace(const char *path);
char *workspace_find_pnpm_root(const char *file_path);
char *workspace_find_eslint_binary(const char *workspace_root);
char *workspace_find_package_root(const char *file_path);
void workspace_cleanup(void);

#endif
