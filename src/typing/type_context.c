#include "typing/type_context.h"
#include <string.h>
#include <stdlib.h>
#include "util/error.h"

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
#define INITIAL_FORWARD_CAPACITY 4
#define INITIAL_THIS_CAPACITY 8
#define INITIAL_FILE_CAPACITY 4
#define INITIAL_GLOBAL_CAPACITY 4

TypeContext* type_context_new(Arena* arena, InternTable* interns) {
  if (!arena || !interns) return NULL;
  
  TypeContext* ctx = arena_alloc(arena, sizeof(TypeContext));
  if (!ctx) return NULL;
  memset(ctx, 0, sizeof(TypeContext));
  
  ctx->arena = arena;
  ctx->interns = interns;
  ctx->expected_return_type = NULL;
  ctx->file_type = NULL;
  ctx->global_type = NULL;
  ctx->file_stack = arena_alloc(arena, INITIAL_FILE_CAPACITY * sizeof(MorphlType*));
  if (!ctx->file_stack) return NULL;
  ctx->file_depth = 0;
  ctx->file_capacity = INITIAL_FILE_CAPACITY;
  ctx->global_stack = arena_alloc(arena, INITIAL_GLOBAL_CAPACITY * sizeof(MorphlType*));
  if (!ctx->global_stack) return NULL;
  ctx->global_depth = 0;
  ctx->global_capacity = INITIAL_GLOBAL_CAPACITY;
  ctx->this_stack = arena_alloc(arena, INITIAL_THIS_CAPACITY * sizeof(MorphlType*));
  if (!ctx->this_stack) return NULL;
  ctx->this_depth = 0;
  ctx->this_capacity = INITIAL_THIS_CAPACITY;
  
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
  global->forwards = arena_alloc(arena, INITIAL_FORWARD_CAPACITY * sizeof(ForwardEntry));
  if (!global->forwards) return NULL;
  global->forward_count = 0;
  global->forward_capacity = INITIAL_FORWARD_CAPACITY;
  global->has_forward_errors = false;
  
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
  new_scope->forwards = arena_alloc(ctx->arena, INITIAL_FORWARD_CAPACITY * sizeof(ForwardEntry));
  if (!new_scope->forwards) return false;
  new_scope->forward_count = 0;
  new_scope->forward_capacity = INITIAL_FORWARD_CAPACITY;
  new_scope->has_forward_errors = false;
  
  ctx->scope_count++;
  return true;
}

