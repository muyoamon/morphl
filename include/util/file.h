#ifndef MORPHL_UTIL_FILE_H_
#define MORPHL_UTIL_FILE_H_

#include <stdbool.h>
#include <stddef.h>

// Read the entire file into a newly allocated, null-terminated buffer.
// The caller owns the returned buffer and must free it with free().
bool file_read_all(const char* path, char** buffer, size_t* len);

#endif // MORPHL_UTIL_FILE_H_
