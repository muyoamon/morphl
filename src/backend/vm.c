/*
 * src/backend/vm.c — morphl VM bytecode emitter
 *
 * Lowers the AST to typed, frame-offset-based bytecode as specified in
 * SPEC.md Section 11.  Only the "core" opcode subset is emitted; reference
 * and block-instantiation opcodes are stubbed (see vm.h TODO list).
 *
 * Binary file layout (format version 0.2):
 *   [Header]         4 bytes magic + u16 major + u16 minor + u32 flags
 *   [Function Table] u32 count; then per-function: entry_point, frame_size,
 *                    param_size, flags (all u32 LE)
 *   [Code Section]   u32 code_len; then code_len bytes
 */

#include "backend/vm.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "backend/frame.h"
#include "typing/inference.h"
#include "typing/typing.h"
#include "util/error.h"
#include "util/util.h"

/* ── diagnostic helpers ──────────────────────────────────────────────────── */

/* Build a MorphlSpan from an AstNode's location fields (NULL-safe). */
static MorphlSpan vm_span_from_node(const AstNode* node) {
  if (!node) return morphl_span_unknown();
  return morphl_span_from_loc(node->filename, node->row, node->col);
}

/* Emit a compiler diagnostic through the error system with optional source
 * span. */
static void vm_diag(MorphlSeverity sev, const AstNode* node, MorphlErrCode code,
                    const char* fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 4, 5)))
#endif
    ;
static void vm_diag(MorphlSeverity sev, const AstNode* node, MorphlErrCode code,
                    const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  MorphlError err = morphl_error_makev(code, sev, vm_span_from_node(node),
                                       __FILE__, __LINE__, fmt, ap);
  va_end(ap);
  morphl_error_emit(NULL, &err);
}

#define VM_ERR(node, fmt, ...) \
  vm_diag(MORPHL_SEV_ERROR, (node), MORPHL_E_CODEGEN, fmt, ##__VA_ARGS__)
#define VM_WARN(node, fmt, ...) \
  vm_diag(MORPHL_SEV_WARN, (node), MORPHL_E_CODEGEN, fmt, ##__VA_ARGS__)

/* ── growable byte buffer ───────────────────────────────────────────────────
 */

static bool vm_grow(void** ptr, size_t* capacity, size_t elem_size,
                    size_t min) {
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
  uint8_t raw[2] = {(uint8_t)(v), (uint8_t)(v >> 8)};
  return bytes_push(b, raw, 2);
}

static bool bytes_push_u32_le(VmBytes* b, uint32_t v) {
  uint8_t raw[4] = {(uint8_t)(v), (uint8_t)(v >> 8), (uint8_t)(v >> 16),
                    (uint8_t)(v >> 24)};
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

static bool bytes_push_len_string(VmBytes* b, Str s) {
  uint32_t slen = (uint32_t)(s.ptr ? s.len : 0);
  char nul = '\0';
  return bytes_push_u32_le(b, slen) &&
         (slen == 0 || bytes_push(b, s.ptr, slen)) &&
         bytes_push(b, &nul, 1);
}

static bool path_has_suffix(const char* path, const char* suffix) {
  if (!path || !suffix) return false;
  size_t path_len = strlen(path);
  size_t suffix_len = strlen(suffix);
  if (path_len < suffix_len) return false;
  return memcmp(path + path_len - suffix_len, suffix, suffix_len) == 0;
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
  size_t patch_site; /* byte offset in code where the jump operand starts */
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
  size_t* offsets; /* SIZE_MAX = unresolved */
  size_t count, capacity;
} VmLabelTable;

typedef struct {
  struct AstNode* node;
  size_t func_idx;
  Str name; /* name of the variable holding this function */
  Str file_root;
} DeferredFunc;

typedef struct {
  Str binding_name;
  const AstNode* block;
  const MorphlType* block_type;
  const MorphlType* binding_type;
  size_t scope_depth;
  bool run_on_scope_exit;
  bool run_on_free;
} BindingCleanup;

/* Compile-time alias: $decl r $ref x makes 'r' an alias for 'x' (no frame
 * storage). extra_offset is added to the target's frame offset when resolving;
 * used for $ref of compound lvalues like $member and $index where the offset is
 * statically known. */
typedef struct {
  Str alias;
  Str target;
  ptrdiff_t extra_offset;
} RefAlias;

/* Loop context: tracks jump targets for $break/$continue inside $while bodies
 */
typedef struct {
  size_t break_label;          /* jump target for $break    (exit_label) */
  size_t continue_label;       /* jump target for $continue (loop_start) */
  size_t scope_depth_at_entry; /* emitter scope_depth when the loop started */
} VmLoopCtx;

typedef struct {
  Str name;           /* import variable name (e.g. "m") */
  size_t global_slot; /* byte offset in the global frame where this slot lives
                         (32, 40, ...) */
  Str module_path;
  AstNode* module_root;
} ImportSlot;

typedef struct {
  Str name;
  const MorphlType* type;
  size_t global_slot;
  size_t size;
  size_t guard_slot;
} StaticSlot;

typedef struct {
  const StaticSlot* slot;
  ptrdiff_t byte_offset;
  const MorphlType* value_type;
  bool is_external_import;
  Str module_path;
  Str symbol_name;
} StaticAccess;

typedef struct {
  char* full_path;
  size_t next_anon;
} LexicalScope;

/* Trait implementation entry: maps impl type name → property table offset in
 * global frame */
typedef struct {
  Str impl_name;         /* name of the implementing type (e.g., "typeE") */
  size_t prop_table_off; /* byte offset in global frame where this impl's prop
                            table starts */
  size_t prop_count;     /* number of prop slots in the property table */
} ImplEntry;

typedef struct VmEmitter {
  VmBytes code;
  VmFunctionTable functions;
  VmPatchList patches;
  VmLabelTable labels;
  DeferredFunc* deferred;
  size_t deferred_count, deferred_capacity;
  InternTable* interns;
  MorphlBackendFrameInfo frameInfo;
  TypeContext* type_ctx;
  /* return-slot offset for the current function (relative to callee frame base)
   */
  int32_t return_slot_offset;
  /* frame size accumulator for the current function scope */
  size_t current_func_frame_size;
  /* compile-time $ref aliases (local, non-struct refs) */
  RefAlias* ref_aliases;
  size_t alias_count, alias_capacity;
  /* loop context stack for $break/$continue target resolution */
  VmLoopCtx* loop_stack;
  size_t loop_stack_count, loop_stack_capacity;
  /* scope stack for unwinding: each entry is the ENTER size for that scope
   * level */
  uint32_t* scope_sizes;
  size_t scope_depth, scope_capacity;
  /* string table: collect deduplicated string literals for SCONST emission */
  char** str_table;
  size_t str_count, str_capacity;
  /* true while emitting a deferred function body (false for top-level) */
  bool in_function;
  bool emit_object;
  /* global frame: 32 bytes fixed ($argc,$argv,$env,$entry) + 8 bytes per
   * $import */
  size_t global_frame_size;
  ImportSlot* import_slots;
  size_t import_slot_count, import_slot_capacity;
  StaticSlot* static_slots;
  size_t static_slot_count, static_slot_capacity;
  size_t static_slot_base;
  size_t static_slot_ptr;
  LexicalScope* lexical_scopes;
  size_t lexical_scope_count, lexical_scope_capacity;
  BindingCleanup* binding_cleanups;
  size_t binding_cleanup_count, binding_cleanup_capacity;
  BindingCleanup* static_cleanups;
  size_t static_cleanup_count, static_cleanup_capacity;
  /* function-body $defer: collected at the top level of each function body and
   * emitted before $ret / implicit end-of-body. */
  struct AstNode** func_defers;
  size_t func_defer_count, func_defer_capacity;
  size_t func_defer_base; /* index of first defer owned by the current function */
  /* native symbol table: names of $extern declarations, in order of allocation
   */
  char** native_syms;
  size_t native_sym_count, native_sym_capacity;
  /* trait implementation property tables: stored in global frame after import
   * slots */
  ImplEntry* impl_entries;
  size_t impl_count, impl_capacity;
  size_t impl_prop_table_base; /* byte offset in global frame where prop tables
                                  start */
  size_t impl_prop_table_ptr;  /* current alloc pointer for next prop table */
  /* block declaration map: binding name → (block AST, block type) so that
     $new <ident> can find the original block for cleanup registration */
  struct VmBlockDeclEntry {
    Str name;
    struct AstNode* block;
    const MorphlType* block_type;
  } * block_decl_map;
  size_t block_decl_map_count, block_decl_map_capacity;
  /* deferred cleanup thunks: heap block decls with $defer register a generated
     cleanup function to be emitted after all other deferred functions */
  struct DeferredCleanupThunk {
    size_t fidx;
    const struct AstNode* block;
    const MorphlType* block_type;
    const MorphlType* binding_type;
    char* saved_lexical_path;  /* lexical scope path at registration time */
  } * deferred_cleanups;
  size_t deferred_cleanup_count, deferred_cleanup_capacity;
  MorphlVmRelocation* object_relocs;
  size_t object_reloc_count, object_reloc_capacity;
} VmEmitter;

typedef struct {
  Str name;
  uint16_t kind;
  uint16_t flags;
  uint32_t symbol_value;
} VmObjectExport;

typedef struct {
  Str binding_name;
  Str path;
  size_t global_slot;
  Str* required_funcs;
  size_t required_func_count;
} VmObjectImport;

/* ── opcode helpers ─────────────────────────────────────────────────────── */

static bool emit_op(VmEmitter* e, uint8_t op) {
  return bytes_push_u8(&e->code, op);
}

static bool emit_op_u32(VmEmitter* e, uint8_t op, uint32_t imm) {
  return emit_op(e, op) && bytes_push_u32_le(&e->code, imm);
}

static bool emit_object_reloc(VmEmitter* e, uint16_t kind, size_t code_offset) {
  if (!e || !e->emit_object) return true;
  if (e->object_reloc_count >= e->object_reloc_capacity) {
    if (!vm_grow((void**)&e->object_relocs, &e->object_reloc_capacity,
                 sizeof(MorphlVmRelocation), e->object_reloc_count + 1)) {
      return false;
    }
  }
  e->object_relocs[e->object_reloc_count++] = (MorphlVmRelocation){
      .kind = kind,
      .code_offset = (uint32_t)code_offset,
      .module_path = NULL,
      .symbol_name = NULL,
  };
  return true;
}

static bool emit_external_func_reloc(VmEmitter* e, uint16_t kind, size_t code_offset,
                                     Str module_path, Str symbol_name) {
  if (!e || !e->emit_object) return true;
  if (e->object_reloc_count >= e->object_reloc_capacity) {
    if (!vm_grow((void**)&e->object_relocs, &e->object_reloc_capacity,
                 sizeof(MorphlVmRelocation), e->object_reloc_count + 1)) {
      return false;
    }
  }
  char* path_copy = (char*)malloc(module_path.len + 1);
  char* sym_copy = (char*)malloc(symbol_name.len + 1);
  if (!path_copy || !sym_copy) {
    free(path_copy);
    free(sym_copy);
    return false;
  }
  memcpy(path_copy, module_path.ptr, module_path.len);
  path_copy[module_path.len] = '\0';
  memcpy(sym_copy, symbol_name.ptr, symbol_name.len);
  sym_copy[symbol_name.len] = '\0';
  e->object_relocs[e->object_reloc_count++] = (MorphlVmRelocation){
      .kind = kind,
      .code_offset = (uint32_t)code_offset,
      .module_path = path_copy,
      .symbol_name = sym_copy,
  };
  return true;
}

static const ImportSlot* import_slot_by_global_slot(const VmEmitter* e,
                                                    size_t global_slot) {
  if (!e) return NULL;
  for (size_t i = 0; i < e->import_slot_count; ++i) {
    if (e->import_slots[i].global_slot == global_slot) return &e->import_slots[i];
  }
  return NULL;
}

static bool emit_op_i32(VmEmitter* e, uint8_t op, int32_t imm) {
  return emit_op(e, op) && bytes_push_i32_le(&e->code, imm);
}

static bool emit_iconst(VmEmitter* e, int64_t v) {
  return emit_op(e, VM_OP_ICONST) && bytes_push_i64_le(&e->code, v);
}

static bool emit_global_offset_i32(VmEmitter* e, uint8_t op, size_t off) {
  if (!emit_op(e, op)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i32_le(&e->code, (int32_t)off)) return false;
  if (e && e->emit_object && off >= 32) {
    const ImportSlot* import_slot = import_slot_by_global_slot(e, off);
    if (import_slot) {
      return emit_external_func_reloc(e, MORPHL_VM_RELOC_MODULE_SLOT_I32,
                                      operand_off, import_slot->module_path,
                                      str_from("", 0));
    }
    return emit_object_reloc(e, MORPHL_VM_RELOC_GLOBAL_DATA_I32, operand_off);
  }
  return true;
}

static bool emit_global_offset_iconst(VmEmitter* e, size_t off) {
  if (!emit_op(e, VM_OP_ICONST)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i64_le(&e->code, (int64_t)off)) return false;
  if (e && e->emit_object && off >= 32) {
    return emit_object_reloc(e, MORPHL_VM_RELOC_GLOBAL_DATA_I64, operand_off);
  }
  return true;
}

static bool emit_module_frame_base_iconst(VmEmitter* e, int64_t base) {
  if (!emit_op(e, VM_OP_ICONST)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i64_le(&e->code, base)) return false;
  if (e && e->emit_object) {
    return emit_object_reloc(e, MORPHL_VM_RELOC_MODULE_FRAME_BASE_I64,
                             operand_off);
  }
  return true;
}

static bool emit_func_index_u32(VmEmitter* e, uint8_t op, uint32_t fidx) {
  if (!emit_op(e, op)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_u32_le(&e->code, fidx)) return false;
  return emit_object_reloc(e, MORPHL_VM_RELOC_FUNC_INDEX_U32, operand_off);
}

static bool emit_func_index_iconst(VmEmitter* e, uint32_t fidx) {
  if (!emit_op(e, VM_OP_ICONST)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i64_le(&e->code, (int64_t)fidx)) return false;
  return emit_object_reloc(e, MORPHL_VM_RELOC_FUNC_INDEX_I64, operand_off);
}

static const ImportSlot* emitter_find_import_slot(const VmEmitter* e, Str name) {
  if (!e) return NULL;
  for (size_t i = 0; i < e->import_slot_count; ++i) {
    if (str_eq(e->import_slots[i].name, name)) return &e->import_slots[i];
  }
  return NULL;
}

static const MorphlType* import_module_decl_type(const ImportSlot* slot,
                                                 Str symbol_name) {
  if (!slot || !slot->module_root) return NULL;
  AstNode* root = slot->module_root;
  if (root->kind != AST_FILE && root->kind != AST_BLOCK) return NULL;
  for (size_t i = 0; i < root->child_count; ++i) {
    AstNode* node = root->children[i];
    if (!node || node->kind != AST_DECL || node->child_count < 2 ||
        !node->children[0] || node->children[0]->kind != AST_IDENT) {
      continue;
    }
    if (str_eq(node->children[0]->value, symbol_name)) {
      return node->type;
    }
  }
  return NULL;
}

static bool emit_external_func_call(VmEmitter* e, Str module_path, Str func_name) {
  if (!emit_op(e, VM_OP_CALL)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_u32_le(&e->code, 0)) return false;
  return emit_external_func_reloc(e, MORPHL_VM_RELOC_EXTERN_FUNC_U32,
                                  operand_off, module_path, func_name);
}

static bool emit_external_func_iconst(VmEmitter* e, Str module_path, Str func_name) {
  if (!emit_op(e, VM_OP_ICONST)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i64_le(&e->code, 0)) return false;
  return emit_external_func_reloc(e, MORPHL_VM_RELOC_EXTERN_FUNC_I64,
                                  operand_off, module_path, func_name);
}

static bool emit_external_data_offset_i32(VmEmitter* e, uint8_t op,
                                          Str module_path, Str symbol_name) {
  if (!emit_op(e, op)) return false;
  size_t operand_off = e->code.len;
  if (!bytes_push_i32_le(&e->code, 0)) return false;
  return emit_external_func_reloc(e, MORPHL_VM_RELOC_EXTERN_DATA_I32,
                                  operand_off, module_path, symbol_name);
}

static bool emit_fconst(VmEmitter* e, double v) {
  return emit_op(e, VM_OP_FCONST) && bytes_push_f64_le(&e->code, v);
}

/* Add a string literal to the emitter's string table; return its index
 * (deduplicated). */
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

/* Push an ENTER scope of given size, tracking depth for $break/$continue
 * unwinding */
static bool emit_enter(VmEmitter* e, uint32_t sz) {
  if (e->scope_depth >= e->scope_capacity) {
    if (!vm_grow((void**)&e->scope_sizes, &e->scope_capacity, sizeof(uint32_t),
                 e->scope_depth + 1))
      return false;
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
                 sizeof(size_t), e->labels.count + 1))
      return SIZE_MAX;
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
                 sizeof(VmPatch), e->patches.count + 1))
      return false;
  }
  e->patches.items[e->patches.count++] = (VmPatch){site, label_id};
  return true;
}

static bool patches_apply(VmEmitter* e) {
  for (size_t i = 0; i < e->patches.count; i++) {
    VmPatch* p = &e->patches.items[i];
    if (p->label_id >= e->labels.count) return false;
    size_t target = e->labels.offsets[p->label_id];
    if (target == SIZE_MAX) {
      VM_ERR(NULL, "unresolved label %zu", p->label_id);
      return false;
    }
    /* relative offset = target - (patch_site + 4) */
    int32_t rel = (int32_t)((ptrdiff_t)target - (ptrdiff_t)(p->patch_site + 4));
    bytes_patch_u32_le(&e->code, p->patch_site, (uint32_t)rel);
  }
  return true;
}

/* ── ref alias helpers ──────────────────────────────────────────────────── */

static bool alias_add(VmEmitter* e, Str alias, Str target,
                      ptrdiff_t extra_offset) {
  if (e->alias_count >= e->alias_capacity) {
    if (!vm_grow((void**)&e->ref_aliases, &e->alias_capacity, sizeof(RefAlias),
                 e->alias_count + 1))
      return false;
  }
  e->ref_aliases[e->alias_count++] = (RefAlias){alias, target, extra_offset};
  return true;
}

/* Resolve an alias chain; also accumulate any extra byte offsets stored in
 * alias entries. Returns the final resolved name and sets *out_extra to the
 * total accumulated offset. */
static Str alias_resolve_full(VmEmitter* e, Str name, ptrdiff_t* out_extra) {
  *out_extra = 0;
  for (int depth = 0; depth < 64; depth++) {
    bool found = false;
    for (size_t i = e->alias_count; i > 0; i--) {
      RefAlias* a = &e->ref_aliases[i - 1];
      if (str_eq(a->alias, name)) {
        name = a->target;
        *out_extra += a->extra_offset;
        found = true;
        break;
      }
    }
    if (!found) break;
  }
  return name;
}

/* Resolve an alias chain to its final target name (handles chained $ref
 * aliases) */
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

static size_t align_up(size_t offset, size_t align);
static size_t type_frame_align(const MorphlType* t);
static size_t type_frame_size(const MorphlType* t);
static size_t overload_candidate_offset(const MorphlType* t, size_t index);

static const char* lexical_current_path(const VmEmitter* e) {
  if (!e || e->lexical_scope_count == 0) return "";
  return e->lexical_scopes[e->lexical_scope_count - 1].full_path;
}

static bool lexical_scope_push_full(VmEmitter* e, char* full_path) {
  if (e->lexical_scope_count >= e->lexical_scope_capacity) {
    if (!vm_grow((void**)&e->lexical_scopes, &e->lexical_scope_capacity,
                 sizeof(LexicalScope), e->lexical_scope_count + 1)) {
      free(full_path);
      return false;
    }
  }
  e->lexical_scopes[e->lexical_scope_count++] = (LexicalScope){full_path, 0};
  return true;
}

static bool lexical_scope_push_named(VmEmitter* e, Str name) {
  const char* cur = lexical_current_path(e);
  size_t cur_len = strlen(cur);
  size_t len = cur_len ? (cur_len + 1 + name.len) : name.len;
  char* full = (char*)malloc(len + 1);
  if (!full) return false;
  if (cur_len) {
    memcpy(full, cur, cur_len);
    full[cur_len] = '.';
    memcpy(full + cur_len + 1, name.ptr, name.len);
  } else if (name.len) {
    memcpy(full, name.ptr, name.len);
  }
  full[len] = '\0';
  return lexical_scope_push_full(e, full);
}

static bool lexical_scope_push_anon(VmEmitter* e) {
  size_t anon_idx = 0;
  if (e && e->lexical_scope_count > 0) {
    anon_idx = e->lexical_scopes[e->lexical_scope_count - 1].next_anon++;
  }
  char label[32];
  snprintf(label, sizeof(label), "$anon$%zu", anon_idx);
  return lexical_scope_push_named(e, str_from(label, strlen(label)));
}

static void lexical_scope_pop(VmEmitter* e) {
  if (!e || e->lexical_scope_count == 0) return;
  free(e->lexical_scopes[e->lexical_scope_count - 1].full_path);
  e->lexical_scope_count--;
}

static char* lexical_make_binding_path(const VmEmitter* e, Str name) {
  const char* cur = lexical_current_path(e);
  size_t cur_len = strlen(cur);
  size_t len = cur_len ? (cur_len + 1 + name.len) : name.len;
  char* full = (char*)malloc(len + 1);
  if (!full) return NULL;
  if (cur_len) {
    memcpy(full, cur, cur_len);
    full[cur_len] = '.';
    memcpy(full + cur_len + 1, name.ptr, name.len);
  } else if (name.len) {
    memcpy(full, name.ptr, name.len);
  }
  full[len] = '\0';
  return full;
}

static const StaticSlot* static_slot_lookup(const VmEmitter* e, Str name) {
  if (!e) return NULL;
  for (size_t i = e->static_slot_count; i > 0; --i) {
    if (str_eq(e->static_slots[i - 1].name, name))
      return &e->static_slots[i - 1];
  }
  return NULL;
}

/* Try the fully-qualified scope-prefixed path first; if that misses, fall back
 * to the bare name. This lets cleanup expressions refer to top-level statics
 * even when emitted inside a nested lexical scope. */
static const StaticSlot* static_slot_lookup_scoped(const VmEmitter* e,
                                                    Str name) {
  char* full = lexical_make_binding_path(e, name);
  const StaticSlot* slot =
      full ? static_slot_lookup(e, str_from(full, strlen(full))) : NULL;
  free(full);
  if (!slot) slot = static_slot_lookup(e, name);
  return slot;
}

static size_t static_slot_align(const MorphlType* t) {
  size_t align = type_frame_align(t);
  return align < 8 ? 8 : align;
}

static size_t static_slot_size(const MorphlType* t) {
  size_t size = type_frame_size(t);
  return size < 8 ? 8 : size;
}

static const StaticSlot* static_slot_register(VmEmitter* e, Str name,
                                              const MorphlType* t) {
  const StaticSlot* existing = static_slot_lookup(e, name);
  if (existing) return existing;
  if (e->static_slot_count >= e->static_slot_capacity) {
    if (!vm_grow((void**)&e->static_slots, &e->static_slot_capacity,
                 sizeof(StaticSlot), e->static_slot_count + 1))
      return NULL;
  }
  size_t guard_off = align_up(e->static_slot_ptr, 8);
  size_t slot_off = align_up(guard_off + 8, static_slot_align(t));
  size_t slot_size = static_slot_size(t);
  e->static_slots[e->static_slot_count++] =
      (StaticSlot){name, t, slot_off, slot_size, guard_off};
  e->static_slot_ptr = slot_off + slot_size;
  return &e->static_slots[e->static_slot_count - 1];
}

static const MorphlType* unwrap_ref(
    const MorphlType* t); /* forward declaration */
static ptrdiff_t block_layout_field_offset(const MorphlType* block_type,
                                           InternTable* interns, Str field_name,
                                           const MorphlType** out_field_type);
static size_t block_scope_size(struct AstNode* block);
static bool emit_node(VmEmitter* e, struct AstNode* node);
static bool emit_func_body_defers(VmEmitter* e);

typedef struct {
  Str name;
  AstNode* value;
} InlineParamBinding;

typedef struct {
  size_t exit_label;
  size_t return_scope_depth;
  const AstNode* call_site;
} InlineReturnCtx;

static bool builtin_is_name(const VmEmitter* e, const AstNode* node,
                            const char* name) {
  if (!node || node->kind != AST_BUILTIN) return false;
  Str op = node->value;
  if ((!op.ptr || op.len == 0) && e && e->interns && node->op) {
    op = interns_lookup(e->interns, node->op);
  }
  if (!op.ptr) return false;
  size_t len = strlen(name);
  return op.len == len && memcmp(op.ptr, name, len) == 0;
}

static bool ast_node_name(const VmEmitter* e, const AstNode* node, Str* out) {
  if (!e || !node || !out) return false;
  if ((node->kind != AST_IDENT && node->kind != AST_BUILTIN) ||
      (!node->value.ptr && !node->op)) {
    return false;
  }
  *out = node->value;
  if (!out->ptr && node->op) *out = interns_lookup(e->interns, node->op);
  return out->ptr != NULL;
}

static bool collect_member_chain(const VmEmitter* e, const AstNode* node,
                                 const AstNode** out_root, Str* segments,
                                 size_t* segment_count,
                                 size_t segment_capacity) {
  if (!e || !node || !out_root || !segments || !segment_count) return false;
  if (builtin_is_name(e, node, "$member") && node->child_count >= 2 &&
      node->children[1]) {
    if (!collect_member_chain(e, node->children[0], out_root, segments,
                              segment_count, segment_capacity)) {
      return false;
    }
    if (*segment_count >= segment_capacity) return false;
    if (!ast_node_name(e, node->children[1], &segments[*segment_count]))
      return false;
    (*segment_count)++;
    return true;
  }
  *out_root = node;
  return true;
}

static bool emitter_has_import_slot(const VmEmitter* e, Str name) {
  if (!e) return false;
  for (size_t i = 0; i < e->import_slot_count; ++i) {
    if (str_eq(e->import_slots[i].name, name)) return true;
  }
  return false;
}

static AstNode* import_module_root(const AstNode* node) {
  if (!node || node->kind != AST_BUILTIN || node->child_count < 1 ||
      !node->children[0]) {
    return NULL;
  }
  AstNode* module_file = node->children[0]->import_module;
  if (!module_file) return NULL;
  if (module_file->kind != AST_FILE && module_file->kind != AST_BLOCK) return NULL;
  return module_file;
}

static bool collect_object_exports(VmEmitter* e, AstNode* root,
                                   VmObjectExport** out_items,
                                   size_t* out_count) {
  if (!e || !root || !out_items || !out_count) return false;
  *out_items = NULL;
  *out_count = 0;
  size_t cap = 0;
  if (root->kind != AST_FILE && root->kind != AST_BLOCK) return true;
  for (size_t i = 0; i < root->child_count; ++i) {
    AstNode* node = root->children[i];
    if (!node || node->kind != AST_DECL || node->child_count < 2 ||
        !node->children[0] || node->children[0]->kind != AST_IDENT) {
      continue;
    }
    if (*out_count >= cap) {
      size_t new_cap = cap ? cap * 2 : 8;
      if (!vm_grow((void**)out_items, &cap, sizeof(VmObjectExport),
                   *out_count + 1)) {
        free(*out_items);
        *out_items = NULL;
        *out_count = 0;
        return false;
      }
      if (new_cap > cap) cap = new_cap;
    }
    const MorphlType* t = node->type ? unwrap_ref(node->type) : NULL;
    uint16_t kind =
        (t && t->kind == MORPHL_TYPE_FUNC) ? MORPHL_VM_EXPORT_FUNCTION
                                           : MORPHL_VM_EXPORT_VALUE;
    uint16_t flags = 0;
    uint32_t symbol_value = UINT32_MAX;
    if (node->storage_residence == MORPHL_STORAGE_STATIC)
      flags |= MORPHL_VM_EXPORT_FLAG_STATIC;
    if (node->storage_residence == MORPHL_STORAGE_IMPORT)
      flags |= MORPHL_VM_EXPORT_FLAG_IMPORT;
    if (node->storage_residence == MORPHL_STORAGE_EXTERN)
      flags |= MORPHL_VM_EXPORT_FLAG_EXTERN;
    if (kind == MORPHL_VM_EXPORT_FUNCTION) {
      for (size_t di = 0; di < e->deferred_count; ++di) {
        if (str_eq(e->deferred[di].name, node->children[0]->value) &&
            (!e->deferred[di].file_root.ptr || e->deferred[di].file_root.len == 0)) {
          symbol_value = (uint32_t)e->deferred[di].func_idx;
          break;
        }
      }
      if (symbol_value == UINT32_MAX) kind = MORPHL_VM_EXPORT_VALUE;
    } else if (node->storage_residence == MORPHL_STORAGE_STATIC) {
      const StaticSlot* slot = static_slot_lookup(e, node->children[0]->value);
      if (slot) symbol_value = (uint32_t)slot->global_slot;
    } else if (node->storage_residence == MORPHL_STORAGE_IMPORT) {
      const ImportSlot* import_slot =
          emitter_find_import_slot(e, node->children[0]->value);
      if (import_slot) symbol_value = (uint32_t)import_slot->global_slot;
    }
    (*out_items)[(*out_count)++] = (VmObjectExport){
        .name = node->children[0]->value,
        .kind = kind,
        .flags = flags,
        .symbol_value = symbol_value,
    };
  }
  return true;
}

