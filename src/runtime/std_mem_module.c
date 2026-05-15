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
  morphl_ref_t arg0 = MORPHL_READ_ARG(morphl_ref_t, stack, frame_base, 16);
  MORPHL_I64 arg1 = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  morphl_ref_t old_handle = arg0;
  MORPHL_I64 new_size = arg1;
  morphl_ref_t new_handle = 0;
  size_t old_size = 0;
  size_t copy_size = 0;
  uint8_t chunk[256];

  if (arg0 != 0 && !morphl_native_heap_size(ctx, arg0, &old_size)) {
    old_handle = (morphl_ref_t)arg1;
    new_size = (MORPHL_I64)arg0;
    old_size = 0;
  }

  if (new_size <= 0) {
    if (old_handle != 0 && !morphl_native_heap_free(ctx, old_handle)) return false;
    return mem_write_ref_ret(ret_ptr, ret_size, 0);
  }
  if (!morphl_native_heap_alloc(ctx, (size_t)new_size, &new_handle)) {
    return mem_write_ref_ret(ret_ptr, ret_size, 0);
  }
  if (old_handle != 0) {
    if (old_size == 0 && !morphl_native_heap_size(ctx, old_handle, &old_size)) return false;
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

static bool mem_native_read_value(MorphlNativeCtx* ctx, uint8_t* stack,
                                  size_t frame_base, size_t param_size,
                                  uint8_t* ret_ptr, size_t ret_size) {
  (void)param_size;
  morphl_ref_t handle = MORPHL_READ_ARG(morphl_ref_t, stack, frame_base, 16);
  MORPHL_I64 byte_offset = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
  if (byte_offset < 0) return false;
  if (ret_size == 0) return true;
  return morphl_native_heap_read(ctx, handle, (size_t)byte_offset, ret_ptr,
                                 ret_size);
}

static bool mem_native_write_value(MorphlNativeCtx* ctx, uint8_t* stack,
                                   size_t frame_base, size_t param_size,
                                   uint8_t* ret_ptr, size_t ret_size) {
  if (param_size < 16 || ret_size != sizeof(MORPHL_I64)) return false;
  size_t value_size = param_size - 16;
  morphl_ref_t handle =
      MORPHL_READ_ARG(morphl_ref_t, stack, frame_base, value_size + 16);
  MORPHL_I64 byte_offset =
      MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, value_size + 8);
  const uint8_t* value = MORPHL_ARG_PTR(stack, frame_base, value_size);
  MORPHL_I64 ok = 0;
  if (byte_offset >= 0 &&
      morphl_native_heap_write(ctx, handle, (size_t)byte_offset, value,
                               value_size)) {
    ok = 1;
  }
  MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, ok);
  return true;
}

void morphl_module_register(MorphlRegisterFn reg) {
  reg("_native_malloc", mem_native_malloc);
  reg("_native_realloc", mem_native_realloc);
  reg("_native_free", mem_native_free);
  reg("_native_read_value", mem_native_read_value);
  reg("_native_write_value", mem_native_write_value);
}
