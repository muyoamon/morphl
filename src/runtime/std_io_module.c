/*
 * src/runtime/std_io_module.c — companion native module for std/io.mpl.
 */

#include "runtime/runtime.h"

#include <stdint.h>
#include <stdio.h>

static bool io_print(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                     size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
    (void)ctx;
    (void)param_size;
    const char* s = (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
    if (s) fputs(s, stdout);
    if (ret_size != sizeof(MORPHL_I64)) return false;
    MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, 0);
    return true;
}

static bool io_println(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                       size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
    (void)ctx;
    (void)param_size;
    const char* s = (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
    if (s) fputs(s, stdout);
    fputc('\n', stdout);
    if (ret_size != sizeof(MORPHL_I64)) return false;
    MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, 0);
    return true;
}

static bool io_print_int(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                         size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
    (void)ctx;
    (void)param_size;
    MORPHL_I64 n = MORPHL_READ_ARG(MORPHL_I64, stack, frame_base, 8);
    printf("%lld", (long long)n);
    if (ret_size != sizeof(MORPHL_I64)) return false;
    MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, 0);
    return true;
}

static bool io_eprint(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                      size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
    (void)ctx;
    (void)param_size;
    const char* s = (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
    if (s) fputs(s, stderr);
    if (ret_size != sizeof(MORPHL_I64)) return false;
    MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, 0);
    return true;
}

static bool io_eprintln(MorphlNativeCtx* ctx, uint8_t* stack, size_t frame_base,
                        size_t param_size, uint8_t* ret_ptr, size_t ret_size) {
    (void)ctx;
    (void)param_size;
    const char* s = (const char*)(uintptr_t)MORPHL_READ_ARG(MORPHL_STR, stack, frame_base, 8);
    if (s) fputs(s, stderr);
    fputc('\n', stderr);
    if (ret_size != sizeof(MORPHL_I64)) return false;
    MORPHL_WRITE_RET(MORPHL_I64, ret_ptr, 0);
    return true;
}

void morphl_module_register(MorphlRegisterFn reg) {
    reg("print", io_print);
    reg("println", io_println);
    reg("print_int", io_print_int);
    reg("eprint", io_eprint);
    reg("eprintln", io_eprintln);
}