static bool collect_object_imports(const VmEmitter* e, AstNode* root,
                                   VmObjectImport** out_items,
                                   size_t* out_count) {
  if (!e || !root || !out_items || !out_count) return false;
  *out_items = NULL;
  *out_count = 0;
  size_t cap = 0;
  if (root->kind != AST_FILE && root->kind != AST_BLOCK) return true;
  for (size_t i = 0; i < root->child_count; ++i) {
    AstNode* node = root->children[i];
    if (!node || node->kind != AST_DECL || node->child_count < 2) continue;
    AstNode* rhs = node->children[1];
    if (!rhs || import_module_root(rhs) == NULL || rhs->child_count < 1 ||
        !rhs->children[0] || !rhs->children[0]->import_path.ptr) {
      continue;
    }
    Str import_path = rhs->children[0]->import_path;
    if (*out_count >= cap) {
      size_t new_cap = cap ? cap * 2 : 4;
      if (!vm_grow((void**)out_items, &cap, sizeof(VmObjectImport),
                   *out_count + 1)) {
        free(*out_items);
        *out_items = NULL;
        *out_count = 0;
        return false;
      }
      if (new_cap > cap) cap = new_cap;
    }
    VmObjectImport* entry = &(*out_items)[(*out_count)++];
    entry->binding_name = node->children[0]->value;
    entry->path = import_path;
    entry->global_slot = 0;
    entry->required_funcs = NULL;
    entry->required_func_count = 0;
    {
      const ImportSlot* slot = emitter_find_import_slot(e, entry->binding_name);
      if (slot) entry->global_slot = slot->global_slot;
    }
    AstNode* module_root = import_module_root(rhs);
    if (!module_root || (module_root->kind != AST_FILE && module_root->kind != AST_BLOCK))
      continue;
    size_t req_cap = 0;
    for (size_t mi = 0; mi < module_root->child_count; ++mi) {
      AstNode* mnode = module_root->children[mi];
      if (!mnode || mnode->kind != AST_DECL || mnode->child_count < 2 ||
          !mnode->children[0] || mnode->children[0]->kind != AST_IDENT) {
        continue;
      }
      if (mnode->storage_residence == MORPHL_STORAGE_EXTERN) continue;
      const MorphlType* mt = mnode->type ? unwrap_ref(mnode->type) : NULL;
      if (!mt || mt->kind != MORPHL_TYPE_FUNC) continue;
      if (entry->required_func_count >= req_cap) {
        if (!vm_grow((void**)&entry->required_funcs, &req_cap, sizeof(Str),
                     entry->required_func_count + 1)) {
          free(entry->required_funcs);
          entry->required_funcs = NULL;
          entry->required_func_count = 0;
          return false;
        }
      }
      entry->required_funcs[entry->required_func_count++] =
          mnode->children[0]->value;
    }
  }
  return true;
}

static Str current_file_root_prefix(const VmEmitter* e) {
  Str empty = {NULL, 0};
  if (!e) return empty;
  const char* cur = lexical_current_path(e);
  if (!cur || !cur[0]) return empty;
  const char* dot = strchr(cur, '.');
  size_t len = dot ? (size_t)(dot - cur) : strlen(cur);
  for (size_t i = 0; i < e->import_slot_count; ++i) {
    Str candidate = e->import_slots[i].name;
    if (candidate.len == len && memcmp(candidate.ptr, cur, len) == 0) {
      return candidate;
    }
  }
  return empty;
}

static char* join_static_path(Str root, const Str* segments, size_t start,
                              size_t end) {
  size_t len = root.len;
  if (end <= start) {
    char* empty = (char*)malloc(len + 1);
    if (!empty) return NULL;
    if (root.len) memcpy(empty, root.ptr, root.len);
    empty[len] = '\0';
    return empty;
  }
  for (size_t i = start; i < end; ++i) {
    if (len) len++;
    len += segments[i].len;
  }
  char* out = (char*)malloc(len + 1);
  if (!out) return NULL;
  size_t pos = 0;
  if (root.len) {
    memcpy(out + pos, root.ptr, root.len);
    pos += root.len;
  }
  for (size_t i = start; i < end; ++i) {
    if (pos) out[pos++] = '.';
    memcpy(out + pos, segments[i].ptr, segments[i].len);
    pos += segments[i].len;
  }
  out[pos] = '\0';
  return out;
}

static bool resolve_static_access_chain(const VmEmitter* e, const AstNode* node,
                                        StaticAccess* out) {
  if (!e || !node || !out) return false;
  Str segments[64];
  size_t segment_count = 0;
  const AstNode* root = NULL;
  if (!collect_member_chain(e, node, &root, segments, &segment_count, 64))
    return false;
  if (!root) return false;

  size_t path_start = 0;
  Str root_prefix = {NULL, 0};
  if (builtin_is_name(e, root, "$file")) {
    if (segment_count < 1 || !(segments[0].len == 9 &&
                               memcmp(segments[0].ptr, "$$statics", 9) == 0)) {
      return false;
    }
    root_prefix = current_file_root_prefix(e);
    path_start = 1;
  } else if (builtin_is_name(e, root, "$global")) {
    if (segment_count >= 2 && segments[0].len == 7 &&
        memcmp(segments[0].ptr, "$source", 7) == 0 && segments[1].len == 9 &&
        memcmp(segments[1].ptr, "$$statics", 9) == 0) {
      path_start = 2;
    } else if (segment_count >= 3 && segments[0].len == 8 &&
               memcmp(segments[0].ptr, "$modules", 8) == 0 &&
               segments[2].len == 9 &&
               memcmp(segments[2].ptr, "$$statics", 9) == 0) {
      root_prefix = segments[1];
      path_start = 3;
    } else {
      return false;
    }
  } else if (root->kind == AST_IDENT) {
    Str root_name = {NULL, 0};
    if (!ast_node_name(e, root, &root_name)) return false;
    if (!emitter_has_import_slot(e, root_name)) return false;
    if (segment_count < 1 || !(segments[0].len == 9 &&
                               memcmp(segments[0].ptr, "$$statics", 9) == 0)) {
      return false;
    }
    root_prefix = root_name;
    path_start = 1;
  } else {
    return false;
  }

  if (segment_count <= path_start) return false;

  const StaticSlot* slot = NULL;
  size_t matched_end = path_start;
  for (size_t end = segment_count; end > path_start; --end) {
    char* full_name = join_static_path(root_prefix, segments, path_start, end);
    if (!full_name) return false;
    slot = static_slot_lookup(e, str_from(full_name, strlen(full_name)));
    free(full_name);
    if (slot) {
      matched_end = end;
      break;
    }
  }
  if (!slot) {
    if (e->emit_object && segment_count == path_start + 1) {
      const ImportSlot* import_slot = emitter_find_import_slot(e, root_prefix);
      const MorphlType* import_symbol_type =
          import_module_decl_type(import_slot, segments[path_start]);
      if (!import_slot || !import_symbol_type) return false;
      out->slot = NULL;
      out->byte_offset = 0;
      out->value_type = unwrap_ref(import_symbol_type);
      out->is_external_import = true;
      out->module_path = import_slot->module_path;
      out->symbol_name = segments[path_start];
      return true;
    }
    return false;
  }

  ptrdiff_t extra_off = 0;
  const MorphlType* cur_type = unwrap_ref(slot->type);

  for (size_t i = matched_end; i < segment_count; ++i) {
    if (!cur_type) return false;
    if (cur_type->kind == MORPHL_TYPE_UNION) {
      bool is_tag =
          segments[i].len == 5 && memcmp(segments[i].ptr, "$$tag", 5) == 0;
      bool is_data =
          segments[i].len == 6 && memcmp(segments[i].ptr, "$$data", 6) == 0;
      if (is_tag) {
        extra_off += (ptrdiff_t)(cur_type->size - 8);
        cur_type = morphl_type_int(e->type_ctx->arena);
        continue;
      }
      if (is_data) {
        cur_type = morphl_type_block(e->type_ctx->arena, NULL, NULL, 0);
        continue;
      }
      return false;
    }
    if (cur_type->kind != MORPHL_TYPE_BLOCK) return false;
    const MorphlType* field_type = NULL;
    ptrdiff_t field_off = block_layout_field_offset(cur_type, e->interns,
                                                    segments[i], &field_type);
    if (field_off == PTRDIFF_MAX || !field_type) return false;
    extra_off += field_off;
    cur_type = unwrap_ref(field_type);
  }

  out->slot = slot;
  out->byte_offset = extra_off;
  out->value_type = cur_type;
  out->is_external_import = false;
  out->module_path = str_from("", 0);
  out->symbol_name = str_from("", 0);
  return true;
}

static bool emit_static_access_load(VmEmitter* e, const AstNode* node,
                                    const StaticAccess* access) {
  if (!e || !node || !access || !access->value_type)
    return false;
  if (access->is_external_import) {
    const MorphlType* t = unwrap_ref(access->value_type);
    if (t && (t->kind == MORPHL_TYPE_BLOCK || t->kind == MORPHL_TYPE_ARRAY ||
              t->kind == MORPHL_TYPE_UNION)) {
      VM_ERR(node,
             "imported module static aggregate access is not supported in object mode");
      return false;
    }
    return emit_op(e, VM_OP_GLOBAL) &&
           emit_external_data_offset_i32(e, VM_OP_ALOAD, access->module_path,
                                         access->symbol_name);
  }
  if (!access->slot) return false;
  const MorphlType* t = unwrap_ref(access->value_type);
  size_t abs_off = access->slot->global_slot + (size_t)access->byte_offset;
  if (t && (t->kind == MORPHL_TYPE_BLOCK || t->kind == MORPHL_TYPE_ARRAY ||
            t->kind == MORPHL_TYPE_UNION)) {
    return emit_global_offset_iconst(e, abs_off);
  }
  return emit_op(e, VM_OP_GLOBAL) && emit_global_offset_i32(e, VM_OP_ALOAD, abs_off);
}

static bool emit_static_access_store(VmEmitter* e, const AstNode* target,
                                     const StaticAccess* access,
                                     AstNode* value) {
  if (!e || !target || !access || !value) return false;
  if (access->is_external_import) {
    return emit_op(e, VM_OP_GLOBAL) && emit_node(e, value) &&
           emit_external_data_offset_i32(e, VM_OP_ASTORE, access->module_path,
                                         access->symbol_name);
  }
  if (!access->slot) return false;
  if (access->byte_offset < 0) {
    VM_ERR(target, "negative offset into static storage is not supported");
    return false;
  }
  return emit_op(e, VM_OP_GLOBAL) && emit_node(e, value) &&
         emit_global_offset_i32(e, VM_OP_ASTORE,
                                access->slot->global_slot +
                                    (size_t)access->byte_offset);
}

/* ── type helpers ───────────────────────────────────────────────────────── */

static const MorphlType* unwrap_ref(
    const MorphlType* t); /* forward declaration */

/* Round up offset to the nearest multiple of align (align must be power of 2).
 */
static size_t align_up(size_t offset, size_t align) {
  if (align <= 1) return offset;
  return (offset + align - 1) & ~(align - 1);
}

/* Natural alignment requirement for a type (power of 2). */
static size_t type_frame_align(const MorphlType* t) {
  if (!t) return 1;
  switch (t->kind) {
    case MORPHL_TYPE_INT:
    case MORPHL_TYPE_FLOAT:
    case MORPHL_TYPE_BOOL:
    case MORPHL_TYPE_STRING:
    case MORPHL_TYPE_FUNC:
      return 8;
    case MORPHL_TYPE_REF:
      if (t->data.ref.is_ref) return 8;
      return t->data.ref.target ? type_frame_align(t->data.ref.target) : 1;
    case MORPHL_TYPE_BLOCK: {
      size_t max_align = 1;
      for (size_t i = 0; i < t->data.block.layout_field_count; i++) {
        if (t->data.block.layout_field_types[i]) {
          size_t fa = type_frame_align(t->data.block.layout_field_types[i]);
          if (fa > max_align) max_align = fa;
        }
      }
      return max_align;
    }
    case MORPHL_TYPE_ARRAY:
      return t->data.array.elem_type ? type_frame_align(t->data.array.elem_type)
                                     : 1;
    case MORPHL_TYPE_UNION:
      return 8; /* tag slot is i64 */
    case MORPHL_TYPE_OVERLOAD: {
      size_t max_align = 1;
      for (size_t i = 0; i < t->data.overload.candidate_count; ++i) {
        const MorphlType* candidate =
            unwrap_ref(t->data.overload.candidate_types[i]);
        size_t fa = type_frame_align(candidate);
        if (fa > max_align) max_align = fa;
      }
      return max_align;
    }
    default:
      return 1;
  }
}

static size_t overload_candidate_offset(const MorphlType* t, size_t index) {
  if (!t || t->kind != MORPHL_TYPE_OVERLOAD ||
      index >= t->data.overload.candidate_count) {
    return 0;
  }
  size_t offset = 0;
  for (size_t i = 0; i < index; ++i) {
    const MorphlType* candidate =
        unwrap_ref(t->data.overload.candidate_types[i]);
    size_t fa = type_frame_align(candidate);
    offset = align_up(offset, fa);
    offset += type_frame_size(candidate);
  }
  const MorphlType* candidate =
      unwrap_ref(t->data.overload.candidate_types[index]);
  return align_up(offset, type_frame_align(candidate));
}

static size_t type_frame_size(const MorphlType* t) {
  if (!t) return 0;
  switch (t->kind) {
    case MORPHL_TYPE_INT:
    case MORPHL_TYPE_FLOAT:
    case MORPHL_TYPE_BOOL:
    case MORPHL_TYPE_STRING:
      return 8; /* stored as i64 or f64 or string pointer */
    case MORPHL_TYPE_FUNC:
      return 8; /* stored as i64 (function table index) */
    case MORPHL_TYPE_REF:
      /* $ref (is_ref=true) stores an 8-byte absolute stack address (i64).
       * $mut/$const/$inline qualifiers are transparent — size comes from
       * target.
       */
      if (t->data.ref.is_ref)
        return 8; /* stored as i64 absolute stack address */
      return t->data.ref.target ? type_frame_size(t->data.ref.target) : 0;
    case MORPHL_TYPE_BLOCK: {
      if (t->size > 0) return t->size;
      /* size field is 0 (set so by morphl_type_block); compute from fields
       * using natural alignment: each field is aligned to its own alignment. */
      size_t offset = 0;
      for (size_t i = 0; i < t->data.block.layout_field_count; i++) {
        const MorphlType* ft = t->data.block.layout_field_types[i];
        if (!ft) continue;
        const MorphlType* uft = unwrap_ref(ft);
        size_t fa = type_frame_align(uft);
        offset = align_up(offset, fa);
        offset += type_frame_size(uft);
      }
      /* pad total size to struct's own alignment */
      size_t sa = type_frame_align(t);
      return align_up(offset, sa);
    }
    case MORPHL_TYPE_ARRAY:
      return t->data.array.count * type_frame_size(t->data.array.elem_type);
    case MORPHL_TYPE_UNION:
      return t->size; /* pre-computed: 8 (tag slot) + max(variant sizes) */
    case MORPHL_TYPE_OVERLOAD: {
      size_t offset = 0;
      for (size_t i = 0; i < t->data.overload.candidate_count; ++i) {
        const MorphlType* candidate =
            unwrap_ref(t->data.overload.candidate_types[i]);
        size_t fa = type_frame_align(candidate);
        offset = align_up(offset, fa);
        offset += type_frame_size(candidate);
      }
      return align_up(offset, type_frame_align(t));
    }
    default:
      return 0;
  }
}

/* load opcode for a type; returns 0xFF if unsupported */
static uint8_t load_op(const MorphlType* t) {
  if (!t) return 0xFF;
  switch (t->kind) {
    case MORPHL_TYPE_INT:
    case MORPHL_TYPE_BOOL:
    case MORPHL_TYPE_FUNC:
    case MORPHL_TYPE_STRING:
      return VM_OP_ILOAD; /* string pointer fits in i64 slot */
    case MORPHL_TYPE_FLOAT:
      return VM_OP_FLOAD;
    case MORPHL_TYPE_REF:
      if (t->data.ref.is_ref) return VM_OP_RLOAD;
      /* qualifier refs: fall through to load from target type */
      return t->data.ref.target ? load_op(t->data.ref.target) : 0xFF;
    default:
      return 0xFF;
  }
}

/* store opcode for a type; returns 0xFF if unsupported */
static uint8_t store_op(const MorphlType* t) {
  if (!t) return 0xFF;
  switch (t->kind) {
    case MORPHL_TYPE_INT:
    case MORPHL_TYPE_BOOL:
    case MORPHL_TYPE_FUNC:
    case MORPHL_TYPE_STRING:
      return VM_OP_ISTORE; /* string pointer fits in i64 slot */
    case MORPHL_TYPE_FLOAT:
      return VM_OP_FSTORE;
    case MORPHL_TYPE_REF:
      if (t->data.ref.is_ref) return VM_OP_RSTORE;
      return t->data.ref.target ? store_op(t->data.ref.target) : 0xFF;
    default:
      return 0xFF;
  }
}

static Str metadata_op_string(const VmEmitter* e, const AstNode* node) {
  if (!node) return str_from("", 0);
  if (node->kind == AST_BUILTIN || node->kind == AST_CALL || node->kind == AST_IF ||
      node->kind == AST_SET) {
    if (node->op && e && e->interns) return interns_lookup(e->interns, node->op);
    if (node->value.ptr) return node->value;
  }
  if (node->kind == AST_IDENT || node->kind == AST_LITERAL) {
    return node->value.ptr ? node->value : str_from("", 0);
  }
  return str_from("", 0);
}

static bool collect_inline_param_bindings(
    VmEmitter* e, AstNode* params, AstNode* call_args,
    InlineParamBinding* bindings, size_t binding_cap, size_t* out_count,
    const AstNode* err_node) {
  if (!out_count) return false;
  *out_count = 0;

  AstNode* param_nodes[64];
  size_t param_count = 0;
  if (params) {
    if (params->kind == AST_DECL) {
      param_nodes[param_count++] = params;
    } else if (params->kind == AST_GROUP) {
      if (params->child_count > 64) {
        VM_ERR(err_node, "inline call supports at most 64 parameters");
        return false;
      }
      for (size_t i = 0; i < params->child_count; ++i) {
        param_nodes[param_count++] = params->children[i];
      }
    } else {
      VM_ERR(err_node, "inline function parameters must be declarations");
      return false;
    }
  }

  AstNode* arg_nodes[64];
  size_t arg_count = 0;
  if (call_args) {
    if (call_args->kind == AST_GROUP) {
      if (call_args->child_count > 64) {
        VM_ERR(err_node, "inline call supports at most 64 arguments");
        return false;
      }
      for (size_t i = 0; i < call_args->child_count; ++i) {
        arg_nodes[arg_count++] = call_args->children[i];
      }
    } else {
      arg_nodes[arg_count++] = call_args;
    }
  }

  if (param_count != arg_count) {
    VM_ERR(err_node, "inline call arity mismatch: expected %zu argument%s, got %zu",
           param_count, param_count == 1 ? "" : "s", arg_count);
    return false;
  }
  if (param_count > binding_cap) {
    VM_ERR(err_node, "inline call exceeds parameter binding capacity");
    return false;
  }

  for (size_t i = 0; i < param_count; ++i) {
    AstNode* param = param_nodes[i];
    if (!param || param->kind != AST_DECL || param->child_count < 1 ||
        !param->children[0] || param->children[0]->kind != AST_IDENT) {
      VM_ERR(err_node, "inline function parameters must be identifier declarations");
      return false;
    }
    bindings[i].name = param->children[0]->value;
    if (!bindings[i].name.ptr && e && e->interns && param->children[0]->op) {
      bindings[i].name = interns_lookup(e->interns, param->children[0]->op);
    }
    bindings[i].value = arg_nodes[i];
  }

  *out_count = param_count;
  return true;
}

static bool inline_name_is_shadowed(Str name, const Str* shadowed,
                                    size_t shadowed_count) {
  for (size_t i = shadowed_count; i > 0; --i) {
    if (str_eq(name, shadowed[i - 1])) return true;
  }
  return false;
}

static AstNode* inline_binding_value(Str name, const InlineParamBinding* bindings,
                                     size_t binding_count) {
  for (size_t i = 0; i < binding_count; ++i) {
    if (str_eq(name, bindings[i].name)) return bindings[i].value;
  }
  return NULL;
}

static bool inline_substitute_node(VmEmitter* e, AstNode* node,
                                   const InlineParamBinding* bindings,
                                   size_t binding_count, Str* shadowed,
                                   size_t shadowed_count);

static bool inline_substitute_block(VmEmitter* e, AstNode* node,
                                    const InlineParamBinding* bindings,
                                    size_t binding_count, Str* shadowed,
                                    size_t shadowed_count) {
  if (!node) return true;
  size_t local_shadowed = shadowed_count;
  for (size_t i = 0; i < node->child_count; ++i) {
    if (!inline_substitute_node(e, node->children[i], bindings, binding_count,
                                shadowed, local_shadowed)) {
      return false;
    }
    AstNode* child = node->children[i];
    if ((child->kind == AST_DECL || child->kind == AST_PROP) &&
        child->child_count > 0 && child->children[0] &&
        child->children[0]->kind == AST_IDENT) {
      Str declared = child->children[0]->value;
      if (!declared.ptr && e && e->interns && child->children[0]->op) {
        declared = interns_lookup(e->interns, child->children[0]->op);
      }
      if (declared.ptr) shadowed[local_shadowed++] = declared;
    }
  }
  return true;
}

static bool inline_substitute_node(VmEmitter* e, AstNode* node,
                                   const InlineParamBinding* bindings,
                                   size_t binding_count, Str* shadowed,
                                   size_t shadowed_count) {
  if (!node) return true;
  if (node->kind == AST_IDENT) {
    Str ident = node->value;
    if (!ident.ptr && e && e->interns && node->op) {
      ident = interns_lookup(e->interns, node->op);
    }
    if (!ident.ptr || inline_name_is_shadowed(ident, shadowed, shadowed_count))
      return true;
    AstNode* binding_value = inline_binding_value(ident, bindings, binding_count);
    if (!binding_value) return true;
    AstNode* replacement = ast_clone(binding_value);
    if (!replacement) return false;
    AstNode** old_children = node->children;
    *node = *replacement;
    free(replacement);
    free(old_children);
    return true;
  }

  if (node->kind == AST_FILE || node->kind == AST_BLOCK) {
    return inline_substitute_block(e, node, bindings, binding_count, shadowed,
                                   shadowed_count);
  }

  if (node->kind == AST_FUNC) {
    return true;
  }

  if ((node->kind == AST_DECL || node->kind == AST_PROP) && node->child_count > 1) {
    for (size_t i = 1; i < node->child_count; ++i) {
      if (!inline_substitute_node(e, node->children[i], bindings, binding_count,
                                  shadowed, shadowed_count)) {
        return false;
      }
    }
    return true;
  }

  for (size_t i = 0; i < node->child_count; ++i) {
    if (!inline_substitute_node(e, node->children[i], bindings, binding_count,
                                shadowed, shadowed_count)) {
      return false;
    }
  }
  return true;
}

static bool inline_body_contains_builtin(const VmEmitter* e, const AstNode* node,
                                         const char* builtin_name) {
  if (!node) return false;
  if (builtin_is_name(e, node, builtin_name)) return true;
  if (node->kind == AST_FUNC) return false;
  for (size_t i = 0; i < node->child_count; ++i) {
    if (inline_body_contains_builtin(e, node->children[i], builtin_name))
      return true;
  }
  return false;
}

static bool inline_runtime_builtin_forbidden(const VmEmitter* e,
                                             const AstNode* node) {
  static const char* const forbidden[] = {
      "$set", "$while", "$ret", "$exit", "$break", "$continue", "$call",
      "$parent", "$this"};
  for (size_t i = 0; i < sizeof(forbidden) / sizeof(forbidden[0]); ++i) {
    if (builtin_is_name(e, node, forbidden[i])) return true;
  }
  return false;
}

static bool inline_container_has_decl_named(const VmEmitter* e,
                                            const AstNode* container,
                                            Str name) {
  if (!container || (container->kind != AST_FILE && container->kind != AST_BLOCK))
    return false;
  for (size_t i = 0; i < container->child_count; ++i) {
    AstNode* child = container->children[i];
    if (!child ||
        (child->kind != AST_DECL && child->kind != AST_PROP) ||
        child->child_count < 1 || !child->children[0] ||
        child->children[0]->kind != AST_IDENT)
      continue;
    Str declared = child->children[0]->value;
    if (!declared.ptr && e && e->interns && child->children[0]->op) {
      declared = interns_lookup(e->interns, child->children[0]->op);
    }
    if (declared.ptr && str_eq(declared, name)) return true;
  }
  return false;
}

static bool inline_expand_compile_time_expr(VmEmitter* e, AstNode* node,
                                            const AstNode* container,
                                            const InlineParamBinding* bindings,
                                            size_t binding_count,
                                            const AstNode* err_node,
                                            size_t depth) {
  if (!node) return true;
  if (depth > 128) {
    VM_ERR(err_node, "$member: inline expression expansion exceeded recursion limit");
    return false;
  }

  if (node->kind == AST_IDENT) {
    Str ident = node->value;
    if (!ident.ptr && e && e->interns && node->op) {
      ident = interns_lookup(e->interns, node->op);
    }
    if (!ident.ptr) return true;
    AstNode* binding_value = inline_binding_value(ident, bindings, binding_count);
    if (!binding_value) {
      if (inline_container_has_decl_named(e, container, ident)) {
        VM_ERR(err_node,
               "$member: inline field depends on declaration '%.*s' that is "
               "not statically available at this use site",
               (int)ident.len, ident.ptr);
        return false;
      }
      return true;
    }
    AstNode* replacement = ast_clone(binding_value);
    if (!replacement) return false;
    AstNode** old_children = node->children;
    *node = *replacement;
    free(replacement);
    free(old_children);
    return inline_expand_compile_time_expr(
        e, node, container, bindings, binding_count, err_node, depth + 1);
  }

  if (inline_runtime_builtin_forbidden(e, node)) {
    Str opname = node->op && e && e->interns ? interns_lookup(e->interns, node->op)
                                             : node->value;
    VM_WARN(err_node,
            "$member: inline field uses runtime-only builtin '%.*s'; "
            "attempting static collapse failed",
            (int)opname.len, opname.ptr);
    VM_ERR(err_node,
           "$member: inline field depends on runtime-only builtin '%.*s'",
           (int)opname.len, opname.ptr);
    return false;
  }

  if (node->kind == AST_FUNC) return true;

  if (node->kind == AST_FILE || node->kind == AST_BLOCK) {
    for (size_t i = 0; i < node->child_count; ++i) {
      AstNode* child = node->children[i];
      if (!child) continue;
      if (child->kind != AST_DECL && child->kind != AST_PROP) {
        VM_WARN(err_node,
                "$member: inline block contains runtime logic; attempting "
                "static collapse failed");
        VM_ERR(err_node,
               "$member: inline block imports/blocks must be declaration-only");
        return false;
      }
      if (child->child_count > 1 &&
          !inline_expand_compile_time_expr(e, child->children[1], container,
                                           bindings, binding_count, err_node,
                                           depth + 1)) {
        return false;
      }
    }
    return true;
  }

  if ((node->kind == AST_DECL || node->kind == AST_PROP) && node->child_count > 1) {
    return inline_expand_compile_time_expr(e, node->children[1], container,
                                           bindings, binding_count, err_node,
                                           depth + 1);
  }

  for (size_t i = 0; i < node->child_count; ++i) {
    if (!inline_expand_compile_time_expr(e, node->children[i], container,
                                         bindings, binding_count, err_node,
                                         depth + 1)) {
      return false;
    }
  }
  return true;
}

static AstNode* inline_member_container(const VmEmitter* e, AstNode* target) {
  if (!builtin_is_name(e, target, "$inline") || target->child_count < 1 ||
      !target->children[0]) {
    return NULL;
  }
  AstNode* inner = target->children[0];
  if (inner->kind == AST_BLOCK || inner->kind == AST_FILE) return inner;
  if (builtin_is_name(e, inner, "$import")) {
    AstNode* module_file = import_module_root(inner);
    if (module_file) {
      return module_file;
    }
  }
  return NULL;
}

