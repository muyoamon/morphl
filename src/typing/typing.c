#include "typing/typing.h"
#include "ast/ast.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "util/util.h"

// Helper: allocate and zero-init memory from arena
static void* arena_alloc(Arena* a, size_t size) {
  if (!a || size == 0) return NULL;
  char* mem = arena_push(a, NULL, size);
  if (mem) memset(mem, 0, size);
  return mem;
}

// Primitive type constructors
MorphlType* morphl_type_unknown(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_UNKNOWN;
  t->size = 0;
  t->align = 1;
  return t;
}

MorphlType* morphl_type_void(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_VOID;
  t->size = 0;
  t->align = 1;
  return t;
}

MorphlType* morphl_type_int(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_INT;
  t->size = 8;  // Assume 64-bit integers
  t->align = 8;
  return t;
}

MorphlType* morphl_type_float(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_FLOAT;
  t->size = 8;  // Assume 64-bit (double)
  t->align = 8;
  return t;
}

MorphlType* morphl_type_string(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_STRING;
  t->size = 8; // stored as 8-byte pointer into the bytecode string table
  t->align = 8;
  return t;
}

MorphlType* morphl_type_ident(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_IDENT;
  t->size = 8; // Assume symbol-sized
  t->align = 8;
  return t;
}

MorphlType* morphl_type_bool(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_BOOL;
  t->size = 1;
  t->align = 1;
  return t;
}

// Function type constructor
MorphlType* morphl_type_func(Arena* arena,
                             MorphlType* param_type,
                             MorphlType* return_type) {
  if (!arena || !return_type) return NULL;
  
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  
  t->kind = MORPHL_TYPE_FUNC;
  t->size = 8;  // Function pointer size
  t->align = 8;
  
  // Copy single parameter type (functions take one parameter expression)
  if (param_type) {
    MorphlType** params = arena_alloc(arena, sizeof(MorphlType*));
    if (!params) return NULL;
    params[0] = param_type;
    t->data.func.param_types = params;
    t->data.func.param_count = 1;
  } else {
    t->data.func.param_types = NULL;
    t->data.func.param_count = 0;
  }
  
  t->data.func.return_type = return_type;
  return t;
}

MorphlType* morphl_type_ref(Arena* arena,
                            MorphlType* target,
                            bool is_mutable,
                            bool is_inline) {
  if (!arena || !target) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_REF;
  t->size = 8;
  t->align = 8;
  t->data.ref.target = target;
  t->data.ref.is_mutable = is_mutable;
  t->data.ref.is_inline = is_inline;
  return t;
}

// Group type constructor
MorphlType* morphl_type_group(Arena* arena,
                              MorphlType** elem_types,
                              size_t elem_count) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_GROUP;
  t->size = 0;
  t->align = 1;
  if (elem_count > 0 && elem_types) {
    MorphlType** elems = arena_alloc(arena, elem_count * sizeof(MorphlType*));
    if (!elems) return NULL;
    for (size_t i = 0; i < elem_count; ++i) {
      elems[i] = elem_types[i];
    }
    t->data.group.elem_types = elems;
    t->data.group.elem_count = elem_count;
  } else {
    t->data.group.elem_types = NULL;
    t->data.group.elem_count = 0;
  }
  return t;
}

// Block type constructor
MorphlType* morphl_type_block(Arena* arena,
                              Sym* field_names,
                              MorphlType** field_types,
                              size_t field_count) {
  return morphl_type_block_with_props(arena, field_names, field_types, field_count,
                                      NULL, field_names, field_types, field_count, NULL,
                                      NULL, NULL, NULL, 0);
}

