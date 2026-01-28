#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <ctype.h>
#include <libgen.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "util.h"

char *str_dup(const char *str) {
    if (!str) {
        return NULL;
    }

    return strdup(str);
}

char *str_concat(const char *s1, const char *s2) {
    if (!s1 || !s2) {
        return NULL;
    }

    size_t len = strlen(s1) + strlen(s2) + 1;
    char *result = malloc(len);

    if (!result) {
        return NULL;
    }

    strcpy(result, s1);
    strcat(result, s2);

    return result;
}

char *str_trim(char *str) {
    if (!str) {
        return NULL;
    }

    while (isspace((unsigned char)*str)) {
        str++;
    }

    if (*str == 0) {
        return str;
    }

    char *end = str + strlen(str) - 1;

    while (end > str && isspace((unsigned char)*end)) {
        end--;
    }

    end[1] = '\0';

    return str;
}

bool str_starts_with(const char *str, const char *prefix) {
    if (!str || !prefix) {
        return false;
    }

    return strncmp(str, prefix, strlen(prefix)) == 0;
}

bool str_ends_with(const char *str, const char *suffix) {
    if (!str || !suffix) {
        return false;
    }

    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);

    if (suffix_len > str_len) {
        return false;
    }

    return strcmp(str + str_len - suffix_len, suffix) == 0;
}

char *path_join(const char *p1, const char *p2) {
    if (!p1 || !p2) {
        return NULL;
    }

    size_t len = strlen(p1) + strlen(p2) + 2;
    char *result = malloc(len);

    if (!result) {
        return NULL;
    }
    
    strcpy(result, p1);

    if (!str_ends_with(p1, "/")) {
        strcat(result, "/");
    }

    strcat(result, p2);

    return result;
}

char *path_dirname(const char *path) {
    if (!path) {
        return NULL;
    }

    char *tmp = str_dup(path);
    char *dir = dirname(tmp);
    char *result = str_dup(dir);

    free(tmp);

    return result;
}

char *path_basename(const char *path) {
    if (!path) {
        return NULL;
    }

    char *tmp = str_dup(path);
    char *base = basename(tmp);
    char *result = str_dup(base);

    free(tmp);

    return result;
}

bool path_exists(const char *path) {
    if (!path) {
        return false;
    }

    return access(path, F_OK) == 0;
}

bool path_is_directory(const char *path) {
    if (!path) {
        return false;
    }

    struct stat st;

    if (stat(path, &st) != 0) {
        return false;
    }

    return S_ISDIR(st.st_mode);
}

bool path_is_file(const char *path) {
    if (!path) {
        return false;
    }

    struct stat st;

    if (stat(path, &st) != 0) {
        return false;
    }

    return S_ISREG(st.st_mode);
}

char *path_resolve(const char *path) {
    if (!path) {
        return NULL;
    }

    char *resolved = realpath(path, NULL);

    return resolved;
}

char *file_read_all(const char *path) {
    if (!path) {
        return NULL;
    }

    FILE *f = fopen(path, "rb");

    if (!f) {
        return NULL;
    }
    
    fseek(f, 0, SEEK_END);

    long size = ftell(f);

    fseek(f, 0, SEEK_SET);
    
    char *content = malloc(size + 1);

    if (!content) {
        fclose(f);

        return NULL;
    }
    
    size_t read = fread(content, 1, size, f);

    content[read] = '\0';

    fclose(f);

    return content;
}

bool file_write_all(const char *path, const char *content) {
    if (!path || !content) {
        return false;
    }

    FILE *f = fopen(path, "wb");

    if (!f) {
        return false;
    }
    
    size_t len = strlen(content);
    size_t written = fwrite(content, 1, len, f);

    fclose(f);

    return written == len;
}

char *uri_to_path(const char *uri) {
    if (!uri) {
        return NULL;
    }
    
    if (str_starts_with(uri, "file://")) {
        const char *path = uri + 7;

        return str_dup(path);
    }
    
    return str_dup(uri);
}

char *path_to_uri(const char *path) {
    if (!path) {
        return NULL;
    }
    
    size_t len = strlen(path) + 8;
    char *uri = malloc(len);

    if (!uri) {
        return NULL;
    }
    
    snprintf(uri, len, "file://%s", path);

    return uri;
}

void log_debug(const char *format, ...) {
#ifdef DEBUG
    va_list args;
    va_start(args, format);
    fprintf(stderr, "[DEBUG] ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
#else
    (void)format;
#endif
}

void log_info(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "[INFO] ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
}

void log_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "[ERROR] ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
}
