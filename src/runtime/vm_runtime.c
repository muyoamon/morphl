/*
 * src/runtime/vm_runtime.c — morphl VM bytecode interpreter
 *
 * Executes typed, frame-offset-based bytecode produced by the vm.c emitter.
 * The stack is a flat byte array; variables are accessed by signed offsets
 * relative to the current call frame's base pointer.
 *
 * Calling convention (sret):
 *   Caller:  RESERVE <ret_size>   — extends stack by ret_size zeroed bytes
 *            [push args]
 *            CALL <func_idx>      — saves IP, sets frame_base = stack.top,
 *                                   reserves frame_size bytes for callee
 *   Callee:  body runs; $ret writes result to frame[-ret_size]
 *            RET                  — restores IP, collapses callee frame
 *   Caller:  return value sits at stack[caller_top .. caller_top+ret_size]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "backend/vm.h"
#include "interface/abi.h"
#include "runtime/runtime.h"

/* ── flat byte stack ─────────────────────────────────────────────────────── */

typedef struct {
    uint8_t* data;
    size_t   top;       /* next free byte index (exclusive) */
    size_t   capacity;
} VmByteStack;

static bool stack_grow(VmByteStack* s, size_t min_cap) {
    size_t cap = s->capacity ? s->capacity : 4096;
    while (cap < min_cap) cap *= 2;
    uint8_t* p = (uint8_t*)realloc(s->data, cap);
    if (!p) return false;
    s->data     = p;
    s->capacity = cap;
    return true;
}

static bool stack_reserve(VmByteStack* s, size_t n) {
    if (n == 0) return true;
    if (s->top + n > s->capacity) {
        if (!stack_grow(s, s->top + n)) return false;
    }
    memset(s->data + s->top, 0, n);
    s->top += n;
    return true;
}

static bool stack_push_i64(VmByteStack* s, int64_t v) {
    if (s->top + 8 > s->capacity) {
        if (!stack_grow(s, s->top + 8)) return false;
    }
    memcpy(s->data + s->top, &v, 8);
    s->top += 8;
    return true;
}

static bool stack_push_f64(VmByteStack* s, double v) {
    if (s->top + 8 > s->capacity) {
        if (!stack_grow(s, s->top + 8)) return false;
    }
    memcpy(s->data + s->top, &v, 8);
    s->top += 8;
    return true;
}

static bool stack_pop_i64(VmByteStack* s, int64_t* out) {
    if (s->top < 8) return false;
    s->top -= 8;
    memcpy(out, s->data + s->top, 8);
    return true;
}

static bool stack_pop_f64(VmByteStack* s, double* out) {
    if (s->top < 8) return false;
    s->top -= 8;
    memcpy(out, s->data + s->top, 8);
    return true;
}

/* ── call frame ─────────────────────────────────────────────────────────── */

typedef struct {
    size_t   frame_base;  /* stack.top value when this frame was entered */
    size_t   return_ip;   /* instruction pointer to restore on RET */
    uint32_t func_index;  /* for diagnostics */
} VmCallFrame;

/* ── program and VM structs (opaque in runtime.h) ───────────────────────── */

struct MorphlVmProgram {
    uint16_t        version_major;
    uint16_t        version_minor;
    VmFunctionMeta* functions;
    uint32_t        func_count;
    uint8_t*        code;
    uint32_t        code_len;
};

struct MorphlVm {
    const MorphlVmProgram* program;
    size_t          ip;
    VmByteStack     stack;
    VmCallFrame*    call_frames;
    size_t          call_frame_count;
    size_t          call_frame_capacity;
};

/* ── low-level file helpers ─────────────────────────────────────────────── */

static bool read_bytes(const uint8_t* buf, size_t buf_len,
                       size_t* pos, void* out, size_t n) {
    if (*pos + n > buf_len) return false;
    memcpy(out, buf + *pos, n);
    *pos += n;
    return true;
}

