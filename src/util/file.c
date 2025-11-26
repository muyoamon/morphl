#include "util/file.h"

#include <stdio.h>
#include <stdlib.h>

bool file_read_all(const char* path, char** buffer, size_t* len) {
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