MorphlType* morphl_type_block_with_props(Arena* arena,
                                         Sym* field_names,
                                         MorphlType** field_types,
                                         size_t field_count,
                                         MorphlMemberStorage* field_storage,
                                         Sym* layout_field_names,
                                         MorphlType** layout_field_types,
                                         size_t layout_field_count,
                                         MorphlMemberStorage* layout_field_storage,
                                         Sym* prop_names,
                                         MorphlType** prop_types,
                                         AstNode** prop_values,
                                         size_t prop_count) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  t->kind = MORPHL_TYPE_BLOCK;
  t->size = 0;
  t->align = 1;
  if (field_count > 0 && field_names && field_types) {
    Sym* names = arena_alloc(arena, field_count * sizeof(Sym));
    MorphlType** types = arena_alloc(arena, field_count * sizeof(MorphlType*));
    MorphlMemberStorage* storage = arena_alloc(arena, field_count * sizeof(MorphlMemberStorage));
    if (!names || !types || !storage) return NULL;
    for (size_t i = 0; i < field_count; ++i) {
      names[i] = field_names[i];
      types[i] = field_types[i];
      storage[i] = field_storage
        ? field_storage[i]
        : morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
    }
    t->data.block.field_names = names;
    t->data.block.field_types = types;
    t->data.block.field_storage = storage;
    t->data.block.field_count = field_count;
  }
  if (layout_field_count > 0 && layout_field_names && layout_field_types) {
    Sym* layout_names = arena_alloc(arena, layout_field_count * sizeof(Sym));
    MorphlType** layout_types = arena_alloc(arena, layout_field_count * sizeof(MorphlType*));
    MorphlMemberStorage* layout_storage = arena_alloc(arena, layout_field_count * sizeof(MorphlMemberStorage));
    if (!layout_names || !layout_types || !layout_storage) return NULL;
    for (size_t i = 0; i < layout_field_count; ++i) {
      layout_names[i] = layout_field_names[i];
      layout_types[i] = layout_field_types[i];
      layout_storage[i] = layout_field_storage
        ? layout_field_storage[i]
        : morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
    }
    t->data.block.layout_field_names = layout_names;
    t->data.block.layout_field_types = layout_types;
    t->data.block.layout_field_storage = layout_storage;
    t->data.block.layout_field_count = layout_field_count;
  }
  if (prop_count > 0 && prop_names && prop_types) {
    Sym* pnames = arena_alloc(arena, prop_count * sizeof(Sym));
    MorphlType** ptypes = arena_alloc(arena, prop_count * sizeof(MorphlType*));
    AstNode** pvals = arena_alloc(arena, prop_count * sizeof(AstNode*));
    if (!pnames || !ptypes || !pvals) return NULL;
    for (size_t i = 0; i < prop_count; ++i) {
      pnames[i] = prop_names[i];
      ptypes[i] = prop_types[i];
      pvals[i]  = prop_values ? prop_values[i] : NULL;
    }
    t->data.block.prop_names  = pnames;
    t->data.block.prop_types  = ptypes;
    t->data.block.prop_values = pvals;
    t->data.block.prop_count  = prop_count;
  }
  return t;
}

// Array type constructor: [elem_type * count]
MorphlType* morphl_type_array(Arena* arena, MorphlType* elem_type, size_t count) {
  if (!arena || !elem_type) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  t->kind = MORPHL_TYPE_ARRAY;
  t->size  = count * elem_type->size;
  t->align = elem_type->align;
  t->data.array.elem_type = elem_type;
  t->data.array.count     = count;
  return t;
}

// Union type constructor: $union V1 V2 ...
// Flattens nested unions. Returns elem directly if only 1 variant remains,
// void if 0 variants remain (all were $never).
MorphlType* morphl_type_union(Arena* arena, MorphlType** variant_types, size_t variant_count) {
  if (!arena) return NULL;

  // Collect flattened, non-never variants
  MorphlType** flat = arena_alloc(arena, variant_count * 2 * sizeof(MorphlType*));
  if (!flat) return NULL;
  size_t flat_count = 0;

  for (size_t i = 0; i < variant_count; ++i) {
    MorphlType* v = variant_types[i];
    if (!v || v->kind == MORPHL_TYPE_NEVER) continue;
    if (v->kind == MORPHL_TYPE_UNION) {
      // Flatten nested union
      for (size_t j = 0; j < v->data.union_t.variant_count; ++j) {
        MorphlType* inner = v->data.union_t.variant_types[j];
        if (inner && inner->kind != MORPHL_TYPE_NEVER)
          flat[flat_count++] = inner;
      }
    } else {
      flat[flat_count++] = v;
    }
  }

  if (flat_count == 0) return morphl_type_void(arena);
  if (flat_count == 1) return flat[0];

  // Compute layout: slot 0 (8 bytes) = $$tag; slot 1+ = data payload
  size_t max_payload = 0;
  for (size_t i = 0; i < flat_count; ++i) {
    size_t sz = flat[i]->size;
    if (sz > max_payload) max_payload = sz;
  }

  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  t->kind  = MORPHL_TYPE_UNION;
  t->size  = 8 + max_payload; // 8-byte tag slot + payload
  t->align = 8;

  MorphlType** stored = arena_alloc(arena, flat_count * sizeof(MorphlType*));
  if (!stored) return NULL;
  for (size_t i = 0; i < flat_count; ++i) stored[i] = flat[i];
  t->data.union_t.variant_types  = stored;
  t->data.union_t.variant_count  = flat_count;
  return t;
}