static bool read_u16_le(const uint8_t* buf, size_t len, size_t* pos, uint16_t* out) {
    uint8_t raw[2];
    if (!read_bytes(buf, len, pos, raw, 2)) return false;
    *out = (uint16_t)(raw[0] | ((uint16_t)raw[1] << 8));
    return true;
}

static bool read_u32_le(const uint8_t* buf, size_t len, size_t* pos, uint32_t* out) {
    uint8_t raw[4];
    if (!read_bytes(buf, len, pos, raw, 4)) return false;
    *out = (uint32_t)(raw[0] | ((uint32_t)raw[1] << 8) |
                      ((uint32_t)raw[2] << 16) | ((uint32_t)raw[3] << 24));
    return true;
}

/* ── program loader ─────────────────────────────────────────────────────── */

bool morphl_vm_program_load(const char* path, MorphlVmProgram** out) {
    if (!path || !out) return false;

    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "vm: cannot open '%s'\n", path); return false; }

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsize <= 0) { fclose(f); return false; }

    uint8_t* buf = (uint8_t*)malloc((size_t)fsize);
    if (!buf) { fclose(f); return false; }
    if (fread(buf, 1, (size_t)fsize, f) != (size_t)fsize) {
        free(buf); fclose(f); return false;
    }
    fclose(f);

    size_t pos = 0;
    size_t len = (size_t)fsize;

    /* magic */
    uint8_t magic[4];
    if (!read_bytes(buf, len, &pos, magic, 4) ||
        memcmp(magic, MORPHL_VM_MAGIC, 4) != 0) {
        fprintf(stderr, "vm: bad magic in '%s'\n", path);
        free(buf); return false;
    }

    MorphlVmProgram* prog = (MorphlVmProgram*)calloc(1, sizeof(*prog));
    if (!prog) { free(buf); return false; }

    /* version */
    uint16_t vmaj, vmin;
    if (!read_u16_le(buf, len, &pos, &vmaj) ||
        !read_u16_le(buf, len, &pos, &vmin)) goto err;
    if (vmaj != MORPHL_VM_VERSION_MAJOR) {
        fprintf(stderr, "vm: unsupported bytecode version %u.%u (expected %u.x)\n",
                vmaj, vmin, MORPHL_VM_VERSION_MAJOR);
        goto err;
    }
    prog->version_major = vmaj;
    prog->version_minor = vmin;

    /* flags (reserved) */
    uint32_t flags;
    if (!read_u32_le(buf, len, &pos, &flags)) goto err;

    /* function table */
    if (!read_u32_le(buf, len, &pos, &prog->func_count)) goto err;
    if (prog->func_count > 0) {
        prog->functions = (VmFunctionMeta*)malloc(
            prog->func_count * sizeof(VmFunctionMeta));
        if (!prog->functions) goto err;
        for (uint32_t i = 0; i < prog->func_count; i++) {
            VmFunctionMeta* fn = &prog->functions[i];
            if (!read_u32_le(buf, len, &pos, &fn->entry_point) ||
                !read_u32_le(buf, len, &pos, &fn->frame_size)  ||
                !read_u32_le(buf, len, &pos, &fn->param_size)  ||
                !read_u32_le(buf, len, &pos, &fn->flags))
                goto err;
        }
    }

    /* code section */
    if (!read_u32_le(buf, len, &pos, &prog->code_len)) goto err;
    if (prog->code_len > 0) {
        prog->code = (uint8_t*)malloc(prog->code_len);
        if (!prog->code) goto err;
        if (!read_bytes(buf, len, &pos, prog->code, prog->code_len)) goto err;
    }

    free(buf);
    *out = prog;
    return true;

err:
    free(prog->functions);
    free(prog->code);
    free(prog);
    free(buf);
    return false;
}

void morphl_vm_program_free(MorphlVmProgram* prog) {
    if (!prog) return;
    free(prog->functions);
    free(prog->code);
    free(prog);
}

/* ── VM lifecycle ───────────────────────────────────────────────────────── */

