#include "util/fs.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

#define MAX_PATH 4096

typedef struct {
  char path[MAX_PATH];
  struct stat st;
} fs_context_t;

bool fs_path_exists(const char *path) {
  if (path == NULL || strlen(path) >= MAX_PATH) {
    return false;
  }
#ifdef _WIN32
  DWORD attrib = GetFileAttributesA(path);
  return (attrib != INVALID_FILE_ATTRIBUTES);
#else
  return access(path, F_OK) == 0;
#endif
}

bool fs_is_directory(const char *path) {
  if (path == NULL || strlen(path) >= MAX_PATH) {
    return false;
  }
#ifdef _WIN32
  DWORD attrib = GetFileAttributesA(path);
  if (attrib == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  return (attrib & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
  struct stat st;
  if (stat(path, &st) != 0) {
    return false;
  }
  return S_ISDIR(st.st_mode);
#endif
}

bool fs_is_relative_path(const char *path) {
  if (path == NULL || path[0] == '\0') {
    return true;
  }
#ifdef _WIN32
  return path[0] != '\\' && path[0] != '/' && !(path[1] == ':');
#else
  return path[0] != '/';
#endif
}

Str fs_get_absolute_path_from_source(const char *path,
                                     const char *source_file) {
  if (path == NULL || source_file == NULL) {
    return str_from(NULL, 0);
  }

  char abs_path[MAX_PATH];
#ifdef _WIN32
  if (fs_is_relative_path(path)) {
    char source_dir[MAX_PATH];
    strncpy(source_dir, source_file, MAX_PATH);
    char *last_sep = strrchr(source_dir, '\\');
    if (last_sep) {
      *last_sep = '\0';
    }
    snprintf(abs_path, MAX_PATH, "%s\\%s", source_dir, path);
  } else {
    strncpy(abs_path, path, MAX_PATH);
  }
#else
  if (fs_is_relative_path(path)) {
    char source_dir[MAX_PATH];
    strncpy(source_dir, source_file, MAX_PATH);
    char *last_sep = strrchr(source_dir, '/');
    if (last_sep) {
      *last_sep = '\0';
    }
    if (strlen(source_dir) + strlen(path) + 2 > MAX_PATH) {
      return str_from(NULL, 0);
    }
    #pragma GCC diagnostic push
    #pragma GCC diagnostic ignored "-Wformat-truncation"
    snprintf(abs_path, MAX_PATH, "%s/%s", source_dir, path);
    #pragma GCC diagnostic pop
  } else {
    strncpy(abs_path, path, MAX_PATH);
  }
#endif

  // Normalize the path (remove ., .. etc.) - platform dependent
  // For simplicity, we skip this step in this implementation

  return str_from(strdup(abs_path), strlen(abs_path));
}
