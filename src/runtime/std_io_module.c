/*
 * src/runtime/std_io_module.c — companion native module for std/io.mpl.
 */

#include "runtime/runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  MORPHL_I64 handle;
  MORPHL_I64 owned;
  MORPHL_I64 ok;
} MorphlIoFile;

typedef struct {
  MORPHL_STR text;
  MORPHL_I64 len;
  MORPHL_I64 raw;
  MORPHL_I64 ok;
} MorphlIoLine;

typedef struct {
  uintptr_t* items;
  size_t count;
  size_t capacity;
} PtrRegistry;

static PtrRegistry closed_files_g = {0};
static PtrRegistry freed_lines_g = {0};

static bool ptr_registry_contains(const PtrRegistry* registry, uintptr_t value) {
  if (!registry || value == 0) return false;
  for (size_t i = 0; i < registry->count; ++i) {
    if (registry->items[i] == value) return true;
  }
  return false;
}

static bool ptr_registry_add(PtrRegistry* registry, uintptr_t value) {
  if (!registry || value == 0) return false;
  if (ptr_registry_contains(registry, value)) return true;
  if (registry->count >= registry->capacity) {
    size_t new_capacity = registry->capacity ? registry->capacity * 2 : 16;
    uintptr_t* new_items =
        (uintptr_t*)realloc(registry->items, new_capacity * sizeof(uintptr_t));
    if (!new_items) return false;
    registry->items = new_items;
    registry->capacity = new_capacity;
  }
  registry->items[registry->count++] = value;
  return true;
}

static void ptr_registry_remove(PtrRegistry* registry, uintptr_t value) {
  if (!registry || value == 0) return;
  for (size_t i = 0; i < registry->count; ++i) {
    if (registry->items[i] == value) {
      registry->items[i] = registry->items[registry->count - 1];
      registry->count -= 1;
      return;
    }
  }
}

static bool write_i64_ret(uint8_t* ret_ptr, size_t ret_size, MORPHL_I64 value) {
  if (ret_size != sizeof(MORPHL_I64)) return false;
  MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, value);
  return true;
}

static bool write_file_ret(uint8_t* ret_ptr, size_t ret_size,
                           MorphlIoFile value) {
  if (ret_size != sizeof(MorphlIoFile)) return false;
  MORPHL_WRITE_RET_BYTES(ret_ptr, &value, sizeof(value));
  return true;
}

static bool write_line_ret(uint8_t* ret_ptr, size_t ret_size,
                           MorphlIoLine value) {
  if (ret_size != sizeof(MorphlIoLine)) return false;
  MORPHL_WRITE_RET_BYTES(ret_ptr, &value, sizeof(value));
  return true;
}

static bool read_file_arg(const uint8_t* stack, size_t frame_base,
                          size_t offset, MorphlIoFile* out) {
  if (!stack || !out) return false;
  memcpy(out, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(*out));
  return true;
}

static FILE* io_file_ptr(MorphlIoFile file) {
  return (FILE*)(uintptr_t)file.handle;
}

static bool io_file_is_active(MorphlIoFile file) {
  uintptr_t handle = (uintptr_t)file.handle;
  return file.ok && handle != 0 && !ptr_registry_contains(&closed_files_g, handle);
}

static MorphlIoFile make_file(FILE* stream, MORPHL_I64 owned) {
  MorphlIoFile file = {0};
  if (stream) {
    uintptr_t handle = (uintptr_t)stream;
    file.handle = (MORPHL_I64)handle;
    file.owned = owned;
    file.ok = 1;
    ptr_registry_remove(&closed_files_g, handle);
  }
  return file;
}

static MorphlIoLine make_invalid_line(void) {
  MorphlIoLine line = {0};
  line.len = -1;
  return line;
}

static MORPHL_I64 io_write_text(FILE* stream, const char* text, bool newline) {
  size_t text_len = text ? strlen(text) : 0;
  size_t written = 0;
  if (!stream) return -1;
  if (text_len > 0) {
    written = fwrite(text, 1, text_len, stream);
    if (written != text_len) return -1;
  }
  if (newline) {
    if (fputc('\n', stream) == EOF) return -1;
    written += 1;
  }
  return (MORPHL_I64)written;
}

static MORPHL_I64 io_close_fields(MORPHL_I64 handle, MORPHL_I64 owned,
                                  MORPHL_I64 ok) {
  uintptr_t raw_handle = (uintptr_t)handle;
  if (!ok || raw_handle == 0) return 0;
  if (!owned) return 0;
  if (ptr_registry_contains(&closed_files_g, raw_handle)) return 0;
  if (!ptr_registry_add(&closed_files_g, raw_handle)) return -1;
  return fclose((FILE*)raw_handle) == 0 ? 0 : -1;
}

static MORPHL_I64 io_free_line_raw(MORPHL_I64 raw) {
  uintptr_t ptr = (uintptr_t)raw;
  if (ptr == 0) return 0;
  if (ptr_registry_contains(&freed_lines_g, ptr)) return 0;
  if (!ptr_registry_add(&freed_lines_g, ptr)) return -1;
  free((void*)ptr);
  return 0;
}

static bool io_stdout_file(MorphlNativeCtx* ctx, uint8_t* stack,
                           size_t frame_base, size_t param_size,
                           uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)stack;
  (void)frame_base;
  (void)param_size;
  return write_file_ret(ret_ptr, ret_size, make_file(stdout, 0));
}