MorphlVm* morphl_vm_new(const MorphlVmProgram* program) {
    if (!program) return NULL;
    MorphlVm* vm = (MorphlVm*)calloc(1, sizeof(*vm));
    if (!vm) return NULL;
    vm->program = program;
    vm->ip      = 0;
    return vm;
}

void morphl_vm_free(MorphlVm* vm) {
    if (!vm) return;
    free(vm->stack.data);
    free(vm->call_frames);
    free(vm);
}

/* ── frame pointer ──────────────────────────────────────────────────────── */

static uint8_t* frame_ptr(MorphlVm* vm, int32_t offset) {
    if (vm->call_frame_count == 0) {
        return vm->stack.data + (ptrdiff_t)offset;
    }
    VmCallFrame* cf = &vm->call_frames[vm->call_frame_count - 1];
    return vm->stack.data + (ptrdiff_t)cf->frame_base + (ptrdiff_t)offset;
}

/* ── call frame push ────────────────────────────────────────────────────── */

static bool push_call_frame(MorphlVm* vm, VmCallFrame cf) {
    if (vm->call_frame_count >= vm->call_frame_capacity) {
        size_t newcap = vm->call_frame_capacity ? vm->call_frame_capacity * 2 : 64;
        VmCallFrame* p = (VmCallFrame*)realloc(vm->call_frames,
                                               newcap * sizeof(VmCallFrame));
        if (!p) return false;
        vm->call_frames         = p;
        vm->call_frame_capacity = newcap;
    }
    vm->call_frames[vm->call_frame_count++] = cf;
    return true;
}

/* ── operand read macros ─────────────────────────────────────────────────── */

#define CHECK_IP(n) do { \
    if (vm->ip + (n) > (size_t)vm->program->code_len) { \
        fprintf(err, "vm: ip overrun at %zu\n", vm->ip); return 1; \
    } } while(0)

#define READ_U8(v) do { \
    CHECK_IP(1); \
    (v) = vm->program->code[vm->ip++]; \
} while(0)

#define READ_U32(v) do { \
    CHECK_IP(4); \
    uint8_t _r[4]; memcpy(_r, vm->program->code + vm->ip, 4); vm->ip += 4; \
    (v) = (uint32_t)(_r[0] | ((uint32_t)_r[1]<<8) | ((uint32_t)_r[2]<<16) | ((uint32_t)_r[3]<<24)); \
} while(0)

#define READ_I32(v) do { \
    uint32_t _u; READ_U32(_u); (v) = (int32_t)_u; \
} while(0)

#define READ_I64(v) do { \
    CHECK_IP(8); \
    uint8_t _r[8]; memcpy(_r, vm->program->code + vm->ip, 8); vm->ip += 8; \
    uint64_t _u = (uint64_t)_r[0] | ((uint64_t)_r[1]<<8) | ((uint64_t)_r[2]<<16) | \
                  ((uint64_t)_r[3]<<24) | ((uint64_t)_r[4]<<32) | ((uint64_t)_r[5]<<40) | \
                  ((uint64_t)_r[6]<<48) | ((uint64_t)_r[7]<<56); \
    (v) = (int64_t)_u; \
} while(0)

#define READ_F64(v) do { \
    CHECK_IP(8); \
    uint8_t _r[8]; memcpy(_r, vm->program->code + vm->ip, 8); vm->ip += 8; \
    uint64_t _u = (uint64_t)_r[0] | ((uint64_t)_r[1]<<8) | ((uint64_t)_r[2]<<16) | \
                  ((uint64_t)_r[3]<<24) | ((uint64_t)_r[4]<<32) | ((uint64_t)_r[5]<<40) | \
                  ((uint64_t)_r[6]<<48) | ((uint64_t)_r[7]<<56); \
    memcpy(&(v), &_u, 8); \
} while(0)

#define PUSH_I64(v) do { if (!stack_push_i64(&vm->stack, (v))) { fprintf(err, "vm: stack overflow\n"); return 1; } } while(0)
#define PUSH_F64(v) do { if (!stack_push_f64(&vm->stack, (v))) { fprintf(err, "vm: stack overflow\n"); return 1; } } while(0)
#define POP_I64(v)  do { if (!stack_pop_i64(&vm->stack,  &(v))) { fprintf(err, "vm: stack underflow\n"); return 1; } } while(0)
#define POP_F64(v)  do { if (!stack_pop_f64(&vm->stack,  &(v))) { fprintf(err, "vm: stack underflow\n"); return 1; } } while(0)