static bool emit_inline_member_field(VmEmitter* e, AstNode* target,
                                     Str field_name, const AstNode* err_node) {
  AstNode* container = inline_member_container(e, target);
  if (!container) {
    VM_ERR(err_node,
           "$member: $inline target must wrap a declaration block or import");
    return false;
  }

  InlineParamBinding bindings[128];
  size_t binding_count = 0;
  AstNode* selected_value = NULL;
  for (size_t i = 0; i < container->child_count; ++i) {
    AstNode* child = container->children[i];
    if (!child) continue;
    if (child->kind != AST_DECL && child->kind != AST_PROP) {
      VM_WARN(err_node,
              "$member: inline block contains runtime logic; attempting "
              "static collapse failed");
      VM_ERR(err_node,
             "$member: inline block imports/blocks must be declaration-only");
      return false;
    }
  }

  for (size_t i = 0; i < container->child_count; ++i) {
    AstNode* child = container->children[i];
    if (!child) continue;
    if (child->child_count < 2 || !child->children[0] ||
        child->children[0]->kind != AST_IDENT) {
      continue;
    }
    Str declared = child->children[0]->value;
    if (!declared.ptr && e && e->interns && child->children[0]->op) {
      declared = interns_lookup(e->interns, child->children[0]->op);
    }
    if (!declared.ptr) continue;
    if (str_eq(declared, field_name)) {
      selected_value = child->children[1];
      break;
    }
    if (binding_count >= sizeof(bindings) / sizeof(bindings[0])) {
      VM_ERR(err_node, "$member: inline block exceeds compile-time binding limit");
      return false;
    }
    bindings[binding_count++] =
        (InlineParamBinding){.name = declared, .value = child->children[1]};
  }

  if (!selected_value) {
    VM_ERR(err_node, "$member: field '%.*s' not found", (int)field_name.len,
           field_name.ptr);
    return false;
  }

  AstNode* resolved = ast_clone(selected_value);
  if (!resolved) return false;
  bool ok = inline_expand_compile_time_expr(
      e, resolved, container, bindings, binding_count, err_node, 0);
  if (ok) ok = emit_node(e, resolved);
  ast_free(resolved);
  return ok;
}

static bool emit_inline_node(VmEmitter* e, AstNode* node,
                             const InlineReturnCtx* ret_ctx);

static bool emit_inline_block(VmEmitter* e, AstNode* node,
                              const InlineReturnCtx* ret_ctx) {
  bool pushed_lexical = false;
  if (node->kind == AST_BLOCK) {
    if (!lexical_scope_push_anon(e)) return false;
    pushed_lexical = true;
  }
  size_t scope_sz = block_scope_size(node);
  if (!morphl_backend_push_frame(&e->frameInfo)) {
    if (pushed_lexical) lexical_scope_pop(e);
    return false;
  }
  if (!emit_enter(e, (uint32_t)scope_sz)) {
    if (pushed_lexical) lexical_scope_pop(e);
    morphl_backend_pop_frame(&e->frameInfo);
    return false;
  }
  for (size_t i = 0; i < node->child_count; ++i) {
    if (!emit_inline_node(e, node->children[i], ret_ctx)) {
      if (pushed_lexical) lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
  }
  for (size_t i = node->child_count; i > 0; --i) {
    AstNode* child = node->children[i - 1];
    if (!builtin_is_name(e, child, "$defer") || child->child_count < 1 || !child->children[0])
      continue;
    if (!emit_inline_node(e, child->children[0], ret_ctx)) {
      if (pushed_lexical) lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
  }
  if (!emit_leave(e, (uint32_t)scope_sz)) {
    if (pushed_lexical) lexical_scope_pop(e);
    morphl_backend_pop_frame(&e->frameInfo);
    return false;
  }
  morphl_backend_pop_frame(&e->frameInfo);
  if (pushed_lexical) lexical_scope_pop(e);
  return true;
}

static bool emit_inline_ret(VmEmitter* e, AstNode* node,
                            const InlineReturnCtx* ret_ctx) {
  if (!ret_ctx) return emit_node(e, node);
  if (node->child_count > 0 && node->children[0]) {
    if (!emit_node(e, node->children[0])) return false;
  }
  while (e->scope_depth > ret_ctx->return_scope_depth) {
    uint32_t sz = e->scope_sizes[e->scope_depth - 1];
    if (!emit_leave(e, sz)) return false;
  }
  return emit_jump(e, VM_OP_JMP, ret_ctx->exit_label);
}

static bool emit_inline_if(VmEmitter* e, AstNode* node,
                           const InlineReturnCtx* ret_ctx) {
  if (node->child_count < 2) return false;
  if (!emit_node(e, node->children[0])) return false;
  if (!emit_iconst(e, 0)) return false;
  if (!emit_op(e, VM_OP_IEQ)) return false;
  size_t else_lbl = label_new(e);
  size_t end_lbl = label_new(e);
  if (else_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;
  if (!emit_jump(e, VM_OP_JIF, else_lbl)) return false;
  if (!emit_inline_node(e, node->children[1], ret_ctx)) return false;
  if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;
  if (!label_bind(e, else_lbl)) return false;
  if (node->child_count > 2 && node->children[2]) {
    if (!emit_inline_node(e, node->children[2], ret_ctx)) return false;
  }
  return label_bind(e, end_lbl);
}

static bool emit_inline_while(VmEmitter* e, AstNode* node,
                              const InlineReturnCtx* ret_ctx) {
  if (node->child_count < 2) return false;
  size_t loop_start = label_new(e);
  size_t exit_lbl = label_new(e);
  if (loop_start == SIZE_MAX || exit_lbl == SIZE_MAX) return false;

  if (e->loop_stack_count >= e->loop_stack_capacity) {
    if (!vm_grow((void**)&e->loop_stack, &e->loop_stack_capacity,
                 sizeof(VmLoopCtx), e->loop_stack_count + 1))
      return false;
  }
  e->loop_stack[e->loop_stack_count++] =
      (VmLoopCtx){exit_lbl, loop_start, e->scope_depth};

  if (!label_bind(e, loop_start)) {
    e->loop_stack_count--;
    return false;
  }
  if (!emit_node(e, node->children[0]) || !emit_iconst(e, 0) ||
      !emit_op(e, VM_OP_IEQ) || !emit_jump(e, VM_OP_JIF, exit_lbl)) {
    e->loop_stack_count--;
    return false;
  }

  AstNode* body = node->children[1];
  bool ok = true;
  if (body) ok = emit_inline_node(e, body, ret_ctx);
  if (ok) ok = emit_jump(e, VM_OP_JMP, loop_start);
  if (ok) ok = label_bind(e, exit_lbl);
  e->loop_stack_count--;
  return ok;
}

static bool emit_inline_node(VmEmitter* e, AstNode* node,
                             const InlineReturnCtx* ret_ctx) {
  if (!node) return true;
  if (node->kind == AST_FILE || node->kind == AST_BLOCK) {
    return emit_inline_block(e, node, ret_ctx);
  }
  if (node->kind == AST_IF) return emit_inline_if(e, node, ret_ctx);
  if (builtin_is_name(e, node, "$while")) return emit_inline_while(e, node, ret_ctx);
  if (builtin_is_name(e, node, "$ret")) return emit_inline_ret(e, node, ret_ctx);
  return emit_node(e, node);
}

static bool emit_inline_call(VmEmitter* e, AstNode* call_node, AstNode* callee,
                             AstNode* args, uint32_t ret_sz) {
  if (!builtin_is_name(e, callee, "$inline") || callee->child_count < 1 ||
      !callee->children[0]) {
    return false;
  }

  AstNode* func = callee->children[0];
  if (!func || func->kind != AST_FUNC || func->child_count < 2) {
    VM_ERR(callee, "$inline call expects an inline function");
    return false;
  }

  AstNode* body = ast_clone(func->children[1]);
  if (!body) return false;

  InlineParamBinding bindings[64];
  size_t binding_count = 0;
  bool ok = collect_inline_param_bindings(e, func->children[0], args, bindings,
                                          64, &binding_count, call_node);
  if (ok) {
    Str shadowed[128];
    ok = inline_substitute_node(e, body, bindings, binding_count, shadowed, 0);
  }
  if (ok && inline_body_contains_builtin(e, body, "$parent")) {
    VM_ERR(call_node, "$parent is not supported inside an inlined function body");
    ok = false;
  }

  if (ok && body->kind == AST_BLOCK) {
    bool has_ret = inline_body_contains_builtin(e, body, "$ret");
    size_t exit_lbl = SIZE_MAX;
    InlineReturnCtx ret_ctx = {0};
    if (ok && has_ret) {
      exit_lbl = label_new(e);
      if (exit_lbl == SIZE_MAX) ok = false;
      ret_ctx.exit_label = exit_lbl;
      ret_ctx.return_scope_depth = e->scope_depth;
      ret_ctx.call_site = call_node;
      ok = emit_inline_node(e, body, &ret_ctx);
      if (ok) ok = label_bind(e, exit_lbl);
    } else if (ok) {
      ok = emit_inline_node(e, body, NULL);
    }
    if (ok && !has_ret && ret_sz > 0) ok = emit_iconst(e, 0);
  } else if (ok) {
    ok = emit_node(e, body);
  }

  ast_free(body);
  return ok;
}

/* unwrap $mut / $const / $inline qualifier layers; stop at real $ref
 * (is_ref=true) */
static const MorphlType* unwrap_ref(const MorphlType* t) {
  while (t && t->kind == MORPHL_TYPE_REF && !t->data.ref.is_ref)
    t = t->data.ref.target;
  return t;
}

static struct AstNode* unwrap_extern_expr(struct AstNode* node,
                                          InternTable* interns) {
  while (node && node->kind == AST_BUILTIN && node->op &&
         node->child_count == 1) {
    Str op = interns_lookup(interns, node->op);
    if (op.len == 7 && memcmp(op.ptr, "$extern", 7) == 0) return node;
    if ((op.len == 4 && memcmp(op.ptr, "$mut", 4) == 0) ||
        (op.len == 6 && memcmp(op.ptr, "$const", 6) == 0) ||
        (op.len == 7 && memcmp(op.ptr, "$inline", 7) == 0) ||
        (op.len == 7 && memcmp(op.ptr, "$static", 7) == 0)) {
      node = node->children[0];
      continue;
    }
    break;
  }
  if (node && node->kind == AST_BUILTIN && node->op) {
    Str op = interns_lookup(interns, node->op);
    if (op.len == 7 && memcmp(op.ptr, "$extern", 7) == 0) return node;
  }
  return NULL;
}

static ptrdiff_t block_layout_field_offset(const MorphlType* block_type,
                                           InternTable* interns, Str field_name,
                                           const MorphlType** out_field_type) {
  if (!block_type || block_type->kind != MORPHL_TYPE_BLOCK) return PTRDIFF_MAX;
  ptrdiff_t offset = 0;
  for (size_t i = 0; i < block_type->data.block.layout_field_count; ++i) {
    Str name = {NULL, 0};
    if (interns && block_type->data.block.layout_field_names[i]) {
      name =
          interns_lookup(interns, block_type->data.block.layout_field_names[i]);
    }
    if (str_eq(name, field_name)) {
      if (out_field_type)
        *out_field_type = block_type->data.block.layout_field_types[i];
      return offset;
    }
    offset += (ptrdiff_t)type_frame_size(
        unwrap_ref(block_type->data.block.layout_field_types[i]));
  }
  return PTRDIFF_MAX;
}

static bool emit_block_decl_initializers_into_slot(VmEmitter* e,
                                                   const MorphlType* block_type,
                                                   struct AstNode* block,
                                                   ptrdiff_t base_off) {
  if (!e || !block_type || block_type->kind != MORPHL_TYPE_BLOCK || !block)
    return true;
  for (size_t ci = 0; ci < block->child_count; ci++) {
    struct AstNode* child = block->children[ci];
    if (!child || child->kind != AST_DECL || child->child_count < 2)
      continue;
    struct AstNode* fn = child->children[0];
    struct AstNode* fv = child->children[1];
    if (!fn || !fv) continue;
    Str field_name = fn->value;
    if (!field_name.ptr && e->interns && fn->op)
      field_name = interns_lookup(e->interns, fn->op);
    const MorphlType* field_type = NULL;
    ptrdiff_t field_off =
        block_layout_field_offset(block_type, e->interns, field_name, &field_type);
    if (field_off == PTRDIFF_MAX || !field_type) continue;
    if (!emit_node(e, fv)) return false;
    uint8_t sop = store_op(unwrap_ref(field_type));
    if (sop != 0xFF) {
      if (!emit_op_i32(e, sop, (int32_t)(base_off + field_off))) return false;
    }
  }
  return true;
}

static AstNode* unwrap_storage_builtin(const VmEmitter* e, AstNode* node,
                                       const char* builtin_name);

static bool emit_block_value_into_slot(VmEmitter* e,
                                       const MorphlType* block_type,
                                       struct AstNode* block,
                                       Str target_name,
                                       ptrdiff_t base_off) {
  if (!e || !block_type || block_type->kind != MORPHL_TYPE_BLOCK || !block)
    return true;

  size_t alias_mark = e->alias_count;
  InlineParamBinding local_bindings[128];
  size_t local_binding_count = 0;
  for (size_t i = 0; i < block_type->data.block.layout_field_count; ++i) {
    Str field_name = {NULL, 0};
    if (e->interns && block_type->data.block.layout_field_names[i]) {
      field_name =
          interns_lookup(e->interns, block_type->data.block.layout_field_names[i]);
    }
    if (!field_name.ptr) continue;
    ptrdiff_t field_off =
        block_layout_field_offset(block_type, e->interns, field_name, NULL);
    if (field_off == PTRDIFF_MAX) continue;
    if (!alias_add(e, field_name, target_name, field_off)) {
      e->alias_count = alias_mark;
      return false;
    }
  }

  bool ok = true;
  for (size_t ci = 0; ci < block->child_count; ci++) {
    struct AstNode* child = block->children[ci];
    if (!child) continue;
    if (child->kind == AST_PROP) continue;
    if (child->kind == AST_DECL) {
      if (child->child_count < 1 || !child->children[0] ||
          child->children[0]->kind != AST_IDENT) {
        VM_ERR(child, "block-as-value declaration must bind an identifier");
        ok = false;
        break;
      }
      Str field_name = child->children[0]->value;
      if (!field_name.ptr && e->interns && child->children[0]->op)
        field_name = interns_lookup(e->interns, child->children[0]->op);
      const MorphlType* field_type = NULL;
      ptrdiff_t field_off =
          block_layout_field_offset(block_type, e->interns, field_name, &field_type);
      if (field_off == PTRDIFF_MAX || !field_type) {
        if (child->child_count >= 2 && child->children[1]) {
          if (local_binding_count >=
              sizeof(local_bindings) / sizeof(local_bindings[0])) {
            VM_ERR(child, "block-as-value local binding limit exceeded");
            ok = false;
            break;
          }
          local_bindings[local_binding_count++] =
              (InlineParamBinding){.name = field_name, .value = child->children[1]};
        }
        continue;
      }
      if (child->child_count >= 2 && child->children[1]) {
        AstNode* value = child->children[1];
        AstNode* owned_value = NULL;
        if (value->kind != AST_FUNC) {
          owned_value = ast_clone(value);
          if (!owned_value) {
            ok = false;
            break;
          }
          value = owned_value;
          Str shadowed[128];
          ok = inline_substitute_node(e, value, local_bindings,
                                      local_binding_count, shadowed, 0);
        }
        if (ok) ok = emit_node(e, value);
        if (owned_value) ast_free(owned_value);
        if (!ok) break;
        uint8_t sop = store_op(unwrap_ref(field_type));
        if (sop != 0xFF &&
            !emit_op_i32(e, sop, (int32_t)(base_off + field_off))) {
          ok = false;
          break;
        }
      }
      continue;
    }
    AstNode* stmt = ast_clone(child);
    if (!stmt) {
      ok = false;
      break;
    }
    Str shadowed[128];
    ok = inline_substitute_node(e, stmt, local_bindings, local_binding_count,
                                shadowed, 0);
    if (ok) ok = emit_node(e, stmt);
    ast_free(stmt);
    if (!ok) break;
  }

  e->alias_count = alias_mark;
  return ok;
}

static bool emit_store_into_handle_slot(VmEmitter* e, ptrdiff_t handle_off,
                                        ptrdiff_t field_off,
                                        const MorphlType* field_type,
                                        AstNode* value) {
  if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)handle_off)) return false;
  AstNode* heap_value = unwrap_storage_builtin(e, value, "$heap");
  if (heap_value) {
    const MorphlType* heap_target = field_type;
    if (heap_target && heap_target->kind == MORPHL_TYPE_REF && heap_target->data.ref.is_ref)
      heap_target = heap_target->data.ref.target;
    size_t alloc_sz = heap_target ? type_frame_size(unwrap_ref(heap_target)) : 8;
    if (!emit_op_u32(e, VM_OP_HEAP, (uint32_t)alloc_sz)) return false;
  } else {
    if (!emit_node(e, value)) return false;
  }
  return emit_op_i32(e, VM_OP_ASTORE, (int32_t)field_off);
}

static bool emit_block_decl_initializers_into_handle_slot(VmEmitter* e,
                                                          const MorphlType* block_type,
                                                          struct AstNode* block,
                                                          ptrdiff_t handle_off) {
  if (!e || !block_type || block_type->kind != MORPHL_TYPE_BLOCK || !block)
    return true;
  for (size_t ci = 0; ci < block->child_count; ci++) {
    struct AstNode* child = block->children[ci];
    if (!child || child->kind != AST_DECL || child->child_count < 2)
      continue;
    struct AstNode* fn = child->children[0];
    struct AstNode* fv = child->children[1];
    if (!fn || !fv) continue;
    Str field_name = fn->value;
    if (!field_name.ptr && e->interns && fn->op)
      field_name = interns_lookup(e->interns, fn->op);
    const MorphlType* field_type = NULL;
    ptrdiff_t field_off =
        block_layout_field_offset(block_type, e->interns, field_name, &field_type);
    if (field_off == PTRDIFF_MAX || !field_type) continue;
    if (!emit_store_into_handle_slot(e, handle_off, field_off, field_type, fv))
      return false;
  }
  return true;
}

static struct AstNode* new_base_inline_block_initializer(VmEmitter* e,
                                                         struct AstNode* base) {
  if (!base) return NULL;
  if (base->kind == AST_BLOCK) return base;
  if (builtin_is_name(e, base, "$inline") && base->child_count > 0) {
    return new_base_inline_block_initializer(e, base->children[0]);
  }
  if (base->kind == AST_IDENT && e) {
    Str name = base->value;
    if (!name.ptr && e->interns && base->op)
      name = interns_lookup(e->interns, base->op);
    for (size_t i = e->block_decl_map_count; i > 0; --i) {
      if (str_eq(e->block_decl_map[i - 1].name, name))
        return e->block_decl_map[i - 1].block;
    }
  }
  return NULL;
}

static AstNode* unwrap_storage_builtin(const VmEmitter* e, AstNode* node,
                                       const char* builtin_name) {
  while (node && node->kind == AST_BUILTIN) {
    if (builtin_is_name(e, node, builtin_name)) return node;
    if ((builtin_is_name(e, node, "$mut") || builtin_is_name(e, node, "$const") ||
         builtin_is_name(e, node, "$inline") || builtin_is_name(e, node, "$static")) &&
        node->child_count > 0) {
      node = node->children[0];
      continue;
    }
    break;
  }
  return NULL;
}

static bool block_has_defer(const VmEmitter* e, const AstNode* block) {
  if (!block || block->kind != AST_BLOCK) return false;
  for (size_t i = 0; i < block->child_count; ++i) {
    if (builtin_is_name(e, block->children[i], "$defer")) return true;
  }
  return false;
}

static bool cleanup_array_push(BindingCleanup** items, size_t* count,
                               size_t* capacity, const BindingCleanup* entry) {
  if (*count >= *capacity) {
    if (!vm_grow((void**)items, capacity, sizeof(BindingCleanup), *count + 1))
      return false;
  }
  (*items)[(*count)++] = *entry;
  return true;
}

static AstNode* rewrite_cleanup_expr(const VmEmitter* e, const AstNode* node,
                                     Str binding_name,
                                     const MorphlType* block_type,
                                     const MorphlType* binding_type) {
  if (!node) return NULL;
  if (node->kind == AST_IDENT && block_type && block_type->kind == MORPHL_TYPE_BLOCK) {
    const MorphlType* field_type = NULL;
    if (block_layout_field_offset(block_type, e->interns, node->value, &field_type) != PTRDIFF_MAX) {
      AstNode* member = ast_new(AST_BUILTIN);
      if (!member) return NULL;
      member->value = str_from("$member", 7);
      if (e->interns) member->op = interns_intern(e->interns, member->value);
      AstNode* target = ast_make_leaf(AST_IDENT, binding_name, node->filename, node->row, node->col);
      AstNode* field = ast_make_leaf(AST_IDENT, node->value, node->filename, node->row, node->col);
      if (!target || !field || !ast_append_child(member, target) || !ast_append_child(member, field)) {
        if (target) ast_free(target);
        if (field) ast_free(field);
        ast_free(member);
        return NULL;
      }
      if (e->interns) {
        target->op = interns_intern(e->interns, binding_name);
        field->op = node->op ? node->op : interns_intern(e->interns, node->value);
      }
      target->type = (MorphlType*)binding_type;
      field->type = (MorphlType*)field_type;
      member->type = node->type;
      return member;
    }
  }
  AstNode* clone = ast_new(node->kind);
  if (!clone) return NULL;
  clone->op = node->op;
  clone->value = node->value;
  clone->filename = node->filename;
  clone->row = node->row;
  clone->col = node->col;
  clone->type = node->type;
  clone->contributes_to_shape = node->contributes_to_shape;
  clone->contributes_to_layout = node->contributes_to_layout;
  clone->storage_is_mutable = node->storage_is_mutable;
  clone->storage_residence = node->storage_residence;
  clone->extern_symbol = node->extern_symbol;
  clone->import_module_shared = node->import_module_shared;
  clone->import_path = node->import_path;
  if (node->import_path.ptr && node->import_path.len > 0) {
    char* path_copy = (char*)malloc(node->import_path.len + 1);
    if (!path_copy) {
      ast_free(clone);
      return NULL;
    }
    memcpy(path_copy, node->import_path.ptr, node->import_path.len);
    path_copy[node->import_path.len] = '\0';
    clone->import_path = str_from(path_copy, node->import_path.len);
  }
  if (node->import_module) {
    if (node->import_module_shared) {
      clone->import_module = node->import_module;
    } else {
      clone->import_module = ast_clone(node->import_module);
      if (!clone->import_module) {
        ast_free(clone);
        return NULL;
      }
    }
  }
  for (size_t i = 0; i < node->child_count; ++i) {
    AstNode* child = rewrite_cleanup_expr(e, node->children[i], binding_name, block_type,
                                          binding_type);
    if (!child || !ast_append_child(clone, child)) {
      if (child) ast_free(child);
      ast_free(clone);
      return NULL;
    }
  }
  return clone;
}

static bool emit_binding_cleanup_block(VmEmitter* e, Str binding_name,
                                       const AstNode* block,
                                       const MorphlType* block_type,
                                       const MorphlType* binding_type) {
  if (!e || !block || block->kind != AST_BLOCK) return true;
  for (size_t i = block->child_count; i > 0; --i) {
    const AstNode* child = block->children[i - 1];
    if (!builtin_is_name(e, child, "$defer") || child->child_count < 1 || !child->children[0]) continue;
    AstNode* rewritten =
        rewrite_cleanup_expr(e, child->children[0], binding_name, block_type, binding_type);
    if (!rewritten) return false;
    bool ok = emit_node(e, rewritten);
    ast_free(rewritten);
    if (!ok) return false;
  }
  return true;
}

static bool emit_scope_binding_cleanups(VmEmitter* e, size_t scope_depth) {
  if (!e) return false;
  while (e->binding_cleanup_count > 0 &&
         e->binding_cleanups[e->binding_cleanup_count - 1].scope_depth == scope_depth) {
    BindingCleanup cleanup = e->binding_cleanups[--e->binding_cleanup_count];
    if (cleanup.run_on_scope_exit &&
        !emit_binding_cleanup_block(e, cleanup.binding_name, cleanup.block,
                                    cleanup.block_type, cleanup.binding_type))
      return false;
  }
  return true;
}


static bool emit_ref_handle_expr(VmEmitter* e, AstNode* node) {
  if (!e || !node) return false;
  if (node->kind == AST_IDENT) {
    ptrdiff_t extra = 0;
    Str resolved = alias_resolve_full(e, node->value, &extra);
    ptrdiff_t base_off = morphl_backend_find_offset(&e->frameInfo, resolved);
    if (!str_eq(resolved, node->value) || extra != 0) {
      if (base_off == PTRDIFF_MAX) return false;
      return emit_op_i32(e, VM_OP_ADDREF, (int32_t)(base_off + extra));
    }
    if (base_off != PTRDIFF_MAX) {
      return emit_op_i32(e, VM_OP_RLOAD, (int32_t)base_off);
    }
    char* full_name = lexical_make_binding_path(e, resolved);
    const StaticSlot* slot =
        full_name ? static_slot_lookup(e, str_from(full_name, strlen(full_name))) : NULL;
    free(full_name);
    if (!slot) return false;
    return emit_op(e, VM_OP_GLOBAL) &&
           emit_global_offset_i32(e, VM_OP_ALOAD,
                                  slot->global_slot + (size_t)extra);
  }
  if (builtin_is_name(e, node, "$member") && node->child_count >= 2 &&
      node->children[0] && node->children[1]) {
    AstNode* target = node->children[0];
    AstNode* field_nd = node->children[1];
    Str field_name = field_nd->value;
    if (!field_name.ptr && e->interns && field_nd->op)
      field_name = interns_lookup(e->interns, field_nd->op);
    const MorphlType* target_btype = target->type;
    bool target_is_ref = target_btype && target_btype->kind == MORPHL_TYPE_REF &&
                         target_btype->data.ref.is_ref;
    if (target_is_ref && target_btype->data.ref.target)
      target_btype = unwrap_ref(target_btype->data.ref.target);
    else
      target_btype = unwrap_ref(target_btype);
    const MorphlType* field_type = NULL;
    ptrdiff_t field_offset = block_layout_field_offset(target_btype, e->interns,
                                                       field_name, &field_type);
    if (field_offset == PTRDIFF_MAX || !field_type ||
        field_type->kind != MORPHL_TYPE_REF || !field_type->data.ref.is_ref) {
      return false;
    }
    /* AST_IDENT target: look up in frame or static slots */
    if (target->kind == AST_IDENT) {
      ptrdiff_t target_off = morphl_backend_find_offset(&e->frameInfo, target->value);
      if (target_off != PTRDIFF_MAX) {
        if (target_is_ref) {
          return emit_op_i32(e, VM_OP_RLOAD, (int32_t)target_off) &&
                 emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
        }
        return emit_op_i32(e, VM_OP_RLOAD, (int32_t)(target_off + field_offset));
      }
      char* full_name = lexical_make_binding_path(e, target->value);
      const StaticSlot* slot =
          full_name ? static_slot_lookup(e, str_from(full_name, strlen(full_name))) : NULL;
      free(full_name);
      if (!slot) return false;
      return emit_op(e, VM_OP_GLOBAL) &&
             emit_global_offset_i32(e, VM_OP_ALOAD,
                                    slot->global_slot + (size_t)field_offset);
    }
    /* Non-ident target (nested $member or other ref-yielding expr): recursively
     * obtain the base handle then offset into the ref field. */
    if (!emit_ref_handle_expr(e, target)) return false;
    return emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
  }
  return false;
}

/* ── frame alignment helper ─────────────────────────────────────────────── */

/* Sum of all entry sizes in the current frame (= byte position of next entry).
 */
static size_t frame_current_size(MorphlBackendFrameInfo* fi) {
  struct MorphlBackendFrame* f = fi->current;
  size_t total = 0;
  for (size_t i = 0; i < f->offset_count; i++) total += f->offsets[i].size;
  return total;
}

/* Insert alignment padding before registering a variable of the given type.
 * Padding is recorded as an anonymous entry so offset arithmetic stays correct.
 */
static bool frame_align_for_type(VmEmitter* e, const MorphlType* t) {
  size_t fa = type_frame_align(t);
  if (fa <= 1) return true;
  size_t cur = frame_current_size(&e->frameInfo);
  size_t aligned = align_up(cur, fa);
  size_t pad = aligned - cur;
  if (pad == 0) return true;
  struct MorphlBackendFrameOffset poff = {.name = str_from("", 0), .size = pad};
  return morphl_backend_append_offset(&e->frameInfo, poff);
}

/* ── function table helpers ─────────────────────────────────────────────── */

static size_t func_alloc(VmEmitter* e) {
  if (e->functions.count >= e->functions.capacity) {
    if (!vm_grow((void**)&e->functions.items, &e->functions.capacity,
                 sizeof(VmFunctionMeta), e->functions.count + 1))
      return SIZE_MAX;
  }
  size_t idx = e->functions.count++;
  memset(&e->functions.items[idx], 0, sizeof(VmFunctionMeta));
  return idx;
}

/* ── forward declaration ────────────────────────────────────────────────── */
static bool emit_node(VmEmitter* e, struct AstNode* node);
static bool emit_block_value_into_slot(VmEmitter* e, const MorphlType* block_t,
                                       struct AstNode* block_ref, Str binding_name,
                                       ptrdiff_t off);

/* ── pre-scan block to compute its total $decl byte size ─────────────────── */
/* Local variables on the frame are laid out in declaration order with natural
 * alignment, matching the same padding rules used for struct fields. */
static size_t block_scope_size(struct AstNode* block) {
  if (!block) return 0;
  size_t offset = 0;
  for (size_t i = 0; i < block->child_count; i++) {
    struct AstNode* ch = block->children[i];
    if (!ch) continue;
    if (ch->kind == AST_DECL && ch->type && ch->contributes_to_layout) {
      const MorphlType* t = unwrap_ref(ch->type);
      /* Trait variable: RHS is ident with a trait-only-prop BLOCK type →
       * fat-block = 16 bytes */
      if (t && t->kind == MORPHL_TYPE_BLOCK && t->data.block.field_count == 0 &&
          t->data.block.prop_count > 0 && ch->child_count >= 2 &&
          ch->children[1] && ch->children[1]->kind == AST_IDENT) {
        offset = align_up(offset, 8);
        offset += 16;
      } else {
        size_t fa = type_frame_align(t);
        offset = align_up(offset, fa);
        offset += type_frame_size(t);
      }
    }
  }
  return offset;
}