// $never — bottom type (subtype of all types)
MorphlType* morphl_type_never(Arena* arena) {
  if (!arena) return NULL;
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  t->kind  = MORPHL_TYPE_NEVER;
  t->size  = 0;
  t->align = 1;
  return t;
}

/* {} — empty block type, distinct from () (void).
 * Used as the result type of loops and implicit return of void functions. */
MorphlType* morphl_type_empty_block(Arena* arena) {
  return morphl_type_block(arena, NULL, NULL, 0);
}

// Clone a type (allocate new copy in arena)
MorphlType* morphl_type_clone(Arena* arena, const MorphlType* type) {
  if (!arena || !type) return NULL;
  
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memcpy(t, type, sizeof(MorphlType));
  
  // For function types, deep-copy parameter and return types
  if (t->kind == MORPHL_TYPE_FUNC) {
    if (t->data.func.param_count > 0 && t->data.func.param_types) {
      MorphlType** params = arena_alloc(arena, t->data.func.param_count * sizeof(MorphlType*));
      if (!params) return NULL;
      for (size_t i = 0; i < t->data.func.param_count; ++i) {
        params[i] = morphl_type_clone(arena, t->data.func.param_types[i]);
        if (!params[i]) return NULL;
      }
      t->data.func.param_types = params;
    }
    if (t->data.func.return_type) {
      t->data.func.return_type = morphl_type_clone(arena, t->data.func.return_type);
      if (!t->data.func.return_type) return NULL;
    }
  } else if (t->kind == MORPHL_TYPE_GROUP) {
    if (t->data.group.elem_count > 0 && t->data.group.elem_types) {
      MorphlType** elems = arena_alloc(arena, t->data.group.elem_count * sizeof(MorphlType*));
      if (!elems) return NULL;
      for (size_t i = 0; i < t->data.group.elem_count; ++i) {
        elems[i] = morphl_type_clone(arena, t->data.group.elem_types[i]);
        if (!elems[i]) return NULL;
      }
      t->data.group.elem_types = elems;
    }
  } else if (t->kind == MORPHL_TYPE_BLOCK) {
    if (t->data.block.field_count > 0 && t->data.block.field_types && t->data.block.field_names) {
      Sym* names = arena_alloc(arena, t->data.block.field_count * sizeof(Sym));
      MorphlType** types = arena_alloc(arena, t->data.block.field_count * sizeof(MorphlType*));
      MorphlMemberStorage* storage = arena_alloc(arena, t->data.block.field_count * sizeof(MorphlMemberStorage));
      if (!names || !types || !storage) return NULL;
      for (size_t i = 0; i < t->data.block.field_count; ++i) {
        names[i] = t->data.block.field_names[i];
        types[i] = morphl_type_clone(arena, t->data.block.field_types[i]);
        storage[i] = t->data.block.field_storage ? t->data.block.field_storage[i]
                                                 : morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
        if (!types[i]) return NULL;
      }
      t->data.block.field_names = names;
      t->data.block.field_types = types;
      t->data.block.field_storage = storage;
    }
    if (t->data.block.layout_field_count > 0 &&
        t->data.block.layout_field_types && t->data.block.layout_field_names) {
      Sym* layout_names = arena_alloc(arena, t->data.block.layout_field_count * sizeof(Sym));
      MorphlType** layout_types = arena_alloc(arena, t->data.block.layout_field_count * sizeof(MorphlType*));
      MorphlMemberStorage* layout_storage =
        arena_alloc(arena, t->data.block.layout_field_count * sizeof(MorphlMemberStorage));
      if (!layout_names || !layout_types || !layout_storage) return NULL;
      for (size_t i = 0; i < t->data.block.layout_field_count; ++i) {
        layout_names[i] = t->data.block.layout_field_names[i];
        layout_types[i] = morphl_type_clone(arena, t->data.block.layout_field_types[i]);
        layout_storage[i] = t->data.block.layout_field_storage
          ? t->data.block.layout_field_storage[i]
          : morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
        if (!layout_types[i]) return NULL;
      }
      t->data.block.layout_field_names = layout_names;
      t->data.block.layout_field_types = layout_types;
      t->data.block.layout_field_storage = layout_storage;
    }
    if (t->data.block.prop_count > 0 && t->data.block.prop_types && t->data.block.prop_names) {
      Sym* pnames = arena_alloc(arena, t->data.block.prop_count * sizeof(Sym));
      MorphlType** ptypes = arena_alloc(arena, t->data.block.prop_count * sizeof(MorphlType*));
      if (!pnames || !ptypes) return NULL;
      for (size_t i = 0; i < t->data.block.prop_count; ++i) {
        pnames[i] = t->data.block.prop_names[i];
        ptypes[i] = morphl_type_clone(arena, t->data.block.prop_types[i]);
        if (!ptypes[i]) return NULL;
      }
      t->data.block.prop_names = pnames;
      t->data.block.prop_types = ptypes;
    }
  } else if (t->kind == MORPHL_TYPE_REF) {
    if (t->data.ref.target) {
      t->data.ref.target = morphl_type_clone(arena, t->data.ref.target);
      if (!t->data.ref.target) return NULL;
    }
  } else if (t->kind == MORPHL_TYPE_ARRAY) {
    if (t->data.array.elem_type) {
      t->data.array.elem_type = morphl_type_clone(arena, t->data.array.elem_type);
      if (!t->data.array.elem_type) return NULL;
    }
  } else if (t->kind == MORPHL_TYPE_UNION) {
    if (t->data.union_t.variant_count > 0 && t->data.union_t.variant_types) {
      MorphlType** variants = arena_alloc(arena, t->data.union_t.variant_count * sizeof(MorphlType*));
      if (!variants) return NULL;
      for (size_t i = 0; i < t->data.union_t.variant_count; ++i) {
        variants[i] = morphl_type_clone(arena, t->data.union_t.variant_types[i]);
        if (!variants[i]) return NULL;
      }
      t->data.union_t.variant_types = variants;
    }
  }

  return t;
}

