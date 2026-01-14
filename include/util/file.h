#ifndef MORPHL_UTIL_FILE_H_
#define MORPHL_UTIL_FILE_H_

#include <stdbool.h>
#include <stddef.h>

// Read the entire file into a newly allocated, null-terminated buffer.
// The caller owns the returned buffer and must free it with free().
bool morphl_file_read_all(const char* path, char** buffer, size_t* len);

/// @brief Dynamically allocate a specific line from a file.
/// @param path The path to the file.
/// @param line_number The line number to retrieve (1-based).
/// @return A pointer to the line string, or NULL if not found.
const char* morphl_file_get_line(const char* path, size_t line_number);

#endif // MORPHL_UTIL_FILE_H_