static bool emit_expr_into_known_slot(VmEmitter* e, AstNode* expr,
                                      const MorphlType* t, ptrdiff_t off,
                                      Str binding_name) {
  if (!e || !expr || !t) return false;
  const MorphlType* ut = unwrap_ref(t);
  if (!ut) return false;
  if (expr->kind == AST_FUNC) {
    size_t fidx = func_alloc(e);
    if (fidx == SIZE_MAX) return false;
    if (e->deferred_count >= e->deferred_capacity) {
      if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                   sizeof(DeferredFunc), e->deferred_count + 1))
        return false;
    }
    e->deferred[e->deferred_count++] =
        (DeferredFunc){expr, fidx, binding_name, current_file_root_prefix(e)};
    if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
    return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
  }
  if (ut->kind == MORPHL_TYPE_BLOCK && expr->kind == AST_BLOCK) {
    return emit_block_value_into_slot(e, ut, expr, binding_name, off);
  }
  if (!emit_node(e, expr)) return false;
  uint8_t sop = store_op(ut);
  if (sop == 0xFF) return false;
  return emit_op_i32(e, sop, (int32_t)off);
}

static bool emit_overload_value_into_slot(VmEmitter* e, const MorphlType* overload_t,
                                          AstNode* overload_expr,
                                          ptrdiff_t off, Str binding_name) {
  if (!e || !overload_t || overload_t->kind != MORPHL_TYPE_OVERLOAD ||
      !overload_expr || overload_expr->child_count != overload_t->data.overload.candidate_count) {
    return false;
  }
  for (size_t i = 0; i < overload_t->data.overload.candidate_count; ++i) {
    ptrdiff_t cand_off = off + (ptrdiff_t)overload_candidate_offset(overload_t, i);
    if (!emit_expr_into_known_slot(e, overload_expr->children[i],
                                   overload_t->data.overload.candidate_types[i],
                                   cand_off, binding_name)) {
      return false;
    }
  }
  return true;
}

/* ── emit a single AST node ─────────────────────────────────────────────── */

