/*
 * src/backend/vm.c — morphl VM bytecode emitter
 *
 * Lowers the AST to typed, frame-offset-based bytecode as specified in
 * SPEC.md Section 11.  Only the "core" opcode subset is emitted; reference
 * and block-instantiation opcodes are stubbed (see vm.h TODO list).
 *
 * Binary file layout (format version 2.0):
 *   [Header]         4 bytes magic + u16 major + u16 minor + u32 flags
 *   [Function Table] u32 count; then per-function: entry_point, frame_size,
 *                    param_size, flags (all u32 LE)
 *   [Code Section]   u32 code_len; then code_len bytes
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "backend/frame.h"
#include "backend/vm.h"
#include "typing/inference.h"
#include "typing/typing.h"
#include "util/util.h"

/* ── growable byte buffer ─────────────────────────────────────────────────── */

static bool vm_grow(void** ptr, size_t* capacity, size_t elem_size, size_t min) {
    size_t cap = (*capacity == 0) ? 16 : *capacity;
    while (cap < min) {
        if (cap > SIZE_MAX / 2) return false;
        cap *= 2;
    }
    void* p = realloc(*ptr, cap * elem_size);
    if (!p) return false;
    *ptr = p;
    *capacity = cap;
    return true;
}

static bool bytes_push(VmBytes* b, const void* src, size_t n) {
    if (n == 0) return true;
    size_t need = b->len + n;
    if (need > b->capacity) {
        if (!vm_grow((void**)&b->data, &b->capacity, 1, need)) return false;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return true;
}

static bool bytes_push_u8(VmBytes* b, uint8_t v) {
    return bytes_push(b, &v, 1);
}

static bool bytes_push_u16_le(VmBytes* b, uint16_t v) {
    uint8_t raw[2] = { (uint8_t)(v), (uint8_t)(v >> 8) };
    return bytes_push(b, raw, 2);
}

static bool bytes_push_u32_le(VmBytes* b, uint32_t v) {
    uint8_t raw[4] = {
        (uint8_t)(v),        (uint8_t)(v >> 8),
        (uint8_t)(v >> 16),  (uint8_t)(v >> 24)
    };
    return bytes_push(b, raw, 4);
}

static bool bytes_push_i32_le(VmBytes* b, int32_t v) {
    return bytes_push_u32_le(b, (uint32_t)v);
}

static bool bytes_push_i64_le(VmBytes* b, int64_t v) {
    uint8_t raw[8];
    uint64_t u = (uint64_t)v;
    for (int i = 0; i < 8; i++) raw[i] = (uint8_t)(u >> (8 * i));
    return bytes_push(b, raw, 8);
}

static bool bytes_push_f64_le(VmBytes* b, double v) {
    uint64_t u;
    memcpy(&u, &v, 8);
    uint8_t raw[8];
    for (int i = 0; i < 8; i++) raw[i] = (uint8_t)(u >> (8 * i));
    return bytes_push(b, raw, 8);
}

/* write a u32 at an existing byte position (for patching) */
static void bytes_patch_u32_le(VmBytes* b, size_t pos, uint32_t v) {
    b->data[pos + 0] = (uint8_t)(v);
    b->data[pos + 1] = (uint8_t)(v >> 8);
    b->data[pos + 2] = (uint8_t)(v >> 16);
    b->data[pos + 3] = (uint8_t)(v >> 24);
}

/* ── emitter data structures ─────────────────────────────────────────────── */

typedef struct {
    size_t patch_site;  /* byte offset in code where the jump operand starts */
    size_t label_id;
} VmPatch;

typedef struct {
    VmFunctionMeta* items;
    size_t count, capacity;
} VmFunctionTable;

typedef struct {
    VmPatch* items;
    size_t count, capacity;
} VmPatchList;

typedef struct {
    size_t* offsets;   /* SIZE_MAX = unresolved */
    size_t count, capacity;
} VmLabelTable;

typedef struct {
    struct AstNode* node;
    size_t          func_idx;
    Str             name;    /* name of the variable holding this function */
} DeferredFunc;

/* Compile-time alias: $decl r $ref x makes 'r' an alias for 'x' (no frame storage) */
typedef struct {
    Str alias;   /* the alias name (e.g. "r") */
    Str target;  /* the target name (e.g. "x") */
} RefAlias;

/* Loop context: tracks jump targets for $break/$continue inside $while bodies */
typedef struct {
    size_t break_label;       /* jump target for $break    (exit_label) */
    size_t continue_label;    /* jump target for $continue (loop_start) */
    size_t scope_depth_at_entry; /* emitter scope_depth when the loop started */
} VmLoopCtx;

typedef struct {
    Str    name;         /* import variable name (e.g. "m") */
    size_t global_slot;  /* byte offset in the global frame where this slot lives (32, 40, ...) */
} ImportSlot;

typedef struct VmEmitter {
    VmBytes         code;
    VmFunctionTable functions;
    VmPatchList     patches;
    VmLabelTable    labels;
    DeferredFunc*   deferred;
    size_t          deferred_count, deferred_capacity;
    InternTable*    interns;
    MorphlBackendFrameInfo frameInfo;
    TypeContext*    type_ctx;
    /* return-slot offset for the current function (relative to callee frame base) */
    int32_t         return_slot_offset;
    /* frame size accumulator for the current function scope */
    size_t          current_func_frame_size;
    /* compile-time $ref aliases (local, non-struct refs) */
    RefAlias*       ref_aliases;
    size_t          alias_count, alias_capacity;
    /* loop context stack for $break/$continue target resolution */
    VmLoopCtx*      loop_stack;
    size_t          loop_stack_count, loop_stack_capacity;
    /* scope stack for unwinding: each entry is the ENTER size for that scope level */
    uint32_t*       scope_sizes;
    size_t          scope_depth, scope_capacity;
    /* string table: collect deduplicated string literals for SCONST emission */
    char**          str_table;
    size_t          str_count, str_capacity;
    /* true while emitting a deferred function body (false for top-level) */
    bool            in_function;
    /* function table index of top-level 'main', or SIZE_MAX if not declared */
    size_t          main_func_fidx;
    /* global frame: 32 bytes fixed ($argc,$argv,$env,$entry) + 8 bytes per $import */
    size_t          global_frame_size;
    ImportSlot*     import_slots;
    size_t          import_slot_count, import_slot_capacity;
    /* native symbol table: names of $extern declarations, in order of allocation */
    char**          native_syms;
    size_t          native_sym_count, native_sym_capacity;
} VmEmitter;

/* ── opcode helpers ─────────────────────────────────────────────────────── */

static bool emit_op(VmEmitter* e, uint8_t op) {
    return bytes_push_u8(&e->code, op);
}

static bool emit_op_u32(VmEmitter* e, uint8_t op, uint32_t imm) {
    return emit_op(e, op) && bytes_push_u32_le(&e->code, imm);
}

static bool emit_op_i32(VmEmitter* e, uint8_t op, int32_t imm) {
    return emit_op(e, op) && bytes_push_i32_le(&e->code, imm);
}

static bool emit_iconst(VmEmitter* e, int64_t v) {
    return emit_op(e, VM_OP_ICONST) && bytes_push_i64_le(&e->code, v);
}

static bool emit_fconst(VmEmitter* e, double v) {
    return emit_op(e, VM_OP_FCONST) && bytes_push_f64_le(&e->code, v);
}

/* Add a string literal to the emitter's string table; return its index (deduplicated). */
static uint32_t string_intern(VmEmitter* e, Str s) {
    /* Linear scan for dedup — string tables are small */
    for (size_t i = 0; i < e->str_count; i++) {
        size_t slen = strlen(e->str_table[i]);
        if (slen == s.len && memcmp(e->str_table[i], s.ptr, s.len) == 0) {
            return (uint32_t)i;
        }
    }
    if (e->str_count >= e->str_capacity) {
        size_t new_cap = e->str_capacity ? e->str_capacity * 2 : 8;
        char** p = (char**)realloc(e->str_table, new_cap * sizeof(char*));
        if (!p) return UINT32_MAX;
        e->str_table = p;
        e->str_capacity = new_cap;
    }
    char* copy = (char*)malloc(s.len + 1);
    if (!copy) return UINT32_MAX;
    memcpy(copy, s.ptr, s.len);
    copy[s.len] = '\0';
    uint32_t idx = (uint32_t)e->str_count;
    e->str_table[e->str_count++] = copy;
    return idx;
}

/* Emit SCONST <u32 idx> for a string literal */
static bool emit_sconst(VmEmitter* e, Str s) {
    uint32_t idx = string_intern(e, s);
    if (idx == UINT32_MAX) return false;
    return emit_op(e, VM_OP_SCONST) && bytes_push_u32_le(&e->code, idx);
}

/* Push an ENTER scope of given size, tracking depth for $break/$continue unwinding */
static bool emit_enter(VmEmitter* e, uint32_t sz) {
    if (e->scope_depth >= e->scope_capacity) {
        if (!vm_grow((void**)&e->scope_sizes, &e->scope_capacity,
                     sizeof(uint32_t), e->scope_depth + 1)) return false;
    }
    e->scope_sizes[e->scope_depth++] = sz;
    return emit_op_u32(e, VM_OP_ENTER, sz);
}

/* Pop an ENTER scope, emitting LEAVE */
static bool emit_leave(VmEmitter* e, uint32_t sz) {
    if (e->scope_depth > 0) e->scope_depth--;
    return emit_op_u32(e, VM_OP_LEAVE, sz);
}

/* ── label / backpatch ──────────────────────────────────────────────────── */

static size_t label_new(VmEmitter* e) {
    if (e->labels.count >= e->labels.capacity) {
        if (!vm_grow((void**)&e->labels.offsets, &e->labels.capacity,
                     sizeof(size_t), e->labels.count + 1)) return SIZE_MAX;
    }
    size_t id = e->labels.count++;
    e->labels.offsets[id] = SIZE_MAX; /* unresolved */
    return id;
}

static bool label_bind(VmEmitter* e, size_t id) {
    if (id >= e->labels.count) return false;
    e->labels.offsets[id] = e->code.len;
    return true;
}

/* emit jump opcode + placeholder; records patch site */
static bool emit_jump(VmEmitter* e, uint8_t op, size_t label_id) {
    if (!emit_op(e, op)) return false;
    size_t site = e->code.len;
    if (!bytes_push_u32_le(&e->code, 0)) return false;

    if (e->patches.count >= e->patches.capacity) {
        if (!vm_grow((void**)&e->patches.items, &e->patches.capacity,
                     sizeof(VmPatch), e->patches.count + 1)) return false;
    }
    e->patches.items[e->patches.count++] = (VmPatch){ site, label_id };
    return true;
}

static bool patches_apply(VmEmitter* e) {
    for (size_t i = 0; i < e->patches.count; i++) {
        VmPatch* p = &e->patches.items[i];
        if (p->label_id >= e->labels.count) return false;
        size_t target = e->labels.offsets[p->label_id];
        if (target == SIZE_MAX) {
            fprintf(stderr, "vm emitter: unresolved label %zu\n", p->label_id);
            return false;
        }
        /* relative offset = target - (patch_site + 4) */
        int32_t rel = (int32_t)((ptrdiff_t)target - (ptrdiff_t)(p->patch_site + 4));
        bytes_patch_u32_le(&e->code, p->patch_site, (uint32_t)rel);
    }
    return true;
}

/* ── ref alias helpers ──────────────────────────────────────────────────── */

static bool alias_add(VmEmitter* e, Str alias, Str target) {
    if (e->alias_count >= e->alias_capacity) {
        if (!vm_grow((void**)&e->ref_aliases, &e->alias_capacity,
                     sizeof(RefAlias), e->alias_count + 1)) return false;
    }
    e->ref_aliases[e->alias_count++] = (RefAlias){ alias, target };
    return true;
}

/* Resolve an alias chain to its final target name (handles chained $ref aliases) */
static Str alias_resolve(VmEmitter* e, Str name) {
    for (int depth = 0; depth < 64; depth++) {
        bool found = false;
        for (size_t i = e->alias_count; i > 0; i--) {
            RefAlias* a = &e->ref_aliases[i - 1];
            if (str_eq(a->alias, name)) {
                name = a->target;
                found = true;
                break;
            }
        }
        if (!found) break;
    }
    return name;
}

/* ── type helpers ───────────────────────────────────────────────────────── */

static const MorphlType* unwrap_ref(const MorphlType* t);  /* forward declaration */

static size_t type_frame_size(const MorphlType* t) {
    if (!t) return 0;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_FLOAT:
        case MORPHL_TYPE_BOOL:
        case MORPHL_TYPE_STRING: return 8;   /* stored as i64 or f64 or string pointer */
        case MORPHL_TYPE_FUNC:   return 8;   /* stored as i64 (function table index) */
        case MORPHL_TYPE_REF:
            /* $ref (is_ref=true) stores a 4-byte absolute stack address.
             * $mut/$const/$inline qualifiers are transparent — size comes from target. */
            if (t->data.ref.is_ref) return 8;  /* stored as i64 absolute stack address */
            return t->data.ref.target ? type_frame_size(t->data.ref.target) : 0;
        case MORPHL_TYPE_BLOCK: {
            if (t->size > 0) return t->size;
            /* size field is 0 (set so by morphl_type_block); compute from fields */
            size_t total = 0;
            for (size_t i = 0; i < t->data.block.field_count; i++) {
                if (t->data.block.field_types[i])
                    total += type_frame_size(unwrap_ref(t->data.block.field_types[i]));
            }
            return total;
        }
        default:                 return 0;
    }
}