/* ── main execute loop ──────────────────────────────────────────────────── */

morphl_exit_code_t morphl_vm_execute(MorphlVm* vm, FILE* err) {
    if (!vm || !vm->program) return 1;
    if (!err) err = stderr;

    if (vm->program->func_count == 0) {
        fprintf(err, "vm: no functions in program\n");
        return 1;
    }
    vm->ip = vm->program->functions[0].entry_point;

    while (vm->ip < (size_t)vm->program->code_len) {
        uint8_t op;
        READ_U8(op);

        switch (op) {

        /* ── halt ── */
        case VM_OP_HALT:
            return 0;

        /* ── constants ── */
        case VM_OP_ICONST: { int64_t v; READ_I64(v); PUSH_I64(v); break; }
        case VM_OP_FCONST: { double  v; READ_F64(v); PUSH_F64(v); break; }
        case VM_OP_RNULL:  { PUSH_I64(0); break; }

        /* ── integer arithmetic ── */
        case VM_OP_IADD: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a + b); break; }
        case VM_OP_ISUB: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a - b); break; }
        case VM_OP_IMUL: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a * b); break; }
        case VM_OP_IDIV: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            if (b == 0) { fprintf(err, "vm: integer division by zero\n"); return 1; }
            PUSH_I64(a / b); break;
        }
        case VM_OP_IMOD: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            if (b == 0) { fprintf(err, "vm: integer modulo by zero\n"); return 1; }
            PUSH_I64(a % b); break;
        }

        /* ── float arithmetic ── */
        case VM_OP_FADD: { double b, a; POP_F64(b); POP_F64(a); PUSH_F64(a + b); break; }
        case VM_OP_FSUB: { double b, a; POP_F64(b); POP_F64(a); PUSH_F64(a - b); break; }
        case VM_OP_FMUL: { double b, a; POP_F64(b); POP_F64(a); PUSH_F64(a * b); break; }
        case VM_OP_FDIV: { double b, a; POP_F64(b); POP_F64(a); PUSH_F64(a / b); break; }

        /* ── integer comparison ── */
        case VM_OP_IEQ:  { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a==b?1:0); break; }
        case VM_OP_INEQ: { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a!=b?1:0); break; }
        case VM_OP_ILT:  { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a< b?1:0); break; }
        case VM_OP_IGT:  { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a> b?1:0); break; }
        case VM_OP_ILTE: { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a<=b?1:0); break; }
        case VM_OP_IGTE: { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64(a>=b?1:0); break; }

        /* ── float comparison ── */
        case VM_OP_FEQ:  { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a==b?1:0); break; }
        case VM_OP_FNEQ: { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a!=b?1:0); break; }
        case VM_OP_FLT:  { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a< b?1:0); break; }
        case VM_OP_FGT:  { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a> b?1:0); break; }
        case VM_OP_FLTE: { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a<=b?1:0); break; }
        case VM_OP_FGTE: { double b,a; POP_F64(b); POP_F64(a); PUSH_I64(a>=b?1:0); break; }

        /* ── type conversion ── */
        case VM_OP_I2F: { int64_t v; POP_I64(v); PUSH_F64((double)v);  break; }
        case VM_OP_F2I: { double  v; POP_F64(v); PUSH_I64((int64_t)v); break; }

        /* ── scope management ── */
        case VM_OP_ENTER: {
            uint32_t sz; READ_U32(sz);
            if (!stack_reserve(&vm->stack, sz)) {
                fprintf(err, "vm: OOM on ENTER\n"); return 1;
            }
            break;
        }
        case VM_OP_LEAVE: {
            uint32_t sz; READ_U32(sz);
            if (sz > vm->stack.top) {
                fprintf(err, "vm: LEAVE underflow\n"); return 1;
            }
            vm->stack.top -= sz;
            break;
        }

        /* ── load / store ── */
        case VM_OP_ILOAD: {
            int32_t off; READ_I32(off);
            int64_t v;
            memcpy(&v, frame_ptr(vm, off), 8);
            PUSH_I64(v);
            break;
        }
        case VM_OP_FLOAD: {
            int32_t off; READ_I32(off);
            double v;
            memcpy(&v, frame_ptr(vm, off), 8);
            PUSH_F64(v);
            break;
        }
        case VM_OP_ISTORE: {
            int32_t off; READ_I32(off);
            int64_t v; POP_I64(v);
            memcpy(frame_ptr(vm, off), &v, 8);
            break;
        }
        case VM_OP_FSTORE: {
            int32_t off; READ_I32(off);
            double v; POP_F64(v);
            memcpy(frame_ptr(vm, off), &v, 8);
            break;
        }

        /* ── control flow ── */
        case VM_OP_JMP: {
            int32_t rel; READ_I32(rel);
            vm->ip = (size_t)((ptrdiff_t)vm->ip + rel);
            break;
        }
        case VM_OP_JIF: {
            int32_t rel; READ_I32(rel);
            int64_t v; POP_I64(v);
            if (v) vm->ip = (size_t)((ptrdiff_t)vm->ip + rel);
            break;
        }

        /* ── function calls ── */
        case VM_OP_RESERVE: {
            uint32_t sz; READ_U32(sz);
            if (!stack_reserve(&vm->stack, sz)) {
                fprintf(err, "vm: OOM on RESERVE\n"); return 1;
            }
            break;
        }
        case VM_OP_CALL: {
            uint32_t idx; READ_U32(idx);
            if (idx >= vm->program->func_count) {
                fprintf(err, "vm: CALL index %u out of range\n", idx);
                return 1;
            }
            VmFunctionMeta* fn = &vm->program->functions[idx];
            VmCallFrame cf = {
                .frame_base = vm->stack.top,
                .return_ip  = vm->ip,
                .func_index = idx,
            };
            if (!push_call_frame(vm, cf)) {
                fprintf(err, "vm: call frame OOM\n"); return 1;
            }
            if (!stack_reserve(&vm->stack, fn->frame_size)) {
                fprintf(err, "vm: OOM on CALL frame\n"); return 1;
            }
            vm->ip = fn->entry_point;
            break;
        }
        case VM_OP_RET: {
            if (vm->call_frame_count == 0) {
                return 0;
            }
            VmCallFrame cf = vm->call_frames[--vm->call_frame_count];
            vm->stack.top = cf.frame_base;
            vm->ip        = cf.return_ip;
            break;
        }

        default:
            fprintf(err, "vm: unknown opcode 0x%02X at ip=%zu\n", op, vm->ip - 1);
            return 1;
        }
    }

    return 0;
}

/* ── convenience wrapper ─────────────────────────────────────────────────── */

morphl_exit_code_t morphl_vm_run_file(const char* path, FILE* err) {
    MorphlVmProgram* prog = NULL;
    if (!morphl_vm_program_load(path, &prog)) return 1;

    MorphlVm* vm = morphl_vm_new(prog);
    if (!vm) { morphl_vm_program_free(prog); return 1; }

    morphl_exit_code_t code = morphl_vm_execute(vm, err);

    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    return code;
}

/* ── test accessors ──────────────────────────────────────────────────────── */

bool morphl_vm_read_stack_i64(const MorphlVm* vm, size_t byte_offset, int64_t* out) {
    if (!vm || !out || byte_offset + 8 > vm->stack.top) return false;
    memcpy(out, vm->stack.data + byte_offset, 8);
    return true;
}

bool morphl_vm_read_stack_f64(const MorphlVm* vm, size_t byte_offset, double* out) {
    if (!vm || !out || byte_offset + 8 > vm->stack.top) return false;
    memcpy(out, vm->stack.data + byte_offset, 8);
    return true;
}
