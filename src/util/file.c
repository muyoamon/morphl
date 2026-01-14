#include "util/file.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

bool morphl_file_read_all(const char* path, char** buffer, size_t* len) {
  if (!buffer) return false;
  *buffer = NULL;
  if (len) *len = 0;

  FILE* f = fopen(path, "rb");
  if (!f) return false;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return false;
  }
  long sz = ftell(f);
  if (sz < 0) {
    fclose(f);
    return false;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    return false;
  }

  char* data = (char*)malloc((size_t)sz + 1);
  if (!data) {
    fclose(f);
    return false;
  }
  size_t read = fread(data, 1, (size_t)sz, f);
  fclose(f);
  if (read != (size_t)sz) {
    free(data);
    return false;
  }
  data[sz] = '\0';
  *buffer = data;
  if (len) *len = (size_t)sz;
  return true;
}

const char* morphl_file_get_line(const char* path, size_t line_number) {
  if (!path || line_number == 0) return NULL;

  FILE* f = fopen(path, "r");
  if (!f) return NULL;

  char *result = NULL;
  char buffer[1024];
  size_t current_line = 1;
    
  while (fgets(buffer, sizeof(buffer), f)) {
    if (current_line == line_number) {
      // Remove trailing newline if present
      size_t len = strlen(buffer);
      if (len > 0 && buffer[len - 1] == '\n') {
        buffer[len - 1] = '\0';
      }
      
      result = strdup(buffer);
      break;
    }
    current_line++;
  }
    
  fclose(f);
  return result;
}
