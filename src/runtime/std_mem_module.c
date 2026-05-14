/*
 * src/runtime/std_mem_module.c — companion native module for std/mem.mpl.
 */

#include "runtime/runtime.h"

#include <stdint.h>
#include <string.h>

static bool mem_write_ref_ret(uint8_t* ret_ptr, size_t ret_size,
                              morphl_ref_t value) {
  if (ret_size != sizeof(morphl_ref_t)) return false;
  MORPHL_WRITE_RET(morphl_ref_t, ret_ptr, value);
  return true;
}

static bool mem_native_malloc(MorphlNativeCtx* ctx, uint8_t* stack,
                              size_t frame_base, size_t param_size,
                              uint8_t* ret_ptr, size_t ret_size) {
  (void)param_size;
  MORPHL_I64 size = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  morphl_ref_t handle = 0;
  if (size <= 0) return mem_write_ref_ret(ret_ptr, ret_size, 0);
  if (!morphl_native_heap_alloc(ctx, (size_t)size, &handle)) {
    return mem_write_ref_ret(ret_ptr, ret_size, 0);
  }
  return mem_write_ref_ret(ret_ptr, ret_size, handle);
}

static bool mem_native_realloc(MorphlNativeCtx* ctx, uint8_t* stack,
                               size_t frame_base, size_t param_size,
                               uint8_t* ret_ptr, size_t ret_size) {
  (void)param_size;
  morphl_ref_t old_handle =
      MORPHL_READ_ARG(morphl_ref_t, stack, frame_base, 16);
  MORPHL_I64 new_size = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  morphl_ref_t new_handle = 0;
  size_t old_size = 0;
  size_t copy_size = 0;
  uint8_t chunk[256];

  if (new_size <= 0) {
    if (old_handle != 0 && !morphl_native_heap_free(ctx, old_handle)) return false;
    return mem_write_ref_ret(ret_ptr, ret_size, 0);
  }
  if (!morphl_native_heap_alloc(ctx, (size_t)new_size, &new_handle)) {
    return mem_write_ref_ret(ret_ptr, ret_size, 0);
  }
  if (old_handle != 0) {
    if (!morphl_native_heap_size(ctx, old_handle, &old_size)) return false;
    copy_size = old_size < (size_t)new_size ? old_size : (size_t)new_size;
    for (size_t off = 0; off < copy_size; off += sizeof(chunk)) {
      size_t n = copy_size - off;
      if (n > sizeof(chunk)) n = sizeof(chunk);
      if (!morphl_native_heap_read(ctx, old_handle, off, chunk, n) ||
          !morphl_native_heap_write(ctx, new_handle, off, chunk, n)) {
        return false;
      }
    }
    if (!morphl_native_heap_free(ctx, old_handle)) return false;
  }
  return mem_write_ref_ret(ret_ptr, ret_size, new_handle);
}

static bool mem_native_free(MorphlNativeCtx* ctx, uint8_t* stack,
                            size_t frame_base, size_t param_size,
                            uint8_t* ret_ptr, size_t ret_size) {
  (void)param_size;
  morphl_ref_t handle = MORPHL_READ_ARG(morphl_ref_t, stack, frame_base, 8);
  if (ret_size != 0 || ret_ptr == NULL) {
    return false;
  }
  if (handle == 0) return true;
  return morphl_native_heap_free(ctx, handle);
}

void morphl_module_register(MorphlRegisterFn reg) {
  reg("_native_malloc", mem_native_malloc);
  reg("_native_realloc", mem_native_realloc);
  reg("_native_free", mem_native_free);
}
