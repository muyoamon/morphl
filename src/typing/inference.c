#include "typing/inference.h"
#include "parser/operators.h"
#include "ast/ast.h"
#include "util/error.h"
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
    
    if (!types_comparable(arg_types[0], arg_types[1])) {
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
      if (!arg_types[i] || arg_types[i]->kind != MORPHL_TYPE_BOOL) {
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: arg %llu must be bool", op_name, (unsigned long long)(i + 1));
        morphl_error_emit(NULL, &err);
        return NULL;
      }
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$not", 4))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$not expects 1 arg, got %llu", arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    if (!arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_BOOL) {
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
    
    if (!arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_INT ||
        !arg_types[1] || arg_types[1]->kind != MORPHL_TYPE_INT) {
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
    
    if (!arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_FLOAT ||
        !arg_types[1] || arg_types[1]->kind != MORPHL_TYPE_FLOAT) {
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
    
    if (!arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_INT ||
        !arg_types[1] || arg_types[1]->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "%s: both arguments must be int", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_int(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$bnot", 5))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$bnot expects 1 arg, got %llu", arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    if (!arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_INT) {
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
  
  // Unknown or untyped operator
  MorphlError err = MORPHL_WARN(MORPHL_E_TYPE, "type inference not implemented for %s", op_name);
  morphl_error_emit(NULL, &err);
  return morphl_type_void(ctx->arena);
}

MorphlType* morphl_infer_type_of_ast(TypeContext* ctx, const AstNode* node) {
  if (!ctx || !node) return NULL;
  
  switch (node->kind) {
    case AST_BUILTIN:
    case AST_CALL:
    case AST_FUNC:
    case AST_IF:
    case AST_SET:
    case AST_DECL:
    case AST_GROUP:
    case AST_BLOCK: {
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
      if (!node->op) return NULL;
      MorphlType* var_type = type_context_lookup_var(ctx, node->op);
      if (!var_type) {
        Str name = interns_lookup(ctx->interns, node->op);
        MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "undefined variable '%.*s'", (int)name.len, name.ptr);
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      return var_type;
    }
    
    case AST_LITERAL: {
      // Infer type from literal value
      if (!node->value.ptr || node->value.len == 0) return morphl_type_void(ctx->arena);
      
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
