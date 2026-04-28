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
  MORPHL_TYPE_OVERLOAD,  // Overload type ($overload T1 T2 ...)
  MORPHL_TYPE_TRAIT,     // Trait type (interface-like)
  MORPHL_TYPE_ARRAY,     // Fixed-size array type [T * N]
  MORPHL_TYPE_UNION,     // Tagged union type $union V1 V2 ...
  MORPHL_TYPE_NEVER,     // Bottom type ($never) — subtype of all types
} MorphlTypeKind;

// Forward declaration
typedef struct MorphlType MorphlType;
typedef struct AstNode AstNode;

typedef enum {
  MORPHL_STORAGE_INSTANCE = 0,
  MORPHL_STORAGE_STATIC,
  MORPHL_STORAGE_HEAP,
  MORPHL_STORAGE_IMPORT,
  MORPHL_STORAGE_EXTERN,
  MORPHL_STORAGE_INLINE,
} MorphlStorageResidence;

typedef struct {
  bool contributes_to_shape;
  bool contributes_to_layout;
  bool is_mutable;
  MorphlStorageResidence residence;
} MorphlMemberStorage;

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

typedef struct {
  MorphlType** candidate_types;
  size_t candidate_count;
} MorphlOverloadType;

// Block type metadata: fields declared in the block scope
typedef struct {
  Sym* field_names;
  MorphlType** field_types;
  size_t field_count;
  MorphlMemberStorage* field_storage;
  Sym* layout_field_names;
  MorphlType** layout_field_types;
  MorphlMemberStorage* layout_field_storage;
  size_t layout_field_count;
  // Properties ($prop) — do not participate in structural subtyping;
  // resolved at compile time via $member (static substitution)
  Sym* prop_names;
  MorphlType** prop_types;
  AstNode** prop_values;  // value AST nodes for compile-time substitution
  size_t prop_count;
} MorphlBlockType;

// Reference type metadata
typedef struct {
  MorphlType* target;
  bool is_mutable;
  bool is_inline;
  bool is_ref;     // true for $ref / heap-capable storage handles; false for $mut/$const/$inline qualifiers
  bool is_recursive;
  Sym recursive_sym; // only check when is recursive
} MorphlRefType;

// Array type metadata: fixed-size contiguous sequence of N elements of type T
typedef struct {
  MorphlType* elem_type;
  size_t count;       // number of elements
} MorphlArrayType;

// Union type metadata: tagged union of variant types
typedef struct {
  MorphlType** variant_types;
  size_t variant_count;
} MorphlUnionType;

// Main type structure
typedef struct MorphlType {
  MorphlTypeKind kind;
  size_t size;        // size in bytes
  size_t align;       // alignment requirement
  union {
    MorphlFuncType func;    // kind == MORPHL_TYPE_FUNC
    MorphlGroupType group;  // kind == MORPHL_TYPE_GROUP
    MorphlOverloadType overload; // kind == MORPHL_TYPE_OVERLOAD
    MorphlBlockType block;  // kind == MORPHL_TYPE_BLOCK
    MorphlRefType ref;       // kind == MORPHL_TYPE_REF
    MorphlArrayType array;   // kind == MORPHL_TYPE_ARRAY
    MorphlUnionType union_t; // kind == MORPHL_TYPE_UNION
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
MorphlType* morphl_type_overload(Arena* arena,
                                 MorphlType** candidate_types,
                                 size_t candidate_count);
MorphlType* morphl_type_block(Arena* arena,
                              Sym* field_names,
                              MorphlType** field_types,
                              size_t field_count);
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
                                         size_t prop_count);
MorphlType* morphl_type_array(Arena* arena, MorphlType* elem_type, size_t count);
MorphlType* morphl_type_union(Arena* arena, MorphlType** variant_types, size_t variant_count);
MorphlType* morphl_type_never(Arena* arena);
/* {} — empty block type; distinct from () (void). Used as the result of $while loops
 * and as the implicit return type of functions that do not return a value. */
MorphlType* morphl_type_empty_block(Arena* arena);
MorphlType* morphl_type_clone(Arena* arena, const MorphlType* type);

// Type utilities

bool morphl_type_equals(const MorphlType* a, const MorphlType* b);

/// @brief Convert a MorphlType to its string representation.
/// @param type The type to convert.
/// @param interns The intern table for string interning.
/// @return A Str containing the string representation of the type. The caller is responsible for freeing the `ptr` field.
Str morphl_type_to_string(const MorphlType* type, InternTable *interns);

bool morphl_type_is_subtype(const MorphlType* sub, const MorphlType* super);

static inline MorphlMemberStorage morphl_member_storage_make(bool shape,
                                                             bool layout,
                                                             bool is_mutable,
                                                             MorphlStorageResidence residence) {
  MorphlMemberStorage storage;
  storage.contributes_to_shape = shape;
  storage.contributes_to_layout = layout;
  storage.is_mutable = is_mutable;
  storage.residence = residence;
  return storage;
}

static inline bool morphl_type_is_primitive(const MorphlType* type) {
  return type && (type->kind == MORPHL_TYPE_INT ||
                     type->kind == MORPHL_TYPE_FLOAT ||
                     type->kind == MORPHL_TYPE_BOOL || 
                     type->kind == MORPHL_TYPE_STRING || 
                     type->kind == MORPHL_TYPE_VOID);
}

#endif // MORPHL_TYPING_TYPING_H_
