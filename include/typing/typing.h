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
  MORPHL_TYPE_STRING,
  MORPHL_TYPE_IDENT,
  MORPHL_TYPE_BOOL,
  MORPHL_TYPE_FUNC,      // Function type with parameters and return type
  MORPHL_TYPE_REF,       // Reference type with mutability/inline flags
  MORPHL_TYPE_PRIMITIVE, // (Deprecated) Primitive type placeholder
  MORPHL_TYPE_BLOCK,     // Block type (struct-like)
  MORPHL_TYPE_GROUP,     // Group type (tuple-like)
  MORPHL_TYPE_TRAIT,     // Trait type (interface-like)
} MorphlTypeKind;

// Forward declaration
typedef struct MorphlType MorphlType;

// Function type metadata: stores parameter and return types
typedef struct {
  MorphlType** param_types;
  size_t param_count;
  MorphlType* return_type;
} MorphlFuncType;

// Group type metadata: ordered tuple of element types
typedef struct {
  MorphlType** elem_types;
  size_t elem_count;
} MorphlGroupType;

// Block type metadata: fields declared in the block scope
typedef struct {
  Sym* field_names;
  MorphlType** field_types;
  size_t field_count;
} MorphlBlockType;

// Reference type metadata
typedef struct {
  MorphlType* target;
  bool is_mutable;
  bool is_inline;
} MorphlRefType;

// Main type structure
typedef struct MorphlType {
  MorphlTypeKind kind;
  size_t size;        // size in bytes
  size_t align;       // alignment requirement
  union {
    MorphlFuncType func;    // kind == MORPHL_TYPE_FUNC
    MorphlGroupType group;  // kind == MORPHL_TYPE_GROUP
    MorphlBlockType block;  // kind == MORPHL_TYPE_BLOCK
    MorphlRefType ref;       // kind == MORPHL_TYPE_REF
    Sym sym;                // Used for named types (traits, structs, etc.)
  } data;
  void* details;      // For future extensibility
} MorphlType;

// Type constructors - allocate from arena
MorphlType* morphl_type_unknown(Arena* arena);
MorphlType* morphl_type_void(Arena* arena);
MorphlType* morphl_type_int(Arena* arena);
MorphlType* morphl_type_float(Arena* arena);
MorphlType* morphl_type_string(Arena* arena);
MorphlType* morphl_type_ident(Arena* arena);
MorphlType* morphl_type_bool(Arena* arena);
MorphlType* morphl_type_func(Arena* arena,
                             MorphlType* param_type,
                             MorphlType* return_type);
MorphlType* morphl_type_ref(Arena* arena,
                            MorphlType* target,
                            bool is_mutable,
                            bool is_inline);
MorphlType* morphl_type_group(Arena* arena,
                              MorphlType** elem_types,
                              size_t elem_count);
MorphlType* morphl_type_block(Arena* arena,
                              Sym* field_names,
                              MorphlType** field_types,
                              size_t field_count);
MorphlType* morphl_type_clone(Arena* arena, const MorphlType* type);

// Type utilities

bool morphl_type_equals(const MorphlType* a, const MorphlType* b);

/// @brief Convert a MorphlType to its string representation.
/// @param type The type to convert.
/// @param interns The intern table for string interning.
/// @return A Str containing the string representation of the type. The caller is responsible for freeing the `ptr` field.
Str morphl_type_to_string(const MorphlType* type, InternTable *interns);

bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super);

static inline bool morphl_type_is_primitive(const MorphlType* type) {
  return type && (type->kind == MORPHL_TYPE_INT ||
                     type->kind == MORPHL_TYPE_FLOAT ||
                     type->kind == MORPHL_TYPE_BOOL || 
                     type->kind == MORPHL_TYPE_STRING || 
                     type->kind == MORPHL_TYPE_VOID);
}

#endif // MORPHL_TYPING_TYPING_H_
