#ifndef MORPHL_RUNTIME_RUNTIME_H_
#define MORPHL_RUNTIME_RUNTIME_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "interface/abi.h"
#include "backend/vm.h"

typedef struct MorphlVmProgram MorphlVmProgram;
typedef struct MorphlVm MorphlVm;
typedef struct MorphlNativeCtx MorphlNativeCtx;

/* ABI-level scalar storage aliases for morphl native modules. */
typedef int64_t   morphl_i64_t;
typedef double    morphl_f64_t;
typedef int64_t   morphl_bool_t;
typedef uintptr_t morphl_ref_t;
typedef uintptr_t morphl_str_handle_t;

#define MORPHL_I64  morphl_i64_t
#define MORPHL_F64  morphl_f64_t
#define MORPHL_BOOL morphl_bool_t
#define MORPHL_REF  morphl_ref_t
#define MORPHL_STR  morphl_str_handle_t

#define MORPHL_CONCAT_INNER(a, b) a##b
#define MORPHL_CONCAT(a, b) MORPHL_CONCAT_INNER(a, b)

#define MORPHL_ARG_PTR(stack, frame_base, offset) \
  ((uint8_t*)(stack) + ((frame_base) - (offset)))

#define MORPHL_RET_PTR_AS(type, ret_ptr) ((type*)(void*)(ret_ptr))

#define MORPHL_READ_ARG(type, stack, frame_base, offset) \
  MORPHL_CONCAT(morphl_read_arg_impl_, type)((stack), (frame_base), (offset))

#define MORPHL_WRITE_RET(type, ret_ptr, value) \
  MORPHL_CONCAT(morphl_write_ret_impl_, type)((ret_ptr), (value))

#define MORPHL_WRITE_RET_BYTES(ret_ptr, src, size) \
  memcpy((ret_ptr), (src), (size))

static inline morphl_i64_t morphl_read_arg_impl_morphl_i64_t(
    const uint8_t* stack, size_t frame_base, size_t offset) {
  morphl_i64_t value = 0;
  memcpy(&value, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(value));
  return value;
}

static inline morphl_f64_t morphl_read_arg_impl_morphl_f64_t(
    const uint8_t* stack, size_t frame_base, size_t offset) {
  morphl_f64_t value = 0.0;
  memcpy(&value, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(value));
  return value;
}

static inline morphl_bool_t morphl_read_arg_impl_morphl_bool_t(
    const uint8_t* stack, size_t frame_base, size_t offset) {
  morphl_bool_t value = 0;
  memcpy(&value, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(value));
  return value;
}

static inline morphl_ref_t morphl_read_arg_impl_morphl_ref_t(
    const uint8_t* stack, size_t frame_base, size_t offset) {
  morphl_ref_t value = 0;
  memcpy(&value, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(value));
  return value;
}

static inline morphl_str_handle_t morphl_read_arg_impl_morphl_str_handle_t(
    const uint8_t* stack, size_t frame_base, size_t offset) {
  morphl_str_handle_t value = 0;
  memcpy(&value, MORPHL_ARG_PTR(stack, frame_base, offset), sizeof(value));
  return value;
}

static inline void morphl_write_ret_impl_morphl_i64_t(uint8_t* ret_ptr,
                                                       morphl_i64_t value) {
  memcpy(ret_ptr, &value, sizeof(value));
}

static inline void morphl_write_ret_impl_morphl_f64_t(uint8_t* ret_ptr,
                                                       morphl_f64_t value) {
  memcpy(ret_ptr, &value, sizeof(value));
}

static inline void morphl_write_ret_impl_morphl_bool_t(uint8_t* ret_ptr,
                                                        morphl_bool_t value) {
  memcpy(ret_ptr, &value, sizeof(value));
}

static inline void morphl_write_ret_impl_morphl_ref_t(uint8_t* ret_ptr,
                                                       morphl_ref_t value) {
  memcpy(ret_ptr, &value, sizeof(value));
}

static inline void morphl_write_ret_impl_morphl_str_handle_t(
    uint8_t* ret_ptr, morphl_str_handle_t value) {
  memcpy(ret_ptr, &value, sizeof(value));
}

