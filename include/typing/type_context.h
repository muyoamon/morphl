#ifndef MORPHL_TYPING_TYPE_CONTEXT_H_
#define MORPHL_TYPING_TYPE_CONTEXT_H_

#include "typing/typing.h"
#include "util/util.h"
#include <stddef.h>
#include <stdbool.h>

// Symbol-to-Type mapping for function registry
typedef struct {
  Sym name;
  MorphlType* type;
} TypeEntry;

// Forward declaration entry
typedef struct {
  Sym name;
  MorphlType* type;
  bool resolved;
} ForwardEntry;

// Variable entry in symbol table
typedef struct {
  Sym name;
  MorphlType* type;
} VarEntry;

// Scope frame containing variable definitions
typedef struct {
  VarEntry* vars;
  size_t var_count;
  size_t var_capacity;
  ForwardEntry* forwards;
  size_t forward_count;
  size_t forward_capacity;
  bool has_forward_errors;
} Scope;

// Type checking context
typedef struct {
  Arena* arena;              // Type allocation arena
  InternTable* interns;      // For intern table access
  
  // Function registry: maps function names to types
  TypeEntry* functions;
  size_t func_count;
  size_t func_capacity;
  
  // Scope stack for variable tracking
  Scope* scopes;
  size_t scope_count;
  size_t scope_capacity;
  
  // Current expected return type (set when checking function body)
  MorphlType* expected_return_type;

  // Special scope bindings
  MorphlType* file_type;
  MorphlType* global_type;
  MorphlType** file_stack;
  size_t file_depth;
  size_t file_capacity;
  MorphlType** global_stack;
  size_t global_depth;
  size_t global_capacity;

  MorphlType** this_stack;
  size_t this_depth;
  size_t this_capacity;
} TypeContext;

// Create/destroy TypeContext
TypeContext* type_context_new(Arena* arena, InternTable* interns);
void type_context_free(TypeContext* ctx);

// Scope management
bool type_context_push_scope(TypeContext* ctx);
bool type_context_pop_scope(TypeContext* ctx);

// Variable tracking
bool type_context_define_var(TypeContext* ctx, Sym name, MorphlType* type);
bool type_context_update_var(TypeContext* ctx, Sym name, MorphlType* type);
MorphlType* type_context_lookup_var(TypeContext* ctx, Sym name);
bool type_context_check_duplicate_var(TypeContext* ctx, Sym name);

// Function registry
bool type_context_define_func(TypeContext* ctx, Sym name, MorphlType* func_type);
bool type_context_update_func(TypeContext* ctx, Sym name, MorphlType* func_type);
MorphlType* type_context_lookup_func(TypeContext* ctx, Sym name);

// Forward declarations
bool type_context_define_forward(TypeContext* ctx, Sym name, MorphlType* func_type);
bool type_context_define_forward_body(TypeContext* ctx, Sym name, MorphlType* func_type);
ForwardEntry* type_context_lookup_forward(TypeContext* ctx, Sym name);
bool type_context_check_unresolved_forwards(TypeContext* ctx);

// Special scope bindings
bool type_context_push_this(TypeContext* ctx, MorphlType* this_type);
bool type_context_pop_this(TypeContext* ctx);
MorphlType* type_context_get_this(TypeContext* ctx);
bool type_context_push_file(TypeContext* ctx, MorphlType* file_type);
bool type_context_pop_file(TypeContext* ctx);
bool type_context_push_global(TypeContext* ctx, MorphlType* global_type);
bool type_context_pop_global(TypeContext* ctx);
MorphlType* type_context_get_file(TypeContext* ctx);
MorphlType* type_context_get_global(TypeContext* ctx);

// Return type management
void type_context_set_return_type(TypeContext* ctx, MorphlType* ret_type);
MorphlType* type_context_get_return_type(TypeContext* ctx);

// Utilities
void type_context_print_debug(TypeContext* ctx);

#endif  // MORPHL_TYPING_TYPE_CONTEXT_H_