// Check type equality
bool morphl_type_equals(const MorphlType* a, const MorphlType* b) {
  if (!a || !b) return a == b;
  if (a->kind != b->kind) return false;
  
  if (a->kind == MORPHL_TYPE_FUNC) {
    if (a->data.func.param_count != b->data.func.param_count) return false;
    
    // Check all parameter types match
    for (size_t i = 0; i < a->data.func.param_count; ++i) {
      if (!morphl_type_equals(a->data.func.param_types[i], 
                              b->data.func.param_types[i])) {
        return false;
      }
    }
    
    // Check return types match
    return morphl_type_equals(a->data.func.return_type, b->data.func.return_type);
  }

  if (a->kind == MORPHL_TYPE_GROUP) {
    if (a->data.group.elem_count != b->data.group.elem_count) return false;
    for (size_t i = 0; i < a->data.group.elem_count; ++i) {
      if (!morphl_type_equals(a->data.group.elem_types[i], b->data.group.elem_types[i])) {
        return false;
      }
    }
    return true;
  }

  if (a->kind == MORPHL_TYPE_BLOCK) {
    if (a->data.block.field_count != b->data.block.field_count) return false;
    for (size_t i = 0; i < a->data.block.field_count; ++i) {
      if (a->data.block.field_names[i] != b->data.block.field_names[i]) return false;
      if (!morphl_type_equals(a->data.block.field_types[i], b->data.block.field_types[i])) {
        return false;
      }
      if (a->data.block.field_storage && b->data.block.field_storage) {
        if (a->data.block.field_storage[i].contributes_to_shape !=
              b->data.block.field_storage[i].contributes_to_shape ||
            a->data.block.field_storage[i].contributes_to_layout !=
              b->data.block.field_storage[i].contributes_to_layout ||
            a->data.block.field_storage[i].is_mutable !=
              b->data.block.field_storage[i].is_mutable ||
            a->data.block.field_storage[i].residence !=
              b->data.block.field_storage[i].residence) {
          return false;
        }
      }
    }
    // Also compare properties for exact equality
    if (a->data.block.prop_count != b->data.block.prop_count) return false;
    for (size_t i = 0; i < a->data.block.prop_count; ++i) {
      if (a->data.block.prop_names[i] != b->data.block.prop_names[i]) return false;
      if (!morphl_type_equals(a->data.block.prop_types[i], b->data.block.prop_types[i])) {
        return false;
      }
    }
    return true;
  }

  if (a->kind == MORPHL_TYPE_REF) {
    if (a->data.ref.is_mutable != b->data.ref.is_mutable) return false;
    if (a->data.ref.is_inline != b->data.ref.is_inline) return false;
    return morphl_type_equals(a->data.ref.target, b->data.ref.target);
  }

  if (a->kind == MORPHL_TYPE_ARRAY) {
    if (a->data.array.count != b->data.array.count) return false;
    return morphl_type_equals(a->data.array.elem_type, b->data.array.elem_type);
  }

  if (a->kind == MORPHL_TYPE_UNION) {
    if (a->data.union_t.variant_count != b->data.union_t.variant_count) return false;
    for (size_t i = 0; i < a->data.union_t.variant_count; ++i) {
      if (!morphl_type_equals(a->data.union_t.variant_types[i],
                              b->data.union_t.variant_types[i])) return false;
    }
    return true;
  }

  return true;
}