static bool emit_node(VmEmitter* e, struct AstNode* node) {
  if (!node) return true;

  switch (node->kind) {
    /* ── literals ── */
    case AST_LITERAL: {
      const MorphlType* t = unwrap_ref(node->type);
      if (!t) {
        VM_ERR(node, "literal has no type");
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
        /* String literal: strip surrounding quotes and intern into string table
         */
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
      /* resolve compile-time $ref aliases; accumulate any extra byte offset */
      ptrdiff_t extra = 0;
      Str resolved = alias_resolve_full(e, node->value, &extra);
      const ImportSlot* import_slot =
          (e->emit_object && extra == 0) ? emitter_find_import_slot(e, resolved)
                                         : NULL;
      if (import_slot) {
        const MorphlType* t = unwrap_ref(node->type);
        if (!t || (t->kind != MORPHL_TYPE_BLOCK && t->kind != MORPHL_TYPE_ARRAY &&
                   t->kind != MORPHL_TYPE_UNION)) {
          VM_ERR(node, "cannot load imported identifier '%.*s' directly",
                 (int)node->value.len, node->value.ptr);
          return false;
        }
        return emit_op(e, VM_OP_GLOBAL) &&
               emit_global_offset_i32(e, VM_OP_ALOAD, import_slot->global_slot);
      }
      ptrdiff_t base_off = morphl_backend_find_offset(&e->frameInfo, resolved);
      if (base_off == PTRDIFF_MAX) {
        const StaticSlot* slot = static_slot_lookup_scoped(e, resolved);
        if (slot) {
          const MorphlType* t = unwrap_ref(node->type);
          if (t &&
              (t->kind == MORPHL_TYPE_BLOCK || t->kind == MORPHL_TYPE_ARRAY ||
               t->kind == MORPHL_TYPE_UNION)) {
            VM_ERR(node,
                   "plain access to static aggregate '%.*s' is not supported",
                   (int)node->value.len, node->value.ptr);
            return false;
          }
          return emit_op(e, VM_OP_GLOBAL) &&
                 emit_global_offset_i32(e, VM_OP_ALOAD,
                                        slot->global_slot + (size_t)extra);
        }
      }
      if (base_off == PTRDIFF_MAX) {
        VM_ERR(node, "undefined identifier '%.*s'", (int)node->value.len,
               node->value.ptr);
        return false;
      }
      ptrdiff_t off = base_off + extra;
      /* For alias refs, fully unwrap through the $ref layer to get the target
       * type. For normal idents (including $ref struct fields), use normal
       * unwrap. */
      const MorphlType* t;
      if (!str_eq(resolved, node->value) || extra != 0) {
        /* alias: strip ALL ref layers to reach actual stored type */
        t = node->type;
        while (t && t->kind == MORPHL_TYPE_REF) t = t->data.ref.target;
      } else {
        t = unwrap_ref(node->type);
      }
      if (t && t->kind == MORPHL_TYPE_OVERLOAD) {
        if (!node->overload_has_selection || node->overload_select_self) {
          VM_ERR(node, "plain access to overload object is not supported here");
          return false;
        }
        if (node->overload_selected_index >= t->data.overload.candidate_count) {
          VM_ERR(node, "invalid overload candidate selection");
          return false;
        }
        const MorphlType* candidate = unwrap_ref(
            t->data.overload.candidate_types[node->overload_selected_index]);
        ptrdiff_t candidate_off =
            off + (ptrdiff_t)overload_candidate_offset(
                          t, node->overload_selected_index);
        uint8_t op = load_op(candidate);
        if (op == 0xFF) {
          VM_ERR(node, "cannot load selected overload candidate");
          return false;
        }
        return emit_op_i32(e, op, (int32_t)candidate_off);
      }
      uint8_t op = load_op(t);
      if (op == 0xFF) {
        VM_ERR(node, "cannot load type for '%.*s'", (int)node->value.len,
               node->value.ptr);
        return false;
      }
      return emit_op_i32(e, op, (int32_t)off);
    }

    /* ── declarations ── */
    case AST_DECL: {
      if (node->child_count < 2) return true; /* empty decl, skip */
      struct AstNode* name_node = node->children[0];
      struct AstNode* rhs = node->children[1];
      struct AstNode* heap_rhs = unwrap_storage_builtin(e, rhs, "$heap");
      struct AstNode* heap_init =
          (heap_rhs && heap_rhs->child_count > 0) ? heap_rhs->children[0] : NULL;
      struct AstNode* extern_rhs = unwrap_extern_expr(rhs, e->interns);
      bool rhs_is_import =
          builtin_is_name(e, rhs, "$import") && import_module_root(rhs) != NULL;
      if (!name_node || name_node->kind != AST_IDENT) return false;

      Str name = name_node->value;
      /* handle compile-time $ref alias BEFORE any frame registration.
       * Supports any lvalue: identifier, $member, $index (literal), $as. */
      if (rhs && rhs->kind == AST_BUILTIN) {
        Str op_name = (e->interns && rhs->op)
                          ? interns_lookup(e->interns, rhs->op)
                          : rhs->value;
        if (op_name.len == 4 && memcmp(op_name.ptr, "$ref", 4) == 0 &&
            rhs->child_count > 0 && rhs->children[0]) {
          struct AstNode* lval = rhs->children[0];

          /* $ref x — simple ident alias (current behavior) */
          if (lval->kind == AST_IDENT) {
            return alias_add(e, name, lval->value, 0);
          }

          /* $ref $member s field — alias with compile-time field offset */
          if (lval->kind == AST_BUILTIN && lval->child_count >= 2) {
            Str lop = (e->interns && lval->op)
                          ? interns_lookup(e->interns, lval->op)
                          : lval->value;
            if (lop.len == 7 && memcmp(lop.ptr, "$member", 7) == 0) {
              struct AstNode* tgt = lval->children[0];
              struct AstNode* fnd = lval->children[1];
              if (tgt && tgt->kind == AST_IDENT && fnd) {
                Str fname = fnd->value;
                if (!fname.ptr && e->interns && fnd->op)
                  fname = interns_lookup(e->interns, fnd->op);
                const MorphlType* ttype = unwrap_ref(tgt->type);
                if (ttype && ttype->kind == MORPHL_TYPE_BLOCK) {
                  ptrdiff_t foff_bytes =
                      block_layout_field_offset(ttype, e->interns, fname, NULL);
                  if (foff_bytes == PTRDIFF_MAX) {
                    VM_ERR(fnd, "$ref $member: field not found");
                    return false;
                  }
                  return alias_add(e, name, tgt->value, foff_bytes);
                }
                /* union $$data or $$tag */
                if (ttype && ttype->kind == MORPHL_TYPE_UNION) {
                  bool is_data =
                      fname.len == 6 && memcmp(fname.ptr, "$$data", 6) == 0;
                  bool is_tag =
                      fname.len == 5 && memcmp(fname.ptr, "$$tag", 5) == 0;
                  ptrdiff_t uoff = 0;
                  if (is_tag) uoff = (ptrdiff_t)(ttype->size - 8);
                  if (is_data || is_tag)
                    return alias_add(e, name, tgt->value, uoff);
                }
              }
            }
            /* $ref $index arr i (literal) */
            if (lop.len == 6 && memcmp(lop.ptr, "$index", 6) == 0) {
              struct AstNode* arr = lval->children[0];
              struct AstNode* idx = lval->children[1];
              if (arr && arr->kind == AST_IDENT && idx &&
                  idx->kind == AST_LITERAL) {
                const MorphlType* at = unwrap_ref(arr->type);
                if (at && at->kind == MORPHL_TYPE_ARRAY) {
                  char ibuf[32];
                  size_t ilen = idx->value.len < sizeof(ibuf) - 1
                                    ? idx->value.len
                                    : sizeof(ibuf) - 1;
                  memcpy(ibuf, idx->value.ptr, ilen);
                  ibuf[ilen] = '\0';
                  long long iv = strtoll(ibuf, NULL, 10);
                  ptrdiff_t eoff = (ptrdiff_t)((long long)type_frame_size(
                                                   at->data.array.elem_type) *
                                               iv);
                  return alias_add(e, name, arr->value, eoff);
                }
              }
            }
            /* $ref $as expr TargetType — reinterpret alias, offset 0 */
            if (lop.len == 3 && memcmp(lop.ptr, "$as", 3) == 0 &&
                lval->children[0]) {
              struct AstNode* src = lval->children[0];
              if (src->kind == AST_IDENT)
                return alias_add(e, name, src->value, 0);
            }
          }
          VM_ERR(node, "$ref: unsupported lvalue kind");
          return false;
        }
      }

      /* If this $decl foo $func... is the real body resolving a prior $forward
       * stub, find the matching deferred entry by name and replace its AST node
       * in-place. The frame slot and fidx were already allocated by the
       * $forward declaration. */
      if (rhs && rhs->kind == AST_FUNC &&
          morphl_backend_find_offset(&e->frameInfo, name) != PTRDIFF_MAX) {
        for (size_t i = 0; i < e->deferred_count; i++) {
          if (str_eq(e->deferred[i].name, name)) {
            e->deferred[i].node = rhs;
            return true;
          }
        }
      }
      /* Forward extern completion reuses the already allocated frame slot. */
      if (extern_rhs &&
          morphl_backend_find_offset(&e->frameInfo, name) != PTRDIFF_MAX) {
        ptrdiff_t existing_off =
            morphl_backend_find_offset(&e->frameInfo, name);
        const MorphlType* fn_type = unwrap_ref(node->type);
        uint32_t param_sz = 0;
        if (fn_type && fn_type->kind == MORPHL_TYPE_FUNC &&
            fn_type->data.func.param_count > 0 &&
            fn_type->data.func.param_types[0]) {
          param_sz = (uint32_t)type_frame_size(
              unwrap_ref(fn_type->data.func.param_types[0]));
        }
        if (e->native_sym_count >= e->native_sym_capacity) {
          if (!vm_grow((void**)&e->native_syms, &e->native_sym_capacity,
                       sizeof(char*), e->native_sym_count + 1))
            return false;
        }
        Str sym_str = node->extern_symbol.ptr ? node->extern_symbol : name;
        char* sym_name = (char*)malloc(sym_str.len + 1);
        if (!sym_name) return false;
        memcpy(sym_name, sym_str.ptr, sym_str.len);
        sym_name[sym_str.len] = '\0';
        e->native_syms[e->native_sym_count] = sym_name;
        size_t native_idx = e->native_sym_count++;
        size_t fidx = func_alloc(e);
        if (fidx == SIZE_MAX) return false;
        e->functions.items[fidx].entry_point = (uint32_t)native_idx;
        e->functions.items[fidx].flags = MORPHL_FUNC_FLAG_NATIVE;
        e->functions.items[fidx].param_size = param_sz;
        e->functions.items[fidx].frame_size = 0;
        if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
        return emit_op_i32(e, VM_OP_ISTORE, (int32_t)existing_off);
      }

      const MorphlType* raw_type = node->type;
      const MorphlType* t = unwrap_ref(raw_type);
      if (node->storage_residence == MORPHL_STORAGE_STATIC) {
        if (rhs && extern_rhs) {
          VM_ERR(node,
                 "$static extern bindings are not implemented in the VM backend");
          return false;
        }
        char* full_name = lexical_make_binding_path(e, name);
        if (!full_name) return false;
        const StaticSlot* slot =
            static_slot_lookup(e, str_from(full_name, strlen(full_name)));
        if (!slot) {
          VM_ERR(node, "internal error: static slot not preallocated for '%s'",
                 full_name);
          free(full_name);
          return false;
        }
        free(full_name);
        size_t done_lbl = label_new(e);
        if (done_lbl == SIZE_MAX) return false;
        if (!emit_op(e, VM_OP_GLOBAL)) return false;
        if (!emit_global_offset_i32(e, VM_OP_ALOAD, slot->guard_slot))
          return false;
        if (!emit_jump(e, VM_OP_JIF, done_lbl)) return false;
        if (!emit_op(e, VM_OP_GLOBAL)) return false;
        if (rhs && rhs->kind == AST_FUNC) {
          size_t fidx = func_alloc(e);
          if (fidx == SIZE_MAX) return false;
          if (e->deferred_count >= e->deferred_capacity) {
            if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                         sizeof(DeferredFunc), e->deferred_count + 1))
              return false;
          }
          e->deferred[e->deferred_count++] =
              (DeferredFunc){rhs, fidx, name, current_file_root_prefix(e)};
          if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
        } else {
          if (!emit_node(e, rhs)) return false;
        }
        if (!emit_global_offset_i32(e, VM_OP_ASTORE, slot->global_slot))
          return false;
        if (!emit_op(e, VM_OP_GLOBAL)) return false;
        if (!emit_iconst(e, 1)) return false;
        if (!emit_global_offset_i32(e, VM_OP_ASTORE, slot->guard_slot))
          return false;
        if (t && t->kind == MORPHL_TYPE_BLOCK && rhs && rhs->kind == AST_BLOCK &&
            block_has_defer(e, rhs)) {
          BindingCleanup cleanup = {
              .binding_name = name,
              .block = rhs,
              .block_type = t,
              .binding_type = raw_type,
              .scope_depth = 0,
              .run_on_scope_exit = false,
              .run_on_free = false,
          };
          if (!cleanup_array_push(&e->static_cleanups, &e->static_cleanup_count,
                                  &e->static_cleanup_capacity, &cleanup))
            return false;
        }
        return label_bind(e, done_lbl);
      }
      bool is_trait_var =
          (t && t->kind == MORPHL_TYPE_BLOCK &&
           t->data.block.field_count == 0 && t->data.block.prop_count > 0 &&
           rhs && rhs->kind == AST_IDENT);

      ptrdiff_t off = PTRDIFF_MAX;
      bool bind_has_frame_storage =
          node->contributes_to_layout && !(rhs_is_import && e->emit_object);
      if (bind_has_frame_storage) {
        /* insert alignment padding before the variable, then register in frame
         * tracker */
        /* Trait variable (no fields, only props, RHS is an ident): fat-block =
         * 2 refs = 16 bytes */
        if (is_trait_var) {
          /* 8-byte align for the two ref slots */
          size_t cur = frame_current_size(&e->frameInfo);
          size_t aligned = align_up(cur, 8);
          if (aligned > cur) {
            struct MorphlBackendFrameOffset pad = {.name = str_from("", 0),
                                                   .size = aligned - cur};
            if (!morphl_backend_append_offset(&e->frameInfo, pad)) return false;
          }
        } else {
          if (t && !frame_align_for_type(e, t)) return false;
        }
        struct MorphlBackendFrameOffset foff = {
            .name = name,
            .size = is_trait_var ? 16 : (t ? type_frame_size(t) : 0)};
        if (!morphl_backend_append_offset(&e->frameInfo, foff)) return false;

        /* find the offset we just registered */
        off = morphl_backend_find_offset(&e->frameInfo, name);
        if (off == PTRDIFF_MAX) return false;
      }

      /* if RHS is a $import, track slot index so we can write the $modules
       * entry after emission */
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
          Str import_path = (rhs->child_count >= 1 && rhs->children[0])
                                ? rhs->children[0]->import_path
                                : str_from("", 0);
          AstNode* module_root = import_module_root(rhs);
          e->import_slots[import_slot_before] = (ImportSlot){
              .name = name,
              .global_slot = 32 + 8 * import_slot_before,
              .module_path = import_path,
              .module_root = module_root,
          };
          e->import_slot_count++;
        }
      }

      /* if RHS is $extern <func-expr>, allocate a native function slot */
      if (extern_rhs) {
        /* compute param_size from the DECL's function type */
        const MorphlType* fn_type = unwrap_ref(node->type);
        uint32_t param_sz = 0;
        if (fn_type && fn_type->kind == MORPHL_TYPE_FUNC &&
            fn_type->data.func.param_count > 0 &&
            fn_type->data.func.param_types[0]) {
          param_sz = (uint32_t)type_frame_size(
              unwrap_ref(fn_type->data.func.param_types[0]));
        }
        /* grow native_syms array and record NUL-terminated copy of symbol name
         */
        if (e->native_sym_count >= e->native_sym_capacity) {
          if (!vm_grow((void**)&e->native_syms, &e->native_sym_capacity,
                       sizeof(char*), e->native_sym_count + 1))
            return false;
        }
        /* For imported modules, value.ptr is freed (pp_action_import frees
         * source_buffer). Fall back to the interned name via name_node->op. */
        Str sym_str = node->extern_symbol.ptr ? node->extern_symbol : name;
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
        e->functions.items[fidx].flags = MORPHL_FUNC_FLAG_NATIVE;
        e->functions.items[fidx].param_size = param_sz;
        e->functions.items[fidx].frame_size = 0;
        /* store function table index as i64 in the variable's frame slot */
        if (!node->contributes_to_layout) return true;
        if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
        return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
      }

      /* $forward func-stub — pre-allocate a fidx for the stub and defer it so
       * that recursive calls made before the real body is defined can resolve
       * the index. When the real $decl foo $func... arrives, the early-return
       * above replaces the stub node in the deferred table without allocating
       * another frame slot. */
      if (rhs && rhs->kind == AST_BUILTIN && e->interns && rhs->op) {
        Str fwd_op = interns_lookup(e->interns, rhs->op);
        if (fwd_op.len == 8 && memcmp(fwd_op.ptr, "$forward", 8) == 0) {
          if (rhs->child_count < 1 || !rhs->children[0]) {
            VM_ERR(node, "$forward: expected a stub expression as argument");
            return false;
          }
          struct AstNode* stub = rhs->children[0];
          bool is_extern_stub =
              (stub->kind == AST_BUILTIN && stub->op &&
               interns_lookup(e->interns, stub->op).len == 7 &&
               memcmp(interns_lookup(e->interns, stub->op).ptr, "$extern", 7) ==
                   0);
          if (stub->kind != AST_FUNC && !is_extern_stub) {
            VM_ERR(node, "$forward: expected a function or extern stub");
            return false;
          }
          size_t fidx = func_alloc(e);
          if (fidx == SIZE_MAX) return false;
          if (!is_extern_stub) {
            if (e->deferred_count >= e->deferred_capacity) {
              if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                           sizeof(DeferredFunc), e->deferred_count + 1))
                return false;
            }
            e->deferred[e->deferred_count++] =
                (DeferredFunc){stub, fidx, name, current_file_root_prefix(e)};
          }
          if (!node->contributes_to_layout) return true;
          if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
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
                       sizeof(DeferredFunc), e->deferred_count + 1))
            return false;
        }
        e->deferred[e->deferred_count++] =
            (DeferredFunc){rhs, fidx, name, current_file_root_prefix(e)};
        /* store function table index as i64 in frame */
        if (!node->contributes_to_layout) return true;
        if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
        return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
      }

      if (heap_rhs) {
        const MorphlType* heap_storage_t =
            (t && t->kind == MORPHL_TYPE_REF && t->data.ref.is_ref && t->data.ref.target)
                ? unwrap_ref(t->data.ref.target)
                : t;
        size_t alloc_sz = heap_storage_t ? type_frame_size(heap_storage_t) : 8;
        if (!node->contributes_to_layout) {
          VM_ERR(node, "$heap declaration must contribute storage");
          return false;
        }
        if (!emit_op_u32(e, VM_OP_HEAP, (uint32_t)alloc_sz)) return false;
        if (!emit_op_i32(e, VM_OP_RSTORE, (int32_t)off)) return false;
        if (heap_storage_t && heap_storage_t->kind == MORPHL_TYPE_BLOCK) {
          struct AstNode* base_block = new_base_inline_block_initializer(e, heap_init);
          if (base_block) {
            if (!emit_block_decl_initializers_into_handle_slot(e, heap_storage_t, base_block, off))
              return false;
            if (block_has_defer(e, base_block)) {
              size_t thunk_fidx = func_alloc(e);
              if (thunk_fidx == SIZE_MAX) return false;
              /* attach cleanup thunk to this allocation via runtime SET_CLEANUP */
              if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)off)) return false;
              if (!emit_func_index_u32(e, VM_OP_SET_CLEANUP, (uint32_t)thunk_fidx)) return false;
              /* record thunk for deferred emission */
              if (e->deferred_cleanup_count >= e->deferred_cleanup_capacity) {
                if (!vm_grow((void**)&e->deferred_cleanups, &e->deferred_cleanup_capacity,
                             sizeof(*e->deferred_cleanups), e->deferred_cleanup_count + 1))
                  return false;
              }
              char* slp = strdup(lexical_current_path(e));
              if (!slp) return false;
              e->deferred_cleanups[e->deferred_cleanup_count++] =
                  (struct DeferredCleanupThunk){thunk_fidx, base_block, heap_storage_t, raw_type, slp};
            }
            return true;
          }
        }
        if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)off)) return false;
        if (!emit_node(e, heap_init ? heap_init : rhs)) return false;
        if (!emit_op_i32(e, VM_OP_ASTORE, 0)) return false;
        return true;
      }

      /* For structural types (union, block, array) declared with a type-alias
       * ident RHS, the frame slot is already zero-initialized by ENTER —
       * nothing to emit or store. This handles `$decl s Shape` where Shape is a
       * named union/block/array type. */
      if (t && (t->kind == MORPHL_TYPE_UNION || t->kind == MORPHL_TYPE_ARRAY) &&
          rhs && rhs->kind == AST_IDENT) {
        /* Check that the RHS ident resolves to the same structural type (not a
         * value copy) */
        const MorphlType* rhs_t = rhs->type ? unwrap_ref(rhs->type) : NULL;
        if (rhs_t && (rhs_t->kind == MORPHL_TYPE_UNION ||
                      rhs_t->kind == MORPHL_TYPE_ARRAY)) {
          /* type-alias declaration: frame is zero-initialized, nothing more to
           * do
           */
          return true;
        }
      }

      /* Block field initialization: `$decl p { $decl x 42; $decl y 7; }`
       * Walk the inline block's $decl children and store each field directly
       * into the target frame slot, bypassing ENTER/LEAVE sub-scope. */
      if (t && t->kind == MORPHL_TYPE_BLOCK && rhs && rhs->kind == AST_BLOCK) {
        /* Register in block_decl_map so $new <name> can find the block AST */
        if (e->block_decl_map_count >= e->block_decl_map_capacity) {
          if (!vm_grow((void**)&e->block_decl_map, &e->block_decl_map_capacity,
                       sizeof(*e->block_decl_map), e->block_decl_map_count + 1))
            return false;
        }
        e->block_decl_map[e->block_decl_map_count++] =
            (struct VmBlockDeclEntry){name, rhs, t};
        if (!emit_block_value_into_slot(e, t, rhs, name, off)) return false;
        if (block_has_defer(e, rhs)) {
          BindingCleanup cleanup = {
              .binding_name = name,
              .block = rhs,
              .block_type = t,
              .binding_type = raw_type,
              .scope_depth = e->scope_depth,
              .run_on_scope_exit = true,
              .run_on_free = false,
          };
          if (node->storage_residence == MORPHL_STORAGE_STATIC) {
            if (!cleanup_array_push(&e->static_cleanups, &e->static_cleanup_count,
                                    &e->static_cleanup_capacity, &cleanup))
              return false;
          } else if (!cleanup_array_push(&e->binding_cleanups, &e->binding_cleanup_count,
                                         &e->binding_cleanup_capacity, &cleanup)) {
            return false;
          }
        }
        return true;
      }

      /* 1-arg $new in declaration context: the target slot already exists and
       * is zeroed by ENTER, so non-identifier type expressions can instantiate
       * by using the inferred declaration type instead of requiring a deferred
       * named template function. Inline block literals still get their
       * declaration defaults copied into the target slot. */
      if (rhs && rhs->kind == AST_BUILTIN && rhs->child_count == 1 &&
          e->interns && rhs->op) {
        Str new_op = interns_lookup(e->interns, rhs->op);
        if (new_op.len == 4 && memcmp(new_op.ptr, "$new", 4) == 0) {
          if (!t) {
            VM_ERR(rhs, "$new: expression is not instantiable");
            return false;
          }
          if (t->kind == MORPHL_TYPE_BLOCK) {
            struct AstNode* base_init =
                new_base_inline_block_initializer(e, rhs->children[0]);
            if (base_init) {
              if (!emit_block_decl_initializers_into_slot(e, t, base_init, off))
                return false;
              /* Register cleanup if the template block has $defer nodes */
              if (block_has_defer(e, base_init)) {
                BindingCleanup cleanup = {
                    .binding_name = name,
                    .block = base_init,
                    .block_type = t,
                    .binding_type = raw_type,
                    .scope_depth = e->scope_depth,
                    .run_on_scope_exit = true,
                    .run_on_free = false,
                };
                if (!cleanup_array_push(&e->binding_cleanups,
                                        &e->binding_cleanup_count,
                                        &e->binding_cleanup_capacity, &cleanup))
                  return false;
              }
              return true;
            }
            return true;
          }
          if (t->kind == MORPHL_TYPE_ARRAY || t->kind == MORPHL_TYPE_UNION ||
              t->kind == MORPHL_TYPE_INT || t->kind == MORPHL_TYPE_FLOAT ||
              t->kind == MORPHL_TYPE_BOOL || t->kind == MORPHL_TYPE_STRING) {
            return true;
          }
          VM_ERR(rhs, "$new: expression is not instantiable");
          return false;
        }
      }

      /* 2-arg $new: `$decl var ($new TypeExpr init)` — universal instantiation.
       * Applies init to the variable's frame slot; for scalar types this is a
       * straightforward store; for block types it is a field override (body
       * execution is V2); for union types the variant tag is injected by the
       * compiler. */
      if (rhs && rhs->kind == AST_BUILTIN && rhs->child_count == 2 &&
          e->interns && rhs->op) {
        Str new_op = interns_lookup(e->interns, rhs->op);
        if (new_op.len == 4 && memcmp(new_op.ptr, "$new", 4) == 0) {
          struct AstNode* init_node = rhs->children[1];
          /* Scalar types: emit init value and store */
          if (t &&
              (t->kind == MORPHL_TYPE_INT || t->kind == MORPHL_TYPE_FLOAT ||
               t->kind == MORPHL_TYPE_BOOL || t->kind == MORPHL_TYPE_STRING)) {
            if (!emit_node(e, init_node)) return false;
            return emit_op_i32(e, store_op(t), (int32_t)off);
          }
          /* Block type: apply positional or named field overrides */
          if (t && t->kind == MORPHL_TYPE_BLOCK) {
            /* Register cleanup for $new if the template block has $defer */
            {
              struct AstNode* tmpl_block =
                  new_base_inline_block_initializer(e, rhs->children[0]);
              if (tmpl_block && block_has_defer(e, tmpl_block)) {
                BindingCleanup cleanup = {
                    .binding_name = name,
                    .block = tmpl_block,
                    .block_type = t,
                    .binding_type = raw_type,
                    .scope_depth = e->scope_depth,
                    .run_on_scope_exit = true,
                    .run_on_free = false,
                };
                if (!cleanup_array_push(&e->binding_cleanups,
                                        &e->binding_cleanup_count,
                                        &e->binding_cleanup_capacity, &cleanup))
                  return false;
              }
            }
            if (init_node->kind == AST_GROUP) {
              size_t field_byte_off = 0;
              for (size_t fi = 0; fi < t->data.block.layout_field_count &&
                                  fi < init_node->child_count;
                   fi++) {
                const MorphlType* raw_ft = t->data.block.layout_field_types[fi];
                const MorphlType* ft = unwrap_ref(raw_ft);
                struct AstNode* gv = init_node->children[fi];
                if (gv) {
                  /* Sibling block ident injected by the flatten pre-pass:
                   * $ref field + block-typed ident → ADDREF + RSTORE */
                  bool handled = false;
                  if (ft && ft->kind == MORPHL_TYPE_REF &&
                      ft->data.ref.is_ref && gv->kind == AST_IDENT) {
                    const MorphlType* gv_t =
                        gv->type ? unwrap_ref(gv->type) : NULL;
                    if (gv_t && gv_t->kind == MORPHL_TYPE_BLOCK) {
                      ptrdiff_t sib_off =
                          morphl_backend_find_offset(&e->frameInfo, gv->value);
                      if (sib_off == PTRDIFF_MAX) {
                        VM_ERR(gv, "$new: sibling block not found: '%.*s'",
                               (int)gv->value.len, gv->value.ptr);
                        return false;
                      }
                      if (!emit_op_i32(e, VM_OP_ADDREF, (int32_t)sib_off) ||
                          !emit_op_i32(
                              e, VM_OP_RSTORE,
                              (int32_t)(off + (ptrdiff_t)field_byte_off)))
                        return false;
                      handled = true;
                    }
                  }
                  if (!handled) {
                    if (!emit_node(e, gv)) return false;
                    uint8_t sop = store_op(ft);
                    if (sop != 0xFF &&
                        !emit_op_i32(e, sop, (int32_t)(off + field_byte_off)))
                      return false;
                  }
                }
                field_byte_off += type_frame_size(ft);
              }
            } else if (init_node->kind == AST_BLOCK) {
              for (size_t ci = 0; ci < init_node->child_count; ci++) {
                struct AstNode* child = init_node->children[ci];
                if (!child || child->kind != AST_DECL || child->child_count < 2)
                  continue;
                struct AstNode* fn = child->children[0];
                struct AstNode* fv = child->children[1];
                if (!fn || !fv) continue;
                Str fname = fn->value;
                if (!fname.ptr && e->interns && fn->op)
                  fname = interns_lookup(e->interns, fn->op);
                size_t foff2 = 0;
                const MorphlType* ftype2 = NULL;
                ptrdiff_t layout_off =
                    block_layout_field_offset(t, e->interns, fname, &ftype2);
                if (layout_off != PTRDIFF_MAX) foff2 = (size_t)layout_off;
                if (!ftype2) continue;
                if (!emit_node(e, fv)) return false;
                uint8_t sop = store_op(unwrap_ref(ftype2));
                if (sop != 0xFF && !emit_op_i32(e, sop, (int32_t)(off + foff2)))
                  return false;
              }
            }
            return true;
          }
          /* Array type: apply positional group initializer */
          if (t && t->kind == MORPHL_TYPE_ARRAY) {
            if (init_node->kind == AST_GROUP) {
              const MorphlType* elem_t = unwrap_ref(t->data.array.elem_type);
              size_t elem_sz = type_frame_size(elem_t);
              for (size_t ai = 0; ai < t->data.array.count &&
                                  ai < init_node->child_count;
                   ai++) {
                struct AstNode* av = init_node->children[ai];
                if (!av) continue;
                if (!emit_node(e, av)) return false;
                uint8_t sop = store_op(elem_t);
                if (sop != 0xFF &&
                    !emit_op_i32(e, sop, (int32_t)(off + (ptrdiff_t)(ai * elem_sz))))
                  return false;
              }
            } else {
              VM_ERR(init_node, "$new array: initializer must be a group");
              return false;
            }
            return true;
          }
          /* Union type: find matching variant by structural subtype, inject tag
           */
          if (t && t->kind == MORPHL_TYPE_UNION) {
            const MorphlType* init_t =
                init_node->type ? unwrap_ref(init_node->type) : NULL;
            int tag = -1;
            const MorphlType* variant_t = NULL;
            for (size_t vi = 0; vi < t->data.union_t.variant_count; vi++) {
              if (morphl_type_is_subtype(init_t,
                                         t->data.union_t.variant_types[vi])) {
                tag = (int)vi;
                variant_t = t->data.union_t.variant_types[vi];
                break;
              }
            }
            if (tag < 0) {
              VM_ERR(node, "$new union: init type does not match any variant");
              return false;
            }
            /* Store variant fields at offset 0 (data-first layout) */
            if (variant_t && variant_t->kind == MORPHL_TYPE_BLOCK &&
                init_node->kind == AST_GROUP) {
              size_t field_byte_off = 0;
              for (size_t fi = 0;
                   fi < variant_t->data.block.layout_field_count &&
                   fi < init_node->child_count;
                   fi++) {
                const MorphlType* ft =
                    unwrap_ref(variant_t->data.block.layout_field_types[fi]);
                struct AstNode* gv = init_node->children[fi];
                if (gv) {
                  if (!emit_node(e, gv)) return false;
                  uint8_t sop = store_op(ft);
                  if (sop != 0xFF &&
                      !emit_op_i32(e, sop, (int32_t)(off + field_byte_off)))
                    return false;
                }
                field_byte_off += type_frame_size(ft);
              }
            } else if (init_t) {
              /* Single-value init (scalar variant) */
              if (!emit_node(e, init_node)) return false;
              uint8_t sop = store_op(init_t);
              if (sop != 0xFF && !emit_op_i32(e, sop, (int32_t)off))
                return false;
            }
            /* Inject $$tag at data-first layout: offset = union_size - 8 */
            ptrdiff_t tag_off = off + (ptrdiff_t)(t->size - 8);
            if (!emit_iconst(e, (int64_t)tag)) return false;
            return emit_op_i32(e, VM_OP_ISTORE, (int32_t)tag_off);
          }
          /* For unrecognized types, fall through to regular 1-arg $new (emit
           * RHS)
           */
        }
      }

      /* Special case: $decl x $if cond A B where the result type is a union.
       * The standard path (emit rhs → stack value → ISTORE) doesn't work
       * because: a) union types have sop==0xFF (no single-slot store), and b)
       * the two branches may have different types (int vs float). Instead, emit
       * each branch with inline data+tag stores directly into x's frame. */
      if (t && t->kind == MORPHL_TYPE_UNION && rhs && rhs->kind == AST_IF &&
          rhs->child_count >= 3) {
        ptrdiff_t tag_off = off + (ptrdiff_t)(t->size - 8);
        struct AstNode* cond_nd = rhs->children[0];
        struct AstNode* then_nd = rhs->children[1];
        struct AstNode* else_nd = rhs->children[2];
        /* emit condition + negate */
        if (!emit_node(e, cond_nd)) return false;
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_IEQ)) return false;
        size_t else_lbl = label_new(e);
        size_t end_lbl = label_new(e);
        if (else_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;
        if (!emit_jump(e, VM_OP_JIF, else_lbl)) return false;
        /* then branch: emit value, store data, store tag=0 */
        if (!emit_node(e, then_nd)) return false;
        {
          const MorphlType* branch_t = unwrap_ref(then_nd->type);
          uint8_t sop2 = branch_t ? store_op(branch_t) : 0xFF;
          if (sop2 == 0xFF) {
            VM_ERR(then_nd, "$if: unsupported then-branch type for union");
            return false;
          }
          if (!emit_op_i32(e, sop2, (int32_t)off)) return false;
        }
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op_i32(e, VM_OP_ISTORE, (int32_t)tag_off)) return false;
        if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;
        /* else branch: emit value, store data, store tag=1 */
        if (!label_bind(e, else_lbl)) return false;
        if (!emit_node(e, else_nd)) return false;
        {
          const MorphlType* branch_t = unwrap_ref(else_nd->type);
          uint8_t sop2 = branch_t ? store_op(branch_t) : 0xFF;
          if (sop2 == 0xFF) {
            VM_ERR(else_nd, "$if: unsupported else-branch type for union");
            return false;
          }
          if (!emit_op_i32(e, sop2, (int32_t)off)) return false;
        }
        if (!emit_iconst(e, 1)) return false;
        if (!emit_op_i32(e, VM_OP_ISTORE, (int32_t)tag_off)) return false;
        return label_bind(e, end_lbl);
      }

      /* Trait variable declaration: $decl traitVar TraitA
       * Frame is zero-initialized (both fat-block ref slots = null) — nothing
       * to emit. */
      if (is_trait_var) {
        return true;
      }

      /* $impl declaration: $decl typeE $impl TraitA typeD { overrides }
       * Emit the override block to register deferred prop functions, then write
       * function indices into the property table in the global frame. */
      if (rhs && rhs->kind == AST_BUILTIN && e->interns && rhs->op) {
        Str rhs_op_s = interns_lookup(e->interns, rhs->op);
        if (rhs_op_s.len == 5 && memcmp(rhs_op_s.ptr, "$impl", 5) == 0) {
          const MorphlType* impl_t = rhs->type ? unwrap_ref(rhs->type) : NULL;
          if (impl_t && impl_t->kind == MORPHL_TYPE_BLOCK &&
              impl_t->data.block.prop_count > 0) {
            /* Allocate prop table space in the global frame */
            size_t entry_prop_off = e->impl_prop_table_ptr;
            e->impl_prop_table_ptr += impl_t->data.block.prop_count * 8;

            /* Emit the override block — this defers the prop functions */
            size_t dc_before = e->deferred_count;
            if (rhs->child_count >= 3 && rhs->children[2]) {
              if (!emit_node(e, rhs->children[2])) return false;
            }
            size_t dc_after = e->deferred_count;

            /* For each newly deferred prop function, ASTORE its index into the
             * prop table */
            for (size_t di = dc_before; di < dc_after; di++) {
              Str prop_name_d = e->deferred[di].name;
              size_t fidx_d = e->deferred[di].func_idx;
              for (size_t pi = 0; pi < impl_t->data.block.prop_count; pi++) {
                if (!impl_t->data.block.prop_names) continue;
                Str pn = e->interns
                             ? interns_lookup(e->interns,
                                              impl_t->data.block.prop_names[pi])
                             : (Str){NULL, 0};
                if (str_eq(pn, prop_name_d)) {
                  /* GLOBAL; ICONST fidx; ASTORE (entry_prop_off + pi*8) */
                  if (!emit_op(e, VM_OP_GLOBAL)) return false;
                  if (!emit_func_index_iconst(e, (uint32_t)fidx_d)) return false;
                  if (!emit_global_offset_i32(e, VM_OP_ASTORE,
                                              entry_prop_off + pi * 8))
                    return false;
                  break;
                }
              }
            }

            /* Register ImplEntry so $set and $call can look it up */
            if (e->impl_count >= e->impl_capacity) {
              if (!vm_grow((void**)&e->impl_entries, &e->impl_capacity,
                           sizeof(ImplEntry), e->impl_count + 1))
                return false;
            }
            e->impl_entries[e->impl_count++] = (ImplEntry){
                .impl_name = name,
                .prop_table_off = entry_prop_off,
                .prop_count = impl_t->data.block.prop_count,
            };
            return true;
          }
        }
      }

      if (t && t->kind == MORPHL_TYPE_OVERLOAD) {
        if (!bind_has_frame_storage) return true;
        AstNode* overload_rhs = unwrap_storage_builtin(e, rhs, "$overload");
        if (overload_rhs && overload_rhs->child_count > 0) {
          return emit_overload_value_into_slot(e, t, overload_rhs, off, name);
        }
        if (rhs && rhs->kind == AST_IDENT) {
          ptrdiff_t src_extra = 0;
          Str src_name = alias_resolve_full(e, rhs->value, &src_extra);
          ptrdiff_t src_off =
              morphl_backend_find_offset(&e->frameInfo, src_name) + src_extra;
          if (src_off != PTRDIFF_MAX + src_extra) {
            for (size_t i = 0; i < t->data.overload.candidate_count; ++i) {
              const MorphlType* candidate =
                  unwrap_ref(t->data.overload.candidate_types[i]);
              size_t cand_off = overload_candidate_offset(t, i);
              uint8_t lop = load_op(candidate);
              uint8_t sop = store_op(candidate);
              if (lop == 0xFF || sop == 0xFF) {
                VM_ERR(rhs, "cannot copy overload candidate");
                return false;
              }
              if (!emit_op_i32(e, lop, (int32_t)(src_off + (ptrdiff_t)cand_off)) ||
                  !emit_op_i32(e, sop, (int32_t)(off + (ptrdiff_t)cand_off))) {
                return false;
              }
            }
            return true;
          }
        }
      }

      /* emit RHS expression */
      if (rhs_is_import) {
        if (!e->emit_object) {
          if (!lexical_scope_push_named(e, name)) return false;
          bool ok = emit_node(e, rhs);
          lexical_scope_pop(e);
          if (!ok) return false;
        }
      } else {
        if (!emit_node(e, rhs)) return false;
      }

      /* if this was a $import, populate the $modules global slot now that the
       * module's frame has been pushed (so frame offsets are stable) */
      if (import_slot_before != SIZE_MAX && !e->emit_object) {
        ImportSlot* sl = &e->import_slots[import_slot_before];
        ptrdiff_t m_off = morphl_backend_find_offset(&e->frameInfo, sl->name);
        if (m_off != PTRDIFF_MAX) {
          int64_t mod_frame_base =
              (int64_t)e->global_frame_size + (int64_t)m_off;
          if (!emit_op(e, VM_OP_GLOBAL) ||
              !emit_module_frame_base_iconst(e, mod_frame_base) ||
              !emit_global_offset_i32(e, VM_OP_ASTORE, sl->global_slot))
            return false;
        }
      }

      if (!bind_has_frame_storage) {
        return true;
      }

      /* store result to frame */
      uint8_t sop = store_op(t);
      if (sop == 0xFF) {
        /* void / block / array / union / unknown — nothing to store (frame
         * already reserved and zeroed by ENTER, or filled by the RHS emitter
         * itself) */
        return true;
      }
      return emit_op_i32(e, sop, (int32_t)off);
    }

    /* ── blocks and file root ── */
    case AST_FILE:
    case AST_BLOCK: {
      bool pushed_lexical = false;
      if (node->kind == AST_BLOCK) {
        if (!lexical_scope_push_anon(e)) return false;
        pushed_lexical = true;
      }
      size_t scope_sz = block_scope_size(node);
      if (!morphl_backend_push_frame(&e->frameInfo)) return false;
      if (!emit_enter(e, (uint32_t)scope_sz)) {
        if (pushed_lexical) lexical_scope_pop(e);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
      for (size_t i = 0; i < node->child_count; i++) {
        if (!emit_node(e, node->children[i])) {
          if (pushed_lexical) lexical_scope_pop(e);
          morphl_backend_pop_frame(&e->frameInfo);
          return false;
        }
      }
      for (size_t i = node->child_count; i > 0; --i) {
        AstNode* child = node->children[i - 1];
        if (!builtin_is_name(e, child, "$defer") || child->child_count < 1 ||
            !child->children[0])
          continue;
        if (!emit_node(e, child->children[0])) {
          if (pushed_lexical) lexical_scope_pop(e);
          morphl_backend_pop_frame(&e->frameInfo);
          return false;
        }
      }
      if (!emit_scope_binding_cleanups(e, e->scope_depth)) {
        if (pushed_lexical) lexical_scope_pop(e);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
      if (!emit_leave(e, (uint32_t)scope_sz)) {
        if (pushed_lexical) lexical_scope_pop(e);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
      morphl_backend_pop_frame(&e->frameInfo);
      if (pushed_lexical) lexical_scope_pop(e);
      return true;
    }

    /* ── function calls ── */
    case AST_CALL: {
      if (node->child_count < 1) return false;
      struct AstNode* callee = node->children[0];
      struct AstNode* args = node->child_count > 1 ? node->children[1] : NULL;

      /* determine return type and its size */
      const MorphlType* ret_t = unwrap_ref(node->type);
      uint32_t ret_sz = (uint32_t)type_frame_size(ret_t);

      if (builtin_is_name(e, callee, "$inline")) {
        return emit_inline_call(e, node, callee, args, ret_sz);
      }

      /* Pre-detect trait dispatch: $call ($member traitVar method) args
       * Must be done before RESERVE/ADDREF since $parent differs (=
       * traitVar.$data). The callee may be wrapped in a group: ($member v
       * method) → unwrap first. */
      {
        struct AstNode* callee_eff = callee;
        /* Unwrap single-element group around callee (e.g. ($member v greet)) */
        if (callee_eff->kind == AST_GROUP && callee_eff->child_count == 1 &&
            callee_eff->children[0])
          callee_eff = callee_eff->children[0];
        if (callee_eff->kind == AST_BUILTIN && e->interns && callee_eff->op &&
            callee_eff->child_count >= 2) {
          Str callee_op_s = interns_lookup(e->interns, callee_eff->op);
          if (callee_op_s.len == 7 &&
              memcmp(callee_op_s.ptr, "$member", 7) == 0) {
            struct AstNode* trait_tgt = callee_eff->children[0];
            const MorphlType* trait_btype =
                trait_tgt ? unwrap_ref(trait_tgt->type) : NULL;
            if (trait_btype && trait_btype->kind == MORPHL_TYPE_BLOCK &&
                trait_btype->data.block.field_count == 0 &&
                trait_btype->data.block.prop_count > 0) {
              /* TRAIT DISPATCH */
              struct AstNode* field_nd2 = callee_eff->children[1];
              Str field_name2 = field_nd2 ? field_nd2->value : (Str){NULL, 0};
              if (!field_name2.ptr && e->interns && field_nd2 && field_nd2->op)
                field_name2 = interns_lookup(e->interns, field_nd2->op);

              /* Find prop index in the trait type */
              size_t prop_idx = SIZE_MAX;
              for (size_t pi = 0; pi < trait_btype->data.block.prop_count;
                   pi++) {
                Str pn = {NULL, 0};
                if (e->interns && trait_btype->data.block.prop_names &&
                    trait_btype->data.block.prop_names[pi])
                  pn = interns_lookup(e->interns,
                                      trait_btype->data.block.prop_names[pi]);
                if (str_eq(pn, field_name2)) {
                  prop_idx = pi;
                  break;
                }
              }
              if (prop_idx == SIZE_MAX) {
                VM_ERR(callee_eff,
                       "trait method '%.*s' not found in trait type",
                       (int)field_name2.len, field_name2.ptr);
                return false;
              }

              /* Find traitVar frame offset */
              if (!trait_tgt || trait_tgt->kind != AST_IDENT) {
                VM_ERR(callee_eff,
                       "trait dispatch: target must be an identifier");
                return false;
              }
              Str traitvar_nm = alias_resolve(e, trait_tgt->value);
              ptrdiff_t traitvar_off =
                  morphl_backend_find_offset(&e->frameInfo, traitvar_nm);
              if (traitvar_off == PTRDIFF_MAX) {
                VM_ERR(trait_tgt, "trait dispatch: undefined '%.*s'",
                       (int)traitvar_nm.len, traitvar_nm.ptr);
                return false;
              }

              /* Emit trait dispatch sequence:
               * RESERVE ret_sz
               * RLOAD traitvar+8   → $data ref = $parent (concrete instance abs
               * addr) [args] RLOAD traitvar     → $impl ref (abs addr of
               * property table) ALOAD prop_idx*8   → function index from prop
               * table CALLX → pop func index, dispatch */
              if (!emit_op_u32(e, VM_OP_RESERVE, ret_sz)) return false;
              if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)(traitvar_off + 8)))
                return false;
              if (args) {
                if (args->kind == AST_GROUP) {
                  for (size_t i = 0; i < args->child_count; i++)
                    if (!emit_node(e, args->children[i])) return false;
                } else {
                  if (!emit_node(e, args)) return false;
                }
              }
              if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)traitvar_off))
                return false;
              if (!emit_op_i32(e, VM_OP_ALOAD, (int32_t)(prop_idx * 8)))
                return false;
              return emit_op(e, VM_OP_CALLX);
            }
          }
        }
      }

      /* RESERVE return slot */
      if (!emit_op_u32(e, VM_OP_RESERVE, ret_sz)) return false;

      /* emit hidden $parent argument: absolute stack address of caller's
       * frame[0]. The callee copies this into its own $parent slot at entry. */
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
      if (callee->kind == AST_FUNC) {
        size_t fidx = func_alloc(e);
        if (fidx == SIZE_MAX) return false;
        if (e->deferred_count >= e->deferred_capacity) {
          if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                       sizeof(DeferredFunc), e->deferred_count + 1))
            return false;
        }
        e->deferred[e->deferred_count++] = (DeferredFunc){
            callee, fidx, str_from("", 0), current_file_root_prefix(e)};
        return emit_func_index_u32(e, VM_OP_CALL, (uint32_t)fidx);
      }

      if (callee->kind == AST_IDENT) {
        Str callee_name = alias_resolve(e, callee->value);
        ptrdiff_t off = morphl_backend_find_offset(&e->frameInfo, callee_name);
        if (off == PTRDIFF_MAX) {
          VM_ERR(callee, "undefined callee '%.*s'", (int)callee->value.len,
                 callee->value.ptr);
          return false;
        }
        /* Use CALLF (indirect call via function index stored at frame[off]).
         * This is the correct implementation: the function index is stored in
         * the frame as i64 (put there when the function was declared), and
         * CALLF loads it and dispatches. For known-at-compile-time callees, we
         * could use CALL, but CALLF is correct and handles dynamic dispatch
         * too. */
        return emit_op_i32(e, VM_OP_CALLF, (int32_t)off);
      }

      /* $member target field — compute combined frame offset and emit CALLF.
       * Handles: $call $member io println (args) */
      if (callee->kind == AST_BUILTIN && callee->op && e->interns &&
          callee->child_count == 2) {
        Str callee_op = interns_lookup(e->interns, callee->op);
        if (callee_op.len == 7 && memcmp(callee_op.ptr, "$member", 7) == 0) {
          struct AstNode* target = callee->children[0];
          struct AstNode* field_nd = callee->children[1];

          Str field_name = field_nd->value;
          if (!field_name.ptr && e->interns && field_nd->op)
            field_name = interns_lookup(e->interns, field_nd->op);

          const MorphlType* target_btype = unwrap_ref(target->type);
          if (!target_btype || target_btype->kind != MORPHL_TYPE_BLOCK) {
            VM_ERR(node, "$call $member: target is not a block");
            return false;
          }

          const MorphlType* field_type = NULL;
          ptrdiff_t field_offset = block_layout_field_offset(
              target_btype, e->interns, field_name, &field_type);
          if (field_offset == PTRDIFF_MAX || !field_type) {
            VM_ERR(node, "$call $member: field not found");
            return false;
          }

          if (target->kind != AST_IDENT) {
            VM_ERR(target, "$call $member: target must be identifier");
            return false;
          }
          Str target_name = alias_resolve(e, target->value);
          const ImportSlot* import_slot =
              emitter_find_import_slot(e, target_name);
          const MorphlType* field_ft = unwrap_ref(field_type);
          if (e->emit_object && import_slot && field_ft &&
              field_ft->kind == MORPHL_TYPE_FUNC) {
            return emit_external_func_call(e, import_slot->module_path,
                                           field_name);
          }
          ptrdiff_t target_off =
              morphl_backend_find_offset(&e->frameInfo, target_name);
          if (target_off == PTRDIFF_MAX) {
            VM_ERR(target, "$call $member: undefined target '%.*s'",
                   (int)target_name.len, target_name.ptr);
            return false;
          }
          return emit_op_i32(e, VM_OP_CALLF,
                             (int32_t)(target_off + field_offset));
        }
      }

      VM_ERR(callee, "unsupported callee kind %d", callee->kind);
      return false;
    }

    /* ── assignment ── */
    case AST_SET: {
      if (node->child_count < 2) return false;
      struct AstNode* target = node->children[0];
      struct AstNode* value = node->children[1];

      /* compound LHS: $member or $index */
      if (target->kind == AST_BUILTIN && e->interns && target->op &&
          target->child_count >= 2) {
        Str tlop = interns_lookup(e->interns, target->op);

        /* $set ($member s field) rhs */
        if (tlop.len == 7 && memcmp(tlop.ptr, "$member", 7) == 0) {
          StaticAccess access;
          if (resolve_static_access_chain(e, target, &access)) {
            return emit_static_access_store(e, target, &access, value);
          }
          struct AstNode* tgt = target->children[0];
          struct AstNode* fnd = target->children[1];
          if (!tgt || !fnd) return false;
          Str fname = fnd->value;
          if (!fname.ptr && e->interns && fnd->op)
            fname = interns_lookup(e->interns, fnd->op);
          const MorphlType* ttype = unwrap_ref(tgt->type);
          if (!ttype) {
            VM_ERR(tgt, "$set $member: cannot resolve target type");
            return false;
          }
          /* union $$tag / $$data */
          if (ttype->kind == MORPHL_TYPE_UNION) {
            bool is_tag = fname.len == 5 && memcmp(fname.ptr, "$$tag", 5) == 0;
            bool is_data =
                fname.len == 6 && memcmp(fname.ptr, "$$data", 6) == 0;
            if (!is_tag && !is_data) {
              VM_ERR(fnd, "$set $member: union only supports $$tag and $$data");
              return false;
            }
            if (tgt->kind != AST_IDENT) return false;
            ptrdiff_t extra = 0;
            Str tname = alias_resolve_full(e, tgt->value, &extra);
            ptrdiff_t toff =
                morphl_backend_find_offset(&e->frameInfo, tname) + extra;
            if (toff == PTRDIFF_MAX + extra) return false;
            if (!emit_node(e, value)) return false;
            ptrdiff_t foff =
                is_tag ? toff + (ptrdiff_t)(ttype->size - 8) : toff;
            return emit_op_i32(e, VM_OP_ISTORE, (int32_t)foff);
          }
          /* block named field */
          if (ttype->kind == MORPHL_TYPE_BLOCK) {
            const MorphlType* field_type = NULL;
            ptrdiff_t field_off = block_layout_field_offset(ttype, e->interns,
                                                            fname, &field_type);
            if (field_off == PTRDIFF_MAX || !field_type) {
              VM_ERR(fnd, "$set $member: field '%.*s' not found",
                     (int)fname.len, fname.ptr);
              return false;
            }
            /* $parent target: emit value, then PSTORE(field_off) */
            if (tgt->kind == AST_BUILTIN && e->interns && tgt->op) {
              Str tname2 = interns_lookup(e->interns, tgt->op);
              if (tname2.len == 7 && memcmp(tname2.ptr, "$parent", 7) == 0) {
                if (!emit_node(e, value)) return false;
                return emit_op_i32(e, VM_OP_PSTORE, (int32_t)field_off);
              }
            }
            if (tgt->kind != AST_IDENT) return false;
            ptrdiff_t extra = 0;
            Str tname = alias_resolve_full(e, tgt->value, &extra);
            ptrdiff_t toff =
                morphl_backend_find_offset(&e->frameInfo, tname) + extra;
            if (!emit_node(e, value)) return false;
            uint8_t sop = store_op(unwrap_ref(field_type));
            if (sop == 0xFF) return false;
            return emit_op_i32(e, sop, (int32_t)(toff + field_off));
          }
        }

        /* $set ($index arr i) rhs */
        if (tlop.len == 6 && memcmp(tlop.ptr, "$index", 6) == 0) {
          struct AstNode* arr = target->children[0];
          struct AstNode* idx = target->children[1];
          if (!arr || arr->kind != AST_IDENT) return false;
          const MorphlType* at = unwrap_ref(arr->type);
          if (!at || at->kind != MORPHL_TYPE_ARRAY) return false;
          const MorphlType* et = at->data.array.elem_type;
          size_t esz = type_frame_size(et);
          ptrdiff_t extra = 0;
          Str aname = alias_resolve_full(e, arr->value, &extra);
          ptrdiff_t arr_off =
              morphl_backend_find_offset(&e->frameInfo, aname) + extra;
          uint8_t sop = store_op(et);
          if (sop == 0xFF) return false;
          /* literal index: emit value, then ISTORE/FSTORE at computed offset */
          if (idx->kind == AST_LITERAL) {
            char ibuf[32];
            size_t ilen = idx->value.len < sizeof(ibuf) - 1 ? idx->value.len
                                                            : sizeof(ibuf) - 1;
            memcpy(ibuf, idx->value.ptr, ilen);
            ibuf[ilen] = '\0';
            long long iv = strtoll(ibuf, NULL, 10);
            if (!emit_node(e, value)) return false;
            return emit_op_i32(e, sop,
                               (int32_t)(arr_off + iv * (long long)esz));
          }
          /* runtime index: compute address first (ADDREF+IMUL+IADD), then emit
           * value, then ASTORE 0. Stack order for ASTORE: [base, value]; off=0
           * because base already incorporates the full byte offset. */
          if (!emit_op_i32(e, VM_OP_ADDREF, (int32_t)arr_off)) return false;
          if (!emit_node(e, idx)) return false;
          if (!emit_iconst(e, (int64_t)esz)) return false;
          if (!emit_op(e, VM_OP_IMUL)) return false;
          if (!emit_op(e, VM_OP_IADD)) return false;
          if (!emit_node(e, value)) return false;
          return emit_op_i32(e, VM_OP_ASTORE, 0);
        }
      }

      if (target->kind != AST_IDENT) {
        VM_ERR(target, "$set target must be identifier or compound lvalue");
        return false;
      }

      /* Trait variable assignment: $set traitVar someImpl
       * Store prop-table ref ($impl) and concrete-instance ref ($data) into the
       * fat-block. */
      {
        const MorphlType* tgt_t =
            target->type ? unwrap_ref(target->type) : NULL;
        if (tgt_t && tgt_t->kind == MORPHL_TYPE_BLOCK &&
            tgt_t->data.block.field_count == 0 &&
            tgt_t->data.block.prop_count > 0) {
          /* Resolve trait variable's frame offset */
          ptrdiff_t tv_extra = 0;
          Str tv_name = alias_resolve_full(e, target->value, &tv_extra);
          ptrdiff_t tv_off =
              morphl_backend_find_offset(&e->frameInfo, tv_name) + tv_extra;
          if (tv_off == PTRDIFF_MAX + tv_extra) {
            VM_ERR(target, "undefined trait variable '%.*s'",
                   (int)target->value.len, target->value.ptr);
            return false;
          }
          /* value must be an identifier (impl type name) */
          if (value->kind != AST_IDENT) {
            VM_ERR(value,
                   "$set: trait assignment requires an identifier on the "
                   "right-hand side");
            return false;
          }
          Str val_name = value->value;
          /* Look up the ImplEntry for this impl type */
          const ImplEntry* entry = NULL;
          for (size_t ie = 0; ie < e->impl_count; ie++) {
            if (str_eq(e->impl_entries[ie].impl_name, val_name)) {
              entry = &e->impl_entries[ie];
              break;
            }
          }
          if (!entry) {
            VM_ERR(value, "$set: '%.*s' has no trait impl registered",
                   (int)val_name.len, val_name.ptr);
            return false;
          }
          /* Find the frame offset of the impl instance */
          ptrdiff_t val_extra = 0;
          Str val_resolved = alias_resolve_full(e, val_name, &val_extra);
          ptrdiff_t val_off =
              morphl_backend_find_offset(&e->frameInfo, val_resolved) +
              val_extra;
          /* Store $impl ref = absolute address of prop table (global frame
           * offset IS abs addr) */
          if (!emit_iconst(e, (int64_t)entry->prop_table_off)) return false;
          if (!emit_op_i32(e, VM_OP_RSTORE, (int32_t)tv_off)) return false;
          /* Store $data ref = absolute address of the impl instance */
          if (!emit_op_i32(e, VM_OP_ADDREF, (int32_t)val_off)) return false;
          if (!emit_op_i32(e, VM_OP_RSTORE, (int32_t)(tv_off + 8)))
            return false;
          return true;
        }
      }

      if (value->kind == AST_BUILTIN && value->op) {
        Str value_op = interns_lookup(e->interns, value->op);
        if (value_op.len == 7 && memcmp(value_op.ptr, "$extern", 7) == 0) {
          ptrdiff_t textra = 0;
          Str target_name = alias_resolve_full(e, target->value, &textra);
          ptrdiff_t off =
              morphl_backend_find_offset(&e->frameInfo, target_name) + textra;
          if (off == PTRDIFF_MAX + textra) {
            VM_ERR(target, "undefined target '%.*s' in $set",
                   (int)target->value.len, target->value.ptr);
            return false;
          }
          const MorphlType* fn_type =
              target->type ? unwrap_ref(target->type) : NULL;
          uint32_t param_sz = 0;
          if (fn_type && fn_type->kind == MORPHL_TYPE_FUNC &&
              fn_type->data.func.param_count > 0 &&
              fn_type->data.func.param_types[0]) {
            param_sz = (uint32_t)type_frame_size(
                unwrap_ref(fn_type->data.func.param_types[0]));
          }
          if (e->native_sym_count >= e->native_sym_capacity) {
            if (!vm_grow((void**)&e->native_syms, &e->native_sym_capacity,
                         sizeof(char*), e->native_sym_count + 1))
              return false;
          }
          Str sym_str =
              value->extern_symbol.ptr ? value->extern_symbol : target->value;
          char* sym_name = (char*)malloc(sym_str.len + 1);
          if (!sym_name) return false;
          memcpy(sym_name, sym_str.ptr, sym_str.len);
          sym_name[sym_str.len] = '\0';
          e->native_syms[e->native_sym_count] = sym_name;
          size_t native_idx = e->native_sym_count++;
          size_t fidx = func_alloc(e);
          if (fidx == SIZE_MAX) return false;
          e->functions.items[fidx].entry_point = (uint32_t)native_idx;
          e->functions.items[fidx].flags = MORPHL_FUNC_FLAG_NATIVE;
          e->functions.items[fidx].param_size = param_sz;
          e->functions.items[fidx].frame_size = 0;
          if (!emit_func_index_iconst(e, (uint32_t)fidx)) return false;
          return emit_op_i32(e, VM_OP_ISTORE, (int32_t)off);
        }
      }

      /* resolve compile-time $ref aliases for the assignment target */
      ptrdiff_t textra = 0;
      Str target_name = alias_resolve_full(e, target->value, &textra);
      ptrdiff_t off =
          morphl_backend_find_offset(&e->frameInfo, target_name) + textra;
      const MorphlType* target_slot_type =
          target->type ? target->type : node->children[0]->type;
      bool direct_rebinding =
          target_slot_type && target_slot_type->kind == MORPHL_TYPE_REF &&
          target_slot_type->data.ref.is_ref && value->type &&
          value->type->kind == MORPHL_TYPE_REF && value->type->data.ref.is_ref &&
          str_eq(target_name, target->value) && textra == 0;
      if (off == PTRDIFF_MAX + textra) {
        const StaticSlot* slot = static_slot_lookup_scoped(e, target_name);
        if (slot) {
          if (!emit_op(e, VM_OP_GLOBAL)) return false;
          if (!emit_node(e, value)) return false;
          if (textra < 0) {
            VM_ERR(target,
                   "negative offset into static storage is not supported");
            return false;
          }
          return emit_global_offset_i32(e, VM_OP_ASTORE,
                                        slot->global_slot + (size_t)textra);
        }
      }
      if (off == PTRDIFF_MAX + textra) {
        VM_ERR(target, "undefined target '%.*s' in $set",
               (int)target->value.len, target->value.ptr);
        return false;
      }
      const MorphlType* target_overload = unwrap_ref(target->type);
      if (target_overload && target_overload->kind == MORPHL_TYPE_OVERLOAD) {
        if (target->overload_has_selection && target->overload_select_self &&
            value->overload_has_selection && value->overload_select_self) {
          const MorphlType* value_overload = unwrap_ref(value->type);
          if (!value_overload ||
              value_overload->kind != MORPHL_TYPE_OVERLOAD ||
              !morphl_type_equals(target_overload, value_overload)) {
            VM_ERR(node, "$set: overload type mismatch in assignment");
            return false;
          }
          if (value->kind == AST_IDENT) {
            ptrdiff_t src_extra = 0;
            Str src_name = alias_resolve_full(e, value->value, &src_extra);
            ptrdiff_t src_off =
                morphl_backend_find_offset(&e->frameInfo, src_name) + src_extra;
            if (src_off == PTRDIFF_MAX + src_extra) {
              VM_ERR(value, "undefined overload source '%.*s'",
                     (int)value->value.len, value->value.ptr);
              return false;
            }
            for (size_t i = 0; i < target_overload->data.overload.candidate_count;
                 ++i) {
              const MorphlType* candidate = unwrap_ref(
                  target_overload->data.overload.candidate_types[i]);
              size_t cand_off = overload_candidate_offset(target_overload, i);
              uint8_t lop = load_op(candidate);
              uint8_t sop = store_op(candidate);
              if (lop == 0xFF || sop == 0xFF) {
                VM_ERR(node, "$set: cannot copy overload candidate");
                return false;
              }
              if (!emit_op_i32(e, lop, (int32_t)(src_off + (ptrdiff_t)cand_off)) ||
                  !emit_op_i32(e, sop, (int32_t)(off + (ptrdiff_t)cand_off))) {
                return false;
              }
            }
            return true;
          }
          if (value->kind == AST_BUILTIN && e->interns && value->op) {
            Str value_op = interns_lookup(e->interns, value->op);
            if (value_op.len == 9 && memcmp(value_op.ptr, "$overload", 9) == 0) {
              return emit_overload_value_into_slot(e, target_overload, value, off,
                                                   target_name);
            }
          }
          VM_ERR(value, "$set: unsupported whole-overload source");
          return false;
        }
        if (target->overload_has_selection && !target->overload_select_self) {
          size_t idx = target->overload_selected_index;
          if (idx >= target_overload->data.overload.candidate_count) {
            VM_ERR(target, "invalid overload candidate selection");
            return false;
          }
          const MorphlType* candidate = unwrap_ref(
              target_overload->data.overload.candidate_types[idx]);
          ptrdiff_t cand_off =
              off + (ptrdiff_t)overload_candidate_offset(target_overload, idx);
          if (!emit_node(e, value)) return false;
          uint8_t sop = store_op(candidate);
          if (sop == 0xFF) {
            VM_ERR(node, "$set: cannot store overload candidate");
            return false;
          }
          return emit_op_i32(e, sop, (int32_t)cand_off);
        }
      }
      if (target_slot_type && target_slot_type->kind == MORPHL_TYPE_REF &&
          target_slot_type->data.ref.is_ref && !direct_rebinding &&
          str_eq(target_name, target->value) && textra == 0) {
        if (!emit_op_i32(e, VM_OP_RLOAD, (int32_t)off)) return false;
        if (!emit_node(e, value)) return false;
        return emit_op_i32(e, VM_OP_ASTORE, 0);
      }
      if (direct_rebinding) {
        if (!emit_ref_handle_expr(e, value) && !emit_node(e, value)) return false;
        return emit_op_i32(e, VM_OP_RSTORE, (int32_t)off);
      }
      if (!emit_node(e, value)) return false;
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
      size_t end_lbl = label_new(e);
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
                       sizeof(DeferredFunc), e->deferred_count + 1))
            return false;
        }
        Str prop_name = {NULL, 0};
        if (node->children[0] && node->children[0]->kind == AST_IDENT)
          prop_name = node->children[0]->value;
        e->deferred[e->deferred_count++] =
            (DeferredFunc){rhs, fidx, prop_name, current_file_root_prefix(e)};
      }
      /* props produce no runtime value — nothing stored in frame */
      return true;
    }

    /* ── builtin operators ── */
    case AST_BUILTIN: {
      Str op_name = (e->interns && node->op)
                        ? interns_lookup(e->interns, node->op)
                        : node->value;

#define OP_IS(s) \
  (op_name.len == sizeof(s) - 1 && memcmp(op_name.ptr, s, sizeof(s) - 1) == 0)

      if (OP_IS("$overload")) {
        if (!node->overload_has_selection || node->overload_select_self) {
          VM_ERR(node, "plain runtime access to overload object is not supported");
          return false;
        }
        if (node->overload_selected_index >= node->child_count) {
          VM_ERR(node, "invalid overload candidate selection");
          return false;
        }
        return emit_node(e, node->children[node->overload_selected_index]);
      }

      /* $ret */
      if (OP_IS("$ret")) {
        if (node->child_count > 0 && node->children[0]) {
          if (!emit_node(e, node->children[0])) return false;
          /* store return value into return slot (below callee frame base) */
          const MorphlType* t = unwrap_ref(node->children[0]->type);
          uint8_t sop = store_op(t);
          if (sop != 0xFF) {
            if (!emit_op_i32(e, sop, e->return_slot_offset)) return false;
          }
        }
        /* run pending function-body $defer statements before returning */
        if (e->in_function && !emit_func_body_defers(e)) return false;
        return emit_op(e, VM_OP_RET);
      }

      /* $mut / $const / $inline / $static / $ref / $heap (qualifier form) —
       * transparent storage qualifiers */
      if (OP_IS("$mut") || OP_IS("$const") || OP_IS("$inline") ||
          OP_IS("$static") || OP_IS("$ref") || OP_IS("$heap")) {
        if (node->overload_has_selection && !node->overload_select_self &&
            node->child_count > 0 && node->children[0]) {
          AstNode* child = node->children[0];
          if (child->kind == AST_BUILTIN && e->interns && child->op &&
              interns_lookup(e->interns, child->op).len == 9 &&
              memcmp(interns_lookup(e->interns, child->op).ptr, "$overload", 9) == 0 &&
              node->overload_selected_index < child->child_count) {
            return emit_node(e, child->children[node->overload_selected_index]);
          }
        }
        return node->child_count > 0 ? emit_node(e, node->children[0]) : true;
      }

      if (OP_IS("$defer")) {
        return true;
      }

      if (OP_IS("$free")) {
        if (node->child_count < 1 || !node->children[0]) return false;
        AstNode* target = node->children[0];
        if (!emit_ref_handle_expr(e, target) && !emit_node(e, target)) return false;
        return emit_op(e, VM_OP_FREE);
      }

      /* $this — push absolute stack address of the current function's frame
       * start
       */
      if (OP_IS("$this")) {
        return emit_op_i32(e, VM_OP_ADDREF, 0);
      }

      /* $parent — load the hidden parent frame address from frame[0] */
      if (OP_IS("$parent")) {
        return emit_op_i32(e, VM_OP_ILOAD, 0);
      }

      /* $member target field — load a field from a block-typed value.
       * For $parent as target: uses PLOAD (reads from parent address + field
       * offset). For identifier targets: uses ILOAD at (var_offset +
       * field_offset). */
      if (OP_IS("$member")) {
        if (node->child_count < 2) return false;
        struct AstNode* target = node->children[0];
        struct AstNode* field_nd = node->children[1];
        if (!field_nd) return false;

        /* resolve field name */
        Str field_name = field_nd->value;
        if (!field_name.ptr && e->interns && field_nd->op) {
          field_name = interns_lookup(e->interns, field_nd->op);
        }

        /* ── compile-time intrinsic properties ──
         * These resolve entirely at compile time; the target expression is
         * NOT emitted (pure compile-time, analogous to C's sizeof). */
        {
          bool is_cname =
              field_name.len == 6 && memcmp(field_name.ptr, "$$name", 6) == 0;
          bool is_csize =
              field_name.len == 6 && memcmp(field_name.ptr, "$$size", 6) == 0;
          bool is_ctype =
              field_name.len == 6 && memcmp(field_name.ptr, "$$type", 6) == 0;
          bool is_cop =
              field_name.len == 4 && memcmp(field_name.ptr, "$$op", 4) == 0;
          bool is_cpath =
              field_name.len == 6 && memcmp(field_name.ptr, "$$path", 6) == 0;
          bool is_cdelim =
              field_name.len == 7 && memcmp(field_name.ptr, "$$delim", 7) == 0;
          bool is_cversion =
              field_name.len == 9 && memcmp(field_name.ptr, "$$version", 9) == 0;
          bool is_cline =
              field_name.len == 6 && memcmp(field_name.ptr, "$$line", 6) == 0;
          bool is_ccol =
              field_name.len == 5 && memcmp(field_name.ptr, "$$col", 5) == 0;
          bool is_csyntax =
              field_name.len == 8 && memcmp(field_name.ptr, "$$syntax", 8) == 0;

          if (is_cname) {
            /* Bound name of the expression, or "" for non-identifiers. */
            Str name =
                (target->kind == AST_IDENT) ? target->value : str_from("", 0);
            return emit_sconst(e, name);
          }
          if (is_csize) {
            /* Size in bytes of the target's type. */
            const MorphlType* t = unwrap_ref(target->type);
            size_t sz = t ? type_frame_size(t) : 0;
            return emit_iconst(e, (int64_t)sz);
          }
          if (is_ctype) {
            /* Type signature as a string. morphl_type_to_string heap-allocates;
             * the string table copies it, so we free after interning. */
            const MorphlType* t = unwrap_ref(target->type);
            Str ts = t ? morphl_type_to_string(t, e->interns)
                       : str_from("unknown", 7);
            bool ok = emit_sconst(e, ts);
            if (t && ts.ptr) free((void*)ts.ptr);
            return ok;
          }
          if (is_cop) {
            return emit_sconst(e, metadata_op_string(e, target));
          }
          if (is_cpath) {
            const char* path = target->filename ? target->filename : node->filename;
            return emit_sconst(e, path ? str_from(path, strlen(path)) : str_from("", 0));
          }
          if (is_cdelim) {
            return emit_sconst(e, str_from(";", 1));
          }
          if (is_cversion) {
            char version_buf[32];
            int n = snprintf(version_buf, sizeof(version_buf), "%u.%u",
                             (unsigned)MORPHL_VM_VERSION_MAJOR,
                             (unsigned)MORPHL_VM_VERSION_MINOR);
            if (n < 0) return false;
            return emit_sconst(e, str_from(version_buf, (size_t)n));
          }
          if (is_cline) {
            size_t line = target->row ? target->row : node->row;
            return emit_iconst(e, (int64_t)line);
          }
          if (is_ccol) {
            size_t col = target->col ? target->col : node->col;
            return emit_iconst(e, (int64_t)col);
          }
          if (is_csyntax) {
            VM_ERR(field_nd, "$$syntax is reserved and not implemented");
            return false;
          }
        }

        {
          StaticAccess access;
          if (resolve_static_access_chain(e, node, &access)) {
            return emit_static_access_load(e, node, &access);
          }
        }

        if (builtin_is_name(e, target, "$inline")) {
          return emit_inline_member_field(e, target, field_name, field_nd);
        }

        /* get target type (block or union) */
        const MorphlType* raw_target_type = target->type;
        const MorphlType* target_btype = unwrap_ref(raw_target_type);
        if (!target_btype) {
          VM_ERR(target, "$member: cannot resolve target type");
          return false;
        }

        /* ── compile-time property substitution ──
         * If the field name matches a $prop on the target block, emit the
         * property's value expression directly without emitting the target.
         * This is pure compile-time substitution (analogous to $$size). */
        if (target_btype->kind == MORPHL_TYPE_BLOCK &&
            target_btype->data.block.prop_count > 0 &&
            target_btype->data.block.prop_names &&
            target_btype->data.block.prop_values) {
          for (size_t pi = 0; pi < target_btype->data.block.prop_count; pi++) {
            Str pname = {NULL, 0};
            if (e->interns && target_btype->data.block.prop_names[pi]) {
              pname = interns_lookup(e->interns,
                                     target_btype->data.block.prop_names[pi]);
            }
            if (str_eq(pname, field_name)) {
              struct AstNode* val = target_btype->data.block.prop_values[pi];
              if (!val) {
                VM_ERR(field_nd, "$member: property '%.*s' has no value",
                       (int)field_name.len, field_name.ptr);
                return false;
              }
              return emit_node(e, val);
            }
          }
        }

        /* --- union $$tag / $$data --- */
        if (target_btype->kind == MORPHL_TYPE_UNION) {
          bool is_tag =
              (field_name.len == 5 && memcmp(field_name.ptr, "$$tag", 5) == 0);
          bool is_data =
              (field_name.len == 6 && memcmp(field_name.ptr, "$$data", 6) == 0);
          if (!is_tag && !is_data) {
            VM_ERR(field_nd, "$member: union only supports $$tag and $$data");
            return false;
          }
          if (target->kind != AST_IDENT) {
            VM_ERR(target, "$member: union target must be an identifier");
            return false;
          }
          Str tname = alias_resolve(e, target->value);
          ptrdiff_t toff = morphl_backend_find_offset(&e->frameInfo, tname);
          if (toff == PTRDIFF_MAX) {
            VM_ERR(target, "$member: undefined union variable '%.*s'",
                   (int)tname.len, tname.ptr);
            return false;
          }
          /* Data-first layout: $$data at union_offset+0, $$tag at
           * union_offset+max_payload_size. max_payload_size = union_size - 8
           * (the 8 reserved for the tag slot). */
          ptrdiff_t tag_off = toff + (ptrdiff_t)(target_btype->size - 8);
          if (is_tag) {
            /* $$tag → ILOAD at union_offset + max_payload_size */
            return emit_op_i32(e, VM_OP_ILOAD, (int32_t)tag_off);
          }
          /* $$data → address of payload region = union_offset + 0.
           * With data-first layout this is the same as the union's own address,
           * so $as s Circle works seamlessly via prefix subtyping. */
          return emit_op_i32(e, VM_OP_ADDREF, (int32_t)toff);
        }

        if (target_btype->kind != MORPHL_TYPE_BLOCK) {
          VM_ERR(target, "$member: target is not a block or union type");
          return false;
        }

        /* compute field offset within the block (natural alignment, declaration
         * order) */
        const MorphlType* field_type = NULL;
        ptrdiff_t field_offset = block_layout_field_offset(
            target_btype, e->interns, field_name, &field_type);
        if (field_offset == PTRDIFF_MAX || !field_type) {
          VM_ERR(field_nd, "$member: field '%.*s' not found",
                 (int)field_name.len, field_name.ptr);
          return false;
        }

        /* determine target kind */
        bool is_parent_target = false;
        bool is_global_target = false;
        if (target->kind == AST_BUILTIN && e->interns && target->op) {
          Str tname = interns_lookup(e->interns, target->op);
          is_parent_target =
              (tname.len == 7 && memcmp(tname.ptr, "$parent", 7) == 0);
          is_global_target =
              (tname.len == 7 && memcmp(tname.ptr, "$global", 7) == 0);
        }

        if (is_parent_target) {
          /* PLOAD: load from (parent_base + field_offset) where parent_base is
           * frame[0] */
          return emit_op_i32(e, VM_OP_PLOAD, (int32_t)field_offset);
        }

        if (is_global_target) {
          if (field_name.len == 7 &&
              memcmp(field_name.ptr, "$source", 7) == 0) {
            return emit_op(e, VM_OP_GLOBAL);
          }
          /* Global frame access: GLOBAL + ALOAD(field_off) for scalar fields,
           * or ICONST(field_off) for block sub-fields (address of the
           * sub-section). */
          const MorphlType* ft = unwrap_ref(field_type);
          if (ft && ft->kind == MORPHL_TYPE_BLOCK) {
            /* Return address of the sub-block section in the global frame */
            return emit_global_offset_iconst(e, (size_t)field_offset);
          }
          /* Scalar: push global base (0) and ALOAD field_off */
          return emit_op(e, VM_OP_GLOBAL) &&
                 emit_global_offset_i32(e, VM_OP_ALOAD, (size_t)field_offset);
        }

        /* computed expression target (e.g. $member $global $modules, or module
         * frame addr): emit the target expression (pushes an i64 base address),
         * then ALOAD field_off. */
        if (target->kind == AST_BUILTIN) {
          if (!emit_node(e, target)) return false;
          return emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
        }

        /* regular local block field access: ILOAD at (target_frame_offset +
         * field_offset) */
        if (target->kind != AST_IDENT) {
          VM_ERR(target, "$member: non-$parent target must be identifier");
          return false;
        }
        Str target_name = alias_resolve(e, target->value);
        const MorphlType* ft_unwrapped = unwrap_ref(field_type);
        const ImportSlot* import_slot = emitter_find_import_slot(e, target_name);
        if (e->emit_object && import_slot && ft_unwrapped &&
            ft_unwrapped->kind == MORPHL_TYPE_FUNC) {
          return emit_external_func_iconst(e, import_slot->module_path, field_name);
        }
        if (e->emit_object && import_slot) {
          const MorphlType* ft_ref = field_type;
          while (ft_ref && ft_ref->kind == MORPHL_TYPE_REF &&
                 !ft_ref->data.ref.is_ref) {
            ft_ref = ft_ref->data.ref.target;
          }
          if (ft_unwrapped &&
              (ft_unwrapped->kind == MORPHL_TYPE_BLOCK ||
               ft_unwrapped->kind == MORPHL_TYPE_ARRAY ||
               ft_unwrapped->kind == MORPHL_TYPE_UNION)) {
            if (ft_ref && ft_ref->kind == MORPHL_TYPE_REF &&
                ft_ref->data.ref.is_ref) {
              return emit_op(e, VM_OP_GLOBAL) &&
                     emit_global_offset_i32(e, VM_OP_ALOAD,
                                            import_slot->global_slot) &&
                     emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
            }
            return emit_op(e, VM_OP_GLOBAL) &&
                   emit_global_offset_i32(e, VM_OP_ALOAD,
                                          import_slot->global_slot) &&
                   emit_iconst(e, (int64_t)field_offset) &&
                   emit_op(e, VM_OP_IADD);
          }
          return emit_op(e, VM_OP_GLOBAL) &&
                 emit_global_offset_i32(e, VM_OP_ALOAD,
                                        import_slot->global_slot) &&
                 emit_op_i32(e, VM_OP_ALOAD, (int32_t)field_offset);
        }
        ptrdiff_t target_off =
            morphl_backend_find_offset(&e->frameInfo, target_name);
        if (target_off == PTRDIFF_MAX) {
          char* full_name = lexical_make_binding_path(e, target_name);
          const StaticSlot* slot =
              full_name
                  ? static_slot_lookup(e, str_from(full_name, strlen(full_name)))
                  : NULL;
          free(full_name);
          if (slot) {
            const MorphlType* ft = field_type;
            while (ft && ft->kind == MORPHL_TYPE_REF && !ft->data.ref.is_ref)
              ft = ft->data.ref.target;
            if (ft && ft->kind == MORPHL_TYPE_REF && ft->data.ref.is_ref) {
              return emit_op(e, VM_OP_GLOBAL) &&
                     emit_global_offset_i32(e, VM_OP_ALOAD,
                                            slot->global_slot +
                                                (size_t)field_offset);
            }
            return emit_op(e, VM_OP_GLOBAL) &&
                   emit_global_offset_i32(e, VM_OP_ALOAD,
                                          slot->global_slot +
                                              (size_t)field_offset);
          }
          VM_ERR(target, "$member: undefined variable '%.*s'",
                 (int)target_name.len, target_name.ptr);
          return false;
        }
        if (ft_unwrapped &&
            (ft_unwrapped->kind == MORPHL_TYPE_BLOCK ||
             ft_unwrapped->kind == MORPHL_TYPE_ARRAY ||
             ft_unwrapped->kind == MORPHL_TYPE_UNION)) {
          const MorphlType* ft_ref = field_type;
          while (ft_ref && ft_ref->kind == MORPHL_TYPE_REF &&
                 !ft_ref->data.ref.is_ref) {
            ft_ref = ft_ref->data.ref.target;
          }
          if (ft_ref && ft_ref->kind == MORPHL_TYPE_REF &&
              ft_ref->data.ref.is_ref) {
            return emit_op_i32(e, VM_OP_ILOAD, (int32_t)(target_off + field_offset));
          }
          return emit_op_i32(e, VM_OP_ADDREF, (int32_t)(target_off + field_offset));
        }

        uint8_t lop = load_op(ft_unwrapped);
        if (lop == 0xFF) {
          VM_ERR(field_nd, "$member: unsupported field type for load");
          return false;
        }
        if (!emit_op_i32(e, lop, (int32_t)(target_off + field_offset)))
          return false;
        /* For true $ref fields (is_ref==true) with a scalar target, RLOAD
         * pushes the stored address; emit DEREF to follow through to the actual
         * scalar value. Block-typed $ref fields keep the address on the stack —
         * it is used as the base for subsequent ALOAD-based nested $member
         * access. */
        {
          const MorphlType* ft = field_type;
          while (ft && ft->kind == MORPHL_TYPE_REF && !ft->data.ref.is_ref)
            ft = ft->data.ref.target;
          if (ft && ft->kind == MORPHL_TYPE_REF && ft->data.ref.is_ref &&
              ft->data.ref.target) {
            MorphlTypeKind tk = ft->data.ref.target->kind;
            if (tk == MORPHL_TYPE_INT || tk == MORPHL_TYPE_FLOAT ||
                tk == MORPHL_TYPE_BOOL || tk == MORPHL_TYPE_STRING) {
              if (!emit_op(e, VM_OP_DEREF)) return false;
            }
          }
        }
        return true;
      }

      /* $traits { $prop... } — trait type declaration; emit the block's init
       * code
       */
      if (OP_IS("$traits")) {
        return node->child_count > 0 ? emit_node(e, node->children[0]) : true;
      }

      /* $impl TraitA typeD { overrides } — emit the override block if present
       */
      if (OP_IS("$impl")) {
        /* children: [0]=trait_ident, [1]=base_ident, [2]=override_block
         * (optional) At runtime, typeE is structurally the same as typeD for
         * now.
         */
        if (node->child_count >= 3 && node->children[2]) {
          return emit_node(e, node->children[2]);
        }
        return true;
      }

      /* $null — push null reference (absolute address 0) */
      if (OP_IS("$null")) {
        return emit_op(e, VM_OP_RNULL);
      }

      /* $new — re-execute a block's init function to produce a fresh instance.
       * Optional 2nd child is an initializer (group or block); field overrides
       * for union types are applied by the parent AST_DECL handler, which has
       * access to the target variable's frame offset. */
      if (OP_IS("$new")) {
        if (node->child_count < 1 || !node->children[0]) return false;
        struct AstNode* block_ref = node->children[0];
        /* resolve the block name to its deferred function index */
        Str block_name =
            block_ref->kind == AST_IDENT ? block_ref->value : (Str){NULL, 0};
        if (!block_name.ptr) {
          VM_ERR(block_ref,
                 "$new: expression is not instantiable in value context");
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
          VM_ERR(block_ref, "$new: expression is not an instantiable type '%.*s'",
                 (int)block_name.len, block_name.ptr);
          return false;
        }
        /* determine block size from the function's frame */
        uint32_t block_sz = (uint32_t)(e->functions.items[fidx].frame_size);
        if (!emit_op_u32(e, VM_OP_RESERVE, block_sz)) return false;
        return emit_func_index_u32(e, VM_OP_CALL, fidx);
        /* NOTE: when child_count == 2, the initializer (child[1]) is
         * intentionally not emitted here.  The parent AST_DECL handler
         * intercepts $new nodes with an initializer when the target type is
         * MORPHL_TYPE_UNION and emits the tag + field-override stores directly
         * into the target frame slot. */
      }

      /* $array elem-type count — declares a fixed-size array.
       * Storage is already zero-initialised by ENTER; no runtime code needed.
       */
      if (OP_IS("$array")) {
        return true; /* no-op: frame slot reserved + zeroed by ENTER */
      }

      /* $union T1 T2 ... — union type declaration.
       * No runtime code: frame storage is reserved by ENTER (type_frame_size
       * handles it). */
      if (OP_IS("$union")) {
        return true;
      }

      /* $as expr TargetType — reinterpret cast (type annotation only).
       * Emits arg[0] unchanged; the node's type is already set to the target
       * type by pp_action_as / morphl_infer_type_for_op. The parent expression
       * uses node->type for type-directed code generation.
       */
      /* $as expr TargetType — reinterpret cast (type annotation only).
       * The result type is node->type (set by inference to the target type).
       *
       * When the source expression is a structural type (union/block/array) and
       * the target is a scalar, emit a typed load from the source's frame
       * offset. This implements "interpret the bytes at source_address as
       * TargetType", which is the core semantics of $as for data-first union
       * access: $as s 0  →  ILOAD from s's frame offset (byte 0 = payload
       * region)
       *
       * For all other cases (target is structural, or source is already
       * scalar), emit the source expression unchanged (pure type
       * re-annotation). */
      if (OP_IS("$as")) {
        if (node->child_count < 1 || !node->children[0]) return false;
        struct AstNode* src_node = node->children[0];
        const MorphlType* src_t =
            src_node->type ? unwrap_ref(src_node->type) : NULL;
        const MorphlType* dst_t = node->type ? unwrap_ref(node->type) : NULL;

        bool src_structural = src_t && (src_t->kind == MORPHL_TYPE_UNION ||
                                        src_t->kind == MORPHL_TYPE_BLOCK ||
                                        src_t->kind == MORPHL_TYPE_ARRAY);
        uint8_t dst_lop = dst_t ? load_op(dst_t) : 0xFF;

        if (src_structural && dst_lop != 0xFF && src_node->kind == AST_IDENT) {
          /* Structural → scalar: emit typed load from source frame slot (offset
           * 0). */
          Str src_name = alias_resolve(e, src_node->value);
          ptrdiff_t src_off =
              morphl_backend_find_offset(&e->frameInfo, src_name);
          if (src_off == PTRDIFF_MAX) {
            VM_ERR(src_node, "$as: undefined source variable '%.*s'",
                   (int)src_name.len, src_name.ptr);
            return false;
          }
          return emit_op_i32(e, dst_lop, (int32_t)src_off);
        }
        /* Default: pure type annotation — emit source as-is. */
        return emit_node(e, src_node);
      }

      /* $index array i — load element; supports literal and runtime (ident)
       * index
       */
      if (OP_IS("$index")) {
        if (node->child_count < 2 || !node->children[0] || !node->children[1])
          return false;
        struct AstNode* arr_node = node->children[0];
        struct AstNode* idx_node = node->children[1];

        /* resolve array identifier → frame offset */
        if (arr_node->kind != AST_IDENT) {
          VM_ERR(arr_node, "$index: array operand must be an identifier");
          return false;
        }
        ptrdiff_t arr_extra = 0;
        Str arr_name = alias_resolve_full(e, arr_node->value, &arr_extra);
        ptrdiff_t arr_off =
            morphl_backend_find_offset(&e->frameInfo, arr_name) + arr_extra;
        if (arr_off == PTRDIFF_MAX + arr_extra) {
          VM_ERR(arr_node, "$index: undefined array '%.*s'", (int)arr_name.len,
                 arr_name.ptr);
          return false;
        }

        /* get array and element types */
        const MorphlType* arr_btype =
            arr_node->type ? (arr_node->type->kind == MORPHL_TYPE_REF &&
                                      !arr_node->type->data.ref.is_ref
                                  ? arr_node->type->data.ref.target
                                  : arr_node->type)
                           : NULL;
        if (!arr_btype || arr_btype->kind != MORPHL_TYPE_ARRAY) {
          VM_ERR(arr_node, "$index: array node type not resolved");
          return false;
        }
        const MorphlType* elem_type = arr_btype->data.array.elem_type;
        size_t elem_size = type_frame_size(elem_type);
        uint8_t lop = load_op(elem_type);
        if (lop == 0xFF) {
          VM_ERR(arr_node, "$index: unsupported element type for load");
          return false;
        }

        /* literal index: compute offset at compile time */
        if (idx_node->kind == AST_LITERAL && idx_node->value.ptr) {
          char ibuf[32];
          size_t ilen = idx_node->value.len < sizeof(ibuf) - 1
                            ? idx_node->value.len
                            : sizeof(ibuf) - 1;
          memcpy(ibuf, idx_node->value.ptr, ilen);
          ibuf[ilen] = '\0';
          char* iend = NULL;
          long long idx_val = strtoll(ibuf, &iend, 10);
          if (iend == ibuf) {
            VM_ERR(idx_node, "$index: invalid index literal");
            return false;
          }
          return emit_op_i32(
              e, lop, (int32_t)(arr_off + idx_val * (long long)elem_size));
        }

        /* runtime index: ADDREF base; emit index; ICONST elem_size; IMUL; IADD;
         * ALOAD 0. After IADD the stack holds the absolute address of
         * arr[index]; ALOAD with offset 0 loads from that exact address (not
         * +elem_size). */
        if (!emit_op_i32(e, VM_OP_ADDREF, (int32_t)arr_off)) return false;
        if (!emit_node(e, idx_node)) return false;
        if (!emit_iconst(e, (int64_t)elem_size)) return false;
        if (!emit_op(e, VM_OP_IMUL)) return false;
        if (!emit_op(e, VM_OP_IADD)) return false;
        return emit_op_i32(e, VM_OP_ALOAD, 0);
      }

      /* $exit expr — exit program with given exit code. Explicit operand
       * required. */
      if (OP_IS("$exit")) {
        if (node->child_count < 1 || !node->children[0]) {
          VM_ERR(node, "$exit requires an explicit exit code (e.g. $exit 0)");
          return false;
        }
        if (!emit_node(e, node->children[0])) return false;
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
        size_t exit_lbl = label_new(e);
        if (loop_start == SIZE_MAX || exit_lbl == SIZE_MAX) return false;

        /* push loop context so $break/$continue can resolve targets */
        if (e->loop_stack_count >= e->loop_stack_capacity) {
          if (!vm_grow((void**)&e->loop_stack, &e->loop_stack_capacity,
                       sizeof(VmLoopCtx), e->loop_stack_count + 1))
            return false;
        }
        e->loop_stack[e->loop_stack_count++] =
            (VmLoopCtx){exit_lbl, loop_start, e->scope_depth};

        /* bind loop_start before condition (continue jumps here) */
        if (!label_bind(e, loop_start)) {
          e->loop_stack_count--;
          return false;
        }
        if (!emit_node(e, node->children[0])) {
          e->loop_stack_count--;
          return false;
        }
        /* negate condition: ICONST 0, IEQ → 1 when condition is false */
        if (!emit_iconst(e, 0)) {
          e->loop_stack_count--;
          return false;
        }
        if (!emit_op(e, VM_OP_IEQ)) {
          e->loop_stack_count--;
          return false;
        }
        /* jump to exit if condition was false */
        if (!emit_jump(e, VM_OP_JIF, exit_lbl)) {
          e->loop_stack_count--;
          return false;
        }
        /* Emit body inline — do NOT call emit_node(body) for an AST_BLOCK here.
         * emit_node for AST_BLOCK would push a new logical emitter frame,
         * making outer-scope vars appear at negative offsets (the $parent
         * cross-function convention). Instead we emit ENTER/children/LEAVE
         * without a frame push, so outer vars like the loop counter remain at
         * their correct positive offsets. $break/$continue now emit LEAVE
         * instructions for any nested scopes before jumping, so nested
         * sub-blocks are correctly unwound. */
        struct AstNode* body = node->children[1];
        if (body && body->kind == AST_BLOCK) {
          if (!lexical_scope_push_anon(e)) {
            e->loop_stack_count--;
            return false;
          }
          size_t bsz = block_scope_size(body);
          if (bsz > 0 && !emit_enter(e, (uint32_t)bsz)) {
            lexical_scope_pop(e);
            e->loop_stack_count--;
            return false;
          }
          for (size_t k = 0; k < body->child_count; k++) {
            if (!emit_node(e, body->children[k])) {
              lexical_scope_pop(e);
              e->loop_stack_count--;
              return false;
            }
          }
          if (bsz > 0 && !emit_leave(e, (uint32_t)bsz)) {
            lexical_scope_pop(e);
            e->loop_stack_count--;
            return false;
          }
          lexical_scope_pop(e);
        } else if (body) {
          if (!emit_node(e, body)) {
            e->loop_stack_count--;
            return false;
          }
        }
        /* unconditional backward jump to re-evaluate condition */
        if (!emit_jump(e, VM_OP_JMP, loop_start)) {
          e->loop_stack_count--;
          return false;
        }

        e->loop_stack_count--;
        return label_bind(e, exit_lbl);
      }

      /* $not expr — logical negation (ICONST 0, IEQ → 1 if false, 0 if true) */
      if (OP_IS("$not")) {
        if (node->child_count < 1) return false;
        return emit_node(e, node->children[0]) && emit_iconst(e, 0) &&
               emit_op(e, VM_OP_IEQ);
      }

      /* $and lhs rhs — short-circuit: skip rhs if lhs is false */
      if (OP_IS("$and")) {
        if (node->child_count < 2) return false;
        size_t false_lbl = label_new(e);
        size_t end_lbl = label_new(e);
        if (false_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;

        if (!emit_node(e, node->children[0])) return false;
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_IEQ)) return false; /* negate: 1 if lhs false */
        if (!emit_jump(e, VM_OP_JIF, false_lbl)) return false;

        if (!emit_node(e, node->children[1])) return false;
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_INEQ)) return false; /* normalize rhs → 0/1 */
        if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;

        if (!label_bind(e, false_lbl)) return false;
        if (!emit_iconst(e, 0)) return false;
        return label_bind(e, end_lbl);
      }

      /* $or lhs rhs — short-circuit: skip rhs if lhs is true */
      if (OP_IS("$or")) {
        if (node->child_count < 2) return false;
        size_t true_lbl = label_new(e);
        size_t end_lbl = label_new(e);
        if (true_lbl == SIZE_MAX || end_lbl == SIZE_MAX) return false;

        if (!emit_node(e, node->children[0])) return false;
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_INEQ)) return false; /* 1 if lhs truthy */
        if (!emit_jump(e, VM_OP_JIF, true_lbl)) return false;

        if (!emit_node(e, node->children[1])) return false;
        if (!emit_iconst(e, 0)) return false;
        if (!emit_op(e, VM_OP_INEQ)) return false; /* normalize rhs → 0/1 */
        if (!emit_jump(e, VM_OP_JMP, end_lbl)) return false;

        if (!label_bind(e, true_lbl)) return false;
        if (!emit_iconst(e, 1)) return false;
        return label_bind(e, end_lbl);
      }

      /* $break — emit LEAVE for any nested scopes entered since the loop
       * started, then jump to the loop's exit label. */
      if (OP_IS("$break")) {
        if (e->loop_stack_count == 0) {
          VM_ERR(node, "$break outside loop");
          return false;
        }
        size_t loop_depth =
            e->loop_stack[e->loop_stack_count - 1].scope_depth_at_entry;
        for (size_t d = e->scope_depth; d > loop_depth; d--) {
          if (!emit_op_u32(e, VM_OP_LEAVE, e->scope_sizes[d - 1])) return false;
        }
        return emit_jump(e, VM_OP_JMP,
                         e->loop_stack[e->loop_stack_count - 1].break_label);
      }

      /* $continue — emit LEAVE for nested scopes, then jump to loop condition.
       */
      if (OP_IS("$continue")) {
        if (e->loop_stack_count == 0) {
          VM_ERR(node, "$continue outside loop");
          return false;
        }
        size_t loop_depth =
            e->loop_stack[e->loop_stack_count - 1].scope_depth_at_entry;
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
      if ((op_name.len == 3 && memcmp(op_name.ptr, "$eq", 3) == 0) ||
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
      struct {
        const char* name;
        uint8_t iop;
        uint8_t fop;
      } binops[] = {
          {   "$add",    VM_OP_IADD, VM_OP_FADD},
          {   "$sub",    VM_OP_ISUB, VM_OP_FSUB},
          {   "$mul",    VM_OP_IMUL, VM_OP_FMUL},
          {   "$div",    VM_OP_IDIV, VM_OP_FDIV},
          {   "$mod",    VM_OP_IMOD,       0xFF},
          {    "$eq",     VM_OP_IEQ,  VM_OP_FEQ},
          {   "$neq",    VM_OP_INEQ, VM_OP_FNEQ},
          {    "$lt",     VM_OP_ILT,  VM_OP_FLT},
          {    "$gt",     VM_OP_IGT,  VM_OP_FGT},
          {   "$lte",    VM_OP_ILTE, VM_OP_FLTE},
          {   "$gte",    VM_OP_IGTE, VM_OP_FGTE},
          /* float-specific aliases (produced by grammar overload resolution) */
          {  "$fadd",          0xFF, VM_OP_FADD},
          {  "$fsub",          0xFF, VM_OP_FSUB},
          {  "$fmul",          0xFF, VM_OP_FMUL},
          {  "$fdiv",          0xFF, VM_OP_FDIV},
          /* bitwise (int-only) */
          {  "$band",   VM_OP_IBAND,       0xFF},
          {   "$bor",    VM_OP_IBOR,       0xFF},
          {  "$bxor",   VM_OP_IBXOR,       0xFF},
          {"$lshift", VM_OP_ILSHIFT,       0xFF},
          {"$rshift", VM_OP_IRSHIFT,       0xFF},
          /* reference equality (treat operands as i64 addresses, not typed) */
          {   "$req",     VM_OP_REQ,       0xFF},
          {  "$rneq",    VM_OP_RNEQ,       0xFF},
      };
      for (size_t i = 0; i < sizeof(binops) / sizeof(binops[0]); i++) {
        size_t nlen = strlen(binops[i].name);
        if (op_name.len == nlen &&
            memcmp(op_name.ptr, binops[i].name, nlen) == 0) {
          if (node->child_count < 2) return false;
          if (!emit_node(e, node->children[0])) return false;
          if (!emit_node(e, node->children[1])) return false;
          /* choose int or float variant based on first operand's type */
          const MorphlType* lhs_t = unwrap_ref(
              node->children[0]->type ? node->children[0]->type : node->type);
          bool is_float = lhs_t && lhs_t->kind == MORPHL_TYPE_FLOAT;
          uint8_t op_byte = is_float ? binops[i].fop : binops[i].iop;
          if (op_byte == 0xFF) {
            VM_ERR(node, "operator '%.*s' not supported for float",
                   (int)op_name.len, op_name.ptr);
            return false;
          }
          return emit_op(e, op_byte);
        }
      }

      /* $bnot — unary bitwise NOT */
      if (OP_IS("$bnot")) {
        if (node->child_count < 1) return false;
        if (!emit_node(e, node->children[0])) return false;
        return emit_op(e, VM_OP_IBNOT);
      }

      /* $file — push reference to the current file's top-level scope.
       * In this VM all top-level declarations live in the global frame, so
       * $file and $global are the same address (0). */
      if (OP_IS("$file")) {
        return emit_op(e, VM_OP_GLOBAL);
      }

      /* $global — push absolute stack address 0 (global frame base) */
      if (OP_IS("$global")) {
        return emit_op(e, VM_OP_GLOBAL);
      }

      /* $import "file" — the child was already replaced with the parsed
       * AST_FILE by pp_action_import in operators.c. Emit module initialization
       * inline, then record the module's absolute stack address in the global
       * $modules slot. The import variable name is already registered in the
       * parent AST_DECL handler; we find its frame offset and use
       * global_frame_size + m_off as the slot value. */
      if (OP_IS("$import")) {
        if (e->emit_object) return true;
        struct AstNode* module_file = import_module_root(node);
        if (!module_file) return false;
        /* emit the module's initialization code; the parent AST_DECL handler
         * handles writing the $modules global slot after this returns */
        return emit_node(e, module_file);
      }

#undef OP_IS

      VM_ERR(node, "unhandled builtin '%.*s'", (int)op_name.len, op_name.ptr);
      return false;
    }

    /* ── function definitions (deferred) ── */
    case AST_FUNC:
      /* AST_FUNC nodes reachable directly (not via AST_DECL) */
      /* Allocate a slot, defer, and leave nothing on the eval stack
       * (anonymous).
       */
      {
        size_t fidx = func_alloc(e);
        if (fidx == SIZE_MAX) return false;
        if (e->deferred_count >= e->deferred_capacity) {
          if (!vm_grow((void**)&e->deferred, &e->deferred_capacity,
                       sizeof(DeferredFunc), e->deferred_count + 1))
            return false;
        }
        e->deferred[e->deferred_count++] = (DeferredFunc){
            node, fidx, {NULL, 0},
              current_file_root_prefix(e)
        };
        return emit_func_index_iconst(e, (uint32_t)fidx);
      }

    default:
      VM_ERR(node, "unsupported AST kind %d", node->kind);
      return false;
  }
}

