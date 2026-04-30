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
#include <inttypes.h>
#include <stdbool.h>
#include <stdarg.h>
#include <dlfcn.h>

#include "backend/vm.h"
#include "interface/abi.h"
#include "runtime/runtime.h"
#include "util/error.h"

/* ── diagnostics helper ─────────────────────────────────────────────────── */

static void rt_diag(FILE* err_file, MorphlSeverity sev,
                    MorphlErrCode code, const char* fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 4, 5)))
#endif
;
static void rt_diag(FILE* err_file, MorphlSeverity sev,
                    MorphlErrCode code, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    MorphlError e = morphl_error_makev(code, sev, morphl_span_unknown(),
                                       __FILE__, __LINE__, fmt, ap);
    va_end(ap);
    MorphlErrorSink sink = morphl_error_get_global_sink();
    if (sink.fn) {
        morphl_error_emit(&sink, &e);
    } else {
        char buf[512];
        morphl_error_format(&e, buf, sizeof(buf));
        fputs(buf, err_file ? err_file : stderr);
        fputc('\n', err_file ? err_file : stderr);
    }
}

#define RT_ERR(file, fmt, ...) rt_diag((file), MORPHL_SEV_ERROR, MORPHL_E_RUNTIME, fmt, ##__VA_ARGS__)

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
    size_t   return_top;  /* caller stack top after reclaiming args on RET */
    size_t   return_ip;   /* instruction pointer to restore on RET */
    uint32_t func_index;  /* for diagnostics */
} VmCallFrame;

typedef struct {
    uint8_t* data;
    size_t   size;
    bool     live;
    uint32_t cleanup_fidx;  /* 0 = none; non-zero = thunk fidx to call before free */
} VmHeapAlloc;

/* ── program and VM structs (opaque in runtime.h) ───────────────────────── */

struct MorphlVmProgram {
    uint16_t        version_major;
    uint16_t        version_minor;
    uint16_t        artifact_kind;
    uint32_t        global_frame_size;  /* bytes reserved for the global frame at stack[0] */
    VmFunctionMeta* functions;
    uint32_t        func_count;
    uint8_t*        code;
    uint32_t        code_len;
    /* string table: pointers into str_data buffer (null-terminated C strings) */
    char**          str_table;
    uint32_t        str_count;
    uint8_t*        str_data;  /* raw string bytes (owned); str_table[i] points into here */
    /* native symbol table: resolved function pointers for $extern declarations */
    MorphlNativeFn* native_fns;         /* indexed by native symbol index */
    char**          native_sym_names;   /* NUL-terminated names (owned) */
    uint32_t        native_sym_count;
    /* dlopen handles loaded during resolution (closed on program_free) */
    void**          dl_handles;
    uint32_t        dl_handle_count;
};

struct MorphlVm {
    const MorphlVmProgram* program;
    size_t          ip;
    VmByteStack     stack;
    VmCallFrame*    call_frames;
    size_t          call_frame_count;
    size_t          call_frame_capacity;
    VmHeapAlloc*    heap_allocs;
    size_t          heap_alloc_count;
    size_t          heap_alloc_capacity;
    /* process arguments forwarded to the $global frame */
    int             argc;
    char**          argv;
    char**          envp;
    int64_t         pending_free_handle;  /* set by FREE when deferring to cleanup thunk */
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

static bool validate_program_functions(MorphlVmProgram* prog);

/* ── program loader ─────────────────────────────────────────────────────── */

bool morphl_vm_program_load(const char* path, MorphlVmProgram** out) {
    if (!path || !out) return false;

    FILE* f = fopen(path, "rb");
    if (!f) { RT_ERR(stderr, "vm: cannot open '%s'", path); return false; }

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
        RT_ERR(stderr, "vm: bad magic in '%s'", path);
        free(buf); return false;
    }

    MorphlVmProgram* prog = (MorphlVmProgram*)calloc(1, sizeof(*prog));
    if (!prog) { free(buf); return false; }

    /* version */
    uint16_t vmaj, vmin, artifact_kind;
    if (!read_u16_le(buf, len, &pos, &vmaj) ||
        !read_u16_le(buf, len, &pos, &vmin) ||
        !read_u16_le(buf, len, &pos, &artifact_kind)) goto err;
    if (vmaj != MORPHL_VM_VERSION_MAJOR) {
        RT_ERR(stderr, "vm: unsupported bytecode version %u.%u (expected %u.x)",
               vmaj, vmin, MORPHL_VM_VERSION_MAJOR);
        goto err;
    }
    if (artifact_kind != MORPHL_VM_ARTIFACT_EXECUTABLE) {
        RT_ERR(stderr, "vm: '%s' is not a runnable VM executable", path);
        goto err;
    }
    prog->version_major = vmaj;
    prog->version_minor = vmin;
    prog->artifact_kind = artifact_kind;

    /* header field after artifact kind stores global_frame_size */
    if (!read_u32_le(buf, len, &pos, &prog->global_frame_size)) goto err;

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
                !read_u32_le(buf, len, &pos, &fn->return_size) ||
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

