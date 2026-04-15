#ifndef MORPHL_RUNTIME_RUNTIME_H_
#define MORPHL_RUNTIME_RUNTIME_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "interface/abi.h"
#include "backend/vm.h"

typedef struct MorphlVmProgram MorphlVmProgram;
typedef struct MorphlVm MorphlVm;

/**
 * Signature for native functions callable from morphl.
 *
 * @param stack      Raw VM stack byte buffer.
 * @param frame_base vm->stack.top at CALL time (points just past the last arg).
 * @param param_size Total bytes of arguments: args are at stack[frame_base-param_size..frame_base-1].
 * @return           i64 result; the dispatcher writes it to stack[frame_base-8] (the last arg slot).
 */
typedef int64_t (*MorphlNativeFn)(uint8_t* stack, size_t frame_base, size_t param_size);

/**
 * Callback passed to morphl_module_register by the runtime.
 * Native modules call reg("symbol_name", fn_ptr) for each function they export.
 * Returns false if the registry is full (usually safe to ignore).
 */
typedef bool (*MorphlRegisterFn)(const char* name, MorphlNativeFn fn);

/**
 * Register a native function in the global static registry.
 * Must be called before morphl_vm_program_load for the symbol to resolve.
 */
bool morphl_register_native(const char* name, MorphlNativeFn fn);

/**
 * Look up a previously registered native function by name.
 * Returns NULL if not found.
 */
MorphlNativeFn morphl_native_registry_lookup(const char* name);

/**
 * Register all built-in stdlib native functions.
 * Called automatically by morphl_vm_run_file before loading the program.
 */
void morphl_stdlib_register(void);

/// Load a MorphL VM bytecode program from disk (out.mbc format).
bool morphl_vm_program_load(const char* path, MorphlVmProgram** out_program);

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
