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