    /* string table (optional — older bytecode may not have it) */
    if (pos < len) {
        if (!read_u32_le(buf, len, &pos, &prog->str_count)) goto err;
        if (prog->str_count > 0) {
            prog->str_table = (char**)malloc(prog->str_count * sizeof(char*));
            if (!prog->str_table) goto err;
            /* accumulate all string bytes into str_data first */
            size_t data_cap = 256;
            size_t data_len = 0;
            prog->str_data = (uint8_t*)malloc(data_cap);
            if (!prog->str_data) goto err;
            for (uint32_t i = 0; i < prog->str_count; i++) {
                uint32_t slen;
                if (!read_u32_le(buf, len, &pos, &slen)) goto err;
                /* slen+1 bytes (including NUL) */
                while (data_len + slen + 1 > data_cap) {
                    data_cap *= 2;
                    uint8_t* p = (uint8_t*)realloc(prog->str_data, data_cap);
                    if (!p) goto err;
                    prog->str_data = p;
                }
                prog->str_table[i] = (char*)(prog->str_data + data_len);
                if (!read_bytes(buf, len, &pos, prog->str_data + data_len, slen + 1)) goto err;
                if (prog->str_data[data_len + slen] != '\0') {
                    RT_ERR(stderr, "vm: string table entry %u is not null-terminated", i);
                    goto err;
                }
                data_len += slen + 1;
            }
        }
    }

    /* native symbol table (optional — bytecode without $extern has none) */
    if (pos < len) {
        if (!read_u32_le(buf, len, &pos, &prog->native_sym_count)) goto err;
        if (prog->native_sym_count > 0) {
            prog->native_sym_names = (char**)calloc(prog->native_sym_count, sizeof(char*));
            prog->native_fns       = (MorphlNativeFn*)calloc(
                                         prog->native_sym_count, sizeof(MorphlNativeFn));
            if (!prog->native_sym_names || !prog->native_fns) goto err;
            for (uint32_t i = 0; i < prog->native_sym_count; i++) {
                uint32_t nlen;
                if (!read_u32_le(buf, len, &pos, &nlen)) goto err;
                prog->native_sym_names[i] = (char*)malloc(nlen + 1);
                if (!prog->native_sym_names[i]) goto err;
                if (!read_bytes(buf, len, &pos, prog->native_sym_names[i], nlen + 1)) goto err;
                if (prog->native_sym_names[i][nlen] != '\0') {
                    RT_ERR(stderr, "vm: native symbol entry %u is not null-terminated", i);
                    goto err;
                }
            }
            /* resolve each symbol: static registry first, then dlopen fallback */
            for (uint32_t i = 0; i < prog->native_sym_count; i++) {
                prog->native_fns[i] = morphl_native_registry_lookup(
                                          prog->native_sym_names[i]);
                if (!prog->native_fns[i]) {
                    /* dlopen fallback: try <path_stem>.so alongside the bytecode file */
                    /* Derive stem path: replace .mbc extension (or append .so) */
                    const char* dot = strrchr(path, '.');
                    size_t stem_len = dot ? (size_t)(dot - path) : strlen(path);
                    char* so_path = (char*)malloc(stem_len + 4); /* stem + ".so\0" */
                    if (so_path) {
                        memcpy(so_path, path, stem_len);
                        memcpy(so_path + stem_len, ".so", 4);
                        void* handle = dlopen(so_path, RTLD_LAZY | RTLD_LOCAL);
                        free(so_path);
                        if (handle) {
                            /* call morphl_module_register to populate the registry */
                            typedef void (*reg_entry_t)(MorphlRegisterFn);
                            reg_entry_t entry = (reg_entry_t)dlsym(handle, "morphl_module_register");
                            if (entry) entry(morphl_register_native);
                            /* track handle for cleanup */
                            void** new_handles = (void**)realloc(
                                prog->dl_handles,
                                (prog->dl_handle_count + 1) * sizeof(void*));
                            if (new_handles) {
                                prog->dl_handles = new_handles;
                                prog->dl_handles[prog->dl_handle_count++] = handle;
                            } else {
                                dlclose(handle);
                            }
                            prog->native_fns[i] = morphl_native_registry_lookup(
                                                      prog->native_sym_names[i]);
                        }
                    }
                }
                if (!prog->native_fns[i]) {
                    RT_ERR(stderr, "morphl: unresolved native symbol: %s",
                           prog->native_sym_names[i]);
                    goto err;
                }
            }
        }
    }

    if (!validate_program_functions(prog)) goto err;

    free(buf);
    *out = prog;
    return true;

err:
    free(prog->functions);
    free(prog->code);
    free(prog->str_table);
    free(prog->str_data);
    if (prog->native_sym_names) {
        for (uint32_t i = 0; i < prog->native_sym_count; i++)
            free(prog->native_sym_names[i]);
        free(prog->native_sym_names);
    }
    free(prog->native_fns);
    if (prog->dl_handles) {
        for (uint32_t i = 0; i < prog->dl_handle_count; i++)
            dlclose(prog->dl_handles[i]);
        free(prog->dl_handles);
    }
    free(prog);
    free(buf);
    return false;
}

void morphl_vm_program_free(MorphlVmProgram* prog) {
    if (!prog) return;
    free(prog->functions);
    free(prog->code);
    free(prog->str_table);
    free(prog->str_data);
    if (prog->native_sym_names) {
        for (uint32_t i = 0; i < prog->native_sym_count; i++)
            free(prog->native_sym_names[i]);
        free(prog->native_sym_names);
    }
    free(prog->native_fns);
    if (prog->dl_handles) {
        for (uint32_t i = 0; i < prog->dl_handle_count; i++)
            dlclose(prog->dl_handles[i]);
        free(prog->dl_handles);
    }
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
    for (size_t i = 0; i < vm->heap_alloc_count; ++i) {
        free(vm->heap_allocs[i].data);
    }
    free(vm->heap_allocs);
    free(vm);
}