/**
 * Signature for native functions callable from morphl.
 *
 * @param ctx        Native runtime context for heap operations and cleanup registration.
 * @param stack      Raw VM stack byte buffer.
 * @param frame_base vm->stack.top at CALL time (points just past the last arg).
 * @param param_size Total bytes of arguments: args are at stack[frame_base-param_size..frame_base-1].
 * @param ret_ptr    Pointer to the caller-reserved return slot.
 * @param ret_size   Size in bytes of the declared morphl return type.
 * @return           true on success, false to raise a VM runtime error.
 */
typedef bool (*MorphlNativeFn)(MorphlNativeCtx* ctx,
                               uint8_t* stack, size_t frame_base, size_t param_size,
                               uint8_t* ret_ptr, size_t ret_size);

/**
 * Callback passed to morphl_module_register by the runtime.
 * Native modules call reg("symbol_name", fn_ptr) for each function they export.
 * Returns false if the registry is full (usually safe to ignore).
 */
typedef bool (*MorphlRegisterFn)(const char* name, MorphlNativeFn fn);

/**
 * Register a native function in the process-native registry.
 * Must be called before morphl_vm_program_load for the symbol to resolve.
 */
bool morphl_register_native(const char* name, MorphlNativeFn fn);

/**
 * Look up a previously registered native function by name.
 * Returns NULL if not found.
 */
MorphlNativeFn morphl_native_registry_lookup(const char* name);

bool morphl_native_heap_alloc(MorphlNativeCtx* ctx, size_t size,
                              morphl_ref_t* out_handle);
bool morphl_native_heap_free(MorphlNativeCtx* ctx, morphl_ref_t handle);
bool morphl_native_heap_read(MorphlNativeCtx* ctx, morphl_ref_t handle,
                             size_t offset, void* dst, size_t size);
bool morphl_native_heap_write(MorphlNativeCtx* ctx, morphl_ref_t handle,
                              size_t offset, const void* src, size_t size);
bool morphl_native_heap_size(MorphlNativeCtx* ctx, morphl_ref_t handle,
                             size_t* out_size);
bool morphl_native_set_cleanup(MorphlNativeCtx* ctx, morphl_ref_t handle,
                               uint32_t cleanup_fidx);

/// Load a MorphL VM bytecode program from disk (out.mbc format).
bool morphl_vm_program_load(const char* path, MorphlVmProgram** out_program);

/// Link one or more MorphL VM object files (.mplo) into one runnable executable (.mplx).
/// Returns false on parse/link/write failure.
bool morphl_vm_link_files(const char* out_path,
                          const char* const* input_paths,
                          size_t input_count,
                          FILE* err_stream);

/// Release memory associated with a loaded program.
void morphl_vm_program_free(MorphlVmProgram* program);

/// Build a VM instance that can execute the loaded program.
MorphlVm* morphl_vm_new(const MorphlVmProgram* program);

/// Destroy a VM instance.
void morphl_vm_free(MorphlVm* vm);

/// Execute bytecode in the VM. Returns exit code (0 for success, nonzero for error).
morphl_exit_code_t morphl_vm_execute(MorphlVm* vm, FILE* err_stream);

/// Convenience helper for load + execute + teardown.
/// argc/argv/envp are the process arguments forwarded to the program's $global frame.
morphl_exit_code_t morphl_vm_run_file(const char* path,
                                      int argc, char** argv, char** envp,
                                      FILE* err_stream);

/// Read an i64 from the raw byte stack at byte_offset after execution.
/// Returns false if out-of-bounds or arguments are NULL.
bool morphl_vm_read_stack_i64(const MorphlVm* vm, size_t byte_offset, int64_t* out);

/// Read an f64 from the raw byte stack at byte_offset after execution.
/// Returns false if out-of-bounds or arguments are NULL.
bool morphl_vm_read_stack_f64(const MorphlVm* vm, size_t byte_offset, double* out);

#endif // MORPHL_RUNTIME_RUNTIME_H_
