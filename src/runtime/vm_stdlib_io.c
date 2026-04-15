/*
 * src/runtime/vm_stdlib_io.c — morphl IO standard library native functions.
 *
 * All string arguments arrive as i64 values containing a raw pointer
 * (uintptr_t) to a NUL-terminated C string.  VM_OP_SCONST stores string
 * literals as (int64_t)(uintptr_t)ptr, so the cast below is safe.
 *
 * Return convention: the dispatcher writes the i64 return value to
 * stack[frame_base - 8], which is always the last slot pushed before CALL.
 * All IO functions return 0 on success.
 */

#include "runtime/runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* ── helpers ──────────────────────────────────────────────────────────────── */

static inline int64_t read_i64(uint8_t* stack, size_t frame_base, size_t offset) {
    int64_t v;
    memcpy(&v, stack + frame_base - offset, 8);
    return v;
}

/* ── print functions ──────────────────────────────────────────────────────── */

static int64_t io_print(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8); /* single string arg at frame[-8] */
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stdout);
    return 0;
}

static int64_t io_println(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stdout);
    fputc('\n', stdout);
    return 0;
}

static int64_t io_print_int(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)param_size;
    int64_t n = read_i64(stack, frame_base, 8);
    printf("%lld", (long long)n);
    return 0;
}

static int64_t io_eprint(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stderr);
    return 0;
}

static int64_t io_eprintln(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stderr);
    fputc('\n', stderr);
    return 0;
}

/* ── registration ─────────────────────────────────────────────────────────── */

static void morphl_stdlib_io_register(void) {
    morphl_register_native("print",     io_print);
    morphl_register_native("println",   io_println);
    morphl_register_native("print_int", io_print_int);
    morphl_register_native("eprint",    io_eprint);
    morphl_register_native("eprintln",  io_eprintln);
}

void morphl_stdlib_register(void) {
    morphl_stdlib_io_register();
}
