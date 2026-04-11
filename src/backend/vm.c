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

/* ── type helpers ───────────────────────────────────────────────────────── */

static size_t type_frame_size(const MorphlType* t) {
    if (!t) return 0;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_FLOAT:
        case MORPHL_TYPE_BOOL:   return 8;   /* stored as i64 or f64 */
        case MORPHL_TYPE_FUNC:   return 8;   /* stored as i64 (function table index) */
        case MORPHL_TYPE_REF:    return 4;   /* i32 relative offset — TODO */
        case MORPHL_TYPE_BLOCK:  return t->size > 0 ? t->size : 0;
        default:                 return 0;
    }
}

/* load opcode for a type; returns 0xFF if unsupported */
static uint8_t load_op(const MorphlType* t) {
    if (!t) return 0xFF;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_BOOL:
        case MORPHL_TYPE_FUNC:  return VM_OP_ILOAD;
        case MORPHL_TYPE_FLOAT: return VM_OP_FLOAD;
        default:                return 0xFF;
    }
}

/* store opcode for a type; returns 0xFF if unsupported */
static uint8_t store_op(const MorphlType* t) {
    if (!t) return 0xFF;
    switch (t->kind) {
        case MORPHL_TYPE_INT:
        case MORPHL_TYPE_BOOL:
        case MORPHL_TYPE_FUNC:  return VM_OP_ISTORE;
        case MORPHL_TYPE_FLOAT: return VM_OP_FSTORE;
        default:                return 0xFF;
    }
}

/* unwrap $mut / $const / $inline ref layers to the underlying type */
static const MorphlType* unwrap_ref(const MorphlType* t) {
    while (t && t->kind == MORPHL_TYPE_REF) t = t->data.ref.target;
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
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, node->value);
        if (off == PTRDIFF_MAX) {
            fprintf(stderr, "vm emitter: undefined identifier '%.*s' at %s:%zu:%zu\n",
                    (int)node->value.len, node->value.ptr,
                    node->filename ? node->filename : "?", node->row, node->col);
            return false;
        }
        const MorphlType* t = unwrap_ref(node->type);
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
            /* store function table index as i64 in frame */
            if (!emit_iconst(e, (int64_t)fidx)) return false;
            return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
        }

        /* emit RHS expression */
        if (!emit_node(e, rhs)) return false;

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
        if (!emit_op_u32(e, VM_OP_ENTER, (uint32_t)scope_sz)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        for (size_t i = 0; i < node->child_count; i++) {
            if (!emit_node(e, node->children[i])) {
                morphl_backend_pop_frame(&e->frameInfo);
                return false;
            }
        }
        if (!emit_op_u32(e, VM_OP_LEAVE, (uint32_t)scope_sz)) {
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

        /* resolve callee to a function table index */
        if (callee->kind == AST_IDENT) {
            ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, callee->value);
            if (off == PTRDIFF_MAX) {
                fprintf(stderr, "vm emitter: undefined callee '%.*s'\n",
                        (int)callee->value.len, callee->value.ptr);
                return false;
            }
            /* load the function index (stored as i64) then call */
            if (!emit_op_i32(e, VM_OP_ILOAD, (int32_t)off)) return false;
            /*
             * We need to call by the loaded index value.
             * For now we use a simple strategy: peek at what index was stored
             * (recorded in the deferred table) by scanning deferred[].
             * TODO: implement CALLF (indirect call) for true dynamic dispatch.
             * As a workaround, we search the deferred list for the callee name.
             */
            /* Search deferred list for this callee name */
            uint32_t fidx = 0;
            bool found = false;
            for (size_t d = 0; d < e->deferred_count && !found; d++) {
                if (str_eq(e->deferred[d].name, callee->value)) {
                    fidx = (uint32_t)e->deferred[d].func_idx;
                    found = true;
                }
            }
            if (!found) {
                fprintf(stderr, "vm emitter: undefined function '%.*s'\n",
                        (int)callee->value.len, callee->value.ptr);
                return false;
            }
            /*
             * Back out the ILOAD we just emitted: trim 5 bytes (1 opcode + 4 operand).
             * Then emit CALL with the static index.
             */
            e->code.len -= 5;
            return emit_op_u32(e, VM_OP_CALL, fidx);
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
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, target->value);
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

        /* $mut / $const — transparent storage qualifiers */
        if (OP_IS("$mut") || OP_IS("$const")) {
            return node->child_count > 0 ? emit_node(e, node->children[0]) : true;
        }

        /* $if (parsed as AST_BUILTIN with $if in some grammar versions) */
        if (OP_IS("$if")) {
            /* re-use AST_IF logic */
            struct AstNode tmp = *node;
            tmp.kind = AST_IF;
            return emit_node(e, &tmp);
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
    if (!emit_op_u32(e, VM_OP_ENTER, (uint32_t)param_sz)) {
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
    }

    /* emit body block without its own ENTER/LEAVE wrapping —
       we emit it as a sequence of statements directly */
    size_t body_scope_sz = body ? block_scope_size(body) : 0;
    if (body_scope_sz > 0) {
        if (!morphl_backend_push_frame(&e->frameInfo)) {
            morphl_backend_pop_frame(&e->frameInfo);
            return false;
        }
        if (!emit_op_u32(e, VM_OP_ENTER, (uint32_t)body_scope_sz)) {
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
        emit_op_u32(e, VM_OP_LEAVE, (uint32_t)body_scope_sz);
        morphl_backend_pop_frame(&e->frameInfo);
    }

    /* implicit RET at end of body */
    if (!emit_op(e, VM_OP_RET)) {
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
    }

    /* record frame size: params + body locals */
    e->functions.items[func_idx].frame_size = (uint32_t)(param_sz + body_scope_sz);

    morphl_backend_pop_frame(&e->frameInfo);
    return true;
}

/* ── emitter cleanup ────────────────────────────────────────────────────── */

static void emitter_free(VmEmitter* e) {
    free(e->code.data);
    free(e->functions.items);
    free(e->patches.items);
    free(e->labels.offsets);
    free(e->deferred);
    morphl_backend_frame_free(&e->frameInfo);
    memset(e, 0, sizeof(*e));
}

/* ── public backend entry point ─────────────────────────────────────────── */

bool morphl_backend_func_vm(MorphlBackendContext* context) {
    if (!context || !context->out_file || !context->tree) return false;

    VmEmitter e;
    memset(&e, 0, sizeof(e));
    e.interns   = context->type_context ? context->type_context->interns : NULL;
    e.type_ctx  = context->type_context;
    e.frameInfo = morphl_backend_frame_init();
    if (!e.frameInfo.root) { emitter_free(&e); return false; }

    /* function 0 = top-level program (implicit main) */
    size_t main_idx = func_alloc(&e);
    if (main_idx == SIZE_MAX) { emitter_free(&e); return false; }
    e.functions.items[main_idx].entry_point = 0; /* set after emission */

    /* emit top-level code */
    e.functions.items[main_idx].entry_point = (uint32_t)e.code.len;
    if (!emit_node(&e, context->tree)) {
        emitter_free(&e);
        return false;
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
    ok = ok && bytes_push_u32_le(&file, 0); /* flags */

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

    if (ok) ok = (fwrite(file.data, 1, file.len, out) == file.len);

    fclose(out);
    free(file.data);
    emitter_free(&e);
    return ok;
}
