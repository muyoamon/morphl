#ifndef MORPHL_RUNTIME_RUNTIME_H_
#define MORPHL_RUNTIME_RUNTIME_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

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

/// Execute bytecode in the VM. Returns true on success, false on runtime error.
bool morphl_vm_execute(MorphlVm* vm, FILE* err_stream);

/// Convenience helper for load + execute + teardown.
bool morphl_vm_run_file(const char* path, FILE* err_stream);

#endif // MORPHL_RUNTIME_RUNTIME_H_