/* load opcode for a type; returns 0xFF if unsupported */
static uint8_t load_op(const MorphlType* t) {
    if (!t) return 0xFF;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_BOOL:
        case MORPHL_TYPE_FUNC:
        case MORPHL_TYPE_STRING: return VM_OP_ILOAD;   /* string pointer fits in i64 slot */
        case MORPHL_TYPE_FLOAT:  return VM_OP_FLOAD;
        case MORPHL_TYPE_REF:
            if (t->data.ref.is_ref) return VM_OP_RLOAD;
            /* qualifier refs: fall through to load from target type */
            return t->data.ref.target ? load_op(t->data.ref.target) : 0xFF;
        default:                 return 0xFF;
    }
}

/* store opcode for a type; returns 0xFF if unsupported */
static uint8_t store_op(const MorphlType* t) {
    if (!t) return 0xFF;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_BOOL:
        case MORPHL_TYPE_FUNC:
        case MORPHL_TYPE_STRING: return VM_OP_ISTORE;  /* string pointer fits in i64 slot */
        case MORPHL_TYPE_FLOAT:  return VM_OP_FSTORE;
        case MORPHL_TYPE_REF:
            if (t->data.ref.is_ref) return VM_OP_RSTORE;
            return t->data.ref.target ? store_op(t->data.ref.target) : 0xFF;
        default:                return 0xFF;
    }
}

/* unwrap $mut / $const / $inline qualifier layers; stop at real $ref (is_ref=true) */
static const MorphlType* unwrap_ref(const MorphlType* t) {
    while (t && t->kind == MORPHL_TYPE_REF && !t->data.ref.is_ref)
        t = t->data.ref.target;
    return t;
}

/* ── function table helpers ─────────────────────────────────────────────── */

static size_t func_alloc(VmEmitter* e) {
    if (e->functions.count >= e->functions.capacity) {
        if (!vm_grow((void**)&e->functions.items, &e->functions.capacity,
                     sizeof(VmFunctionMeta), e->functions.count + 1)) return SIZE_MAX;
    }
    size_t idx = e->functions.count++;
    memset(&e->functions.items[idx], 0, sizeof(VmFunctionMeta));
    return idx;
}

/* ── forward declaration ────────────────────────────────────────────────── */
static bool emit_node(VmEmitter* e, struct AstNode* node);

/* ── pre-scan block to compute its total $decl byte size ─────────────────── */
static size_t block_scope_size(struct AstNode* block) {
    if (!block) return 0;
    size_t sz = 0;
    for (size_t i = 0; i < block->child_count; i++) {
        struct AstNode* ch = block->children[i];
        if (!ch) continue;
        if (ch->kind == AST_DECL && ch->type) {
            const MorphlType* t = unwrap_ref(ch->type);
            sz += type_frame_size(t);
        }
    }
    return sz;
}

