#include "typing/type_context.h"
#include <string.h>
#include <stdlib.h>

// Helper: allocate and zero-init memory from arena
static void* arena_alloc(Arena* a, size_t size) {
  if (!a || size == 0) return NULL;
  char* mem = arena_push(a, NULL, size);
  if (mem) memset(mem, 0, size);
  return mem;
}

#define INITIAL_FUNC_CAPACITY 32
#define INITIAL_SCOPE_CAPACITY 8
#define INITIAL_VAR_CAPACITY 16

TypeContext* type_context_new(Arena* arena, InternTable* interns) {
  if (!arena || !interns) return NULL;
  
  TypeContext* ctx = arena_alloc(arena, sizeof(TypeContext));
  if (!ctx) return NULL;
  memset(ctx, 0, sizeof(TypeContext));
  
  ctx->arena = arena;
  ctx->interns = interns;
  ctx->expected_return_type = NULL;
  
  // Initialize function registry
  ctx->functions = arena_alloc(arena, INITIAL_FUNC_CAPACITY * sizeof(TypeEntry));
  if (!ctx->functions) return NULL;
  ctx->func_count = 0;
  ctx->func_capacity = INITIAL_FUNC_CAPACITY;
  
  // Initialize scope stack with global scope
  ctx->scopes = arena_alloc(arena, INITIAL_SCOPE_CAPACITY * sizeof(Scope));
  if (!ctx->scopes) return NULL;
  ctx->scope_count = 1;
  ctx->scope_capacity = INITIAL_SCOPE_CAPACITY;
  
  // Initialize global scope
  Scope* global = &ctx->scopes[0];
  global->vars = arena_alloc(arena, INITIAL_VAR_CAPACITY * sizeof(VarEntry));
  if (!global->vars) return NULL;
  global->var_count = 0;
  global->var_capacity = INITIAL_VAR_CAPACITY;
  
  return ctx;
}

void type_context_free(TypeContext* ctx) {
  // Context is allocated from arena, so just set to NULL
  // Arena cleanup is handled elsewhere
  (void)ctx;
}

bool type_context_push_scope(TypeContext* ctx) {
  if (!ctx) return false;
  
  // Expand scope stack if needed
  if (ctx->scope_count >= ctx->scope_capacity) {
    size_t new_cap = ctx->scope_capacity * 2;
    Scope* new_scopes = arena_alloc(ctx->arena, new_cap * sizeof(Scope));
    if (!new_scopes) return false;
    memcpy(new_scopes, ctx->scopes, ctx->scope_count * sizeof(Scope));
    ctx->scopes = new_scopes;
    ctx->scope_capacity = new_cap;
  }
  
  // Initialize new scope
  Scope* new_scope = &ctx->scopes[ctx->scope_count];
  new_scope->vars = arena_alloc(ctx->arena, INITIAL_VAR_CAPACITY * sizeof(VarEntry));
  if (!new_scope->vars) return false;
  new_scope->var_count = 0;
  new_scope->var_capacity = INITIAL_VAR_CAPACITY;
  
  ctx->scope_count++;
  return true;
}

bool type_context_pop_scope(TypeContext* ctx) {
  if (!ctx || ctx->scope_count <= 1) return false;
  ctx->scope_count--;
  return true;
}

bool type_context_define_var(TypeContext* ctx, Sym name, MorphlType* type) {
  if (!ctx || ctx->scope_count == 0 || !name || !type) return false;
  
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  
  // Expand variable list if needed
  if (current->var_count >= current->var_capacity) {
    size_t new_cap = current->var_capacity * 2;
    VarEntry* new_vars = arena_alloc(ctx->arena, new_cap * sizeof(VarEntry));
    if (!new_vars) return false;
    memcpy(new_vars, current->vars, current->var_count * sizeof(VarEntry));
    current->vars = new_vars;
    current->var_capacity = new_cap;
  }
  
  // Add variable
  current->vars[current->var_count].name = name;
  current->vars[current->var_count].type = type;
  current->var_count++;
  return true;
}

MorphlType* type_context_lookup_var(TypeContext* ctx, Sym name) {
  if (!ctx || !name) return NULL;
  
  // Search from innermost to outermost scope
  for (int i = (int)ctx->scope_count - 1; i >= 0; --i) {
    Scope* scope = &ctx->scopes[i];
    for (size_t j = 0; j < scope->var_count; ++j) {
      if (scope->vars[j].name == name) {
        return scope->vars[j].type;
      }
    }
  }
  
  return NULL;  // Variable not found
}

bool type_context_check_duplicate_var(TypeContext* ctx, Sym name) {
  if (!ctx || ctx->scope_count == 0 || !name) return false;
  
  // Only check current scope for duplicates (not parent scopes)
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  for (size_t i = 0; i < current->var_count; ++i) {
    if (current->vars[i].name == name) {
      return true;  // Duplicate found
    }
  }
  
  return false;  // No duplicate
}

bool type_context_define_func(TypeContext* ctx, Sym name, MorphlType* func_type) {
  if (!ctx || !name || !func_type) return false;
  
  // Expand function registry if needed
  if (ctx->func_count >= ctx->func_capacity) {
    size_t new_cap = ctx->func_capacity * 2;
    TypeEntry* new_funcs = arena_alloc(ctx->arena, new_cap * sizeof(TypeEntry));
    if (!new_funcs) return false;
    memcpy(new_funcs, ctx->functions, ctx->func_count * sizeof(TypeEntry));
    ctx->functions = new_funcs;
    ctx->func_capacity = new_cap;
  }
  
  // Add function
  ctx->functions[ctx->func_count].name = name;
  ctx->functions[ctx->func_count].type = func_type;
  ctx->func_count++;
  return true;
}

MorphlType* type_context_lookup_func(TypeContext* ctx, Sym name) {
  if (!ctx || !name) return NULL;
  
  for (size_t i = 0; i < ctx->func_count; ++i) {
    if (ctx->functions[i].name == name) {
      return ctx->functions[i].type;
    }
  }
  
  return NULL;  // Function not found
}

void type_context_set_return_type(TypeContext* ctx, MorphlType* ret_type) {
  if (!ctx) return;
  ctx->expected_return_type = ret_type;
}

MorphlType* type_context_get_return_type(TypeContext* ctx) {
  if (!ctx) return NULL;
  return ctx->expected_return_type;
}