static bool io_stderr_file(MorphlNativeCtx* ctx, uint8_t* stack,
                           size_t frame_base, size_t param_size,
                           uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)stack;
  (void)frame_base;
  (void)param_size;
  return write_file_ret(ret_ptr, ret_size, make_file(stderr, 0));
}

static bool io_stdin_file(MorphlNativeCtx* ctx, uint8_t* stack,
                          size_t frame_base, size_t param_size,
                          uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)stack;
  (void)frame_base;
  (void)param_size;
  return write_file_ret(ret_ptr, ret_size, make_file(stdin, 0));
}

static bool io_open_file(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                         size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  const char* path =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 16);
  const char* mode =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  FILE* opened = (path && mode) ? fopen(path, mode) : NULL;
  return write_file_ret(ret_ptr, ret_size, make_file(opened, opened ? 1 : 0));
}

static bool io_close_file(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                          size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MorphlIoFile file = {0};
  if (!read_file_arg(stack, frame_base, sizeof(MorphlIoFile), &file)) return false;
  return write_i64_ret(ret_ptr, ret_size,
                       io_close_fields(file.handle, file.owned, file.ok));
}

static bool io_close_file_fields_native(MorphlNativeCtx* ctx, uint8_t* stack,
                                        size_t frame_base, size_t param_size,
                                        uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MORPHL_I64 handle = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 24);
  MORPHL_I64 owned = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 16);
  MORPHL_I64 ok = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size, io_close_fields(handle, owned, ok));
}

static bool io_write_file(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                          size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MorphlIoFile file = {0};
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  if (!read_file_arg(stack, frame_base, sizeof(MorphlIoFile) + sizeof(MORPHL_STR),
                     &file))
    return false;
  return write_i64_ret(
      ret_ptr, ret_size,
      io_file_is_active(file) ? io_write_text(io_file_ptr(file), text, false) : -1);
}

static bool io_writeln_file(MorphlNativeCtx* ctx, uint8_t* stack,
                            size_t frame_base, size_t param_size,
                            uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MorphlIoFile file = {0};
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  if (!read_file_arg(stack, frame_base, sizeof(MorphlIoFile) + sizeof(MORPHL_STR),
                     &file))
    return false;
  return write_i64_ret(
      ret_ptr, ret_size,
      io_file_is_active(file) ? io_write_text(io_file_ptr(file), text, true) : -1);
}

static bool io_flush_file(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                          size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MorphlIoFile file = {0};
  if (!read_file_arg(stack, frame_base, sizeof(MorphlIoFile), &file)) return false;
  return write_i64_ret(
      ret_ptr, ret_size,
      (io_file_is_active(file) && fflush(io_file_ptr(file)) == 0) ? 0 : -1);
}

static bool io_read_line(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                         size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MorphlIoFile file = {0};
  char* buf = NULL;
  size_t cap = 0;
  ssize_t nread = -1;
  if (!read_file_arg(stack, frame_base, sizeof(MorphlIoFile), &file)) return false;
  if (!io_file_is_active(file)) {
    return write_line_ret(ret_ptr, ret_size, make_invalid_line());
  }
  nread = getline(&buf, &cap, io_file_ptr(file));
  if (nread < 0) {
    free(buf);
    return write_line_ret(ret_ptr, ret_size, make_invalid_line());
  }
  while (nread > 0 &&
         (buf[nread - 1] == '\n' || buf[nread - 1] == '\r')) {
    buf[--nread] = '\0';
  }
  ptr_registry_remove(&freed_lines_g, (uintptr_t)buf);
  return write_line_ret(ret_ptr, ret_size,
                        (MorphlIoLine){
                            .text = (MORPHL_STR)(uintptr_t)buf,
                            .len = (MORPHL_I64)nread,
                            .raw = (MORPHL_I64)(uintptr_t)buf,
                            .ok = 1,
                        });
}

static bool io_free_line_raw_native(MorphlNativeCtx* ctx, uint8_t* stack,
                                    size_t frame_base, size_t param_size,
                                    uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MORPHL_I64 raw = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size, io_free_line_raw(raw));
}

static bool io_print_int(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                         size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  MORPHL_I64 n = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  printf("%lld", (long long)n);
  return write_i64_ret(ret_ptr, ret_size, 0);
}

static bool io_print(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                     size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size,
                       io_write_text(stdout, text, false) < 0 ? -1 : 0);
}

static bool io_println(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                       size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size,
                       io_write_text(stdout, text, true) < 0 ? -1 : 0);
}

static bool io_eprint(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                      size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size,
                       io_write_text(stderr, text, false) < 0 ? -1 : 0);
}

static bool io_eprintln(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                        size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
  (void)ctx;
  (void)param_size;
  const char* text =
      (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
  return write_i64_ret(ret_ptr, ret_size,
                       io_write_text(stderr, text, true) < 0 ? -1 : 0);
}

void morphl_module_register(MorphlRegisterFn reg) {
  reg("stdout_file", io_stdout_file);
  reg("stderr_file", io_stderr_file);
  reg("stdin_file", io_stdin_file);
  reg("open_file", io_open_file);
  reg("close_file", io_close_file);
  reg("close_file_fields", io_close_file_fields_native);
  reg("write_file", io_write_file);
  reg("writeln_file", io_writeln_file);
  reg("flush_file", io_flush_file);
  reg("read_line", io_read_line);
  reg("free_line_raw", io_free_line_raw_native);
  reg("print", io_print);
  reg("println", io_println);
  reg("print_int", io_print_int);
  reg("eprint", io_eprint);
  reg("eprintln", io_eprintln);
}
