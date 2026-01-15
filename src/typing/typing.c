#include "typing/typing.h"
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
  t->size = 16; // Assume pointer + length (2 x 8 bytes)
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
    if (!names || !types) return NULL;
    for (size_t i = 0; i < field_count; ++i) {
      names[i] = field_names[i];
      types[i] = field_types[i];
    }
    t->data.block.field_names = names;
    t->data.block.field_types = types;
    t->data.block.field_count = field_count;
  } else {
    t->data.block.field_names = NULL;
    t->data.block.field_types = NULL;
    t->data.block.field_count = 0;
  }
  return t;
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
      if (!names || !types) return NULL;
      for (size_t i = 0; i < t->data.block.field_count; ++i) {
        names[i] = t->data.block.field_names[i];
        types[i] = morphl_type_clone(arena, t->data.block.field_types[i]);
        if (!types[i]) return NULL;
      }
      t->data.block.field_names = names;
      t->data.block.field_types = types;
    }
  } else if (t->kind == MORPHL_TYPE_REF) {
    if (t->data.ref.target) {
      t->data.ref.target = morphl_type_clone(arena, t->data.ref.target);
      if (!t->data.ref.target) return NULL;
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
    }
    return true;
  }

  if (a->kind == MORPHL_TYPE_REF) {
    if (a->data.ref.is_mutable != b->data.ref.is_mutable) return false;
    if (a->data.ref.is_inline != b->data.ref.is_inline) return false;
    return morphl_type_equals(a->data.ref.target, b->data.ref.target);
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
        // Print in format: func: <params> => <return>
        Str param_str = morphl_type_to_string(type->data.func.param_types[0], interns);
        Str return_str = morphl_type_to_string(type->data.func.return_type, interns);
        snprintf(buf, sizeof(buf), "func: (%.*s) => %.*s",
                  (int)param_str.len, param_str.ptr,
                  (int)return_str.len, return_str.ptr);
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_GROUP: {
        // Print in format: group: (<elem1>, <elem2>, ...)
        snprintf(buf, sizeof(buf), "group: (");
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
        // Print in format: block: {<name>:<type>, ...}
        snprintf(buf, sizeof(buf), "block: {");
        size_t offset = strlen(buf);
        for (size_t i = 0; i < type->data.block.field_count; ++i) {
          Str field_str = morphl_type_to_string(type->data.block.field_types[i], interns);
          int written = snprintf(buf + offset, sizeof(buf) - offset, "%.*s:%.*s%s",
                                 (int)interns_lookup(interns, type->data.block.field_names[i]).len, interns_lookup(interns, type->data.block.field_names[i]).ptr,
                                 (int)field_str.len, field_str.ptr,
                                 (i + 1 < type->data.block.field_count) ? ", " : "");
          offset += written;
        }
        snprintf(buf + offset, sizeof(buf) - offset, "}");
        result = new_cstr(buf);
        break;
      }
      case MORPHL_TYPE_REF: {
        const char* mut = type->data.ref.is_mutable ? "mut" : "const";
        const char* inl = type->data.ref.is_inline ? " inline" : "";
        snprintf(buf, sizeof(buf), "ref[%s%s]", mut, inl);
        result = new_cstr(buf);
        break;
      }
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

// Check subtype relationship (simplified: exact match for now)
bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super) {
  return morphl_type_equals(sub, super);
}