static bool heap_alloc_slot(MorphlVm* vm, size_t size, int64_t* out_handle, FILE* err) {
    if (!vm || !out_handle) return false;
    if (vm->heap_alloc_count >= vm->heap_alloc_capacity) {
        size_t newcap = vm->heap_alloc_capacity ? vm->heap_alloc_capacity * 2 : 64;
        VmHeapAlloc* p = (VmHeapAlloc*)realloc(vm->heap_allocs, newcap * sizeof(VmHeapAlloc));
        if (!p) {
            RT_ERR(err, "vm: OOM growing heap allocation table");
            return false;
        }
        memset(p + vm->heap_alloc_capacity, 0, (newcap - vm->heap_alloc_capacity) * sizeof(VmHeapAlloc));
        vm->heap_allocs = p;
        vm->heap_alloc_capacity = newcap;
    }
    uint8_t* data = NULL;
    if (size > 0) {
        data = (uint8_t*)calloc(1, size);
        if (!data) {
            RT_ERR(err, "vm: OOM allocating heap object");
            return false;
        }
    }
    size_t idx = vm->heap_alloc_count++;
    vm->heap_allocs[idx].data = data;
    vm->heap_allocs[idx].size = size;
    vm->heap_allocs[idx].live = true;
    *out_handle = -(int64_t)(idx + 1);
    return true;
}

static bool checked_stack_addr(MorphlVm* vm, ptrdiff_t base, int32_t offset, size_t width,
                               ptrdiff_t* out_addr, FILE* err, const char* opname);

static bool checked_heap_addr(MorphlVm* vm, int64_t handle, int32_t offset, size_t width,
                              uint8_t** out_ptr, FILE* err, const char* opname) {
    if (handle >= 0) {
        RT_ERR(err, "vm: %s expected heap handle, got %" PRId64, opname, handle);
        return false;
    }
    size_t idx = (size_t)(-handle - 1);
    if (idx >= vm->heap_alloc_count || !vm->heap_allocs[idx].live) {
        RT_ERR(err, "vm: %s invalid heap handle %" PRId64, opname, handle);
        return false;
    }
    VmHeapAlloc* alloc = &vm->heap_allocs[idx];
    ptrdiff_t addr = (ptrdiff_t)offset;
    if (addr < 0 || width > alloc->size || (size_t)addr > alloc->size - width) {
        RT_ERR(err, "vm: %s heap address %td out of bounds", opname, addr);
        return false;
    }
    *out_ptr = alloc->data + addr;
    return true;
}

static bool checked_ref_addr(MorphlVm* vm, int64_t handle, int32_t offset, size_t width,
                             uint8_t** out_ptr, FILE* err, const char* opname) {
    if (handle < 0) return checked_heap_addr(vm, handle, offset, width, out_ptr, err, opname);
    ptrdiff_t abs = 0;
    if (!checked_stack_addr(vm, (ptrdiff_t)handle, offset, width, &abs, err, opname)) return false;
    *out_ptr = vm->stack.data + abs;
    return true;
}

static bool checked_stack_addr(MorphlVm* vm, ptrdiff_t base, int32_t offset, size_t width,
                               ptrdiff_t* out_addr, FILE* err, const char* opname) {
    ptrdiff_t addr = base + (ptrdiff_t)offset;
    if (addr < 0 || width > vm->stack.top || (size_t)addr > vm->stack.top - width) {
        RT_ERR(err, "vm: %s address %td out of bounds", opname, addr);
        return false;
    }
    *out_addr = addr;
    return true;
}

static bool checked_frame_addr(MorphlVm* vm, int32_t offset, size_t width,
                               ptrdiff_t* out_addr, FILE* err, const char* opname) {
    ptrdiff_t base = 0;
    VmCallFrame* cf = NULL;
    if (vm->call_frame_count > 0) {
        cf = &vm->call_frames[vm->call_frame_count - 1];
        base = (ptrdiff_t)cf->frame_base;
    }
    ptrdiff_t addr = base + (ptrdiff_t)offset;
    if (cf && cf->return_ip == SIZE_MAX && addr >= 0) {
        size_t needed_top = (size_t)addr + width;
        if (needed_top > vm->stack.top) {
            if (!stack_reserve(&vm->stack, needed_top - vm->stack.top)) {
                RT_ERR(err, "vm: OOM extending top-level frame");
                return false;
            }
        }
    }
    return checked_stack_addr(vm, base, offset, width, out_addr, err, opname);
}

static bool read_frame_i64_checked(MorphlVm* vm, int32_t offset, int64_t* out,
                                   FILE* err, const char* opname) {
    ptrdiff_t addr = 0;
    if (!checked_frame_addr(vm, offset, 8, &addr, err, opname)) return false;
    memcpy(out, vm->stack.data + addr, 8);
    return true;
}

static int64_t normalize_int_value(int64_t value, size_t width,
                                   bool is_unsigned) {
    switch (width) {
        case 1:
            if (is_unsigned) return (int64_t)(uint8_t)value;
            return (int64_t)(int8_t)value;
        case 2:
            if (is_unsigned) return (int64_t)(uint16_t)value;
            return (int64_t)(int16_t)value;
        case 4:
            if (is_unsigned) return (int64_t)(uint32_t)value;
            return (int64_t)(int32_t)value;
        default:
            return value;
    }
}

static bool read_frame_int_checked(MorphlVm* vm, int32_t offset, size_t width,
                                   bool is_unsigned, int64_t* out,
                                   FILE* err, const char* opname) {
    if (!vm || !out) return false;
    size_t addr = vm->call_frames[vm->call_frame_count - 1].frame_base + (ptrdiff_t)offset;
    if ((ptrdiff_t)addr < 0 || addr + width > vm->stack.top) {
        RT_ERR(err, "vm: %s frame access OOB (off=%d width=%zu top=%zu)", opname, offset, width, vm->stack.top);
        return false;
    }
    int64_t raw = 0;
    memcpy(&raw, vm->stack.data + addr, width);
    *out = normalize_int_value(raw, width, is_unsigned);
    return true;
}