/* ── emit a deferred function body ──────────────────────────────────────── */

/* Emit a cleanup thunk for a heap block with $defer.
 * The thunk takes one param ($self, 8 bytes = the heap handle at frame[-8]) and
 * runs all $defer expressions from the block in LIFO order via $self field refs. */
static bool emit_cleanup_thunk(VmEmitter* e, size_t fidx,
                                const AstNode* block,
                                const MorphlType* block_type,
                                const MorphlType* binding_type,
                                const char* saved_lexical_path) {
  e->functions.items[fidx].entry_point = (uint32_t)e->code.len;
  e->functions.items[fidx].param_size  = 8;
  e->functions.items[fidx].frame_size  = 16;  /* 8 param + 8 body ($parent) */

  /* restore lexical scope so static_slot_lookup_scoped finds scoped names */
  bool pushed_lexical = false;
  if (saved_lexical_path && *saved_lexical_path) {
    char* path_dup = strdup(saved_lexical_path);
    if (!path_dup) return false;
    if (!lexical_scope_push_full(e, path_dup)) { free(path_dup); return false; }
    pushed_lexical = true;
  }

  /* param frame: $self at frame[-8] */
  if (!morphl_backend_push_frame(&e->frameInfo)) {
    if (pushed_lexical) lexical_scope_pop(e);
    return false;
  }
  struct MorphlBackendFrameOffset self_foff = {str_from("$self", 5), 8};
  if (!morphl_backend_append_offset(&e->frameInfo, self_foff)) {
    morphl_backend_pop_frame(&e->frameInfo);
    if (pushed_lexical) lexical_scope_pop(e);
    return false;
  }
  /* body frame: $parent slot at frame[0] */
  if (!morphl_backend_push_frame(&e->frameInfo)) {
    morphl_backend_pop_frame(&e->frameInfo);
    if (pushed_lexical) lexical_scope_pop(e);
    return false;
  }
  struct MorphlBackendFrameOffset parent_foff = {str_from("$parent", 7), 8};
  if (!morphl_backend_append_offset(&e->frameInfo, parent_foff)) {
    morphl_backend_pop_frame(&e->frameInfo);
    morphl_backend_pop_frame(&e->frameInfo);
    if (pushed_lexical) lexical_scope_pop(e);
    return false;
  }

  bool ok = true;
  ok = ok && emit_enter(e, 8);
  /* copy hidden_parent arg (frame[-16]) into $parent (frame[0]) */
  ok = ok && emit_op_i32(e, VM_OP_ILOAD,  -(int32_t)(8 + 8));
  ok = ok && emit_op_i32(e, VM_OP_ISTORE, 0);
  /* emit defer expressions in LIFO order, rewritten to use $self as binding */
  ok = ok && emit_binding_cleanup_block(e, str_from("$self", 5),
                                        block, block_type, binding_type);
  if (ok) emit_leave(e, 8);
  ok = ok && emit_op(e, VM_OP_RET);

  morphl_backend_pop_frame(&e->frameInfo);
  morphl_backend_pop_frame(&e->frameInfo);
  if (pushed_lexical) lexical_scope_pop(e);
  return ok;
}