static char *new_cstr(const char *s) {
    size_t len = strlen(s);
    char *copy = malloc(len + 1);
    if (copy) {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

// Display type as string
Str morphl_type_to_string(const MorphlType* type, InternTable *interns) {
  char buf[512] = {0};
  const char* result = NULL;
  
  if (!type) {
    result = new_cstr("<null>");
  } else {
    switch (type->kind) {
      case MORPHL_TYPE_VOID:
        result = new_cstr("void");
        break;
      case MORPHL_TYPE_INT:
        result = new_cstr("int");
        break;
      case MORPHL_TYPE_FLOAT:
        result = new_cstr("float");
        break;
      case MORPHL_TYPE_STRING:
        result = new_cstr("string");
        break;
      case MORPHL_TYPE_IDENT:
        result = new_cstr("ident");
        break;
      case MORPHL_TYPE_BOOL:
        result = new_cstr("bool");
        break;
      case MORPHL_TYPE_FUNC: {
        // Print in format: <params> => <return>
        Str param_str = morphl_type_to_string(type->data.func.param_types[0], interns);
        Str return_str = morphl_type_to_string(type->data.func.return_type, interns);
        snprintf(buf, sizeof(buf), "(%.*s) => %.*s",
                  (int)param_str.len, param_str.ptr,
                  (int)return_str.len, return_str.ptr);
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_GROUP: {
        // Print in format: (<elem1>, <elem2>, ...)
        snprintf(buf, sizeof(buf), "(");
        size_t offset = strlen(buf);
        for (size_t i = 0; i < type->data.group.elem_count; ++i) {
          Str elem_str = morphl_type_to_string(type->data.group.elem_types[i], interns);
          int written = snprintf(buf + offset, sizeof(buf) - offset, "%.*s%s",
                                 (int)elem_str.len, elem_str.ptr,
                                 (i + 1 < type->data.group.elem_count) ? ", " : "");
          offset += written;
        }
        snprintf(buf + offset, sizeof(buf) - offset, ")");
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_BLOCK: {
        // Print in format: {<name>:<type>, ...}($<prop>:<type>, ...)
        snprintf(buf, sizeof(buf), "{");
        size_t offset = strlen(buf);
        for (size_t i = 0; i < type->data.block.field_count; ++i) {
          Str field_str = morphl_type_to_string(type->data.block.field_types[i], interns);
          int written = snprintf(buf + offset, sizeof(buf) - offset, "%.*s:%.*s%s",
                                 (int)interns_lookup(interns, type->data.block.field_names[i]).len, interns_lookup(interns, type->data.block.field_names[i]).ptr,
                                 (int)field_str.len, field_str.ptr,
                                 (i + 1 < type->data.block.field_count) ? ", " : "");
          offset += written;
        }
        offset += snprintf(buf + offset, sizeof(buf) - offset, "}");
        if (type->data.block.prop_count > 0) {
          offset += snprintf(buf + offset, sizeof(buf) - offset, "(");
          for (size_t i = 0; i < type->data.block.prop_count; ++i) {
            Str prop_str = morphl_type_to_string(type->data.block.prop_types[i], interns);
            int written = snprintf(buf + offset, sizeof(buf) - offset, "$%.*s:%.*s%s",
                                   (int)interns_lookup(interns, type->data.block.prop_names[i]).len, interns_lookup(interns, type->data.block.prop_names[i]).ptr,
                                   (int)prop_str.len, prop_str.ptr,
                                   (i + 1 < type->data.block.prop_count) ? ", " : "");
            offset += written;
          }
          snprintf(buf + offset, sizeof(buf) - offset, ")");
        }
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_REF: {
        const char* mut = type->data.ref.is_mutable ? "mut" : "const";
        // const char* inl = type->data.ref.is_inline ? "inline" : "";
        Str underlying = (type->data.ref.is_recursive) ? 
          interns_lookup(interns, type->data.ref.recursive_sym) 
          : morphl_type_to_string(type->data.ref.target, interns);
        printf("%.*s", (int)underlying.len, underlying.ptr);
        snprintf(buf, sizeof(buf), "%s&%.*s", mut, (int)underlying.len, underlying.ptr);
        if (!type->data.ref.is_recursive) free((void*)underlying.ptr);
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_ARRAY: {
        Str elem_str = morphl_type_to_string(type->data.array.elem_type, interns);
        snprintf(buf, sizeof(buf), "[%.*s * %zu]", (int)elem_str.len, elem_str.ptr,
                 type->data.array.count);
        free((void*)elem_str.ptr);
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_UNION: {
        size_t offset = 0;
        offset += snprintf(buf + offset, sizeof(buf) - offset, "$union");
        for (size_t i = 0; i < type->data.union_t.variant_count; ++i) {
          Str v_str = morphl_type_to_string(type->data.union_t.variant_types[i], interns);
          offset += snprintf(buf + offset, sizeof(buf) - offset, " %.*s",
                             (int)v_str.len, v_str.ptr);
          free((void*)v_str.ptr);
        }
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_NEVER:
        result = new_cstr("$never");
        break;
      case MORPHL_TYPE_PRIMITIVE:
        result = new_cstr("primitive");
        break;
      case MORPHL_TYPE_TRAIT:
        result = new_cstr("trait");
        break;
      case MORPHL_TYPE_UNKNOWN:
      default:
        result = new_cstr("unknown");
        break;
    }
  }
  
  return str_from(result, strlen(result));
}

// Check subtype relationship.
// For block types: sub must have at least all of super's structural fields
// at the same positions with compatible types. Properties ($prop) are ignored
// for structural subtyping per SPEC §9.2.
bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super) {
  if (!sub || !super) return sub == super;
  // $never is a subtype of everything
  if (sub->kind == MORPHL_TYPE_NEVER) return true;
  if (sub->kind != super->kind) {
    // A concrete type T is a subtype of $union V1 V2... if it matches any variant
    if (super->kind == MORPHL_TYPE_UNION) {
      for (size_t i = 0; i < super->data.union_t.variant_count; ++i) {
        if (morphl_type_is_subtype(sub, super->data.union_t.variant_types[i])) return true;
      }
    }
    return false;
  }
  if (sub->kind == MORPHL_TYPE_BLOCK) {
    // super must be a prefix of sub's fields (same names, compatible types)
    if (sub->data.block.field_count < super->data.block.field_count) return false;
    for (size_t i = 0; i < super->data.block.field_count; ++i) {
      if (sub->data.block.field_names[i] != super->data.block.field_names[i]) return false;
      if (!morphl_type_is_subtype(sub->data.block.field_types[i],
                                   super->data.block.field_types[i])) return false;
    }
    return true;
  }
  if (sub->kind == MORPHL_TYPE_ARRAY) {
    // Arrays are exact-match only (no prefix subtyping)
    return morphl_type_equals(sub, super);
  }
  if (sub->kind == MORPHL_TYPE_UNION) {
    // Union subtype: every variant in sub must be a subtype of some variant in super
    for (size_t i = 0; i < sub->data.union_t.variant_count; ++i) {
      if (!morphl_type_is_subtype(sub->data.union_t.variant_types[i], super)) return false;
    }
    return true;
  }
  if (sub->kind == MORPHL_TYPE_REF) {
    // $mut ref <: $const ref (mutable is a subtype of const, not the reverse)
    if (!sub->data.ref.is_mutable && super->data.ref.is_mutable) return false;
    // is_ref and is_inline qualifiers must match exactly
    if (sub->data.ref.is_ref != super->data.ref.is_ref) return false;
    if (sub->data.ref.is_inline != super->data.ref.is_inline) return false;
    return morphl_type_is_subtype(sub->data.ref.target, super->data.ref.target);
  }
  // For all other types, fall back to exact equality
  return morphl_type_equals(sub, super);
}