/* ── emit a single AST node ─────────────────────────────────────────────── */

static bool emit_node(VmEmitter* e, struct AstNode* node) {
    if (!node) return true;

    switch (node->kind) {

    /* ── literals ── */
    case AST_LITERAL: {
        const MorphlType* t = unwrap_ref(node->type);
        if (!t) {
            fprintf(stderr, "vm emitter: literal has no type at %s:%zu:%zu\n",
                    node->filename ? node->filename : "?", node->row, node->col);
            return false;
        }
        if (t->kind == MORPHL_TYPE_FLOAT) {
            char buf[64];
            size_t n = node->value.len < 63 ? node->value.len : 63;
            memcpy(buf, node->value.ptr, n);
            buf[n] = '\0';
            double v = atof(buf);
            return emit_fconst(e, v);
        }
        if (t->kind == MORPHL_TYPE_STRING) {
            /* String literal: strip surrounding quotes and intern into string table */
            Str raw = node->value;
            if (raw.len >= 2 && raw.ptr[0] == '"' && raw.ptr[raw.len - 1] == '"') {
                raw.ptr++;
                raw.len -= 2;
            }
            return emit_sconst(e, raw);
        }
        /* INT, BOOL, or anything else → ICONST */
        char buf[32];
        size_t n = node->value.len < 31 ? node->value.len : 31;
        memcpy(buf, node->value.ptr, n);
        buf[n] = '\0';
        int64_t v = (int64_t)atoll(buf);
        return emit_iconst(e, v);
    }

    /* ── identifiers (as r-values) ── */
    case AST_IDENT: {
        /* resolve compile-time $ref aliases first */
        Str resolved = alias_resolve(e, node->value);
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, resolved);
        if (off == PTRDIFF_MAX) {
            fprintf(stderr, "vm emitter: undefined identifier '%.*s' at %s:%zu:%zu\n",
                    (int)node->value.len, node->value.ptr,
                    node->filename ? node->filename : "?", node->row, node->col);
            return false;
        }
        /* For alias refs, fully unwrap through the $ref layer to get the target type.
         * For normal idents (including $ref struct fields), use normal unwrap. */
        const MorphlType* t;
        if (!str_eq(resolved, node->value)) {
            /* alias: strip ALL ref layers to reach actual stored type */
            t = node->type;
            while (t && t->kind == MORPHL_TYPE_REF) t = t->data.ref.target;
        } else {
            t = unwrap_ref(node->type);
        }
        uint8_t op = load_op(t);
        if (op == 0xFF) {
            fprintf(stderr, "vm emitter: cannot load type for '%.*s'\n",
                    (int)node->value.len, node->value.ptr);
            return false;
        }
        return emit_op_i32(e, op, (int32_t)off);
    }

    /* ── declarations ── */
    case AST_DECL: {
        if (node->child_count < 2) return true; /* empty decl, skip */
        struct AstNode* name_node = node->children[0];
        struct AstNode* rhs       = node->children[1];
        if (!name_node || name_node->kind != AST_IDENT) return false;

        Str name = name_node->value;

        /* handle compile-time $ref alias BEFORE any frame registration */
        if (rhs && rhs->kind == AST_BUILTIN) {
            Str op_name = (e->interns && rhs->op)
                          ? interns_lookup(e->interns, rhs->op)
                          : rhs->value;
            if (op_name.len == 4 && memcmp(op_name.ptr, "$ref", 4) == 0 &&
                rhs->child_count > 0 && rhs->children[0] &&
                rhs->children[0]->kind == AST_IDENT) {
                /* $decl r $ref x — compile-time alias, no frame storage allocated */
                return alias_add(e, name, rhs->children[0]->value);
            }
        }

        const MorphlType* raw_type = node->type;
        const MorphlType* t = unwrap_ref(raw_type);

        /* register in frame tracker */
        struct MorphlBackendFrameOffset foff = {
            .name = name,
            .size = t ? type_frame_size(t) : 0
        };
        if (!morphl_backend_append_offset(&e->frameInfo, foff)) return false;

        /* find the offset we just registered */
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, name);
        if (off == PTRDIFF_MAX) return false;

        /* if RHS is a $import, track slot index so we can write the $modules entry after emission */
        size_t import_slot_before = SIZE_MAX;
        if (rhs && rhs->kind == AST_BUILTIN && e->interns && rhs->op) {
            Str rhs_op = interns_lookup(e->interns, rhs->op);
            if (rhs_op.len == 7 && memcmp(rhs_op.ptr, "$import", 7) == 0) {
                /* assign next global slot (32, 40, 48, ...) for this import */
                if (e->import_slot_count >= e->import_slot_capacity) {
                    if (!vm_grow((void**)&e->import_slots, &e->import_slot_capacity,
                                 sizeof(ImportSlot), e->import_slot_count + 1))
                        return false;
                }
                import_slot_before = e->import_slot_count;
                e->import_slots[import_slot_before] = (ImportSlot){
                    .name        = name,
                    .global_slot = 32 + 8 * import_slot_before,
                };
                e->import_slot_count++;
            }
        }

        /* if RHS is $extern <func-expr>, allocate a native function slot */
        if (rhs && rhs->kind == AST_BUILTIN && e->interns && rhs->op) {
            Str rhs_op_s = interns_lookup(e->interns, rhs->op);
            if (rhs_op_s.len == 7 && memcmp(rhs_op_s.ptr, "$extern", 7) == 0) {
                /* compute param_size from the DECL's function type */
                const MorphlType* fn_type = unwrap_ref(node->type);
                uint32_t param_sz = 0;
                if (fn_type && fn_type->kind == MORPHL_TYPE_FUNC &&
                    fn_type->data.func.param_count > 0 && fn_type->data.func.param_types[0]) {
                    param_sz = (uint32_t)type_frame_size(
                        unwrap_ref(fn_type->data.func.param_types[0]));
                }
                /* grow native_syms array and record NUL-terminated copy of symbol name */
                if (e->native_sym_count >= e->native_sym_capacity) {
                    if (!vm_grow((void**)&e->native_syms, &e->native_sym_capacity,
                                 sizeof(char*), e->native_sym_count + 1))
                        return false;
                }
                /* For imported modules, value.ptr is freed (pp_action_import frees
                 * source_buffer). Fall back to the interned name via name_node->op. */
                Str sym_str = name;
                if ((!sym_str.ptr || sym_str.len == 0) && e->interns && name_node->op)
                    sym_str = interns_lookup(e->interns, name_node->op);
                char* sym_name = (char*)malloc(sym_str.len + 1);
                if (!sym_name) return false;
                memcpy(sym_name, sym_str.ptr, sym_str.len);
                sym_name[sym_str.len] = '\0';
                e->native_syms[e->native_sym_count] = sym_name;
                size_t native_idx = e->native_sym_count++;
                /* allocate a function table slot */
                size_t fidx = func_alloc(e);
                if (fidx == SIZE_MAX) return false;
                e->functions.items[fidx].entry_point = (uint32_t)native_idx;
                e->functions.items[fidx].flags       = MORPHL_FUNC_FLAG_NATIVE;
                e->functions.items[fidx].param_size  = param_sz;
                e->functions.items[fidx].frame_size  = 0;
                /* store function table index as i64 in the variable's frame slot */
                if (!emit_iconst(e, (int64_t)fidx)) return false;
                return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
            }
        }

        /* if RHS is a function, defer it and store its future table index */
        if (rhs && rhs->kind == AST_FUNC) {
            size_t fidx = func_alloc(e);
            if (fidx == SIZE_MAX) return false;
            /* defer function body emission */
            if (e->deferred_count >= e->deferred_capacity) {
                if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                             sizeof(DeferredFunc), e->deferred_count + 1)) return false;
            }
            e->deferred[e->deferred_count++] = (DeferredFunc){ rhs, fidx, name };
            /* record 'main' for auto-call injection (top-level only) */
            if (!e->in_function &&
                name.len == 4 && memcmp(name.ptr, "main", 4) == 0) {
                /* validate that main returns i32 */
                const MorphlType* fn_type = unwrap_ref(node->type);
                if (!fn_type || fn_type->kind != MORPHL_TYPE_FUNC ||
                    !fn_type->data.func.return_type ||
                    fn_type->data.func.return_type->kind != MORPHL_TYPE_INT) {
                    fprintf(stderr, "vm emitter: 'main' must have return type i32, e.g. main := () => { $ret 0; };\n");
                    return false;
                }
                e->main_func_fidx = fidx;
            }
            /* store function table index as i64 in frame */
            if (!emit_iconst(e, (int64_t)fidx)) return false;
            return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
        }

        /* emit RHS expression */
        if (!emit_node(e, rhs)) return false;

        /* if this was a $import, populate the $modules global slot now that the
         * module's frame has been pushed (so frame offsets are stable) */
        if (import_slot_before != SIZE_MAX) {
            ImportSlot* sl = &e->import_slots[import_slot_before];
            ptrdiff_t m_off = morphl_backend_find_offset(&e->frameInfo, sl->name);
            if (m_off != PTRDIFF_MAX) {
                int64_t mod_frame_base = (int64_t)e->global_frame_size + (int64_t)m_off;
                if (!emit_op(e, VM_OP_GLOBAL)          ||
                    !emit_iconst(e, mod_frame_base)     ||
                    !emit_op_i32(e, VM_OP_ASTORE, (int32_t)sl->global_slot))
                    return false;
            }
        }

        /* store result to frame */
        uint8_t sop = store_op(t);
        if (sop == 0xFF) {
            /* void / block / unknown — nothing to store */
            return true;
        }
        return emit_op_i32(e, sop, (int32_t)off);
    }

    /* ── blocks and file root ── */
    case AST_FILE:
    case AST_BLOCK: {
        size_t scope_sz = block_scope_size(node);
        if (!morphl_backend_push_frame(&e->frameInfo)) return false;
        if (!emit_enter(e, (uint32_t)scope_sz)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        for (size_t i = 0; i < node->child_count; i++) {
            if (!emit_node(e, node->children[i])) {
                morphl_backend_pop_frame(&e->frameInfo);
                return false;
            }
        }
        if (!emit_leave(e, (uint32_t)scope_sz)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        morphl_backend_pop_frame(&e->frameInfo);
        return true;
    }

    /* ── function calls ── */
    case AST_CALL: {
        if (node->child_count < 1) return false;
        struct AstNode* callee = node->children[0];
        struct AstNode* args   = node->child_count > 1 ? node->children[1] : NULL;

        /* determine return type and its size */
        const MorphlType* ret_t = unwrap_ref(node->type);
        uint32_t ret_sz = (uint32_t)type_frame_size(ret_t);

        /* RESERVE return slot */
        if (!emit_op_u32(e, VM_OP_RESERVE, ret_sz)) return false;

        /* emit hidden $parent argument: absolute stack address of caller's frame[0].
         * The callee copies this into its own $parent slot at entry. */
        if (!emit_op_i32(e, VM_OP_ADDREF, 0)) return false;

        /* emit arguments */
        if (args) {
            if (args->kind == AST_GROUP) {
                for (size_t i = 0; i < args->child_count; i++) {
                    if (!emit_node(e, args->children[i])) return false;
                }
            } else {
                if (!emit_node(e, args)) return false;
            }
        }

        /* resolve callee to a function call */
        if (callee->kind == AST_IDENT) {
            Str callee_name = alias_resolve(e, callee->value);
            ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, callee_name);
            if (off == PTRDIFF_MAX) {
                fprintf(stderr, "vm emitter: undefined callee '%.*s'\n",
                        (int)callee->value.len, callee->value.ptr);
                return false;
            }
            /* Use CALLF (indirect call via function index stored at frame[off]).
             * This is the correct implementation: the function index is stored in
             * the frame as i64 (put there when the function was declared), and CALLF
             * loads it and dispatches. For known-at-compile-time callees, we could
             * use CALL, but CALLF is correct and handles dynamic dispatch too. */
            return emit_op_i32(e, VM_OP_CALLF, (int32_t)off);
        }

        /* $member target field — compute combined frame offset and emit CALLF.
         * Handles: $call $member io println (args) */
        if (callee->kind == AST_BUILTIN && callee->op && e->interns &&
            callee->child_count == 2) {
            Str callee_op = interns_lookup(e->interns, callee->op);
            if (callee_op.len == 7 && memcmp(callee_op.ptr, "$member", 7) == 0) {
                struct AstNode* target   = callee->children[0];
                struct AstNode* field_nd = callee->children[1];

                Str field_name = field_nd->value;
                if (!field_name.ptr && e->interns && field_nd->op)
                    field_name = interns_lookup(e->interns, field_nd->op);

                const MorphlType* target_btype = unwrap_ref(target->type);
                if (!target_btype || target_btype->kind != MORPHL_TYPE_BLOCK) {
                    fprintf(stderr, "vm emitter: $call $member: target is not a block\n");
                    return false;
                }

                size_t field_offset = 0;
                bool field_found = false;
                for (size_t fi = 0; fi < target_btype->data.block.field_count; fi++) {
                    Str fname = {NULL, 0};
                    if (e->interns && target_btype->data.block.field_names[fi])
                        fname = interns_lookup(e->interns, target_btype->data.block.field_names[fi]);
                    if (str_eq(fname, field_name)) { field_found = true; break; }
                    field_offset += type_frame_size(unwrap_ref(target_btype->data.block.field_types[fi]));
                }
                if (!field_found) {
                    fprintf(stderr, "vm emitter: $call $member: field not found\n");
                    return false;
                }

                if (target->kind != AST_IDENT) {
                    fprintf(stderr, "vm emitter: $call $member: target must be identifier\n");
                    return false;
                }
                Str target_name = alias_resolve(e, target->value);
                ptrdiff_t target_off = morphl_backend_find_offset(&e->frameInfo, target_name);
                if (target_off == PTRDIFF_MAX) {
                    fprintf(stderr, "vm emitter: $call $member: undefined target '%.*s'\n",
                            (int)target_name.len, target_name.ptr);
                    return false;
                }
                return emit_op_i32(e, VM_OP_CALLF, (int32_t)(target_off + field_offset));
            }
        }

        fprintf(stderr, "vm emitter: unsupported callee kind %d\n", callee->kind);
        return false;
    }

    /* ── assignment ── */
    case AST_SET: {
        if (node->child_count < 2) return false;
        struct AstNode* target = node->children[0];
        struct AstNode* value  = node->children[1];
        if (!emit_node(e, value)) return false;
        if (target->kind != AST_IDENT) {
            fprintf(stderr, "vm emitter: $set target must be identifier\n");
            return false;
        }
        /* resolve compile-time $ref aliases for the assignment target */
        Str target_name = alias_resolve(e, target->value);
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, target_name);
        if (off == PTRDIFF_MAX) {
            fprintf(stderr, "vm emitter: undefined target '%.*s' in $set\n",
                    (int)target->value.len, target->value.ptr);
            return false;
        }
        const MorphlType* t = unwrap_ref(value->type ? value->type : node->type);
        uint8_t sop = store_op(t);
        if (sop == 0xFF) return false;
        return emit_op_i32(e, sop, (int32_t)off);
    }

    /* ── if expression ── */
    case AST_IF: {
        if (node->child_count < 2) return false;
        /* emit condition */
        if (!emit_node(e, node->children[0])) return false;
        /* negate: ICONST 0, IEQ → 1 if condition was false */
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_IEQ)) return false;
        /* JIF to else (jumps if condition was false, i.e. negated == 1) */
        size_t else_lbl = label_new(e);
        size_t end_lbl  = label_new(e);
        if (else_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;
        if (!emit_jump(e, VM_OP_JIF, else_lbl)) return false;
        /* then branch */
        if (!emit_node(e, node->children[1])) return false;
        if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;
        /* else branch */
        if (!label_bind(e, else_lbl)) return false;
        if (node->child_count > 2 && node->children[2]) {
            if (!emit_node(e, node->children[2])) return false;
        }
        return label_bind(e, end_lbl);
    }

    /* ── groups (tuple literals, argument lists) ── */
    case AST_GROUP:
        for (size_t i = 0; i < node->child_count; i++) {
            if (!emit_node(e, node->children[i])) return false;
        }
        return true;

    /* ── property declarations ($prop) — used inside $traits and $impl blocks.
     * Props are type-level declarations; no frame storage is emitted.
     * If the init value is a function, defer it like a normal function decl. */
    case AST_PROP: {
        if (node->child_count < 2) return true;
        struct AstNode* rhs = node->children[1];
        if (!rhs) return true;
        /* if rhs is a function, defer it so the function table is populated */
        if (rhs->kind == AST_FUNC) {
            size_t fidx = func_alloc(e);
            if (fidx == SIZE_MAX) return false;
            if (e->deferred_count >= e->deferred_capacity) {
                if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                             sizeof(DeferredFunc), e->deferred_count + 1)) return false;
            }
            Str prop_name = {NULL, 0};
            if (node->children[0] && node->children[0]->kind == AST_IDENT)
                prop_name = node->children[0]->value;
            e->deferred[e->deferred_count++] = (DeferredFunc){ rhs, fidx, prop_name };
        }
        /* props produce no runtime value — nothing stored in frame */
        return true;
    }

    /* ── builtin operators ── */
    case AST_BUILTIN: {
        Str op_name = (e->interns && node->op)
                      ? interns_lookup(e->interns, node->op)
                      : node->value;

#define OP_IS(s) (op_name.len == sizeof(s)-1 && memcmp(op_name.ptr, s, sizeof(s)-1) == 0)

        /* $ret */
        if (OP_IS("$ret")) {
            if (node->child_count > 0 && node->children[0]) {
                if (!emit_node(e, node->children[0])) return false;
                /* store return value into return slot (below callee frame base) */
                const MorphlType* t = unwrap_ref(node->children[0]->type);
                uint8_t sop = store_op(t);
                if (sop != 0xFF) {
                    /* return slot is at a negative offset from frame base: -ret_size */
                    size_t ret_sz = type_frame_size(t);
                    if (!emit_op_i32(e, sop, -(int32_t)ret_sz)) return false;
                }
            }
            return emit_op(e, VM_OP_RET);
        }

        /* $mut / $const / $ref (qualifier form) — transparent storage qualifiers */
        if (OP_IS("$mut") || OP_IS("$const") || OP_IS("$ref")) {
            return node->child_count > 0 ? emit_node(e, node->children[0]) : true;
        }

        /* $this — push absolute stack address of the current function's frame start */
        if (OP_IS("$this")) {
            return emit_op_i32(e, VM_OP_ADDREF, 0);
        }

        /* $parent — load the hidden parent frame address from frame[0] */
        if (OP_IS("$parent")) {
            return emit_op_i32(e, VM_OP_ILOAD, 0);
        }

        /* $member target field — load a field from a block-typed value.
         * For $parent as target: uses PLOAD (reads from parent address + field offset).
         * For identifier targets: uses ILOAD at (var_offset + field_offset). */
        if (OP_IS("$member")) {
            if (node->child_count < 2) return false;
            struct AstNode* target    = node->children[0];
            struct AstNode* field_nd  = node->children[1];
            if (!field_nd) return false;

            /* resolve field name */
            Str field_name = field_nd->value;
            if (!field_name.ptr && e->interns && field_nd->op) {
                field_name = interns_lookup(e->interns, field_nd->op);
            }

            /* get target block type */
            const MorphlType* raw_target_type = target->type;
            const MorphlType* target_btype = unwrap_ref(raw_target_type);
            if (!target_btype || target_btype->kind != MORPHL_TYPE_BLOCK) {
                fprintf(stderr, "vm emitter: $member: target is not a block type\n");
                return false;
            }

            /* compute field offset within the block (fields are packed in declaration order) */
            size_t field_offset = 0;
            bool field_found = false;
            const MorphlType* field_type = NULL;
            for (size_t fi = 0; fi < target_btype->data.block.field_count; fi++) {
                Str fname = {NULL, 0};
                if (e->interns && target_btype->data.block.field_names[fi]) {
                    fname = interns_lookup(e->interns, target_btype->data.block.field_names[fi]);
                }
                if (str_eq(fname, field_name)) {
                    field_found = true;
                    field_type = target_btype->data.block.field_types[fi];
                    break;
                }
                field_offset += type_frame_size(unwrap_ref(target_btype->data.block.field_types[fi]));
            }
            if (!field_found) {
                fprintf(stderr, "vm emitter: $member: field '%.*s' not found\n",
                        (int)field_name.len, field_name.ptr);
                return false;
            }

            /* determine target kind */
            bool is_parent_target = false;
            bool is_global_target = false;
            if (target->kind == AST_BUILTIN && e->interns && target->op) {
                Str tname = interns_lookup(e->interns, target->op);
                is_parent_target = (tname.len == 7 && memcmp(tname.ptr, "$parent", 7) == 0);
                is_global_target = (tname.len == 7 && memcmp(tname.ptr, "$global", 7) == 0);
            }

            if (is_parent_target) {
                /* PLOAD: load from (parent_base + field_offset) where parent_base is frame[0] */
                return emit_op_i32(e, VM_OP_PLOAD, (int32_t)field_offset);
            }

            if (is_global_target) {
                /* Global frame access: GLOBAL + ALOAD(field_off) for scalar fields,
                 * or ICONST(field_off) for block sub-fields (address of the sub-section). */
                const MorphlType* ft = unwrap_ref(field_type);
                if (ft && ft->kind == MORPHL_TYPE_BLOCK) {
                    /* Return address of the sub-block section in the global frame */
                    return emit_iconst(e, (int64_t)field_offset);
                }
                /* Scalar: push global base (0) and ALOAD field_off */
                return emit_op(e, VM_OP_GLOBAL) && emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
            }

            /* computed expression target (e.g. $member $global $modules, or module frame addr):
             * emit the target expression (pushes an i64 base address), then ALOAD field_off. */
            if (target->kind == AST_BUILTIN) {
                if (!emit_node(e, target)) return false;
                return emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
            }

            /* regular local block field access: ILOAD at (target_frame_offset + field_offset) */
            if (target->kind != AST_IDENT) {
                fprintf(stderr, "vm emitter: $member: non-$parent target must be identifier\n");
                return false;
            }
            Str target_name = alias_resolve(e, target->value);
            ptrdiff_t target_off = morphl_backend_find_offset(&e->frameInfo, target_name);
            if (target_off == PTRDIFF_MAX) {
                fprintf(stderr, "vm emitter: $member: undefined variable '%.*s'\n",
                        (int)target_name.len, target_name.ptr);
                return false;
            }
            uint8_t lop = load_op(unwrap_ref(field_type));
            if (lop == 0xFF) {
                fprintf(stderr, "vm emitter: $member: unsupported field type for load\n");
                return false;
            }
            return emit_op_i32(e, lop, (int32_t)(target_off + field_offset));
        }

        /* $traits { $prop... } — trait type declaration; emit the block's init code */
        if (OP_IS("$traits")) {
            return node->child_count > 0 ? emit_node(e, node->children[0]) : true;
        }

        /* $impl TraitA typeD { overrides } — emit the override block if present */
        if (OP_IS("$impl")) {
            /* children: [0]=trait_ident, [1]=base_ident, [2]=override_block (optional)
             * At runtime, typeE is structurally the same as typeD for now. */
            if (node->child_count >= 3 && node->children[2]) {
                return emit_node(e, node->children[2]);
            }
            return true;
        }

        /* $null — push null reference (absolute address 0) */
        if (OP_IS("$null")) {
            return emit_op(e, VM_OP_RNULL);
        }

        /* $new — re-execute a block's init function to produce a fresh instance */
        if (OP_IS("$new")) {
            if (node->child_count < 1 || !node->children[0]) return false;
            struct AstNode* block_ref = node->children[0];
            /* resolve the block name to its deferred function index */
            Str block_name = block_ref->kind == AST_IDENT ? block_ref->value : (Str){NULL, 0};
            if (!block_name.ptr) {
                fprintf(stderr, "vm emitter: $new requires an identifier\n");
                return false;
            }
            uint32_t fidx = UINT32_MAX;
            for (size_t d = 0; d < e->deferred_count; d++) {
                if (str_eq(e->deferred[d].name, block_name)) {
                    fidx = (uint32_t)e->deferred[d].func_idx;
                    break;
                }
            }
            if (fidx == UINT32_MAX) {
                fprintf(stderr, "vm emitter: $new: unknown block '%.*s'\n",
                        (int)block_name.len, block_name.ptr);
                return false;
            }
            /* determine block size from the function's frame */
            uint32_t block_sz = (uint32_t)(e->functions.items[fidx].frame_size);
            if (!emit_op_u32(e, VM_OP_RESERVE, block_sz)) return false;
            return emit_op_u32(e, VM_OP_CALL, fidx);
        }

        /* $exit [expr] — exit program with given code (default 0) */
        if (OP_IS("$exit")) {
            if (node->child_count > 0 && node->children[0]) {
                if (!emit_node(e, node->children[0])) return false;
            } else {
                if (!emit_iconst(e, 0)) return false;
            }
            return emit_op(e, VM_OP_EXIT);
        }

        /* $if (parsed as AST_BUILTIN with $if in some grammar versions) */
        if (OP_IS("$if")) {
            /* re-use AST_IF logic */
            struct AstNode tmp = *node;
            tmp.kind = AST_IF;
            return emit_node(e, &tmp);
        }

        /* $while cond body — backwards-jump loop */
        if (OP_IS("$while")) {
            if (node->child_count < 2) return false;

            size_t loop_start = label_new(e);
            size_t exit_lbl   = label_new(e);
            if (loop_start == SIZE_MAX || exit_lbl == SIZE_MAX) return false;

            /* push loop context so $break/$continue can resolve targets */
            if (e->loop_stack_count >= e->loop_stack_capacity) {
                if (!vm_grow((void**)&e->loop_stack, &e->loop_stack_capacity,
                             sizeof(VmLoopCtx), e->loop_stack_count + 1)) return false;
            }
            e->loop_stack[e->loop_stack_count++] = (VmLoopCtx){ exit_lbl, loop_start, e->scope_depth };

            /* bind loop_start before condition (continue jumps here) */
            if (!label_bind(e, loop_start))        { e->loop_stack_count--; return false; }
            if (!emit_node(e, node->children[0]))   { e->loop_stack_count--; return false; }
            /* negate condition: ICONST 0, IEQ → 1 when condition is false */
            if (!emit_iconst(e, 0))                 { e->loop_stack_count--; return false; }
            if (!emit_op(e, VM_OP_IEQ))             { e->loop_stack_count--; return false; }
            /* jump to exit if condition was false */
            if (!emit_jump(e, VM_OP_JIF, exit_lbl)) { e->loop_stack_count--; return false; }
            /* Emit body inline — do NOT call emit_node(body) for an AST_BLOCK here.
             * emit_node for AST_BLOCK would push a new logical emitter frame, making
             * outer-scope vars appear at negative offsets (the $parent cross-function
             * convention). Instead we emit ENTER/children/LEAVE without a frame push,
             * so outer vars like the loop counter remain at their correct positive offsets.
             * $break/$continue now emit LEAVE instructions for any nested scopes
             * before jumping, so nested sub-blocks are correctly unwound. */
            struct AstNode* body = node->children[1];
            if (body && body->kind == AST_BLOCK) {
                size_t bsz = block_scope_size(body);
                if (bsz > 0 && !emit_enter(e, (uint32_t)bsz))
                    { e->loop_stack_count--; return false; }
                for (size_t k = 0; k < body->child_count; k++) {
                    if (!emit_node(e, body->children[k]))
                        { e->loop_stack_count--; return false; }
                }
                if (bsz > 0 && !emit_leave(e, (uint32_t)bsz))
                    { e->loop_stack_count--; return false; }
            } else if (body) {
                if (!emit_node(e, body)) { e->loop_stack_count--; return false; }
            }
            /* unconditional backward jump to re-evaluate condition */
            if (!emit_jump(e, VM_OP_JMP, loop_start)) { e->loop_stack_count--; return false; }

            e->loop_stack_count--;
            return label_bind(e, exit_lbl);
        }

        /* $not expr — logical negation (ICONST 0, IEQ → 1 if false, 0 if true) */
        if (OP_IS("$not")) {
            if (node->child_count < 1) return false;
            return emit_node(e, node->children[0]) &&
                   emit_iconst(e, 0) &&
                   emit_op(e, VM_OP_IEQ);
        }

        /* $and lhs rhs — short-circuit: skip rhs if lhs is false */
        if (OP_IS("$and")) {
            if (node->child_count < 2) return false;
            size_t false_lbl = label_new(e);
            size_t end_lbl   = label_new(e);
            if (false_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;

            if (!emit_node(e, node->children[0])) return false;
            if (!emit_iconst(e, 0)) return false;
            if (!emit_op(e, VM_OP_IEQ)) return false;      /* negate: 1 if lhs false */
            if (!emit_jump(e, VM_OP_JIF, false_lbl)) return false;

            if (!emit_node(e, node->children[1])) return false;
            if (!emit_iconst(e, 0)) return false;
            if (!emit_op(e, VM_OP_INEQ)) return false;     /* normalize rhs → 0/1 */
            if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;

            if (!label_bind(e, false_lbl)) return false;
            if (!emit_iconst(e, 0)) return false;
            return label_bind(e, end_lbl);
        }

        /* $or lhs rhs — short-circuit: skip rhs if lhs is true */
        if (OP_IS("$or")) {
            if (node->child_count < 2) return false;
            size_t true_lbl = label_new(e);
            size_t end_lbl  = label_new(e);
            if (true_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;

            if (!emit_node(e, node->children[0])) return false;
            if (!emit_iconst(e, 0)) return false;
            if (!emit_op(e, VM_OP_INEQ)) return false;     /* 1 if lhs truthy */
            if (!emit_jump(e, VM_OP_JIF, true_lbl)) return false;

            if (!emit_node(e, node->children[1])) return false;
            if (!emit_iconst(e, 0)) return false;
            if (!emit_op(e, VM_OP_INEQ)) return false;     /* normalize rhs → 0/1 */
            if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;

            if (!label_bind(e, true_lbl)) return false;
            if (!emit_iconst(e, 1)) return false;
            return label_bind(e, end_lbl);
        }

        /* $break — emit LEAVE for any nested scopes entered since the loop started,
         * then jump to the loop's exit label. */
        if (OP_IS("$break")) {
            if (e->loop_stack_count == 0) {
                fprintf(stderr, "vm emitter: $break outside loop at %s:%zu:%zu\n",
                        node->filename ? node->filename : "?", node->row, node->col);
                return false;
            }
            size_t loop_depth = e->loop_stack[e->loop_stack_count - 1].scope_depth_at_entry;
            for (size_t d = e->scope_depth; d > loop_depth; d--) {
                if (!emit_op_u32(e, VM_OP_LEAVE, e->scope_sizes[d - 1])) return false;
            }
            return emit_jump(e, VM_OP_JMP,
                             e->loop_stack[e->loop_stack_count - 1].break_label);
        }

        /* $continue — emit LEAVE for nested scopes, then jump to loop condition. */
        if (OP_IS("$continue")) {
            if (e->loop_stack_count == 0) {
                fprintf(stderr, "vm emitter: $continue outside loop at %s:%zu:%zu\n",
                        node->filename ? node->filename : "?", node->row, node->col);
                return false;
            }
            size_t loop_depth = e->loop_stack[e->loop_stack_count - 1].scope_depth_at_entry;
            for (size_t d = e->scope_depth; d > loop_depth; d--) {
                if (!emit_op_u32(e, VM_OP_LEAVE, e->scope_sizes[d - 1])) return false;
            }
            return emit_jump(e, VM_OP_JMP,
                             e->loop_stack[e->loop_stack_count - 1].continue_label);
        }

        /* type conversions */
        if (OP_IS("$i2f")) {
            return node->child_count > 0 && emit_node(e, node->children[0]) &&
                   emit_op(e, VM_OP_I2F);
        }
        if (OP_IS("$f2i")) {
            return node->child_count > 0 && emit_node(e, node->children[0]) &&
                   emit_op(e, VM_OP_F2I);
        }

        /* string comparison: $eq and $neq on string operands use SEQ/SNEQ */
        if ((op_name.len == 3 && memcmp(op_name.ptr, "$eq",  3) == 0) ||
            (op_name.len == 4 && memcmp(op_name.ptr, "$neq", 4) == 0)) {
            if (node->child_count >= 2) {
                const MorphlType* lhs_t = unwrap_ref(
                    node->children[0]->type ? node->children[0]->type : node->type);
                if (lhs_t && lhs_t->kind == MORPHL_TYPE_STRING) {
                    if (!emit_node(e, node->children[0])) return false;
                    if (!emit_node(e, node->children[1])) return false;
                    bool is_eq = (op_name.len == 3);
                    return emit_op(e, is_eq ? VM_OP_SEQ : VM_OP_SNEQ);
                }
            }
        }

        /* binary arithmetic / comparison */
        struct { const char* name; uint8_t iop; uint8_t fop; } binops[] = {
            {"$add",  VM_OP_IADD,  VM_OP_FADD},
            {"$sub",  VM_OP_ISUB,  VM_OP_FSUB},
            {"$mul",  VM_OP_IMUL,  VM_OP_FMUL},
            {"$div",  VM_OP_IDIV,  VM_OP_FDIV},
            {"$mod",  VM_OP_IMOD,  0xFF},
            {"$eq",   VM_OP_IEQ,   VM_OP_FEQ},
            {"$neq",  VM_OP_INEQ,  VM_OP_FNEQ},
            {"$lt",   VM_OP_ILT,   VM_OP_FLT},
            {"$gt",   VM_OP_IGT,   VM_OP_FGT},
            {"$lte",  VM_OP_ILTE,  VM_OP_FLTE},
            {"$gte",  VM_OP_IGTE,  VM_OP_FGTE},
            /* float-specific aliases (produced by grammar overload resolution) */
            {"$fadd", 0xFF, VM_OP_FADD},
            {"$fsub", 0xFF, VM_OP_FSUB},
            {"$fmul", 0xFF, VM_OP_FMUL},
            {"$fdiv", 0xFF, VM_OP_FDIV},
        };
        for (size_t i = 0; i < sizeof(binops)/sizeof(binops[0]); i++) {
            size_t nlen = strlen(binops[i].name);
            if (op_name.len == nlen && memcmp(op_name.ptr, binops[i].name, nlen) == 0) {
                if (node->child_count < 2) return false;
                if (!emit_node(e, node->children[0])) return false;
                if (!emit_node(e, node->children[1])) return false;
                /* choose int or float variant based on first operand's type */
                const MorphlType* lhs_t = unwrap_ref(
                    node->children[0]->type ? node->children[0]->type : node->type);
                bool is_float = lhs_t && lhs_t->kind == MORPHL_TYPE_FLOAT;
                uint8_t op_byte = is_float ? binops[i].fop : binops[i].iop;
                if (op_byte == 0xFF) {
                    fprintf(stderr, "vm emitter: operator '%.*s' not supported for float\n",
                            (int)op_name.len, op_name.ptr);
                    return false;
                }
                return emit_op(e, op_byte);
            }
        }

        /* $global — push absolute stack address 0 (global frame base) */
        if (OP_IS("$global")) {
            return emit_op(e, VM_OP_GLOBAL);
        }

        /* $import "file" — the child was already replaced with the parsed AST_FILE
         * by pp_action_import in operators.c. Emit module initialization inline, then
         * record the module's absolute stack address in the global $modules slot.
         * The import variable name is already registered in the parent AST_DECL handler;
         * we find its frame offset and use global_frame_size + m_off as the slot value. */
        if (OP_IS("$import")) {
            if (node->child_count < 1 || !node->children[0]) return false;
            struct AstNode* module_file = node->children[0];
            /* emit the module's initialization code; the parent AST_DECL handler
             * handles writing the $modules global slot after this returns */
            return emit_node(e, module_file);
        }

#undef OP_IS

        fprintf(stderr, "vm emitter: unhandled builtin '%.*s' at %s:%zu:%zu\n",
                (int)op_name.len, op_name.ptr,
                node->filename ? node->filename : "?", node->row, node->col);
        return false;
    }

    /* ── function definitions (deferred) ── */
    case AST_FUNC:
        /* AST_FUNC nodes reachable directly (not via AST_DECL) */
        /* Allocate a slot, defer, and leave nothing on the eval stack (anonymous). */
        {
            size_t fidx = func_alloc(e);
            if (fidx == SIZE_MAX) return false;
            if (e->deferred_count >= e->deferred_capacity) {
                if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                             sizeof(DeferredFunc), e->deferred_count + 1)) return false;
            }
            e->deferred[e->deferred_count++] = (DeferredFunc){ node, fidx, {NULL, 0} };
            return emit_iconst(e, (int64_t)fidx);
        }

    default:
        fprintf(stderr, "vm emitter: unsupported AST kind %d at %s:%zu:%zu\n",
                node->kind, node->filename ? node->filename : "?", node->row, node->col);
        return false;
    }
}

