#include "typing/inference.h"
#include "parser/operators.h"
#include "ast/ast.h"
#include "util/error.h"
#include "util/util.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

// Helper: check if two types are compatible for comparison
static bool types_comparable(const MorphlType* a, const MorphlType* b) {
  if (!a || !b) return false;
  // For now, any two identical types are comparable
  return morphl_type_equals(a, b);
}

// Helper: get operator name string
static const char* op_name_str(Sym op_sym, InternTable* interns) {
  if (!op_sym || !interns) return "<unknown>";
  Str op_name = interns_lookup(interns, op_sym);
  return op_name.ptr;
}

static MorphlType* unwrap_ref(MorphlType* t) {
  while (t && t->kind == MORPHL_TYPE_REF && t->data.ref.target) {
    t = t->data.ref.target;
  }
  return t;
}

MorphlType* morphl_infer_type_for_op(TypeContext* ctx,
                                     Sym op_sym,
                                     MorphlType** arg_types,
                                     size_t arg_count) {
  if (!ctx || !op_sym) return NULL;
  
  const OperatorInfo* info = operator_info_lookup(op_sym);
  if (!info) return NULL;
  
  // Get operator name for error messages
  const char* op_name = op_name_str(op_sym, ctx->interns);
  
  // Check arity
  if (arg_count < info->min_args || arg_count > info->max_args) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "operator %s expects %llu-%llu args, got %llu",
            op_name, (unsigned long long)info->min_args, (unsigned long long)info->max_args, (unsigned long long)arg_count);
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Type inference by operator kind
  if (op_sym == interns_intern(ctx->interns, str_from("$mut", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$const", 6)) ||
      op_sym == interns_intern(ctx->interns, str_from("$inline", 7))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s expects 1 arg, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!arg_types[0]) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: cannot infer argument type", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    bool is_mutable = op_sym == interns_intern(ctx->interns, str_from("$mut", 4));
    bool is_inline = op_sym == interns_intern(ctx->interns, str_from("$inline", 7));
    return morphl_type_ref(ctx->arena, arg_types[0], is_mutable, is_inline);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$this", 5))) {
    MorphlType* this_type = type_context_get_this(ctx);
    if (!this_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$this: no active block scope");
      morphl_error_emit(NULL, &err);
    }
    return this_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$file", 5))) {
    MorphlType* file_type = type_context_get_file(ctx);
    if (!file_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$file: file scope unavailable");
      morphl_error_emit(NULL, &err);
    }
    return file_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$global", 7))) {
    MorphlType* global_type = type_context_get_global(ctx);
    if (!global_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$global: global scope unavailable");
      morphl_error_emit(NULL, &err);
    }
    return global_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$forward", 8))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward expects 1 arg, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!arg_types[0]) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: cannot infer stub type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (arg_types[0]->kind != MORPHL_TYPE_FUNC) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: stub must be a function");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return arg_types[0];
  }

  // Comparison operators: (any, any) → bool
  if (op_sym == interns_intern(ctx->interns, str_from("$eq", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$neq", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lt", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$gt", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lte", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$gte", 4))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "comparison %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!types_comparable(left, right)) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: types not compatible", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  // Logic operators: bool → bool (or (bool, bool) → bool for $and/$or)
  if (op_sym == interns_intern(ctx->interns, str_from("$and", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$or", 3))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "logic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    for (size_t i = 0; i < 2; ++i) {
      MorphlType* check = unwrap_ref(arg_types[i]);
      if (!check || check->kind != MORPHL_TYPE_BOOL) {
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: arg %llu must be bool", op_name, (unsigned long long)(i + 1));
        morphl_error_emit(NULL, &err);
        return NULL;
      }
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$not", 4))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$not expects 1 arg, got %llu",
                                   (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* check = unwrap_ref(arg_types[0]);
    if (!check || check->kind != MORPHL_TYPE_BOOL) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$not: argument must be bool");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  // Arithmetic operators: (int, int) → int or (float, float) → float
  // Integer arithmetic
  if (op_sym == interns_intern(ctx->interns, str_from("$add", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$sub", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$mul", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$div", 4))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "arithmetic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_INT ||
        !right || right->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: both arguments must be int", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_int(ctx->arena);
  }
  
  // Float arithmetic
  if (op_sym == interns_intern(ctx->interns, str_from("$fadd", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$fsub", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$fmul", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$fdiv", 5))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "float arithmetic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_FLOAT ||
        !right || right->kind != MORPHL_TYPE_FLOAT) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: both arguments must be float", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_float(ctx->arena);
  }
  
  // Bitwise operators: (int, int) → int
  if (op_sym == interns_intern(ctx->interns, str_from("$band", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$bor", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$bxor", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lshift", 7)) ||
      op_sym == interns_intern(ctx->interns, str_from("$rshift", 7))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "bitwise %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_INT ||
        !right || right->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: both arguments must be int", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_int(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$bnot", 5))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$bnot expects 1 arg, got %llu",
                                   (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* check = unwrap_ref(arg_types[0]);
    if (!check || check->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$bnot: argument must be int");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_int(ctx->arena);
  }
  
  // Structural operators: $group and $block have void type
  if (op_sym == interns_intern(ctx->interns, str_from("$group", 6)) ||
      op_sym == interns_intern(ctx->interns, str_from("$block", 6))) {
    return morphl_type_void(ctx->arena);
  }

  // Function definition: $func produces a function type
  if (op_sym == interns_intern(ctx->interns, str_from("$func", 5))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$func expects 2 args, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    // First arg: parameter type(s)
    MorphlType* param_type = arg_types[0];
    if (!param_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$func: cannot infer parameter type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    // Second arg: return type
    MorphlType* return_type = arg_types[1];
    if (!return_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$func: cannot infer return type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    // For simplicity, assume single parameter
    return morphl_type_func(ctx->arena, param_type, return_type);
  }
  
  // Unknown or untyped operator
  MorphlError err = MORPHL_WARN(MORPHL_E_TYPE, "type inference not implemented for %s", op_name);
  morphl_error_emit(NULL, &err);
  return morphl_type_void(ctx->arena);
}

MorphlType* morphl_infer_type_of_ast(TypeContext* ctx, const AstNode* node) {
  if (!ctx || !node) return NULL;
  
  switch (node->kind) {
    case AST_DECL: {
      if (node->child_count < 2) return NULL;
      AstNode* name_node = node->children[0];
      AstNode* init_node = node->children[1];
      if (!name_node || name_node->kind != AST_IDENT || !name_node->op) return NULL;
      Sym var_sym = name_node->op;
      if (!init_node) return NULL;
      Sym forward_sym = interns_intern(ctx->interns, str_from("$forward", 8));
      if (init_node->kind == AST_BUILTIN && init_node->op == forward_sym) {
        if (init_node->child_count != 1) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: expected 1 stub expression");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* stub_node = init_node->children[0];
        MorphlType* stub_type = morphl_infer_type_of_ast(ctx, stub_node);
        if (!stub_type || stub_type->kind != MORPHL_TYPE_FUNC) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: stub must be a function");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (type_context_check_duplicate_var(ctx, var_sym)) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: variable already declared");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (!type_context_define_forward(ctx, var_sym, stub_type)) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: duplicate stub in scope");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        type_context_define_var(ctx, var_sym, stub_type);
        type_context_define_func(ctx, var_sym, stub_type);
        return stub_type;
      }

      if (init_node->kind == AST_FUNC ||
          (init_node->kind == AST_BUILTIN && init_node->op &&
           strcmp(op_name_str(init_node->op, ctx->interns), "$func") == 0)) {
        MorphlType* placeholder = morphl_type_func(ctx->arena,
                                                  morphl_type_unknown(ctx->arena),
                                                  morphl_type_unknown(ctx->arena));
        type_context_define_func(ctx, var_sym, placeholder);
        type_context_define_var(ctx, var_sym, placeholder);
      }

      MorphlType* init_type = morphl_infer_type_of_ast(ctx, init_node);
      if (!init_type) {
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$decl: cannot infer variable type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      ForwardEntry* forward = type_context_lookup_forward(ctx, var_sym);
      if (forward && !forward->resolved) {
        if (!type_context_define_forward_body(ctx, var_sym, init_type)) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: definition mismatch for stub");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return init_type;
      } else if (forward && forward->resolved) {
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$forward: multiple bodies for stub");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      bool dup = type_context_check_duplicate_var(ctx, var_sym);
      if (dup) {
        MorphlType* existing = type_context_lookup_var(ctx, var_sym);
        if (!existing || !morphl_type_equals(existing, init_type)) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$decl: variable already declared");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return existing;
      }

      type_context_define_var(ctx, var_sym, init_type);
      return init_type;
    }

    case AST_GROUP: {
      size_t count = node->child_count;
      MorphlType** elems = NULL;
      if (count > 0) {
        elems = (MorphlType**)malloc(count * sizeof(MorphlType*));
        if (!elems) return NULL;
        for (size_t i = 0; i < count; ++i) {
          elems[i] = morphl_infer_type_of_ast(ctx, node->children[i]);
          if (!elems[i]) { free(elems); return NULL; }
        }
      }
      MorphlType* group_type = morphl_type_group(ctx->arena, elems, count);
      free(elems);
      return group_type;
    }

    case AST_BLOCK: {
      if (!type_context_push_scope(ctx)) return NULL;
      MorphlType* block_type = morphl_type_block(ctx->arena, NULL, NULL, 0);
      if (!block_type || !type_context_push_this(ctx, block_type)) {
        type_context_pop_scope(ctx);
        return NULL;
      }
      if (!ctx->file_type) {
        ctx->file_type = block_type;
      }
      if (!ctx->global_type) {
        ctx->global_type = block_type;
      }
      Sym* field_names = NULL;
      MorphlType** field_types = NULL;
      size_t field_count = 0;
      size_t field_cap = 0;
      bool ok = true;
      for (size_t i = 0; i < node->child_count; ++i) {
        AstNode* stmt = node->children[i];
        MorphlType* stmt_type = morphl_infer_type_of_ast(ctx, stmt);
        if (!stmt_type) { ok = false; break; }
        if (stmt && stmt->kind == AST_DECL && stmt->child_count >= 1) {
          AstNode* name_node = stmt->children[0];
          if (!name_node || !name_node->op) { ok = false; break; }
          if (field_count >= field_cap) {
            size_t new_cap = field_cap ? field_cap * 2 : 4;
            Sym* new_names = (Sym*)realloc(field_names, new_cap * sizeof(Sym));
            MorphlType** new_types = (MorphlType**)realloc(field_types, new_cap * sizeof(MorphlType*));
            if (!new_names || !new_types) { ok = false; break; }
            field_names = new_names;
            field_types = new_types;
            field_cap = new_cap;
          }
          field_names[field_count] = name_node->op;
          field_types[field_count] = stmt_type;
          field_count++;
          Sym* names = (Sym*)arena_push(ctx->arena, NULL, field_count * sizeof(Sym));
          MorphlType** types = (MorphlType**)arena_push(ctx->arena, NULL, field_count * sizeof(MorphlType*));
          if (!names || !types) { ok = false; break; }
          memcpy(names, field_names, field_count * sizeof(Sym));
          memcpy(types, field_types, field_count * sizeof(MorphlType*));
          block_type->data.block.field_names = names;
          block_type->data.block.field_types = types;
          block_type->data.block.field_count = field_count;
        }
      }
      type_context_pop_this(ctx);
      type_context_pop_scope(ctx);
      free(field_names);
      free(field_types);
      return ok ? block_type : NULL;
    }

    case AST_BUILTIN:
    case AST_CALL:
    case AST_FUNC:
    case AST_IF:
    case AST_SET: {
      if (!node->op) return NULL;
      Sym idtstr_sym = interns_intern(ctx->interns, str_from("$idtstr", 7));
      Sym strtid_sym = interns_intern(ctx->interns, str_from("$strtid", 7));
      Sym member_sym = interns_intern(ctx->interns, str_from("$member", 7));
      Sym set_sym = interns_intern(ctx->interns, str_from("$set", 4));
      if (node->op == idtstr_sym) {
        if (node->child_count != 1) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$idtstr expects 1 arg");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* arg = node->children[0];
        if (!arg || arg->kind != AST_IDENT) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$idtstr expects identifier");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return morphl_type_string(ctx->arena);
      }
      if (node->op == strtid_sym) {
        if (node->child_count != 1) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$strtid expects 1 arg");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* arg = node->children[0];
        if (!arg || arg->kind != AST_LITERAL || arg->value.len < 2 ||
            arg->value.ptr[0] != '"' || arg->value.ptr[arg->value.len - 1] != '"') {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$strtid expects string literal");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return morphl_type_ident(ctx->arena);
      }
      if (node->op == member_sym) {
        if (node->child_count != 2) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$member expects 2 args");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* target = node->children[0];
        AstNode* field_node = node->children[1];
        if (!field_node || field_node->kind != AST_IDENT) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$member expects identifier field");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        MorphlType* target_type = morphl_infer_type_of_ast(ctx, target);
        if (!target_type) return NULL;
        target_type = unwrap_ref(target_type);
        if (!target_type || target_type->kind != MORPHL_TYPE_BLOCK) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$member: target must be block");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        Sym field_sym = field_node->op;
        if (!field_sym && field_node->value.ptr) {
          field_sym = interns_intern(ctx->interns, field_node->value);
        }
        for (size_t i = 0; i < target_type->data.block.field_count; ++i) {
          if (target_type->data.block.field_names[i] == field_sym) {
            return target_type->data.block.field_types[i];
          }
        }
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$member: field not found");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      if (node->op == set_sym) {
        if (node->child_count != 2) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$set expects 2 args");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        MorphlType* target_type = morphl_infer_type_of_ast(ctx, node->children[0]);
        MorphlType* value_type = morphl_infer_type_of_ast(ctx, node->children[1]);
        if (!target_type || !value_type) return NULL;
        if (target_type->kind == MORPHL_TYPE_REF) {
          if (!target_type->data.ref.is_mutable) {
            MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$set: target is not mutable");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
          if (!morphl_type_equals(target_type->data.ref.target, value_type)) {
            MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$set: type mismatch in assignment");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
          return value_type;
        }
        if (!morphl_type_equals(target_type, value_type)) {
          MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$set: type mismatch in assignment");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return value_type;
      }
      // Infer argument types recursively
      MorphlType** arg_types = NULL;
      size_t arg_count = node->child_count;
      
      if (arg_count > 0) {
        arg_types = (MorphlType**)malloc(arg_count * sizeof(MorphlType*));
        if (!arg_types) return NULL;
        
        for (size_t i = 0; i < arg_count; ++i) {
          arg_types[i] = morphl_infer_type_of_ast(ctx, node->children[i]);
          if (!arg_types[i]) {
            free(arg_types);
            return NULL;
          }
        }
      }
      
      MorphlType* result = NULL;
      if (node->op) {
        result = morphl_infer_type_for_op(ctx, node->op, arg_types, arg_count);
      }
      
      free(arg_types);
      return result;
    }
    
    case AST_IDENT: {
      // Look up identifier in scope
      Sym sym = node->op;
      if (!sym && node->value.ptr) {
        sym = interns_intern(ctx->interns, node->value);
      }
      if (!sym) return NULL;
      MorphlType* var_type = type_context_lookup_var(ctx, sym);
      if (!var_type) {
        Str name = interns_lookup(ctx->interns, sym);
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "undefined variable '%.*s'", (int)name.len, name.ptr);
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      return var_type;
    }
    
    case AST_LITERAL: {
      // Infer type from literal value
      if (!node->value.ptr || node->value.len == 0) return morphl_type_void(ctx->arena);
      
      if (node->value.len >= 2 &&
          node->value.ptr[0] == '"' &&
          node->value.ptr[node->value.len - 1] == '"') {
        return morphl_type_string(ctx->arena);
      }

      // Simple heuristic: if it looks like a number, assume int
      // (in a real implementation, check for . for float, quotes for string, etc.)
      bool has_dot = false;
      for (size_t i = 0; i < node->value.len; ++i) {
        if (node->value.ptr[i] == '.') {
          has_dot = true;
          break;
        }
      }
      
      if (has_dot) {
        return morphl_type_float(ctx->arena);
      } else {
        return morphl_type_int(ctx->arena);
      }
    }
    
    case AST_UNKNOWN:
    case AST_OVERLOAD:
    default:
      return morphl_type_void(ctx->arena);
  }
}
