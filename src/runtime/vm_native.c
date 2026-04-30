/*
 * src/runtime/vm_native.c — global native function registry for morphl FFI.
 *
 * Symbols registered here are resolved at morphl_vm_program_load time before
 * bytecode execution begins.
 *
 * Companion native modules call morphl_register_native() from a
 * morphl_module_register() entry point after being loaded via dlopen.
 */

#include "runtime/runtime.h"

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
    for (size_t i = s_count; i > 0; i--) {
        if (strcmp(s_registry[i - 1].name, name) == 0) return s_registry[i - 1].fn;
    }
    return NULL;
}
