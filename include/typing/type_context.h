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
} TypeContext;

// Create/destroy TypeContext
TypeContext* type_context_new(Arena* arena, InternTable* interns);
void type_context_free(TypeContext* ctx);

// Scope management
bool type_context_push_scope(TypeContext* ctx);
bool type_context_pop_scope(TypeContext* ctx);

// Variable tracking
bool type_context_define_var(TypeContext* ctx, Sym name, MorphlType* type);
MorphlType* type_context_lookup_var(TypeContext* ctx, Sym name);
bool type_context_check_duplicate_var(TypeContext* ctx, Sym name);

// Function registry
bool type_context_define_func(TypeContext* ctx, Sym name, MorphlType* func_type);
MorphlType* type_context_lookup_func(TypeContext* ctx, Sym name);

// Return type management
void type_context_set_return_type(TypeContext* ctx, MorphlType* ret_type);
MorphlType* type_context_get_return_type(TypeContext* ctx);

#endif  // MORPHL_TYPING_TYPE_CONTEXT_H_
