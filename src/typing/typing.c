#include "typing/typing.h"
#include <string.h>
#include <stdio.h>

// Helper: allocate and zero-init memory from arena
static void* arena_alloc(Arena* a, size_t size) {
  if (!a || size == 0) return NULL;
  char* mem = arena_push(a, NULL, size);
  if (mem) memset(mem, 0, size);
  return mem;
}

// Primitive type constructors
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
                             MorphlType** param_types,
                             size_t param_count,
                             MorphlType* return_type) {
  if (!arena || !return_type) return NULL;
  
  MorphlType* t = arena_alloc(arena, sizeof(MorphlType));
  if (!t) return NULL;
  memset(t, 0, sizeof(MorphlType));
  
  t->kind = MORPHL_TYPE_FUNC;
  t->size = 8;  // Function pointer size
  t->align = 8;
  
  // Copy parameter types
  if (param_count > 0 && param_types) {
    MorphlType** params = arena_alloc(arena, param_count * sizeof(MorphlType*));
    if (!params) return NULL;
    memcpy(params, param_types, param_count * sizeof(MorphlType*));
    t->data.func.param_types = params;
    t->data.func.param_count = param_count;
  } else {
    t->data.func.param_types = NULL;
    t->data.func.param_count = 0;
  }
  
  t->data.func.return_type = return_type;
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
  
  return true;
}

// Display type as string
Str morphl_type_to_string(const MorphlType* type) {
  static char buf[256];
  const char* result = NULL;
  
  if (!type) {
    result = "<null>";
  } else {
    switch (type->kind) {
      case MORPHL_TYPE_VOID:
        result = "void";
        break;
      case MORPHL_TYPE_INT:
        result = "int";
        break;
      case MORPHL_TYPE_FLOAT:
        result = "float";
        break;
      case MORPHL_TYPE_BOOL:
        result = "bool";
        break;
      case MORPHL_TYPE_FUNC: {
        // Simple function type display
        snprintf(buf, sizeof(buf), "func");
        result = buf;
        break;
      }
      case MORPHL_TYPE_PRIMITIVE:
        result = "primitive";
        break;
      case MORPHL_TYPE_BLOCK:
        result = "block";
        break;
      case MORPHL_TYPE_GROUP:
        result = "group";
        break;
      case MORPHL_TYPE_TRAIT:
        result = "trait";
        break;
      case MORPHL_TYPE_UNKNOWN:
      default:
        result = "unknown";
        break;
    }
  }
  
  return str_from(result, strlen(result));
}

// Check subtype relationship (simplified: exact match for now)
bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super) {
  return morphl_type_equals(sub, super);
}
