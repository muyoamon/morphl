/*
 * src/runtime/vm_native.c — global native function registry for morphl FFI.
 *
 * Symbols registered here are resolved at morphl_vm_program_load time before
 * bytecode execution begins. The stdlib registers its symbols via
 * morphl_stdlib_register(), which morphl_vm_run_file() calls automatically.
 *
 * For user-defined native modules, users call morphl_register_native() from a
 * morphl_module_register() entry point in a shared library loaded via dlopen.
 */

#include "runtime/runtime.h"

#include <dlfcn.h>
#include <stddef.h>
#include <string.h>

#define NATIVE_REGISTRY_MAX 512

static struct {
    const char*    name;
    MorphlNativeFn fn;
} s_registry[NATIVE_REGISTRY_MAX];

static size_t s_count = 0;

bool morphl_register_native(const char* name, MorphlNativeFn fn) {
    if (!name || !fn || s_count >= NATIVE_REGISTRY_MAX) return false;
    s_registry[s_count].name = name;
    s_registry[s_count].fn   = fn;
    s_count++;
    return true;
}

MorphlNativeFn morphl_native_registry_lookup(const char* name) {
    if (!name) return NULL;
    for (size_t i = 0; i < s_count; i++) {
        if (strcmp(s_registry[i].name, name) == 0) return s_registry[i].fn;
    }
    return NULL;
}
