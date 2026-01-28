#ifndef UTIL_H
#define UTIL_H

#include <stdbool.h>
#include <stddef.h>

char *str_dup(const char *str);
char *str_concat(const char *s1, const char *s2);
char *str_trim(char *str);
bool str_starts_with(const char *str, const char *prefix);
bool str_ends_with(const char *str, const char *suffix);
char *path_join(const char *p1, const char *p2);
char *path_dirname(const char *path);
char *path_basename(const char *path);
bool path_exists(const char *path);
bool path_is_directory(const char *path);
bool path_is_file(const char *path);
char *path_resolve(const char *path);
char *file_read_all(const char *path);
bool file_write_all(const char *path, const char *content);
char *uri_to_path(const char *uri);
char *path_to_uri(const char *path);
void log_debug(const char *format, ...);
void log_info(const char *format, ...);
void log_error(const char *format, ...);

#endif
