#ifndef MORPHL_UTIL_FS_H_
#define MORPHL_UTIL_FS_H_

#include <stdbool.h>
#include "util/util.h"


/// @brief Check if a given path exists in the filesystem.
/// @param path The path to check.
/// @return true if the path exists, false otherwise.
bool fs_path_exists(const char* path);

/// @brief Check if a given path is a directory.
/// @param path The path to check.
/// @return true if the path is a directory, false otherwise.
bool fs_is_directory(const char* path);


/// @brief Check if a given path is a relative path.
/// @param path The path to check.
/// @return true if the path is relative, false if absolute.
bool fs_is_relative_path(const char* path);

/// @brief Get the absolute path of a given path relative to a source file.
/// @param path The relative or absolute path.
/// @param source_file The source file to resolve relative paths against.
/// @return The absolute path as a Str.
Str fs_get_absolute_path_from_source(const char* path, const char* source_file);

#endif // MORPHL_UTIL_FS_H_