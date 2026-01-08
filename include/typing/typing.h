#ifndef MORPHL_TYPING_TYPING_H_
#define MORPHL_TYPING_TYPING_H_

#include "util/util.h"
#include <stdbool.h>
#include <stddef.h>

// Type kind enumeration
typedef enum {
  MORPHL_TYPE_UNKNOWN = 0,
  MORPHL_TYPE_VOID,
  MORPHL_TYPE_INT,
  MORPHL_TYPE_FLOAT,
  MORPHL_TYPE_BOOL,
  MORPHL_TYPE_FUNC,      // Function type with parameters and return type
  MORPHL_TYPE_PRIMITIVE, // Legacy: generic primitive
  MORPHL_TYPE_BLOCK,     // Legacy: generic block
  MORPHL_TYPE_GROUP,     // Legacy: generic group
  MORPHL_TYPE_TRAIT,     // Legacy: generic trait
} MorphlTypeKind;

// Forward declaration
typedef struct MorphlType MorphlType;

// Function type metadata: stores parameter and return types
typedef struct {
  MorphlType** param_types;
  size_t param_count;
  MorphlType* return_type;
} MorphlFuncType;

// Main type structure
typedef struct MorphlType {
  MorphlTypeKind kind;
  size_t size;        // size in bytes
  size_t align;       // alignment requirement
  union {
    MorphlFuncType func;  // Used when kind == MORPHL_TYPE_FUNC
    Sym sym;              // Used for named types (traits, structs, etc.)
  } data;
  void* details;      // For future extensibility
} MorphlType;

// Type constructors - allocate from arena
MorphlType* morphl_type_void(Arena* arena);
MorphlType* morphl_type_int(Arena* arena);
MorphlType* morphl_type_float(Arena* arena);
MorphlType* morphl_type_bool(Arena* arena);
MorphlType* morphl_type_func(Arena* arena,
                             MorphlType** param_types,
                             size_t param_count,
                             MorphlType* return_type);
MorphlType* morphl_type_clone(Arena* arena, const MorphlType* type);

// Type utilities
bool morphl_type_equals(const MorphlType* a, const MorphlType* b);
Str morphl_type_to_string(const MorphlType* type);
bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super);

#endif // MORPHL_TYPING_TYPING_H_