/* Emit pending function-body $defer expressions in LIFO order.
 * Called before each explicit $ret and before the implicit end-of-body exit. */
static bool emit_func_body_defers(VmEmitter* e) {
  for (size_t i = e->func_defer_count; i > e->func_defer_base; --i)
    if (!emit_node(e, e->func_defers[i - 1])) return false;
  return true;
}

static bool emit_function_body(VmEmitter* e, struct AstNode* func_node,
                               size_t func_idx, Str func_name, Str file_root) {
  if (!func_node || func_node->kind != AST_FUNC) {
    VM_ERR(func_node, "internal error: deferred function body is not AST_FUNC");
    return false;
  }
  if (func_node->child_count < 2) {
    VM_ERR(func_node, "internal error: deferred function body missing children");
    return false;
  }
  bool saved_in_function = e->in_function;
  size_t saved_scope_depth = e->scope_depth;
  int32_t saved_return_slot_offset = e->return_slot_offset;
  size_t saved_func_defer_base  = e->func_defer_base;
  size_t saved_func_defer_count = e->func_defer_count;
  e->func_defer_base = e->func_defer_count; /* own defer region starts here */
  e->in_function = true;
  e->scope_depth = 0; /* reset scope tracking for this function body */
  bool pushed_file_root = false;
  if (file_root.ptr && file_root.len > 0) {
    if (!lexical_scope_push_named(e, file_root)) return false;
    pushed_file_root = true;
  }
  if (func_name.ptr && func_name.len > 0) {
    if (!lexical_scope_push_named(e, func_name)) {
      if (pushed_file_root) lexical_scope_pop(e);
      return false;
    }
  } else {
    if (!lexical_scope_push_anon(e)) {
      if (pushed_file_root) lexical_scope_pop(e);
      return false;
    }
  }

  struct AstNode* params = func_node->children[0]; /* AST_GROUP of AST_DECL */
  struct AstNode* body = func_node->children[1];   /* AST_BLOCK */

  /* record entry point */
  e->functions.items[func_idx].entry_point = (uint32_t)e->code.len;

  /* collect parameter decl nodes (handles both single AST_DECL and AST_GROUP)
   */
  struct AstNode** param_decls = NULL;
  size_t param_count = 0;
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

  size_t ret_sz = 0;
  const MorphlType* fn_type = unwrap_ref(func_node->type);
  if (fn_type && fn_type->kind == MORPHL_TYPE_FUNC &&
      fn_type->data.func.return_type) {
    ret_sz = type_frame_size(unwrap_ref(fn_type->data.func.return_type));
  }
  e->return_slot_offset = -(int32_t)(param_sz + 8 + ret_sz);

  /* push param scope */
  if (!morphl_backend_push_frame(&e->frameInfo)) {
    VM_ERR(func_node, "internal error: failed to push function param frame");
    return false;
  }

  /* register parameters in frame */
  for (size_t i = 0; i < param_count; i++) {
    struct AstNode* p = param_decls[i];
    if (!p || p->kind != AST_DECL || p->child_count < 1) continue;
    struct AstNode* pname = p->children[0];
    if (!pname || pname->kind != AST_IDENT) continue;
    const MorphlType* pt = unwrap_ref(p->type);
    struct MorphlBackendFrameOffset foff = {.name = pname->value,
                                            .size = type_frame_size(pt)};
    if (!morphl_backend_append_offset(&e->frameInfo, foff)) {
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
  }

  /* emit body block without its own ENTER/LEAVE wrapping —
     we emit it as a sequence of statements directly.
     The first 8 bytes of the body frame are reserved for the hidden $parent
     slot, which holds the absolute stack address of the caller's frame[0]. This
     slot is populated at function entry by copying from the hidden parent arg
     at frame[-(param_sz + 8)], which the caller pushes before actual arguments.
   */
  size_t body_scope_sz_raw = body ? block_scope_size(body) : 0;
  size_t body_scope_sz =
      body_scope_sz_raw + 8; /* +8 for implicit $parent slot */
  {
    if (!morphl_backend_push_frame(&e->frameInfo)) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
    /* register $parent slot as first body frame entry (offset 0, 8 bytes) */
    struct MorphlBackendFrameOffset parent_foff = {
        .name = str_from("$parent", 7), .size = 8};
    if (!morphl_backend_append_offset(&e->frameInfo, parent_foff)) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
    if (!emit_enter(e, (uint32_t)body_scope_sz)) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
    /* copy hidden parent arg from frame[-(param_sz+8)] into the $parent slot at
     * frame[0] */
    if (!emit_op_i32(e, VM_OP_ILOAD, -(int32_t)(param_sz + 8))) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
    if (!emit_op_i32(e, VM_OP_ISTORE, 0)) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
  }

  /* Track whether the fallthrough $defer emission was done inside an AST_BLOCK
     body (before its anon scope was popped). Static-slot lookups inside deferred
     expressions require the body's anonymous lexical scope to be active, so we
     emit them before popping that scope rather than after. */
  bool fallthrough_defers_done = false;

  if (body) {
    if (body->kind == AST_BLOCK) {
      if (!lexical_scope_push_anon(e)) {
        lexical_scope_pop(e);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
      for (size_t i = 0; i < body->child_count; i++) {
        struct AstNode* child = body->children[i];
        /* Collect top-level $defer nodes; emit everything else normally */
        if (builtin_is_name(e, child, "$defer") && child->child_count > 0 &&
            child->children[0]) {
          if (e->func_defer_count >= e->func_defer_capacity) {
            size_t newcap = e->func_defer_capacity ? e->func_defer_capacity * 2 : 8;
            struct AstNode** tmp = realloc(e->func_defers,
                                           newcap * sizeof(*e->func_defers));
            if (!tmp) {
              lexical_scope_pop(e);
              lexical_scope_pop(e);
              if (body_scope_sz > 0) morphl_backend_pop_frame(&e->frameInfo);
              morphl_backend_pop_frame(&e->frameInfo);
              return false;
            }
            e->func_defers = tmp;
            e->func_defer_capacity = newcap;
          }
          e->func_defers[e->func_defer_count++] = child->children[0];
        } else if (!emit_node(e, child)) {
          VM_ERR(child, "internal error: failed emitting function body statement");
          lexical_scope_pop(e);
          lexical_scope_pop(e);
          if (body_scope_sz > 0) morphl_backend_pop_frame(&e->frameInfo);
          morphl_backend_pop_frame(&e->frameInfo);
          return false;
        }
      }
      /* Emit fallthrough defers HERE, while the body's anon scope is still
         active. This ensures that static-slot lookups inside defer expressions
         use the correct lexical path. (If an explicit $ret already emitted
         them, this produces unreachable dead code — that is fine.) */
      if (!emit_func_body_defers(e)) {
        lexical_scope_pop(e);
        lexical_scope_pop(e);
        if (body_scope_sz > 0) morphl_backend_pop_frame(&e->frameInfo);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
      fallthrough_defers_done = true;
      lexical_scope_pop(e);
    } else {
      if (!emit_node(e, body)) {
        VM_ERR(body, "internal error: failed emitting non-block function body");
        lexical_scope_pop(e);
        if (body_scope_sz > 0) morphl_backend_pop_frame(&e->frameInfo);
        morphl_backend_pop_frame(&e->frameInfo);
        return false;
      }
    }
  }

  if (body_scope_sz > 0) {
    if (!fallthrough_defers_done && !emit_func_body_defers(e)) {
      lexical_scope_pop(e);
      morphl_backend_pop_frame(&e->frameInfo);
      return false;
    }
    emit_leave(e, (uint32_t)body_scope_sz);
    morphl_backend_pop_frame(&e->frameInfo);
  } else {
    if (!fallthrough_defers_done && !emit_func_body_defers(e)) {
      lexical_scope_pop(e);
      return false;
    }
  }

  /* implicit RET at end of body */
  if (!emit_op(e, VM_OP_RET)) {
    lexical_scope_pop(e);
    morphl_backend_pop_frame(&e->frameInfo);
    return false;
  }

  /* record frame size: params + body locals (including the 8-byte $parent slot)
   */
  e->functions.items[func_idx].frame_size =
      (uint32_t)(param_sz + body_scope_sz);

  morphl_backend_pop_frame(&e->frameInfo);
  lexical_scope_pop(e);
  if (pushed_file_root) lexical_scope_pop(e);
  e->in_function = saved_in_function;
  e->scope_depth = saved_scope_depth;
  e->return_slot_offset = saved_return_slot_offset;
  e->func_defer_count = saved_func_defer_count;
  e->func_defer_base  = saved_func_defer_base;
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
  free(e->static_slots);
  free(e->binding_cleanups);
  free(e->static_cleanups);
  free(e->func_defers);
  while (e->lexical_scope_count > 0) lexical_scope_pop(e);
  free(e->lexical_scopes);
  for (size_t i = 0; i < e->str_count; i++) free(e->str_table[i]);
  free(e->str_table);
  for (size_t i = 0; i < e->native_sym_count; i++) free(e->native_syms[i]);
  free(e->native_syms);
  free(e->impl_entries);
  free(e->block_decl_map);
  for (size_t i = 0; i < e->deferred_cleanup_count; i++)
    free(e->deferred_cleanups[i].saved_lexical_path);
  free(e->deferred_cleanups);
  for (size_t i = 0; i < e->object_reloc_count; ++i) {
    free(e->object_relocs[i].module_path);
    free(e->object_relocs[i].symbol_name);
  }
  free(e->object_relocs);
  morphl_backend_frame_free(&e->frameInfo);
  memset(e, 0, sizeof(*e));
}

/* ── pre-pass: flatten nested $new in $ref fields into sibling $decl nodes ──
 */
/*
 * Transforms `$decl node $new Node (0, $new Node (1, $null))` in-place by
 * inserting synthetic sibling declarations before the outer $decl:
 *
 *   $decl $anon$0  $new Node (1, $null)       <- inserted sibling
 *   $decl node     $new Node (0, <ident $anon$0>)  <- original, group element
 * replaced
 *
 * After flattening, block_scope_size naturally counts all $decl children, and
 * each Node struct keeps its static size.  The codegen handles block-typed
 * idents in $ref fields via ADDREF + RSTORE.
 */

/* Insert `child` at position `pos` in `block`'s children, shifting right. */
static bool block_insert_child(struct AstNode* block, size_t pos,
                               struct AstNode* child) {
  if (block->child_count >= block->child_capacity) {
    size_t new_cap = block->child_capacity ? block->child_capacity * 2 : 4;
    struct AstNode** p = (struct AstNode**)realloc(
        block->children, new_cap * sizeof(struct AstNode*));
    if (!p) return false;
    block->children = p;
    block->child_capacity = new_cap;
  }
  for (size_t i = block->child_count; i > pos; i--)
    block->children[i] = block->children[i - 1];
  block->children[pos] = child;
  block->child_count++;
  return true;
}

typedef struct {
  size_t count;
} FlattenCtx;

/* Forward declaration */
static void flatten_block(FlattenCtx* ctx, InternTable* interns,
                          struct AstNode* block);

/*
 * Hoist immediate aggregate operands used as storage-expression targets in
 * `$member` into sibling declarations so VM emission can treat them like any
 * other block value: evaluate once, capture, then access by identifier.
 */
static size_t hoist_immediate_member_targets(FlattenCtx* ctx,
                                             InternTable* interns,
                                             struct AstNode* block,
                                             size_t insert_pos,
                                             struct AstNode* node) {
  if (!ctx || !interns || !block || !node) return 0;
  if (node->kind == AST_FUNC || node->kind == AST_FILE) return 0;

  size_t inserted = 0;
  for (size_t i = 0; i < node->child_count; ++i) {
    struct AstNode* child = node->children[i];
    if (!child || child->kind == AST_BLOCK || child->kind == AST_FILE) continue;
    inserted += hoist_immediate_member_targets(ctx, interns, block,
                                               insert_pos + inserted, child);
  }

  if (node->kind != AST_BUILTIN || !node->op || node->child_count < 2 ||
      !node->children[0]) {
    return inserted;
  }
  Str op = interns_lookup(interns, node->op);
  if (op.len != 7 || memcmp(op.ptr, "$member", 7) != 0) return inserted;

  struct AstNode* target = node->children[0];
  bool target_is_new = false;
  if (target->kind == AST_BUILTIN && target->op) {
    Str target_op = interns_lookup(interns, target->op);
    target_is_new =
        target_op.len == 4 && memcmp(target_op.ptr, "$new", 4) == 0;
  }
  if (target->kind != AST_BLOCK && !target_is_new) return inserted;

  const MorphlType* target_t = target->type ? unwrap_ref(target->type) : NULL;

  char name_buf[48];
  int name_len = snprintf(name_buf, sizeof(name_buf), "$anon$%zu", ctx->count++);
  if (name_len <= 0) return inserted;
  Sym anon_sym = interns_intern(interns, str_from(name_buf, (size_t)name_len));
  Str anon_name = interns_lookup(interns, anon_sym);

  struct AstNode* name_node =
      ast_make_leaf(AST_IDENT, anon_name, target->filename, target->row, target->col);
  if (!name_node) return inserted;
  name_node->type = (MorphlType*)target_t;

  struct AstNode* sibling = ast_new(AST_DECL);
  if (!sibling) {
    ast_free(name_node);
    return inserted;
  }
  sibling->type = (MorphlType*)target_t;
  sibling->filename = target->filename;
  sibling->row = target->row;
  sibling->col = target->col;
  sibling->contributes_to_shape = true;
  sibling->contributes_to_layout = true;
  sibling->storage_is_mutable = false;
  sibling->storage_residence = MORPHL_STORAGE_INSTANCE;
  if (!ast_append_child(sibling, name_node) || !ast_append_child(sibling, target)) {
    sibling->child_count = 1;
    ast_free(sibling);
    return inserted;
  }
  if (!block_insert_child(block, insert_pos + inserted, sibling)) {
    sibling->child_count = 1;
    ast_free(sibling);
    return inserted;
  }
  inserted++;

  struct AstNode* ident =
      ast_make_leaf(AST_IDENT, anon_name, target->filename, target->row, target->col);
  if (!ident) return inserted;
  ident->type = (MorphlType*)target_t;
  node->children[0] = ident;
  return inserted;
}

static size_t hoist_immediate_ref_member_targets(FlattenCtx* ctx,
                                                 InternTable* interns,
                                                 struct AstNode* block,
                                                 size_t insert_pos,
                                                 struct AstNode* node) {
  if (!ctx || !interns || !block || !node || node->kind != AST_DECL ||
      node->child_count < 2 || !node->children[1]) {
    return 0;
  }
  struct AstNode* rhs = node->children[1];
  if (rhs->kind != AST_BUILTIN || !rhs->op || rhs->child_count < 1 ||
      !rhs->children[0]) {
    return 0;
  }
  Str rhs_op = interns_lookup(interns, rhs->op);
  if (rhs_op.len != 4 || memcmp(rhs_op.ptr, "$ref", 4) != 0) return 0;

  struct AstNode* member = rhs->children[0];
  if (!member || member->kind != AST_BUILTIN || !member->op ||
      member->child_count < 2 || !member->children[0]) {
    return 0;
  }
  Str member_op = interns_lookup(interns, member->op);
  if (member_op.len != 7 || memcmp(member_op.ptr, "$member", 7) != 0)
    return 0;

  struct AstNode* target = member->children[0];
  bool target_is_new = false;
  if (target->kind == AST_BUILTIN && target->op) {
    Str target_op = interns_lookup(interns, target->op);
    target_is_new =
        target_op.len == 4 && memcmp(target_op.ptr, "$new", 4) == 0;
  }
  if (target->kind != AST_BLOCK && !target_is_new) return 0;

  const MorphlType* target_t = target->type ? unwrap_ref(target->type) : NULL;
  char name_buf[48];
  int name_len = snprintf(name_buf, sizeof(name_buf), "$anon$%zu", ctx->count++);
  if (name_len <= 0) return 0;
  Sym anon_sym = interns_intern(interns, str_from(name_buf, (size_t)name_len));
  Str anon_name = interns_lookup(interns, anon_sym);

  struct AstNode* name_node =
      ast_make_leaf(AST_IDENT, anon_name, target->filename, target->row, target->col);
  if (!name_node) return 0;
  name_node->type = (MorphlType*)target_t;

  struct AstNode* sibling = ast_new(AST_DECL);
  if (!sibling) {
    ast_free(name_node);
    return 0;
  }
  sibling->type = (MorphlType*)target_t;
  sibling->filename = target->filename;
  sibling->row = target->row;
  sibling->col = target->col;
  sibling->contributes_to_shape = true;
  sibling->contributes_to_layout = true;
  sibling->storage_is_mutable = false;
  sibling->storage_residence = MORPHL_STORAGE_INSTANCE;
  if (!ast_append_child(sibling, name_node) || !ast_append_child(sibling, target)) {
    sibling->child_count = 1;
    ast_free(sibling);
    return 0;
  }
  if (!block_insert_child(block, insert_pos, sibling)) {
    sibling->child_count = 1;
    ast_free(sibling);
    return 0;
  }

  struct AstNode* ident =
      ast_make_leaf(AST_IDENT, anon_name, target->filename, target->row, target->col);
  if (!ident) return 1;
  ident->type = (MorphlType*)target_t;
  member->children[0] = ident;
  return 1;
}

/*
 * Walk a positional group init of `block_type`, find fields where a $ref field
 * is initialised with a nested $new expression, hoist each into a sibling $decl
 * inserted at `insert_pos` in `block`, and replace the group element with a
 * plain ident. Returns the number of siblings inserted.
 */
static size_t flatten_new_group(FlattenCtx* ctx, InternTable* interns,
                                struct AstNode* block, size_t insert_pos,
                                const MorphlType* block_type,
                                struct AstNode* group) {
  if (!block_type || block_type->kind != MORPHL_TYPE_BLOCK || !group ||
      group->kind != AST_GROUP)
    return 0;
  size_t inserted = 0;
  for (size_t fi = 0; fi < block_type->data.block.layout_field_count &&
                      fi < group->child_count;
       fi++) {
    const MorphlType* raw_ft = block_type->data.block.layout_field_types[fi];
    /* Strip $mut/$const qualifiers to reach the actual $ref (is_ref=true) layer
     */
    const MorphlType* ft = unwrap_ref(raw_ft);
    if (!ft || ft->kind != MORPHL_TYPE_REF || !ft->data.ref.is_ref) continue;
    struct AstNode* gv = group->children[fi];
    if (!gv || gv->kind != AST_BUILTIN || !gv->op || gv->child_count < 2)
      continue;
    Str gv_op = interns_lookup(interns, gv->op);
    if (gv_op.len != 4 || memcmp(gv_op.ptr, "$new", 4) != 0) continue;
    const MorphlType* nested_t = gv->type ? unwrap_ref(gv->type) : NULL;
    if (!nested_t || nested_t->kind != MORPHL_TYPE_BLOCK) continue;

    /* Recursively flatten the nested $new's own init group first (depth-first),
     * so innermost siblings land before outer ones in the block. */
    struct AstNode* nested_group =
        (gv->child_count >= 2) ? gv->children[1] : NULL;
    if (nested_group && nested_group->kind == AST_GROUP) {
      size_t deep = flatten_new_group(
          ctx, interns, block, insert_pos + inserted, nested_t, nested_group);
      inserted += deep;
    }

    /* Synthesise a unique name "$anon$N" interned for stable pointer lifetime.
     */
    char name_buf[48];
    int name_len =
        snprintf(name_buf, sizeof(name_buf), "$anon$%zu", ctx->count++);
    if (name_len <= 0) continue;
    Sym anon_sym =
        interns_intern(interns, str_from(name_buf, (size_t)name_len));
    Str anon_name = interns_lookup(interns, anon_sym);

    /* Build: $decl $anon$N $new BlockType2 init2
     * We move the existing $new node (gv) as the RHS — its children are already
     * typed. */
    struct AstNode* name_node =
        ast_make_leaf(AST_IDENT, anon_name, gv->filename, gv->row, gv->col);
    if (!name_node) continue;
    name_node->type = (MorphlType*)nested_t;

    struct AstNode* sibling = ast_new(AST_DECL);
    if (!sibling) {
      ast_free(name_node);
      continue;
    }
    sibling->type = (MorphlType*)nested_t;
    sibling->filename = gv->filename;
    sibling->row = gv->row;
    sibling->col = gv->col;
    sibling->contributes_to_shape = true;
    sibling->contributes_to_layout = true;
    sibling->storage_is_mutable = false;
    sibling->storage_residence = MORPHL_STORAGE_INSTANCE;
    if (!ast_append_child(sibling, name_node) ||
        !ast_append_child(sibling, gv)) {
      /* Roll back: detach gv so it isn't freed with sibling */
      sibling->child_count = 1;
      ast_free(sibling);
      continue;
    }

    /* Insert the sibling before insert_pos + inserted */
    if (!block_insert_child(block, insert_pos + inserted, sibling)) {
      sibling->child_count = 1; /* detach gv */
      ast_free(sibling);
      continue;
    }
    inserted++;

    /* Replace group[fi] with a plain ident node pointing to the sibling. */
    struct AstNode* ident =
        ast_make_leaf(AST_IDENT, anon_name, gv->filename, gv->row, gv->col);
    if (!ident)
      continue; /* gv is now owned by sibling; group[fi] left stale but not
                   freed */
    ident->type = (MorphlType*)nested_t;
    group->children[fi] = ident; /* gv is now owned by sibling_decl */
  }
  return inserted;
}

/*
 * Recursively flatten all blocks in the AST.
 * Handles AST_FILE, AST_BLOCK, and function bodies (via their AST_BLOCK
 * children).
 */
static void flatten_block(FlattenCtx* ctx, InternTable* interns,
                          struct AstNode* block) {
  if (!block || !interns) return;
  size_t i = 0;
  while (i < block->child_count) {
    struct AstNode* child = block->children[i];
    if (!child) {
      i++;
      continue;
    }
    /* Recurse into nested blocks / function bodies */
    if (child->kind == AST_BLOCK || child->kind == AST_FILE) {
      flatten_block(ctx, interns, child);
      i++;
      continue;
    }
    if (child->kind == AST_FUNC) {
      for (size_t ci = 0; ci < child->child_count; ci++) {
        if (child->children[ci] && child->children[ci]->kind == AST_BLOCK)
          flatten_block(ctx, interns, child->children[ci]);
      }
      i++;
      continue;
    }
    size_t hoisted =
        hoist_immediate_member_targets(ctx, interns, block, i, child);
    hoisted += hoist_immediate_ref_member_targets(
        ctx, interns, block, i + hoisted, child);
    i += hoisted;
    child = block->children[i];
    if (!child) {
      i++;
      continue;
    }
    /* Look for: $decl var ($new BlockType group_init) */
    if (child->kind != AST_DECL || child->child_count < 2 ||
        !child->children[1]) {
      i++;
      continue;
    }
    struct AstNode* rhs = child->children[1];
    if (rhs->kind != AST_BUILTIN || !rhs->op || rhs->child_count < 2 ||
        !rhs->children[1]) {
      i++;
      continue;
    }
    Str rhs_op = interns_lookup(interns, rhs->op);
    if (rhs_op.len != 4 || memcmp(rhs_op.ptr, "$new", 4) != 0) {
      i++;
      continue;
    }
    struct AstNode* group = rhs->children[1];
    if (!group || group->kind != AST_GROUP) {
      i++;
      continue;
    }
    const MorphlType* block_type = rhs->type ? unwrap_ref(rhs->type) : NULL;
    if (!block_type || block_type->kind != MORPHL_TYPE_BLOCK) {
      i++;
      continue;
    }

    size_t inserted =
        flatten_new_group(ctx, interns, block, i, block_type, group);
    i +=
        inserted + 1; /* skip over the inserted siblings + the original $decl */
  }
}

/* ── pre-pass: count total property table space for $impl declarations ───── */

static size_t count_impl_prop_space(InternTable* interns,
                                    struct AstNode* root) {
  if (!root || !interns) return 0;
  Sym impl_sym = interns_intern(interns, str_from("$impl", 5));
  size_t total = 0;
  for (size_t i = 0; i < root->child_count; i++) {
    struct AstNode* ch = root->children[i];
    if (!ch || ch->kind != AST_DECL || ch->child_count < 2) continue;
    struct AstNode* rhs = ch->children[1];
    if (!rhs || rhs->kind != AST_BUILTIN || rhs->op != impl_sym) continue;
    const MorphlType* rt = rhs->type ? unwrap_ref(rhs->type) : NULL;
    if (rt && rt->kind == MORPHL_TYPE_BLOCK && rt->data.block.prop_count > 0)
      total += rt->data.block.prop_count * 8;
  }
  return total;
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

static bool collect_static_slots(VmEmitter* e, struct AstNode* node) {
  if (!e || !node) return true;
  switch (node->kind) {
    case AST_FILE:
      for (size_t i = 0; i < node->child_count; ++i) {
        if (!collect_static_slots(e, node->children[i])) return false;
      }
      return true;
    case AST_BLOCK:
      if (!lexical_scope_push_anon(e)) return false;
      for (size_t i = 0; i < node->child_count; ++i) {
        if (!collect_static_slots(e, node->children[i])) {
          lexical_scope_pop(e);
          return false;
        }
      }
      lexical_scope_pop(e);
      return true;
    case AST_DECL: {
      if (node->child_count >= 2 && node->children[0] &&
          node->children[0]->kind == AST_IDENT &&
          builtin_is_name(e, node->children[1], "$import")) {
        if (e->emit_object) return true;
        AstNode* module_root = import_module_root(node->children[1]);
        if (module_root) {
          if (!lexical_scope_push_named(e, node->children[0]->value))
            return false;
          bool ok = collect_static_slots(e, module_root);
          lexical_scope_pop(e);
          return ok;
        }
      }
      if (node->child_count >= 2 &&
          node->storage_residence == MORPHL_STORAGE_STATIC) {
        AstNode* name_node = node->children[0];
        const MorphlType* t = node->type ? unwrap_ref(node->type) : NULL;
        if (name_node && name_node->kind == AST_IDENT && t) {
          char* full_name = lexical_make_binding_path(e, name_node->value);
          if (!full_name) return false;
          const StaticSlot* slot = static_slot_register(
              e, str_from(full_name, strlen(full_name)), t);
          (void)slot;
          if (!slot) {
            free(full_name);
            return false;
          }
        }
      }
      if (node->child_count >= 2 && node->children[1] &&
          node->children[1]->kind == AST_FUNC && node->children[0] &&
          node->children[0]->kind == AST_IDENT) {
        if (!lexical_scope_push_named(e, node->children[0]->value))
          return false;
        bool ok = true;
        for (size_t i = 0; i < node->children[1]->child_count; ++i) {
          if (!collect_static_slots(e, node->children[1]->children[i])) {
            ok = false;
            break;
          }
        }
        lexical_scope_pop(e);
        return ok;
      }
      for (size_t i = 1; i < node->child_count; ++i) {
        if (!collect_static_slots(e, node->children[i])) return false;
      }
      return true;
    }
    case AST_FUNC:
      if (!lexical_scope_push_anon(e)) return false;
      for (size_t i = 0; i < node->child_count; ++i) {
        if (!collect_static_slots(e, node->children[i])) {
          lexical_scope_pop(e);
          return false;
        }
      }
      lexical_scope_pop(e);
      return true;
    default:
      for (size_t i = 0; i < node->child_count; ++i) {
        if (!collect_static_slots(e, node->children[i])) return false;
      }
      return true;
  }
}

/* ── public backend entry point ─────────────────────────────────────────── */

bool morphl_backend_func_vm(MorphlBackendContext* context) {
  if (!context || !context->out_file || !context->tree) return false;
  bool emit_object =
      context->vm_emit_object || path_has_suffix(context->out_file, ".mplo");

  struct AstNode* emit_root = context->tree;
  struct AstNode* wrapper_root = NULL;
  if (emit_root->kind != AST_FILE && emit_root->kind != AST_BLOCK) {
    wrapper_root = ast_new(AST_FILE);
    if (!wrapper_root) return false;
    wrapper_root->filename = emit_root->filename;
    wrapper_root->row = emit_root->row;
    wrapper_root->col = emit_root->col;
    if (!ast_append_child(wrapper_root, emit_root)) {
      ast_free(wrapper_root);
      return false;
    }
    emit_root = wrapper_root;
  }

  VmEmitter e;
  memset(&e, 0, sizeof(e));
  e.emit_object = emit_object;
  e.interns = context->type_context ? context->type_context->interns : NULL;
  e.type_ctx = context->type_context;
  e.frameInfo = morphl_backend_frame_init();
  if (!e.frameInfo.root) {
    emitter_free(&e);
    return false;
  }
  char* root_path = (char*)malloc(1);
  if (!root_path) {
    emitter_free(&e);
    return false;
  }
  root_path[0] = '\0';
  if (!lexical_scope_push_full(&e, root_path)) {
    emitter_free(&e);
    return false;
  }

  /* pre-pass: compute global_frame_size = 32 + 8*import_count + impl_prop_space
   * + static_space */
  {
    size_t import_count = count_imports(e.interns, emit_root);
    size_t impl_prop_space = count_impl_prop_space(e.interns, emit_root);
    e.static_slot_ptr = 0;
    if (!collect_static_slots(&e, emit_root)) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
    size_t static_space = e.static_slot_ptr;
    e.global_frame_size =
        32 + 8 * import_count + impl_prop_space + static_space;
    e.impl_prop_table_base = 32 + 8 * import_count;
    e.impl_prop_table_ptr = e.impl_prop_table_base;
    e.static_slot_base = e.impl_prop_table_base + impl_prop_space;
    for (size_t i = 0; i < e.static_slot_count; ++i) {
      e.static_slots[i].global_slot += e.static_slot_base;
      e.static_slots[i].guard_slot += e.static_slot_base;
    }
    e.static_slot_ptr = e.static_slot_base + static_space;
  }

  /* function 0 = top-level program (implicit main) */
  size_t main_idx = func_alloc(&e);
  if (main_idx == SIZE_MAX) {
    emitter_free(&e);
    return false;
  }
  e.functions.items[main_idx].entry_point = 0; /* set after emission */

  /* emit global frame initialization: write $entry = global_frame_size to
   * global[24] */
  e.functions.items[main_idx].entry_point = (uint32_t)e.code.len;
  if (!emit_object) {
    /* GLOBAL; ICONST global_frame_size; ASTORE 24 */
    bool ok = emit_op(&e, VM_OP_GLOBAL) &&
              emit_iconst(&e, (int64_t)e.global_frame_size) &&
              emit_op_i32(&e, VM_OP_ASTORE, 24);
    if (!ok) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
  }

  /* pre-pass: flatten nested $new in $ref fields into sibling $decl nodes */
  {
    FlattenCtx fctx = {0};
    flatten_block(&fctx, e.interns, emit_root);
  }

  /* emit top-level code */
  if (!emit_node(&e, emit_root)) {
    emitter_free(&e);
    if (wrapper_root) {
      wrapper_root->child_count = 0;
      ast_free(wrapper_root);
    }
    return false;
  }

  if (!emit_object) {
    for (size_t i = e.static_cleanup_count; i > 0; --i) {
      BindingCleanup cleanup = e.static_cleanups[i - 1];
      if (!emit_binding_cleanup_block(&e, cleanup.binding_name, cleanup.block,
                                      cleanup.block_type, cleanup.binding_type)) {
        emitter_free(&e);
        if (wrapper_root) {
          wrapper_root->child_count = 0;
          ast_free(wrapper_root);
        }
        return false;
      }
    }
  }

  if (emit_object) {
    if (!emit_op(&e, VM_OP_RET)) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
  } else {
    if (!emit_op(&e, VM_OP_HALT)) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
  }
  e.functions.items[main_idx].frame_size =
      0; /* top-level has no single frame */

  /* emit all deferred function bodies */
  for (size_t i = 0; i < e.deferred_count; i++) {
    if (!emit_function_body(&e, e.deferred[i].node, e.deferred[i].func_idx,
                            e.deferred[i].name, e.deferred[i].file_root)) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
  }

  /* emit all deferred cleanup thunks (for heap blocks with $defer) */
  for (size_t i = 0; i < e.deferred_cleanup_count; i++) {
    struct DeferredCleanupThunk* t = &e.deferred_cleanups[i];
    if (!emit_cleanup_thunk(&e, t->fidx, t->block, t->block_type, t->binding_type, t->saved_lexical_path)) {
      emitter_free(&e);
      if (wrapper_root) {
        wrapper_root->child_count = 0;
        ast_free(wrapper_root);
      }
      return false;
    }
  }

  /* apply jump patches */
  if (!patches_apply(&e)) {
    emitter_free(&e);
    if (wrapper_root) {
      wrapper_root->child_count = 0;
      ast_free(wrapper_root);
    }
    return false;
  }

  /* serialize to file */
  FILE* out = fopen(context->out_file, "wb");
  if (!out) {
    emitter_free(&e);
    if (wrapper_root) {
      wrapper_root->child_count = 0;
      ast_free(wrapper_root);
    }
    return false;
  }

  VmBytes file = {0};
  bool ok = true;
  VmObjectExport* obj_exports = NULL;
  size_t obj_export_count = 0;
  VmObjectImport* obj_imports = NULL;
  size_t obj_import_count = 0;

  if (emit_object) {
    ok = ok && collect_object_exports(&e, emit_root, &obj_exports,
                                      &obj_export_count);
    ok = ok && collect_object_imports(&e, emit_root, &obj_imports,
                                      &obj_import_count);
  }

  /* header */
  ok = ok && bytes_push(&file, MORPHL_VM_MAGIC, 4);
  ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MAJOR);
  ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MINOR);
  ok = ok && bytes_push_u16_le(&file, emit_object
                                          ? MORPHL_VM_ARTIFACT_OBJECT
                                          : MORPHL_VM_ARTIFACT_EXECUTABLE);
  ok = ok && bytes_push_u32_le(
                 &file, (uint32_t)e.global_frame_size); /* global_frame_size */

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

  /* string table: u32 count, then for each entry: u32 len + bytes
   * (null-terminated) */
  ok = ok && bytes_push_u32_le(&file, (uint32_t)e.str_count);
  for (size_t i = 0; ok && i < e.str_count; i++) {
    uint32_t slen = (uint32_t)strlen(e.str_table[i]);
    ok = ok && bytes_push_u32_le(&file, slen);
    ok = ok && bytes_push(&file, (const uint8_t*)e.str_table[i],
                          slen + 1); /* +1 for NUL */
  }

  /* native symbol table: u32 count, then for each entry: u32 len + bytes
   * (null-terminated) */
  ok = ok && bytes_push_u32_le(&file, (uint32_t)e.native_sym_count);
  for (size_t i = 0; ok && i < e.native_sym_count; i++) {
    uint32_t nlen = (uint32_t)strlen(e.native_syms[i]);
    ok = ok && bytes_push_u32_le(&file, nlen);
    ok = ok && bytes_push(&file, (const uint8_t*)e.native_syms[i],
                          nlen + 1); /* +1 for NUL */
  }

  if (emit_object) {
    Str module_path =
        emit_root->filename ? str_from(emit_root->filename, strlen(emit_root->filename))
                            : str_from("", 0);
    ok = ok && bytes_push_len_string(&file, module_path);
    ok = ok && bytes_push_u32_le(&file, (uint32_t)main_idx); /* module_init */
    ok = ok && bytes_push_u32_le(&file, (uint32_t)obj_export_count);
    for (size_t i = 0; ok && i < obj_export_count; ++i) {
      ok = ok && bytes_push_u16_le(&file, obj_exports[i].kind);
      ok = ok && bytes_push_u16_le(&file, obj_exports[i].flags);
      ok = ok && bytes_push_u32_le(&file, obj_exports[i].symbol_value);
      ok = ok && bytes_push_len_string(&file, obj_exports[i].name);
    }
    ok = ok && bytes_push_u32_le(&file, (uint32_t)obj_import_count);
    for (size_t i = 0; ok && i < obj_import_count; ++i) {
      ok = ok && bytes_push_len_string(&file, obj_imports[i].binding_name);
      ok = ok && bytes_push_len_string(&file, obj_imports[i].path);
      ok = ok && bytes_push_u32_le(&file, (uint32_t)obj_imports[i].global_slot);
      ok = ok && bytes_push_u32_le(&file, (uint32_t)obj_imports[i].required_func_count);
      for (size_t fi = 0; ok && fi < obj_imports[i].required_func_count; ++fi) {
        ok = ok && bytes_push_len_string(&file, obj_imports[i].required_funcs[fi]);
      }
    }
    ok = ok && bytes_push_u32_le(&file, (uint32_t)e.object_reloc_count);
    for (size_t i = 0; ok && i < e.object_reloc_count; ++i) {
      ok = ok && bytes_push_u16_le(&file, e.object_relocs[i].kind);
      ok = ok && bytes_push_u32_le(&file, e.object_relocs[i].code_offset);
      if (e.object_relocs[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32 ||
          e.object_relocs[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_I64 ||
          e.object_relocs[i].kind == MORPHL_VM_RELOC_EXTERN_DATA_I32 ||
          e.object_relocs[i].kind == MORPHL_VM_RELOC_MODULE_SLOT_I32) {
        ok = ok && bytes_push_len_string(
                       &file,
                       str_from(e.object_relocs[i].module_path,
                                strlen(e.object_relocs[i].module_path)));
        ok = ok && bytes_push_len_string(
                       &file,
                       str_from(e.object_relocs[i].symbol_name,
                                strlen(e.object_relocs[i].symbol_name)));
      }
    }
  }

  if (ok) ok = (fwrite(file.data, 1, file.len, out) == file.len);

  fclose(out);
  free(file.data);
  free(obj_exports);
  if (obj_imports) {
    for (size_t i = 0; i < obj_import_count; ++i) {
      free(obj_imports[i].required_funcs);
    }
  }
  free(obj_imports);
  emitter_free(&e);
  if (wrapper_root) {
    wrapper_root->child_count = 0;
    ast_free(wrapper_root);
  }
  return ok;
}
