#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "util.h"
#include "workspace.h"

static workspace_t workspace = {0};

void workspace_init(const char *root_uri) {
    if (!root_uri) {
        return;
    }
    
    workspace.root_path = uri_to_path(root_uri);
    workspace.is_pnpm_workspace = workspace_is_pnpm_workspace(workspace.root_path);
    
    log_info("Workspace initialized: %s (pnpm: %s)", 
             workspace.root_path, 
             workspace.is_pnpm_workspace ? "yes" : "no");
}

char *workspace_get_root_for_file(const char *file_path) {
    if (!file_path) {
        return NULL;
    }

    char *pnpm_root = workspace_find_pnpm_root(file_path);

    if (pnpm_root) {
        return pnpm_root;
    }

    char *dir = path_dirname(file_path);
    char *current = str_dup(dir);

    free(dir);

    while (current && strlen(current) > 1) {
        char *package_json = path_join(current, "package.json");

        if (path_exists(package_json)) {
            free(package_json);

            return current;
        }

        free(package_json);

        char *parent = path_dirname(current);

        free(current);

        current = parent;
    }

    free(current);

    return workspace.root_path ? str_dup(workspace.root_path) : NULL;
}

bool workspace_is_pnpm_workspace(const char *path) {
    if (!path) {
        return false;
    }

    char *workspace_yaml = path_join(path, "pnpm-workspace.yaml");
    bool exists = path_exists(workspace_yaml);

    free(workspace_yaml);

    if (exists) {
        return true;
    }

    char *lock_file = path_join(path, "pnpm-lock.yaml");

    exists = path_exists(lock_file);

    free(lock_file);

    return exists;
}

char *workspace_find_pnpm_root(const char *file_path) {
    if (!file_path) {
        return NULL;
    }

    char *dir = path_dirname(file_path);
    char *current = str_dup(dir);

    free(dir);

    while (current && strlen(current) > 1) {
        if (workspace_is_pnpm_workspace(current)) {
            return current;
        }

        char *parent = path_dirname(current);

        free(current);

        current = parent;
    }

    free(current);

    return NULL;
}

char *workspace_find_eslint_binary(const char *workspace_root) {
    if (!workspace_root) {
        return NULL;
    }

    char *eslint_d_path = path_join(workspace_root, "node_modules/.bin/eslint_d");

    if (path_exists(eslint_d_path)) {
        log_info("Using local eslint_d from node_modules (fast daemon mode!)");

        return eslint_d_path;
    }

    free(eslint_d_path);

    if (system("command -v eslint_d > /dev/null 2>&1") == 0) {
        log_info("Using system eslint_d from PATH (fast daemon mode!)");

        return str_dup("eslint_d");
    }

    char *bin_path = path_join(workspace_root, "node_modules/.bin/eslint");

    if (path_exists(bin_path)) {
        log_info("Using local eslint from node_modules");

        return bin_path;
    }

    free(bin_path);

    char *pnpm_bin = path_join(workspace_root, ".pnpm/node_modules/.bin/eslint");

    if (path_exists(pnpm_bin)) {
        log_info("Using eslint from .pnpm");

        return pnpm_bin;
    }

    free(pnpm_bin);

    log_info("Using system eslint from PATH (slower)");

    return str_dup("eslint");
}

char *workspace_find_package_root(const char *file_path) {
    if (!file_path) {
        return NULL;
    }

    char *dir = path_dirname(file_path);
    char *current = str_dup(dir);

    free(dir);

    while (current && strlen(current) > 1) {
        char *package_json = path_join(current, "package.json");

        if (path_exists(package_json)) {
            free(package_json);

            log_debug("Found package root: %s", current);

            return current;
        }

        free(package_json);

        char *parent = path_dirname(current);
        char *workspace_yaml = path_join(parent, "pnpm-workspace.yaml");
        bool at_workspace_root = path_exists(workspace_yaml);

        free(workspace_yaml);
        free(current);

        current = parent;

        if (at_workspace_root) {
            free(current);

            return NULL;
        }
    }

    free(current);

    return NULL;
}

void workspace_cleanup(void) {
    if (workspace.root_path) {
        free(workspace.root_path);
        workspace.root_path = NULL;
    }

    if (workspace.workspace_folders) {
        for (int i = 0; i < workspace.workspace_count; i++) {
            free(workspace.workspace_folders[i]);
        }

        free(workspace.workspace_folders);
        workspace.workspace_folders = NULL;
    }

    workspace.workspace_count = 0;
    workspace.is_pnpm_workspace = false;
}