static bool write_frame_int_checked(MorphlVm* vm, int32_t offset, size_t width,
                                    int64_t value, FILE* err, const char* opname) {
    if (!vm) return false;
    size_t addr = vm->call_frames[vm->call_frame_count - 1].frame_base + (ptrdiff_t)offset;
    if ((ptrdiff_t)addr < 0 || addr + width > vm->stack.top) {
        RT_ERR(err, "vm: %s frame access OOB (off=%d width=%zu top=%zu)", opname, offset, width, vm->stack.top);
        return false;
    }
    memcpy(vm->stack.data + addr, &value, width);
    return true;
}

static int64_t read_int_from_ptr(const uint8_t* ptr, size_t width, bool is_unsigned) {
    int64_t raw = 0;
    memcpy(&raw, ptr, width);
    return normalize_int_value(raw, width, is_unsigned);
}

static bool write_frame_i64_checked(MorphlVm* vm, int32_t offset, int64_t value,
                                    FILE* err, const char* opname) {
    ptrdiff_t addr = 0;
    if (!checked_frame_addr(vm, offset, 8, &addr, err, opname)) return false;
    memcpy(vm->stack.data + addr, &value, 8);
    return true;
}

static bool validate_program_functions(MorphlVmProgram* prog) {
    if (!prog) return false;

    for (uint32_t i = 0; i < prog->func_count; i++) {
        VmFunctionMeta* fn = &prog->functions[i];
        if ((fn->flags & ~MORPHL_FUNC_FLAG_NATIVE) != 0) {
            RT_ERR(stderr, "vm: function %u has unsupported flags 0x%08X",
                   i, fn->flags & ~MORPHL_FUNC_FLAG_NATIVE);
            return false;
        }
        if ((fn->flags & MORPHL_FUNC_FLAG_NATIVE) != 0) {
            if (fn->entry_point >= prog->native_sym_count) {
                RT_ERR(stderr,
                       "vm: function %u native symbol index %u out of range (table size %u)",
                       i, fn->entry_point, prog->native_sym_count);
                return false;
            }
        } else if (fn->entry_point >= prog->code_len) {
            RT_ERR(stderr,
                   "vm: function %u entry point %u out of range (code size %u)",
                   i, fn->entry_point, prog->code_len);
            return false;
        }
    }

    return true;
}

static bool invoke_native(MorphlVm* vm, const VmFunctionMeta* fn,
                          const char* opname, FILE* err) {
    if (!vm || !fn) return false;
    size_t fb = vm->stack.top;
    size_t needed = (size_t)fn->param_size + 8 + (size_t)fn->return_size;
    if (fn->entry_point >= vm->program->native_sym_count) {
        RT_ERR(err, "vm: %s native index %u out of range", opname, fn->entry_point);
        return false;
    }
    if (fb < needed) {
        RT_ERR(err, "vm: native %s stack underflow", opname);
        return false;
    }
    size_t ret_addr = fb - needed;
    if (!vm->program->native_fns[fn->entry_point](
            vm->stack.data, fb, fn->param_size,
            vm->stack.data + ret_addr, fn->return_size)) {
        const char* sym = NULL;
        if (fn->entry_point < vm->program->native_sym_count) {
            sym = vm->program->native_sym_names[fn->entry_point];
        }
        if (sym) RT_ERR(err, "vm: native %s failed for symbol '%s'", opname, sym);
        else RT_ERR(err, "vm: native %s failed", opname);
        return false;
    }
    vm->stack.top = fb - ((size_t)fn->param_size + 8);
    return true;
}