bool type_context_pop_scope(TypeContext* ctx) {
  if (!ctx || ctx->scope_count <= 1) return false;
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  if (current->forward_count > 0) {
    for (size_t i = 0; i < current->forward_count; ++i) {
      if (!current->forwards[i].resolved) {
        Str name = interns_lookup(ctx->interns, current->forwards[i].name);
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward missing body for '%.*s'", (int)name.len, name.ptr);
        morphl_error_emit(NULL, &err);
        current->has_forward_errors = true;
      }
    }
  }
  ctx->scope_count--;
  return !current->has_forward_errors;
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

bool type_context_update_var(TypeContext* ctx, Sym name, MorphlType* type) {
  if (!ctx || ctx->scope_count == 0 || !name || !type) return false;

  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  for (size_t i = 0; i < current->var_count; ++i) {
    if (current->vars[i].name == name) {
      current->vars[i].type = type;
      return true;
    }
  }

  return false;
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

bool type_context_update_func(TypeContext* ctx, Sym name, MorphlType* func_type) {
  if (!ctx || !name || !func_type) return false;

  for (size_t i = 0; i < ctx->func_count; ++i) {
    if (ctx->functions[i].name == name) {
      ctx->functions[i].type = func_type;
      return true;
    }
  }

  return false;
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

bool type_context_define_forward(TypeContext* ctx, Sym name, MorphlType* func_type) {
  if (!ctx || !name || !func_type || ctx->scope_count == 0) return false;
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  for (size_t i = 0; i < current->forward_count; ++i) {
    if (current->forwards[i].name == name) {
      return false;
    }
  }
  if (current->forward_count >= current->forward_capacity) {
    size_t new_cap = current->forward_capacity * 2;
    ForwardEntry* new_forwards = arena_alloc(ctx->arena, new_cap * sizeof(ForwardEntry));
    if (!new_forwards) return false;
    memcpy(new_forwards, current->forwards, current->forward_count * sizeof(ForwardEntry));
    current->forwards = new_forwards;
    current->forward_capacity = new_cap;
  }
  current->forwards[current->forward_count].name = name;
  current->forwards[current->forward_count].type = func_type;
  current->forwards[current->forward_count].resolved = false;
  current->forward_count++;
  return true;
}

bool type_context_define_forward_body(TypeContext* ctx, Sym name, MorphlType* func_type) {
  if (!ctx || !name || !func_type || ctx->scope_count == 0) return false;
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  for (size_t i = 0; i < current->forward_count; ++i) {
    if (current->forwards[i].name == name) {
      if (current->forwards[i].resolved) {
        return false;
      }
      if (!morphl_type_equals(current->forwards[i].type, func_type)) {
        return false;
      }
      current->forwards[i].resolved = true;
      return true;
    }
  }
  return false;
}

ForwardEntry* type_context_lookup_forward(TypeContext* ctx, Sym name) {
  if (!ctx || !name || ctx->scope_count == 0) return NULL;
  Scope* current = &ctx->scopes[ctx->scope_count - 1];
  for (size_t i = 0; i < current->forward_count; ++i) {
    if (current->forwards[i].name == name) {
      return &current->forwards[i];
    }
  }
  return NULL;
}

bool type_context_check_unresolved_forwards(TypeContext* ctx) {
  if (!ctx) return false;
  bool ok = true;
  for (size_t s = 0; s < ctx->scope_count; ++s) {
    Scope* scope = &ctx->scopes[s];
    if (scope->has_forward_errors) {
      ok = false;
      continue;
    }
    for (size_t i = 0; i < scope->forward_count; ++i) {
      if (!scope->forwards[i].resolved) {
        Str name = interns_lookup(ctx->interns, scope->forwards[i].name);
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward missing body for '%.*s'", (int)name.len, name.ptr);
        morphl_error_emit(NULL, &err);
        ok = false;
        scope->has_forward_errors = true;
        break;
      }
    }
  }
  return ok;
}

void type_context_set_return_type(TypeContext* ctx, MorphlType* ret_type) {
  if (!ctx) return;
  ctx->expected_return_type = ret_type;
}

MorphlType* type_context_get_return_type(TypeContext* ctx) {
  if (!ctx) return NULL;
  return ctx->expected_return_type;
}

bool type_context_push_this(TypeContext* ctx, MorphlType* this_type) {
  if (!ctx || !this_type) return false;
  if (ctx->this_depth >= ctx->this_capacity) {
    size_t new_cap = ctx->this_capacity * 2;
    MorphlType** new_stack = arena_alloc(ctx->arena, new_cap * sizeof(MorphlType*));
    if (!new_stack) return false;
    memcpy(new_stack, ctx->this_stack, ctx->this_depth * sizeof(MorphlType*));
    ctx->this_stack = new_stack;
    ctx->this_capacity = new_cap;
  }
  ctx->this_stack[ctx->this_depth++] = this_type;
  return true;
}

bool type_context_pop_this(TypeContext* ctx) {
  if (!ctx || ctx->this_depth == 0) return false;
  ctx->this_depth--;
  return true;
}

MorphlType* type_context_get_this(TypeContext* ctx) {
  if (!ctx || ctx->this_depth == 0) return NULL;
  return ctx->this_stack[ctx->this_depth - 1];
}

bool type_context_push_file(TypeContext* ctx, MorphlType* file_type) {
  if (!ctx) return false;
  if (ctx->file_depth >= ctx->file_capacity) {
    size_t new_cap = ctx->file_capacity * 2;
    MorphlType** new_stack = arena_alloc(ctx->arena, new_cap * sizeof(MorphlType*));
    if (!new_stack) return false;
    memcpy(new_stack, ctx->file_stack, ctx->file_depth * sizeof(MorphlType*));
    ctx->file_stack = new_stack;
    ctx->file_capacity = new_cap;
  }
  ctx->file_stack[ctx->file_depth++] = ctx->file_type;
  ctx->file_type = file_type;
  return true;
}

bool type_context_pop_file(TypeContext* ctx) {
  if (!ctx || ctx->file_depth == 0) return false;
  ctx->file_type = ctx->file_stack[--ctx->file_depth];
  return true;
}

bool type_context_push_global(TypeContext* ctx, MorphlType* global_type) {
  if (!ctx) return false;
  if (ctx->global_depth >= ctx->global_capacity) {
    size_t new_cap = ctx->global_capacity * 2;
    MorphlType** new_stack = arena_alloc(ctx->arena, new_cap * sizeof(MorphlType*));
    if (!new_stack) return false;
    memcpy(new_stack, ctx->global_stack, ctx->global_depth * sizeof(MorphlType*));
    ctx->global_stack = new_stack;
    ctx->global_capacity = new_cap;
  }
  ctx->global_stack[ctx->global_depth++] = ctx->global_type;
  ctx->global_type = global_type;
  return true;
}

bool type_context_pop_global(TypeContext* ctx) {
  if (!ctx || ctx->global_depth == 0) return false;
  ctx->global_type = ctx->global_stack[--ctx->global_depth];
  return true;
}

MorphlType* type_context_get_file(TypeContext* ctx) {
  if (!ctx) return NULL;
  return ctx->file_type;
}

MorphlType* type_context_get_global(TypeContext* ctx) {
  if (!ctx) return NULL;
  return ctx->global_type;
}
