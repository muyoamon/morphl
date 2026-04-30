/*
 * src/runtime/vm_stdlib_io.c — morphl IO standard library native functions.
 *
 * All string arguments arrive as i64 values containing a raw pointer
 * (uintptr_t) to a NUL-terminated C string.  VM_OP_SCONST stores string
 * literals as (int64_t)(uintptr_t)ptr, so the cast below is safe.
 *
 * Return convention: the dispatcher passes a pointer to the caller-reserved
 * return slot. All IO functions write i64 zero on success.
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

static inline bool write_i64_result(uint8_t* ret_ptr, size_t ret_size, int64_t value) {
    if (ret_size != sizeof(value)) return false;
    memcpy(ret_ptr, &value, sizeof(value));
    return true;
}

/* ── print functions ──────────────────────────────────────────────────────── */

static bool io_print(uint8_t* stack, size_t frame_base, size_t param_size,
                     uint8_t* ret_ptr, size_t ret_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8); /* single string arg at frame[-8] */
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stdout);
    return write_i64_result(ret_ptr, ret_size, 0);
}

static bool io_println(uint8_t* stack, size_t frame_base, size_t param_size,
                       uint8_t* ret_ptr, size_t ret_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stdout);
    fputc('\n', stdout);
    return write_i64_result(ret_ptr, ret_size, 0);
}

static bool io_print_int(uint8_t* stack, size_t frame_base, size_t param_size,
                         uint8_t* ret_ptr, size_t ret_size) {
    (void)param_size;
    int64_t n = read_i64(stack, frame_base, 8);
    printf("%lld", (long long)n);
    return write_i64_result(ret_ptr, ret_size, 0);
}

static bool io_eprint(uint8_t* stack, size_t frame_base, size_t param_size,
                      uint8_t* ret_ptr, size_t ret_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stderr);
    return write_i64_result(ret_ptr, ret_size, 0);
}

static bool io_eprintln(uint8_t* stack, size_t frame_base, size_t param_size,
                        uint8_t* ret_ptr, size_t ret_size) {
    (void)param_size;
    int64_t raw = read_i64(stack, frame_base, 8);
    const char* s = (const char*)(uintptr_t)raw;
    if (s) fputs(s, stderr);
    fputc('\n', stderr);
    return write_i64_result(ret_ptr, ret_size, 0);
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