/* ── emit a deferred function body ──────────────────────────────────────── */

static bool emit_function_body(VmEmitter* e, struct AstNode* func_node, size_t func_idx) {
    if (!func_node || func_node->kind != AST_FUNC) return false;
    if (func_node->child_count < 2) return false;
    bool saved_in_function = e->in_function;
    size_t saved_scope_depth = e->scope_depth;
    e->in_function = true;
    e->scope_depth = 0; /* reset scope tracking for this function body */

    struct AstNode* params = func_node->children[0]; /* AST_GROUP of AST_DECL */
    struct AstNode* body   = func_node->children[1]; /* AST_BLOCK */

    /* record entry point */
    e->functions.items[func_idx].entry_point = (uint32_t)e->code.len;

    /* collect parameter decl nodes (handles both single AST_DECL and AST_GROUP) */
    struct AstNode** param_decls = NULL;
    size_t           param_count = 0;
    if (params) {
        if (params->kind == AST_DECL) {
            param_decls = &func_node->children[0];
            param_count = 1;
        } else if (params->kind == AST_GROUP) {
            param_decls = params->children;
            param_count = params->child_count;
        }
    }

    /* compute param size */
    size_t param_sz = 0;
    for (size_t i = 0; i < param_count; i++) {
        struct AstNode* p = param_decls[i];
        if (p && p->type) {
            param_sz += type_frame_size(unwrap_ref(p->type));
        }
    }
    e->functions.items[func_idx].param_size = (uint32_t)param_sz;

    /* push param scope */
    if (!morphl_backend_push_frame(&e->frameInfo)) return false;

    /* register parameters in frame */
    for (size_t i = 0; i < param_count; i++) {
        struct AstNode* p = param_decls[i];
        if (!p || p->kind != AST_DECL || p->child_count < 1) continue;
        struct AstNode* pname = p->children[0];
        if (!pname || pname->kind != AST_IDENT) continue;
        const MorphlType* pt = unwrap_ref(p->type);
        struct MorphlBackendFrameOffset foff = {
            .name = pname->value,
            .size = type_frame_size(pt)
        };
        if (!morphl_backend_append_offset(&e->frameInfo, foff)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
    }

    /* emit ENTER for params */
    if (!emit_enter(e, (uint32_t)param_sz)) {
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
    }

    /* emit body block without its own ENTER/LEAVE wrapping —
       we emit it as a sequence of statements directly.
       The first 8 bytes of the body frame are reserved for the hidden $parent slot,
       which holds the absolute stack address of the caller's frame[0].
       This slot is populated at function entry by copying from the hidden parent arg
       at frame[-(param_sz + 8)], which the caller pushes before actual arguments. */
    size_t body_scope_sz_raw = body ? block_scope_size(body) : 0;
    size_t body_scope_sz = body_scope_sz_raw + 8; /* +8 for implicit $parent slot */
    {
        if (!morphl_backend_push_frame(&e->frameInfo)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        /* register $parent slot as first body frame entry (offset 0, 8 bytes) */
        struct MorphlBackendFrameOffset parent_foff = {
            .name = str_from("$parent", 7),
            .size = 8
        };
        if (!morphl_backend_append_offset(&e->frameInfo, parent_foff)) {
            morphl_backend_pop_frame(&e->frameInfo);
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        if (!emit_enter(e, (uint32_t)body_scope_sz)) {
            morphl_backend_pop_frame(&e->frameInfo);
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        /* copy hidden parent arg from frame[-(param_sz+8)] into the $parent slot at frame[0] */
        if (!emit_op_i32(e, VM_OP_ILOAD, -(int32_t)(param_sz + 8))) {
            morphl_backend_pop_frame(&e->frameInfo);
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        if (!emit_op_i32(e, VM_OP_ISTORE, 0)) {
            morphl_backend_pop_frame(&e->frameInfo);
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
    }

    if (body) {
        for (size_t i = 0; i < body->child_count; i++) {
            if (!emit_node(e, body->children[i])) {
                if (body_scope_sz > 0) morphl_backend_pop_frame(&e->frameInfo);
                morphl_backend_pop_frame(&e->frameInfo);
                return false;
            }
        }
    }

    if (body_scope_sz > 0) {
        emit_leave(e, (uint32_t)body_scope_sz);
        morphl_backend_pop_frame(&e->frameInfo);
    }

    /* implicit RET at end of body */
    if (!emit_op(e, VM_OP_RET)) {
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
    }

    /* record frame size: params + body locals (including the 8-byte $parent slot) */
    e->functions.items[func_idx].frame_size = (uint32_t)(param_sz + body_scope_sz);

    morphl_backend_pop_frame(&e->frameInfo);
    e->in_function = saved_in_function;
    e->scope_depth = saved_scope_depth;
    return true;
}

/* ── emitter cleanup ────────────────────────────────────────────────────── */

static void emitter_free(VmEmitter* e) {
    free(e->code.data);
    free(e->functions.items);
    free(e->patches.items);
    free(e->labels.offsets);
    free(e->deferred);
    free(e->ref_aliases);
    free(e->loop_stack);
    free(e->scope_sizes);
    free(e->import_slots);
    for (size_t i = 0; i < e->str_count; i++) free(e->str_table[i]);
    free(e->str_table);
    for (size_t i = 0; i < e->native_sym_count; i++) free(e->native_syms[i]);
    free(e->native_syms);
    morphl_backend_frame_free(&e->frameInfo);
    memset(e, 0, sizeof(*e));
}

/* ── pre-pass: count $import declarations in the root AST_FILE ─────────── */

static size_t count_imports(InternTable* interns, struct AstNode* root) {
    if (!root || root->kind != AST_FILE || !interns) return 0;
    Sym import_sym = interns_intern(interns, str_from("$import", 7));
    size_t count = 0;
    for (size_t i = 0; i < root->child_count; i++) {
        struct AstNode* child = root->children[i];
        if (child && child->kind == AST_DECL && child->child_count >= 2) {
            struct AstNode* rhs = child->children[1];
            if (rhs && rhs->kind == AST_BUILTIN && rhs->op == import_sym) {
                count++;
            }
        }
    }
    return count;
}

/* ── public backend entry point ─────────────────────────────────────────── */

bool morphl_backend_func_vm(MorphlBackendContext* context) {
    if (!context || !context->out_file || !context->tree) return false;

    VmEmitter e;
    memset(&e, 0, sizeof(e));
    e.interns         = context->type_context ? context->type_context->interns : NULL;
    e.type_ctx        = context->type_context;
    e.main_func_fidx  = SIZE_MAX;
    e.frameInfo       = morphl_backend_frame_init();
    if (!e.frameInfo.root) { emitter_free(&e); return false; }

    /* pre-pass: compute global_frame_size = 32 + 8 * import_count */
    {
        size_t import_count = count_imports(e.interns, context->tree);
        e.global_frame_size = 32 + 8 * import_count;
    }

    /* function 0 = top-level program (implicit main) */
    size_t main_idx = func_alloc(&e);
    if (main_idx == SIZE_MAX) { emitter_free(&e); return false; }
    e.functions.items[main_idx].entry_point = 0; /* set after emission */

    /* emit global frame initialization: write $entry = global_frame_size to global[24] */
    e.functions.items[main_idx].entry_point = (uint32_t)e.code.len;
    {
        /* GLOBAL; ICONST global_frame_size; ASTORE 24 */
        bool ok = emit_op(&e, VM_OP_GLOBAL)
               && emit_iconst(&e, (int64_t)e.global_frame_size)
               && emit_op_i32(&e, VM_OP_ASTORE, 24);
        if (!ok) { emitter_free(&e); return false; }
    }

    /* emit top-level code */
    if (!emit_node(&e, context->tree)) {
        emitter_free(&e);
        return false;
    }
    /* if a top-level 'main : () => i32' was declared, auto-call it and exit */
    if (e.main_func_fidx != SIZE_MAX) {
        /* RESERVE 8 (i32 return slot), ADDREF 0 (hidden parent), CALL main, EXIT */
        if (!emit_op_u32(&e, VM_OP_RESERVE, 8) ||
            !emit_op_i32(&e, VM_OP_ADDREF, 0)  ||
            !emit_op_u32(&e, VM_OP_CALL, (uint32_t)e.main_func_fidx) ||
            !emit_op(&e, VM_OP_EXIT)) {
            emitter_free(&e);
            return false;
        }
    }

    if (!emit_op(&e, VM_OP_HALT)) {
        emitter_free(&e);
        return false;
    }
    e.functions.items[main_idx].frame_size = 0; /* top-level has no single frame */

    /* emit all deferred function bodies */
    for (size_t i = 0; i < e.deferred_count; i++) {
        if (!emit_function_body(&e, e.deferred[i].node, e.deferred[i].func_idx)) {
            emitter_free(&e);
            return false;
        }
    }

    /* apply jump patches */
    if (!patches_apply(&e)) {
        emitter_free(&e);
        return false;
    }

    /* serialize to file */
    FILE* out = fopen(context->out_file, "wb");
    if (!out) { emitter_free(&e); return false; }

    VmBytes file = {0};
    bool ok = true;

    /* header */
    ok = ok && bytes_push(&file, MORPHL_VM_MAGIC, 4);
    ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MAJOR);
    ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MINOR);
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.global_frame_size); /* global_frame_size */

    /* function table */
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.functions.count);
    for (size_t i = 0; ok && i < e.functions.count; i++) {
        VmFunctionMeta* fn = &e.functions.items[i];
        ok = ok && bytes_push_u32_le(&file, fn->entry_point);
        ok = ok && bytes_push_u32_le(&file, fn->frame_size);
        ok = ok && bytes_push_u32_le(&file, fn->param_size);
        ok = ok && bytes_push_u32_le(&file, fn->flags);
    }

    /* code section */
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.code.len);
    ok = ok && bytes_push(&file, e.code.data, e.code.len);

    /* string table: u32 count, then for each entry: u32 len + bytes (null-terminated) */
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.str_count);
    for (size_t i = 0; ok && i < e.str_count; i++) {
        uint32_t slen = (uint32_t)strlen(e.str_table[i]);
        ok = ok && bytes_push_u32_le(&file, slen);
        ok = ok && bytes_push(&file, (const uint8_t*)e.str_table[i], slen + 1); /* +1 for NUL */
    }

    /* native symbol table: u32 count, then for each entry: u32 len + bytes (null-terminated) */
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.native_sym_count);
    for (size_t i = 0; ok && i < e.native_sym_count; i++) {
        uint32_t nlen = (uint32_t)strlen(e.native_syms[i]);
        ok = ok && bytes_push_u32_le(&file, nlen);
        ok = ok && bytes_push(&file, (const uint8_t*)e.native_syms[i], nlen + 1); /* +1 for NUL */
    }

    if (ok) ok = (fwrite(file.data, 1, file.len, out) == file.len);

    fclose(out);
    free(file.data);
    emitter_free(&e);
    return ok;
}