static bool prepare_call_frame(MorphlVm* vm, uint32_t idx, const VmFunctionMeta* fn,
                               VmCallFrame* out_cf, FILE* err, const char* opname) {
    size_t frame_base = vm->stack.top;
    size_t arg_bytes = (size_t)fn->param_size + 8;
    if (frame_base < arg_bytes) {
        RT_ERR(err, "vm: %s frame underflow for function %u", opname, idx);
        return false;
    }
    out_cf->frame_base = frame_base;
    out_cf->return_top = frame_base - arg_bytes;
    out_cf->return_ip = vm->ip;
    out_cf->func_index = idx;
    return true;
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
        RT_ERR(err, "vm: ip overrun at %zu", vm->ip); return 1; \
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

#define PUSH_I64(v) do { if (!stack_push_i64(&vm->stack, (v))) { RT_ERR(err, "vm: stack overflow"); return 1; } } while(0)
#define PUSH_F64(v) do { if (!stack_push_f64(&vm->stack, (v))) { RT_ERR(err, "vm: stack overflow"); return 1; } } while(0)
#define POP_I64(v)  do { if (!stack_pop_i64(&vm->stack,  &(v))) { RT_ERR(err, "vm: stack underflow"); return 1; } } while(0)
#define POP_F64(v)  do { if (!stack_pop_f64(&vm->stack,  &(v))) { RT_ERR(err, "vm: stack underflow"); return 1; } } while(0)

/* ── main execute loop ──────────────────────────────────────────────────── */

morphl_exit_code_t morphl_vm_execute(MorphlVm* vm, FILE* err) {
    if (!vm || !vm->program) return 1;
    if (!err) err = stderr;

    if (vm->program->func_count == 0) {
        RT_ERR(err, "vm: no functions in program");
        return 1;
    }

    /* ── global frame setup ── */
    uint32_t gfsz = vm->program->global_frame_size;
    if (gfsz > 0) {
        if (!stack_reserve(&vm->stack, gfsz)) {
            RT_ERR(err, "vm: OOM allocating global frame");
            return 1;
        }
        /* pre-populate $argc, $argv, $env at global[0], [8], [16] */
        int64_t i_argc = (int64_t)vm->argc;
        int64_t i_argv = (int64_t)(uintptr_t)vm->argv;
        int64_t i_envp = (int64_t)(uintptr_t)vm->envp;
        memcpy(vm->stack.data + 0,  &i_argc, 8);
        memcpy(vm->stack.data + 8,  &i_argv, 8);
        memcpy(vm->stack.data + 16, &i_envp, 8);
    }
    /* phantom call frame: shifts frame_base so user vars don't clash with global frame */
    {
        VmCallFrame phantom = {
            .frame_base = (size_t)gfsz,
            .return_top = (size_t)gfsz,
            .return_ip  = SIZE_MAX,   /* sentinel: RET from phantom frame → exit program */
            .func_index = 0,
        };
        if (!push_call_frame(vm, phantom)) {
            RT_ERR(err, "vm: OOM pushing phantom call frame");
            return 1;
        }
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
            if (b == 0) { RT_ERR(err, "vm: integer division by zero"); return 1; }
            PUSH_I64(a / b); break;
        }
        case VM_OP_IMOD: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            if (b == 0) { RT_ERR(err, "vm: integer modulo by zero"); return 1; }
            PUSH_I64(a % b); break;
        }
        case VM_OP_IUDIV: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            if ((uint64_t)b == 0) { RT_ERR(err, "vm: integer division by zero"); return 1; }
            PUSH_I64((int64_t)((uint64_t)a / (uint64_t)b)); break;
        }
        case VM_OP_IUMOD: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            if ((uint64_t)b == 0) { RT_ERR(err, "vm: integer modulo by zero"); return 1; }
            PUSH_I64((int64_t)((uint64_t)a % (uint64_t)b)); break;
        }

        /* ── integer bitwise ── */
        case VM_OP_IBAND:   { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a & b);  break; }
        case VM_OP_IBOR:    { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a | b);  break; }
        case VM_OP_IBXOR:   { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a ^ b);  break; }
        case VM_OP_IBNOT:   { int64_t a;    POP_I64(a);              PUSH_I64(~a);     break; }
        case VM_OP_ILSHIFT: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a << b); break; }
        case VM_OP_IRSHIFT: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a >> b); break; }
        case VM_OP_IURSHIFT: {
            int64_t b, a; POP_I64(b); POP_I64(a);
            PUSH_I64((int64_t)((uint64_t)a >> b)); break;
        }

        /* ── reference equality ── */
        case VM_OP_REQ:  { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a == b ? 1 : 0); break; }
        case VM_OP_RNEQ: { int64_t b, a; POP_I64(b); POP_I64(a); PUSH_I64(a != b ? 1 : 0); break; }

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
        case VM_OP_IULT:  { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64((uint64_t)a < (uint64_t)b ? 1 : 0); break; }
        case VM_OP_IUGT:  { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64((uint64_t)a > (uint64_t)b ? 1 : 0); break; }
        case VM_OP_IULTE: { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64((uint64_t)a <= (uint64_t)b ? 1 : 0); break; }
        case VM_OP_IUGTE: { int64_t b,a; POP_I64(b); POP_I64(a); PUSH_I64((uint64_t)a >= (uint64_t)b ? 1 : 0); break; }

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
                RT_ERR(err, "vm: OOM on ENTER"); return 1;
            }
            break;
        }
        case VM_OP_LEAVE: {
            uint32_t sz; READ_U32(sz);
            if (sz > vm->stack.top) {
                RT_ERR(err, "vm: LEAVE underflow"); return 1;
            }
            vm->stack.top -= sz;
            break;
        }

        /* ── load / store ── */
        case VM_OP_ILOAD: {
            int32_t off; READ_I32(off);
            int64_t v;
            if (!read_frame_i64_checked(vm, off, &v, err, "ILOAD")) return 1;
            PUSH_I64(v);
            break;
        }
        case VM_OP_FLOAD: {
            int32_t off; READ_I32(off);
            int64_t raw;
            double v;
            if (!read_frame_i64_checked(vm, off, &raw, err, "FLOAD")) return 1;
            memcpy(&v, &raw, 8);
            PUSH_F64(v);
            break;
        }
        case VM_OP_RLOAD: {
            /* load i64 ref (absolute stack address) stored at frame[off]; push as i64 */
            int32_t off; READ_I32(off);
            int64_t v;
            if (!read_frame_i64_checked(vm, off, &v, err, "RLOAD")) return 1;
            PUSH_I64(v);
            break;
        }
        case VM_OP_ISTORE: {
            int32_t off; READ_I32(off);
            int64_t v; POP_I64(v);
            if (!write_frame_i64_checked(vm, off, v, err, "ISTORE")) return 1;
            break;
        }
        case VM_OP_FSTORE: {
            int32_t off; READ_I32(off);
            double v; POP_F64(v);
            int64_t raw;
            memcpy(&raw, &v, 8);
            if (!write_frame_i64_checked(vm, off, raw, err, "FSTORE")) return 1;
            break;
        }
        case VM_OP_RSTORE: {
            /* pop i64 ref (absolute stack address), store as i64 at frame[off] */
            int32_t off; READ_I32(off);
            int64_t v; POP_I64(v);
            if (!write_frame_i64_checked(vm, off, v, err, "RSTORE")) return 1;
            break;
        }
        case VM_OP_ILOAD1S:
        case VM_OP_ILOAD1U:
        case VM_OP_ILOAD2S:
        case VM_OP_ILOAD2U:
        case VM_OP_ILOAD4S:
        case VM_OP_ILOAD4U: {
            int32_t off; READ_I32(off);
            size_t width = (op == VM_OP_ILOAD1S || op == VM_OP_ILOAD1U) ? 1 :
                           (op == VM_OP_ILOAD2S || op == VM_OP_ILOAD2U) ? 2 : 4;
            bool is_unsigned = (op == VM_OP_ILOAD1U || op == VM_OP_ILOAD2U ||
                                op == VM_OP_ILOAD4U);
            int64_t v;
            if (!read_frame_int_checked(vm, off, width, is_unsigned, &v, err, "ILOADN")) return 1;
            PUSH_I64(v);
            break;
        }
        case VM_OP_ISTORE1:
        case VM_OP_ISTORE2:
        case VM_OP_ISTORE4: {
            int32_t off; READ_I32(off);
            size_t width = (op == VM_OP_ISTORE1) ? 1 : (op == VM_OP_ISTORE2 ? 2 : 4);
            int64_t v; POP_I64(v);
            if (!write_frame_int_checked(vm, off, width, v, err, "ISTOREN")) return 1;
            break;
        }
        case VM_OP_INORM1S:
        case VM_OP_INORM1U:
        case VM_OP_INORM2S:
        case VM_OP_INORM2U:
        case VM_OP_INORM4S:
        case VM_OP_INORM4U: {
            int64_t v; POP_I64(v);
            size_t width = (op == VM_OP_INORM1S || op == VM_OP_INORM1U) ? 1 :
                           (op == VM_OP_INORM2S || op == VM_OP_INORM2U) ? 2 : 4;
            bool is_unsigned = (op == VM_OP_INORM1U || op == VM_OP_INORM2U || op == VM_OP_INORM4U);
            PUSH_I64(normalize_int_value(v, width, is_unsigned));
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
        case VM_OP_JNULL: {
            /* pop i64 ref; jump if it is null (== 0) */
            int32_t rel; READ_I32(rel);
            int64_t v; POP_I64(v);
            if (v == 0) vm->ip = (size_t)((ptrdiff_t)vm->ip + rel);
            break;
        }

        /* ── function calls ── */
        case VM_OP_RESERVE: {
            uint32_t sz; READ_U32(sz);
            if (!stack_reserve(&vm->stack, sz)) {
                RT_ERR(err, "vm: OOM on RESERVE"); return 1;
            }
            break;
        }
        case VM_OP_CALL: {
            uint32_t idx; READ_U32(idx);
            if (idx >= vm->program->func_count) {
                RT_ERR(err, "vm: CALL index %u out of range", idx);
                return 1;
            }
            VmFunctionMeta* fn = &vm->program->functions[idx];
            if (fn->flags & MORPHL_FUNC_FLAG_NATIVE) {
                if (!invoke_native(vm, fn, "CALL", err)) return 1;
                break;
            }
            VmCallFrame cf;
            if (!prepare_call_frame(vm, idx, fn, &cf, err, "CALL")) return 1;
            if (!push_call_frame(vm, cf)) {
                RT_ERR(err, "vm: call frame OOM"); return 1;
            }
            if (!stack_reserve(&vm->stack, fn->frame_size)) {
                RT_ERR(err, "vm: OOM on CALL frame"); return 1;
            }
            vm->ip = fn->entry_point;
            break;
        }
        case VM_OP_RET: {
            if (vm->call_frame_count == 0) {
                return 0;
            }
            VmCallFrame cf = vm->call_frames[--vm->call_frame_count];
            vm->stack.top = cf.return_top;
            if (cf.return_ip == SIZE_MAX) {
                /* phantom call frame sentinel — program exit */
                return 0;
            }
            vm->ip = cf.return_ip;
            /* cleanup thunk: pending_free_handle set by FREE before dispatching */
            if (vm->pending_free_handle != 0) {
                int64_t h = vm->pending_free_handle;
                vm->pending_free_handle = 0;
                if (h < 0) {
                    size_t ci = (size_t)(-h - 1);
                    if (ci < vm->heap_alloc_count && vm->heap_allocs[ci].live) {
                        vm->heap_allocs[ci].live = false;
                        free(vm->heap_allocs[ci].data);
                        vm->heap_allocs[ci].data = NULL;
                        vm->heap_allocs[ci].size = 0;
                    }
                }
            }
            break;
        }
        case VM_OP_EXIT: {
            int64_t v; POP_I64(v);
            return (morphl_exit_code_t)v;
        }
        case VM_OP_HEAP: {
            uint32_t sz; READ_U32(sz);
            int64_t handle = 0;
            if (!heap_alloc_slot(vm, (size_t)sz, &handle, err)) return 1;
            PUSH_I64(handle);
            break;
        }
        case VM_OP_FREE: {
            int64_t handle; POP_I64(handle);
            if (handle == 0) {
                RT_ERR(err, "vm: FREE null reference");
                return 1;
            }
            if (handle >= 0) {
                RT_ERR(err, "vm: FREE expects heap reference");
                return 1;
            }
            size_t idx = (size_t)(-handle - 1);
            if (idx >= vm->heap_alloc_count || !vm->heap_allocs[idx].live) {
                RT_ERR(err, "vm: FREE invalid heap handle %" PRId64, handle);
                return 1;
            }
            {
                uint32_t fidx = vm->heap_allocs[idx].cleanup_fidx;
                if (fidx != 0) {
                    if (fidx >= vm->program->func_count) {
                        RT_ERR(err, "vm: FREE cleanup fidx %u out of range", fidx);
                        return 1;
                    }
                    const VmFunctionMeta* fn = &vm->program->functions[fidx];
                    if (fn->flags & MORPHL_FUNC_FLAG_NATIVE) {
                        RT_ERR(err, "vm: FREE cleanup must not be native");
                        return 1;
                    }
                    vm->heap_allocs[idx].cleanup_fidx = 0;  /* prevent double-call */
                    vm->pending_free_handle = handle;
                    /* push hidden_parent + handle as args to cleanup thunk */
                    int64_t hidden_parent = vm->call_frame_count > 0
                        ? (int64_t)vm->call_frames[vm->call_frame_count - 1].frame_base : 0;
                    PUSH_I64(hidden_parent);
                    PUSH_I64(handle);
                    VmCallFrame cf2;
                    cf2.frame_base  = vm->stack.top;
                    cf2.return_top  = vm->stack.top - ((size_t)fn->param_size + 8);
                    cf2.return_ip   = vm->ip;  /* resume after FREE on thunk return */
                    cf2.func_index  = fidx;
                    if (!push_call_frame(vm, cf2)) {
                        RT_ERR(err, "vm: OOM FREE cleanup frame"); return 1;
                    }
                    if (!stack_reserve(&vm->stack, fn->frame_size)) {
                        RT_ERR(err, "vm: OOM FREE cleanup reserve"); return 1;
                    }
                    vm->ip = fn->entry_point;
                    break;
                }
            }
            vm->heap_allocs[idx].live = false;
            free(vm->heap_allocs[idx].data);
            vm->heap_allocs[idx].data = NULL;
            vm->heap_allocs[idx].size = 0;
            break;
        }
        case VM_OP_SET_CLEANUP: {
            uint32_t fidx; READ_U32(fidx);
            int64_t handle; POP_I64(handle);
            if (handle >= 0) break;  /* ignore non-heap handles */
            size_t idx = (size_t)(-handle - 1);
            if (idx >= vm->heap_alloc_count || !vm->heap_allocs[idx].live) break;
            vm->heap_allocs[idx].cleanup_fidx = fidx;
            break;
        }
        case VM_OP_CALLF: {
            /* indirect call: load func index from frame[off], then dispatch */
            int32_t off; READ_I32(off);
            int64_t raw;
            if (!read_frame_i64_checked(vm, off, &raw, err, "CALLF")) return 1;
            uint32_t idx = (uint32_t)raw;
            if (idx >= vm->program->func_count) {
                RT_ERR(err, "vm: CALLF index %u out of range", idx);
                return 1;
            }
            VmFunctionMeta* fn = &vm->program->functions[idx];
            if (fn->flags & MORPHL_FUNC_FLAG_NATIVE) {
                if (!invoke_native(vm, fn, "CALLF", err)) return 1;
                break;
            }
            VmCallFrame cf;
            if (!prepare_call_frame(vm, idx, fn, &cf, err, "CALLF")) return 1;
            if (!push_call_frame(vm, cf)) {
                RT_ERR(err, "vm: call frame OOM"); return 1;
            }
            if (!stack_reserve(&vm->stack, fn->frame_size)) {
                RT_ERR(err, "vm: OOM on CALLF frame"); return 1;
            }
            vm->ip = fn->entry_point;
            break;
        }

        case VM_OP_CALLX: {
            /* pop i64 function index from stack, dispatch (dynamic trait dispatch) */
            int64_t raw; POP_I64(raw);
            uint32_t idx = (uint32_t)raw;
            if (idx >= vm->program->func_count) {
                RT_ERR(err, "vm: CALLX index %u out of range", idx);
                return 1;
            }
            VmFunctionMeta* fn = &vm->program->functions[idx];
            if (fn->flags & MORPHL_FUNC_FLAG_NATIVE) {
                if (!invoke_native(vm, fn, "CALLX", err)) return 1;
                break;
            }
            VmCallFrame cf;
            if (!prepare_call_frame(vm, idx, fn, &cf, err, "CALLX")) return 1;
            if (!push_call_frame(vm, cf)) {
                RT_ERR(err, "vm: call frame OOM"); return 1;
            }
            if (!stack_reserve(&vm->stack, fn->frame_size)) {
                RT_ERR(err, "vm: OOM on CALLX frame"); return 1;
            }
            vm->ip = fn->entry_point;
            break;
        }

        /* ── reference / indirection ── */
        case VM_OP_ADDREF: {
            /* push stack/storage handle of frame[off] as i64 */
            int32_t off; READ_I32(off);
            ptrdiff_t addr = 0;
            if (!checked_frame_addr(vm, off, 8, &addr, err, "ADDREF")) return 1;
            int64_t abs_addr = (int64_t)addr;
            PUSH_I64(abs_addr);
            break;
        }
        case VM_OP_DEREF: {
            /* pop reference handle, push i64 at that location */
            int64_t addr; POP_I64(addr);
            if (addr == 0) {
                RT_ERR(err, "vm: DEREF null reference");
                return 1;
            }
            int64_t v;
            uint8_t* ptr = NULL;
            if (!checked_ref_addr(vm, addr, 0, 8, &ptr, err, "DEREF")) return 1;
            memcpy(&v, ptr, 8);
            PUSH_I64(v);
            break;
        }

        /* ── $parent field access ── */
        case VM_OP_PLOAD: {
            /* load i64 from (parent_base + off) where parent_base = frame[0] as abs addr */
            int32_t off; READ_I32(off);
            int64_t parent_addr;
            if (!read_frame_i64_checked(vm, 0, &parent_addr, err, "PLOAD")) return 1;
            if (parent_addr == 0) {
                RT_ERR(err, "vm: PLOAD null parent reference");
                return 1;
            }
            uint8_t* field_ptr = NULL;
            if (!checked_ref_addr(vm, parent_addr, off, 8, &field_ptr, err, "PLOAD")) return 1;
            int64_t v;
            memcpy(&v, field_ptr, 8);
            PUSH_I64(v);
            break;
        }
        case VM_OP_PSTORE: {
            /* store i64 to (parent_base + off) */
            int32_t off; READ_I32(off);
            int64_t v; POP_I64(v);
            int64_t parent_addr;
            if (!read_frame_i64_checked(vm, 0, &parent_addr, err, "PSTORE")) return 1;
            if (parent_addr == 0) {
                RT_ERR(err, "vm: PSTORE null parent reference");
                return 1;
            }
            uint8_t* field_ptr = NULL;
            if (!checked_ref_addr(vm, parent_addr, off, 8, &field_ptr, err, "PSTORE")) return 1;
            memcpy(field_ptr, &v, 8);
            break;
        }

        /* ── String operations ── */
        case VM_OP_SCONST: {
            /* push pointer to string table entry as i64 */
            uint32_t idx; READ_U32(idx);
            if (idx >= vm->program->str_count) {
                RT_ERR(err, "vm: SCONST index %u out of range (table size %u)",
                       idx, vm->program->str_count);
                return 1;
            }
            int64_t ptr = (int64_t)(uintptr_t)vm->program->str_table[idx];
            PUSH_I64(ptr);
            break;
        }
        case VM_OP_SEQ: {
            /* pop two string pointers, push 1 if strcmp==0 else 0 */
            int64_t b; POP_I64(b);
            int64_t a; POP_I64(a);
            const char* sa = (const char*)(uintptr_t)a;
            const char* sb = (const char*)(uintptr_t)b;
            PUSH_I64(strcmp(sa, sb) == 0 ? 1 : 0);
            break;
        }
        case VM_OP_SNEQ: {
            /* pop two string pointers, push 0 if strcmp==0 else 1 */
            int64_t b; POP_I64(b);
            int64_t a; POP_I64(a);
            const char* sa = (const char*)(uintptr_t)a;
            const char* sb = (const char*)(uintptr_t)b;
            PUSH_I64(strcmp(sa, sb) != 0 ? 1 : 0);
            break;
        }

        /* ── global frame access ── */
        case VM_OP_GLOBAL: {
            /* push absolute stack address of global frame base (always 0) */
            PUSH_I64(0);
            break;
        }
        case VM_OP_ALOAD: {
            /* pop base handle, push i64 from base + off */
            int32_t off; READ_I32(off);
            int64_t base; POP_I64(base);
            uint8_t* ptr = NULL;
            if (!checked_ref_addr(vm, base, off, 8, &ptr, err, "ALOAD")) return 1;
            int64_t v;
            memcpy(&v, ptr, 8);
            PUSH_I64(v);
            break;
        }
        case VM_OP_ALOAD1S:
        case VM_OP_ALOAD1U:
        case VM_OP_ALOAD2S:
        case VM_OP_ALOAD2U:
        case VM_OP_ALOAD4S:
        case VM_OP_ALOAD4U: {
            int32_t off; READ_I32(off);
            int64_t base; POP_I64(base);
            size_t width = (op == VM_OP_ALOAD1S || op == VM_OP_ALOAD1U) ? 1 :
                           (op == VM_OP_ALOAD2S || op == VM_OP_ALOAD2U) ? 2 : 4;
            bool is_unsigned = (op == VM_OP_ALOAD1U || op == VM_OP_ALOAD2U || op == VM_OP_ALOAD4U);
            uint8_t* ptr = NULL;
            if (!checked_ref_addr(vm, base, off, width, &ptr, err, "ALOADN")) return 1;
            PUSH_I64(read_int_from_ptr(ptr, width, is_unsigned));
            break;
        }
        case VM_OP_ASTORE: {
            /* pop i64 val, pop base handle, store val → base + off */
            int32_t off; READ_I32(off);
            int64_t v;    POP_I64(v);
            int64_t base; POP_I64(base);
            uint8_t* ptr = NULL;
            if (!checked_ref_addr(vm, base, off, 8, &ptr, err, "ASTORE")) return 1;
            memcpy(ptr, &v, 8);
            break;
        }
        case VM_OP_ASTORE1:
        case VM_OP_ASTORE2:
        case VM_OP_ASTORE4: {
            int32_t off; READ_I32(off);
            int64_t v; POP_I64(v);
            int64_t base; POP_I64(base);
            size_t width = (op == VM_OP_ASTORE1) ? 1 : (op == VM_OP_ASTORE2 ? 2 : 4);
            uint8_t* ptr = NULL;
            if (!checked_ref_addr(vm, base, off, width, &ptr, err, "ASTOREN")) return 1;
            memcpy(ptr, &v, width);
            break;
        }
        case VM_OP_VSTORE: {
            int32_t off; READ_I32(off);
            uint32_t sz; READ_U32(sz);
            ptrdiff_t addr = 0;
            if (!checked_frame_addr(vm, off, sz, &addr, err, "VSTORE")) return 1;
            if (vm->stack.top < (size_t)sz) {
                RT_ERR(err, "vm: VSTORE stack underflow");
                return 1;
            }
            memcpy(vm->stack.data + addr, vm->stack.data + vm->stack.top - sz, sz);
            vm->stack.top -= sz;
            break;
        }

        default:
            RT_ERR(err, "vm: unknown opcode 0x%02X at ip=%zu", op, vm->ip - 1);
            return 1;
        }
    }

    return 0;
}

/* ── convenience wrapper ─────────────────────────────────────────────────── */

morphl_exit_code_t morphl_vm_run_file(const char* path,
                                      int argc, char** argv, char** envp,
                                      FILE* err) {
    morphl_stdlib_register();
    MorphlVmProgram* prog = NULL;
    if (!morphl_vm_program_load(path, &prog)) return 1;

    MorphlVm* vm = morphl_vm_new(prog);
    if (!vm) { morphl_vm_program_free(prog); return 1; }

    vm->argc = argc;
    vm->argv = argv;
    vm->envp = envp;

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
