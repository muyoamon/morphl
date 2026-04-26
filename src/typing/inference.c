#include "typing/inference.h"
#include "parser/operators.h"
#include "ast/ast.h"
#include "lexer/lexer.h"
#include "util/error.h"
#include "util/util.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static MorphlSpan span_from_node(const AstNode* node) {
  if (!node) return morphl_span_unknown();
  return morphl_span_from_loc(node->filename, node->row, node->col);
}

#define MORPHL_ERR_AT(node, code, fmt, ...) \
  MORPHL_ERR_SPAN((code), MORPHL_SEV_ERROR, span_from_node(node), (fmt), ##__VA_ARGS__)

#define MORPHL_WARN_AT(node, code, fmt, ...) \
  MORPHL_ERR_SPAN((code), MORPHL_SEV_WARN, span_from_node(node), (fmt), ##__VA_ARGS__)

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

static bool is_truthy_condition_type(const MorphlType* t) {
  t = unwrap_ref((MorphlType*)t);
  return t && (t->kind == MORPHL_TYPE_BOOL || t->kind == MORPHL_TYPE_INT);
}

static bool is_main_signature(const MorphlType* t) {
  t = unwrap_ref((MorphlType*)t);
  if (!t || t->kind != MORPHL_TYPE_FUNC || !t->data.func.return_type ||
      t->data.func.return_type->kind != MORPHL_TYPE_INT ||
      t->data.func.param_count != 1 || !t->data.func.param_types) {
    return false;
  }
  MorphlType* params = unwrap_ref(t->data.func.param_types[0]);
  return params && params->kind == MORPHL_TYPE_GROUP &&
         params->data.group.elem_count == 0;
}

static bool is_string_literal(TypeContext* ctx, const AstNode* node) {
  if (!ctx || !node || node->kind != AST_LITERAL || !node->op) return false;
  Sym string_sym = interns_intern(ctx->interns, str_from(LEXER_KIND_STRING, strlen(LEXER_KIND_STRING)));
  return node->op == string_sym;
}

static Str string_literal_contents(const AstNode* node) {
  if (!node || !node->value.ptr || node->value.len < 2) return node ? node->value : str_from("", 0);
  if (node->value.ptr[0] == '"' && node->value.ptr[node->value.len - 1] == '"') {
    return str_from(node->value.ptr + 1, node->value.len - 2);
  }
  return node->value;
}

static Str default_extern_symbol(const AstNode* node) {
  if (!node) return str_from("", 0);
  if (node->extern_symbol.ptr && node->extern_symbol.len > 0) return node->extern_symbol;
  return node->value;
}

static bool append_member_entry(Sym** names,
                                MorphlType*** types,
                                MorphlMemberStorage** storage,
                                size_t* count,
                                size_t* capacity,
                                Sym name,
                                MorphlType* type,
                                MorphlMemberStorage member_storage) {
  if (!names || !types || !storage || !count || !capacity || !type || !name) return false;
  if (*count >= *capacity) {
    size_t new_cap = *capacity ? *capacity * 2 : 4;
    Sym* new_names = (Sym*)realloc(*names, new_cap * sizeof(Sym));
    MorphlType** new_types = (MorphlType**)realloc(*types, new_cap * sizeof(MorphlType*));
    MorphlMemberStorage* new_storage =
      (MorphlMemberStorage*)realloc(*storage, new_cap * sizeof(MorphlMemberStorage));
    if (!new_names || !new_types || !new_storage) return false;
    *names = new_names;
    *types = new_types;
    *storage = new_storage;
    *capacity = new_cap;
  }
  (*names)[*count] = name;
  (*types)[*count] = type;
  (*storage)[*count] = member_storage;
  (*count)++;
  return true;
}

static bool type_is_nonempty_block(const MorphlType* type) {
  return type && type->kind == MORPHL_TYPE_BLOCK && type->data.block.field_count > 0;
}

static MorphlType* build_static_scope_type(TypeContext* ctx, AstNode* node, size_t limit);

static MorphlType* build_static_function_type(TypeContext* ctx, AstNode* node) {
  if (!ctx || !node || node->kind != AST_FUNC || node->child_count < 2) return NULL;
  AstNode* body = node->children[1];
  if (!body || body->kind != AST_BLOCK) return morphl_type_block(ctx->arena, NULL, NULL, 0);
  MorphlType* body_tree = build_static_scope_type(ctx, body, body->child_count);
  if (!type_is_nonempty_block(body_tree)) return morphl_type_block(ctx->arena, NULL, NULL, 0);
  Sym anon0_sym = interns_intern(ctx->interns, str_from("$anon$0", 7));
  Sym names[1] = { anon0_sym };
  MorphlType* types[1] = { body_tree };
  return morphl_type_block(ctx->arena, names, types, 1);
}

static MorphlType* build_static_scope_type(TypeContext* ctx, AstNode* node, size_t limit) {
  if (!ctx || !node || (node->kind != AST_FILE && node->kind != AST_BLOCK)) return NULL;
  if (limit > node->child_count) limit = node->child_count;

  Sym* field_names = NULL;
  MorphlType** field_types = NULL;
  MorphlMemberStorage* field_storage = NULL;
  size_t field_count = 0;
  size_t field_cap = 0;
  size_t anon_count = 0;
  bool ok = true;
  MorphlMemberStorage storage =
    morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);

  for (size_t i = 0; i < limit; ++i) {
    AstNode* child = node->children[i];
    if (!child) continue;

    if (child->kind == AST_DECL && child->child_count >= 2) {
      AstNode* name_node = child->children[0];
      AstNode* rhs = child->children[1];
      if (child->storage_residence == MORPHL_STORAGE_STATIC && name_node && name_node->op && child->type) {
        if (!append_member_entry(&field_names, &field_types, &field_storage,
                                 &field_count, &field_cap,
                                 name_node->op, child->type, storage)) {
          ok = false;
          break;
        }
      }
      if (rhs && rhs->kind == AST_FUNC && name_node && name_node->op) {
        MorphlType* func_tree = build_static_function_type(ctx, rhs);
        if (type_is_nonempty_block(func_tree)) {
          if (!append_member_entry(&field_names, &field_types, &field_storage,
                                   &field_count, &field_cap,
                                   name_node->op, func_tree, storage)) {
            ok = false;
            break;
          }
        }
      }
      continue;
    }

    if (child->kind == AST_BLOCK) {
      MorphlType* block_tree = build_static_scope_type(ctx, child, child->child_count);
      if (type_is_nonempty_block(block_tree)) {
        char anon_buf[32];
        int anon_len = snprintf(anon_buf, sizeof(anon_buf), "$anon$%zu", anon_count++);
        if (anon_len <= 0) { ok = false; break; }
        Sym anon_sym = interns_intern(ctx->interns, str_from(anon_buf, (size_t)anon_len));
        if (!append_member_entry(&field_names, &field_types, &field_storage,
                                 &field_count, &field_cap,
                                 anon_sym, block_tree, storage)) {
          ok = false;
          break;
        }
      }
      continue;
    }

    if (child->kind == AST_FUNC) {
      MorphlType* func_tree = build_static_function_type(ctx, child);
      if (type_is_nonempty_block(func_tree)) {
        char anon_buf[32];
        int anon_len = snprintf(anon_buf, sizeof(anon_buf), "$anon$%zu", anon_count++);
        if (anon_len <= 0) { ok = false; break; }
        Sym anon_sym = interns_intern(ctx->interns, str_from(anon_buf, (size_t)anon_len));
        if (!append_member_entry(&field_names, &field_types, &field_storage,
                                 &field_count, &field_cap,
                                 anon_sym, func_tree, storage)) {
          ok = false;
          break;
        }
      }
      continue;
    }
  }

  MorphlType* result = ok
    ? morphl_type_block_with_props(ctx->arena,
                                   field_names, field_types, field_count, field_storage,
                                   field_names, field_types, field_count, field_storage,
                                   NULL, NULL, NULL, 0)
    : NULL;
  free(field_names);
  free(field_types);
  free(field_storage);
  if (!result) return morphl_type_block(ctx->arena, NULL, NULL, 0);
  return result;
}

static void refresh_file_intrinsics(TypeContext* ctx,
                                    AstNode* file_node,
                                    MorphlType* file_type,
                                    Sym* user_field_names,
                                    MorphlType** user_field_types,
                                    MorphlMemberStorage* user_field_storage,
                                    size_t user_field_count,
                                    Sym* user_layout_names,
                                    MorphlType** user_layout_types,
                                    MorphlMemberStorage* user_layout_storage,
                                    size_t user_layout_count,
                                    size_t prefix_limit) {
  if (!ctx || !file_node || !file_type || file_node->kind != AST_FILE) return;
  Sym statics_sym = interns_intern(ctx->interns, str_from("$$statics", 9));
  MorphlType* statics_type = build_static_scope_type(ctx, file_node, prefix_limit);
  size_t total_fields = user_field_count + 1;
  size_t total_layout = user_layout_count + 1;
  Sym* names = total_fields ? (Sym*)arena_push(ctx->arena, NULL, total_fields * sizeof(Sym)) : NULL;
  MorphlType** types = total_fields
    ? (MorphlType**)arena_push(ctx->arena, NULL, total_fields * sizeof(MorphlType*)) : NULL;
  MorphlMemberStorage* storage = total_fields
    ? (MorphlMemberStorage*)arena_push(ctx->arena, NULL, total_fields * sizeof(MorphlMemberStorage)) : NULL;
  Sym* layout_names = total_layout
    ? (Sym*)arena_push(ctx->arena, NULL, total_layout * sizeof(Sym)) : NULL;
  MorphlType** layout_types = total_layout
    ? (MorphlType**)arena_push(ctx->arena, NULL, total_layout * sizeof(MorphlType*)) : NULL;
  MorphlMemberStorage* layout_storage = total_layout
    ? (MorphlMemberStorage*)arena_push(ctx->arena, NULL, total_layout * sizeof(MorphlMemberStorage)) : NULL;
  if (!names || !types || !storage || !layout_names || !layout_types || !layout_storage) return;
  if (user_field_count) {
    memcpy(names, user_field_names, user_field_count * sizeof(Sym));
    memcpy(types, user_field_types, user_field_count * sizeof(MorphlType*));
    memcpy(storage, user_field_storage, user_field_count * sizeof(MorphlMemberStorage));
  }
  names[user_field_count] = statics_sym;
  types[user_field_count] = statics_type;
  storage[user_field_count] = morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
  if (user_layout_count) {
    memcpy(layout_names, user_layout_names, user_layout_count * sizeof(Sym));
    memcpy(layout_types, user_layout_types, user_layout_count * sizeof(MorphlType*));
    memcpy(layout_storage, user_layout_storage, user_layout_count * sizeof(MorphlMemberStorage));
  }
  layout_names[user_layout_count] = statics_sym;
  layout_types[user_layout_count] = statics_type;
  layout_storage[user_layout_count] = morphl_member_storage_make(true, true, false, MORPHL_STORAGE_INSTANCE);
  file_type->data.block.field_names = names;
  file_type->data.block.field_types = types;
  file_type->data.block.field_storage = storage;
  file_type->data.block.field_count = total_fields;
  file_type->data.block.layout_field_names = layout_names;
  file_type->data.block.layout_field_types = layout_types;
  file_type->data.block.layout_field_storage = layout_storage;
  file_type->data.block.layout_field_count = total_layout;
}

static void refresh_global_type(TypeContext* ctx,
                                AstNode* file_node,
                                MorphlType* file_type,
                                size_t prefix_limit) {
  if (!ctx || !file_node || !file_type || file_node->kind != AST_FILE) return;
  Sym import_sym = interns_intern(ctx->interns, str_from("$import", 7));
  Sym modules_sym = interns_intern(ctx->interns, str_from("$modules", 8));
  Sym source_sym  = interns_intern(ctx->interns, str_from("$source", 7));
  Sym argc_sym    = interns_intern(ctx->interns, str_from("$argc", 5));
  Sym argv_sym    = interns_intern(ctx->interns, str_from("$argv", 5));
  Sym env_sym     = interns_intern(ctx->interns, str_from("$env", 4));
  Sym entry_sym   = interns_intern(ctx->interns, str_from("$entry", 6));

  size_t mod_count = 0;
  for (size_t i = 0; i < prefix_limit && i < file_node->child_count; ++i) {
    AstNode* ch = file_node->children[i];
    if (!ch || ch->kind != AST_DECL || ch->child_count < 2) continue;
    AstNode* rhs = ch->children[1];
    if (rhs && rhs->kind == AST_BUILTIN && rhs->op == import_sym) mod_count++;
  }
  Sym* mod_names = mod_count ? (Sym*)malloc(mod_count * sizeof(Sym)) : NULL;
  MorphlType** mod_types = mod_count ? (MorphlType**)malloc(mod_count * sizeof(MorphlType*)) : NULL;
  if (mod_count && (!mod_names || !mod_types)) {
    free(mod_names);
    free(mod_types);
    return;
  }
  size_t mi = 0;
  for (size_t i = 0; i < prefix_limit && i < file_node->child_count && mi < mod_count; ++i) {
    AstNode* ch = file_node->children[i];
    if (!ch || ch->kind != AST_DECL || ch->child_count < 2) continue;
    AstNode* rhs = ch->children[1];
    AstNode* nm = ch->children[0];
    if (!rhs || rhs->kind != AST_BUILTIN || rhs->op != import_sym || !nm || !nm->op || !ch->type) continue;
    mod_names[mi] = nm->op;
    mod_types[mi] = ch->type;
    mi++;
  }
  MorphlType* modules_type = morphl_type_block(ctx->arena, mod_names, mod_types, mi);
  free(mod_names);
  free(mod_types);
  if (!modules_type) return;
  Sym gnames[6] = { argc_sym, argv_sym, env_sym, entry_sym, modules_sym, source_sym };
  MorphlType* gtypes[6];
  gtypes[0] = morphl_type_int(ctx->arena);
  gtypes[1] = morphl_type_int(ctx->arena);
  gtypes[2] = morphl_type_int(ctx->arena);
  gtypes[3] = morphl_type_int(ctx->arena);
  gtypes[4] = modules_type;
  gtypes[5] = file_type;
  MorphlType* synthetic_global = morphl_type_block(ctx->arena, gnames, gtypes, 6);
  if (synthetic_global) ctx->global_type = synthetic_global;
}

static void set_storage_defaults(AstNode* node) {
  if (!node) return;
  node->contributes_to_shape = true;
  node->contributes_to_layout = true;
  node->storage_is_mutable = false;
  node->storage_residence = MORPHL_STORAGE_INSTANCE;
}

static void apply_storage_metadata(TypeContext* ctx,
                                   AstNode* decl_or_expr,
                                   Sym bound_sym,
                                   const MorphlType* expected_type) {
  (void)expected_type;
  if (!ctx || !decl_or_expr) return;
  set_storage_defaults(decl_or_expr);
  if (decl_or_expr->kind != AST_BUILTIN || !decl_or_expr->op) return;

  Sym mut_sym = interns_intern(ctx->interns, str_from("$mut", 4));
  Sym const_sym = interns_intern(ctx->interns, str_from("$const", 6));
  Sym inline_sym = interns_intern(ctx->interns, str_from("$inline", 7));
  Sym static_sym = interns_intern(ctx->interns, str_from("$static", 7));
  Sym heap_sym = interns_intern(ctx->interns, str_from("$heap", 5));
  Sym import_sym = interns_intern(ctx->interns, str_from("$import", 7));
  Sym extern_sym = interns_intern(ctx->interns, str_from("$extern", 7));
  Sym ref_sym = interns_intern(ctx->interns, str_from("$ref", 4));

  if (decl_or_expr->op == mut_sym || decl_or_expr->op == const_sym ||
      decl_or_expr->op == inline_sym || decl_or_expr->op == static_sym ||
      decl_or_expr->op == heap_sym) {
    if (decl_or_expr->child_count > 0 && decl_or_expr->children[0]) {
      apply_storage_metadata(ctx, decl_or_expr->children[0], bound_sym, expected_type);
      decl_or_expr->contributes_to_shape = decl_or_expr->children[0]->contributes_to_shape;
      decl_or_expr->contributes_to_layout = decl_or_expr->children[0]->contributes_to_layout;
      decl_or_expr->storage_is_mutable = decl_or_expr->children[0]->storage_is_mutable;
      decl_or_expr->storage_residence = decl_or_expr->children[0]->storage_residence;
      decl_or_expr->extern_symbol = decl_or_expr->children[0]->extern_symbol;
    }
  }

  if (decl_or_expr->op == mut_sym) {
    decl_or_expr->storage_is_mutable = true;
  } else if (decl_or_expr->op == const_sym) {
    decl_or_expr->storage_is_mutable = false;
  } else if (decl_or_expr->op == inline_sym) {
    if (decl_or_expr->child_count > 0 && decl_or_expr->children[0]) {
      decl_or_expr->contributes_to_shape = decl_or_expr->children[0]->contributes_to_shape;
      decl_or_expr->contributes_to_layout = decl_or_expr->children[0]->contributes_to_layout;
      decl_or_expr->storage_residence = decl_or_expr->children[0]->storage_residence;
    }
  } else if (decl_or_expr->op == static_sym) {
    decl_or_expr->contributes_to_shape = false;
    decl_or_expr->contributes_to_layout = false;
    decl_or_expr->storage_residence = MORPHL_STORAGE_STATIC;
  } else if (decl_or_expr->op == heap_sym) {
    decl_or_expr->contributes_to_shape = true;
    decl_or_expr->contributes_to_layout = true;
    decl_or_expr->storage_residence = MORPHL_STORAGE_HEAP;
  } else if (decl_or_expr->op == import_sym) {
    decl_or_expr->contributes_to_shape = true;
    decl_or_expr->contributes_to_layout = true;
    decl_or_expr->storage_is_mutable = false;
    decl_or_expr->storage_residence = MORPHL_STORAGE_IMPORT;
  } else if (decl_or_expr->op == extern_sym) {
    decl_or_expr->contributes_to_shape = true;
    decl_or_expr->contributes_to_layout = true;
    decl_or_expr->storage_is_mutable = false;
    decl_or_expr->storage_residence = MORPHL_STORAGE_EXTERN;
    if (decl_or_expr->child_count == 2 && is_string_literal(ctx, decl_or_expr->children[0])) {
      decl_or_expr->extern_symbol = string_literal_contents(decl_or_expr->children[0]);
    } else if (decl_or_expr->child_count == 1 && is_string_literal(ctx, decl_or_expr->children[0])) {
      decl_or_expr->extern_symbol = string_literal_contents(decl_or_expr->children[0]);
    } else if (bound_sym) {
      decl_or_expr->extern_symbol = interns_lookup(ctx->interns, bound_sym);
    }
  } else if (decl_or_expr->op == ref_sym) {
    decl_or_expr->contributes_to_shape = true;
    decl_or_expr->contributes_to_layout = true;
    decl_or_expr->storage_residence = MORPHL_STORAGE_INSTANCE;
  }
}

static bool is_null_ref_type(const MorphlType* type) {
  return type && type->kind == MORPHL_TYPE_REF && type->data.ref.is_ref &&
         type->data.ref.target && type->data.ref.target->kind == MORPHL_TYPE_VOID;
}

static bool refs_assignable(const MorphlType* target_ref, const MorphlType* value_type) {
  if (!target_ref || target_ref->kind != MORPHL_TYPE_REF || !target_ref->data.ref.is_ref ||
      !value_type || value_type->kind != MORPHL_TYPE_REF || !value_type->data.ref.is_ref) {
    return false;
  }
  if (is_null_ref_type(value_type)) return true;
  return morphl_type_equals(target_ref->data.ref.target, value_type->data.ref.target);
}

static MorphlType* infer_extern_binding_type(TypeContext* ctx,
                                             AstNode* node,
                                             MorphlType* expected_type,
                                             Sym bound_sym) {
  if (!ctx || !node) return NULL;
  if (node->child_count == 1) {
    AstNode* arg = node->children[0];
    if (is_string_literal(ctx, arg)) {
      if (!expected_type) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                        "$extern with only a symbol name requires an expected type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      node->extern_symbol = string_literal_contents(arg);
      return expected_type;
    }
    node->extern_symbol = bound_sym ? interns_lookup(ctx->interns, bound_sym) : str_from("", 0);
    return arg ? arg->type : NULL;
  }
  if (node->child_count == 2) {
    AstNode* sym_node = node->children[0];
    AstNode* type_node = node->children[1];
    if (!is_string_literal(ctx, sym_node)) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                      "$extern expects string literal as first argument when two arguments are used");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    node->extern_symbol = string_literal_contents(sym_node);
    return type_node ? type_node->type : NULL;
  }
  MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                  "$extern expects 1 or 2 arguments");
  morphl_error_emit(NULL, &err);
  return NULL;
}

static void morphl_error_swallow(void* user, const MorphlError* err) {
  (void)user;
  (void)err;
}

// static void morphl_set_func_ret_type(TypeContext* ctx, MorphlType* func_type, MorphlType* ret_type) {
//   if (!ctx || !func_type || !ret_type) return;
  
  
//   if (func_type->data.func.return_type) {
//     if (!morphl_type_equals(func_type->data.func.return_type, ret_type)) {
//       MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "function return type mismatch");
//       morphl_error_emit(NULL, &err);
//     }
//     return;
//   }
//   // Set expected return type 
//   func_type->data.func.return_type = ret_type;
// }

// static void morphl_infer_func_ret_type(TypeContext* ctx, AstNode* body_node, MorphlType* func_type) {
//   if (!ctx || !body_node ) return;
  

//   // Traverse body to find return statements
//   for (size_t i = 0; i < body_node->child_count; ++i) {
//     AstNode* child = body_node->children[i];
//     if (!child) continue;
    
//     if (child->kind == AST_BUILTIN && child->op == operator_sym_from_enum(RET)) {
//       // debug print:
//       MorphlError err = MORPHL_ERR_AT(child, MORPHL_E_TYPE, "found return statement in function body");
//       morphl_error_emit(NULL, &err);
//       // Return statement
//       MorphlType* ret_type = NULL;
//       if (child->child_count > 0) {
//         ret_type = morphl_infer_type_of_ast(ctx, child->children[0]);
//       } else {
//         ret_type = morphl_type_void(ctx->arena);
//       }
//       if (ret_type) {
//         morphl_set_func_ret_type(ctx, func_type, ret_type);
//         // Debug print:
//         Str type_str = morphl_type_to_string(func_type, ctx->interns);
//         printf("Set function return type to: %.*s\n", (int)type_str.len, type_str.ptr);
//         free((void*)type_str.ptr);
//       }
//     } else if (child->kind == AST_IF || child->kind == AST_BLOCK || child->kind == AST_GROUP) {
//       // Recurse into blocks and if-statements
//       morphl_infer_func_ret_type(ctx, child, func_type);
//     }
//   }
// }


MorphlType* morphl_infer_type_for_op(TypeContext* ctx,
                                     const AstNode* node,
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
    MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "operator %s expects %llu-%llu args, got %llu",
            op_name, (unsigned long long)info->min_args, (unsigned long long)info->max_args, (unsigned long long)arg_count);
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Type inference by operator kind
  if (op_sym == interns_intern(ctx->interns, str_from("$extern", 7))) {
    MorphlType* expected_type = NULL;
    if (node && node->kind == AST_BUILTIN) {
      expected_type = infer_extern_binding_type(ctx, (AstNode*)node, NULL, 0);
      if (expected_type) return expected_type;
    }
    if (arg_count == 1 && arg_types[0]) return arg_types[0];
    if (arg_count == 2 && arg_types[1]) return arg_types[1];
    MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$extern expects type information");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$static", 7))) {
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$static expects 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return arg_types[0];
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$heap", 5))) {
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$heap expects 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* target = arg_types[0];
    MorphlType* inner_type;
    bool inherited_mutable;
    if (target->kind == MORPHL_TYPE_REF && !target->data.ref.is_ref) {
      inner_type = target->data.ref.target;
      inherited_mutable = target->data.ref.is_mutable;
    } else {
      inner_type = target;
      inherited_mutable = false;
    }
    MorphlType* ref_type =
        morphl_type_ref(ctx->arena, inner_type, inherited_mutable, false);
    if (ref_type) ref_type->data.ref.is_ref = true;
    return ref_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$free", 5))) {
    if (arg_count != 1 || !arg_types[0] || arg_types[0]->kind != MORPHL_TYPE_REF ||
        !arg_types[0]->data.ref.is_ref) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$free expects 1 reference argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_void(ctx->arena);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$defer", 6))) {
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$defer expects 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_void(ctx->arena);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$mut", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$const", 6)) ||
      op_sym == interns_intern(ctx->interns, str_from("$inline", 7))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s expects 1 arg, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: cannot infer argument type", op_name);
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
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$this: no active block scope");
      morphl_error_emit(NULL, &err);
    }
    return this_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$parent", 7))) {
    /* $parent: the block scope enclosing the current function.
     * Inside a function body, type_context_get_this() returns the block type
     * of the scope that contains the function (since AST_FUNC doesn't push_this),
     * which is exactly the $parent type. */
    MorphlType* parent_type = type_context_get_this(ctx);
    if (!parent_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$parent: no enclosing block scope");
      morphl_error_emit(NULL, &err);
    }
    return parent_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$file", 5))) {
    MorphlType* file_type = type_context_get_file(ctx);
    if (!file_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$file: file scope unavailable");
      morphl_error_emit(NULL, &err);
    }
    return file_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$global", 7))) {
    MorphlType* global_type = type_context_get_global(ctx);
    if (!global_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$global: global scope unavailable");
      morphl_error_emit(NULL, &err);
    }
    return global_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$ref", 4))) {
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$ref expects 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    /* When $ref targets a qualifier-ref ($mut x), unwrap it and inherit mutability.
     * This avoids double-wrapping: $ref($mut(i64)) → REF{is_mutable,is_ref}(i64)
     * not REF{is_ref}(REF{is_mutable}(i64)), so $set type checks work correctly. */
    MorphlType* target = arg_types[0];
    MorphlType* inner_type;
    bool inherited_mutable;
    if (target->kind == MORPHL_TYPE_REF && !target->data.ref.is_ref) {
      inner_type = target->data.ref.target;
      inherited_mutable = target->data.ref.is_mutable;
    } else {
      inner_type = target;
      inherited_mutable = false;
    }
    MorphlType* ref_type = morphl_type_ref(ctx->arena, inner_type, inherited_mutable, false);
    if (ref_type) {
      ref_type->data.ref.is_ref = true;
      /* $ref stores an 8-byte absolute stack address (i64). size/align=8 from morphl_type_ref(). */
    }
    // check if refernce is recursive
    if (node->children[0]->op == interns_intern(ctx->interns, str_from("$parent", 7))
        || node->children[0]->op == interns_intern(ctx->interns, str_from("$file", 5)) 
        || node->children[0]->op == interns_intern(ctx->interns, str_from("$this", 5))
        || node->children[0]->op == interns_intern(ctx->interns, str_from("$global", 7))) {
      ref_type->data.ref.is_recursive = true;
      ref_type->data.ref.recursive_sym = node->children[0]->op;
    }
    return ref_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$null", 5))) {
    MorphlType* void_t = morphl_type_void(ctx->arena);
    MorphlType* ref_type = void_t ? morphl_type_ref(ctx->arena, void_t, false, false) : NULL;
    if (ref_type) {
      ref_type->data.ref.is_ref = true;
      /* $null is the universal null storage handle. */
    }
    return ref_type;
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$new", 4))) {
    if (arg_count < 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$new expects 1 or 2 arguments");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    // $new re-executes a block, returning a fresh instance of the same type.
    // Optional 2nd arg is an initializer (group or block) that overrides fields;
    // the parent AST_DECL/AST_SET handler applies the overrides.
    return unwrap_ref(arg_types[0]);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$forward", 8))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward expects 1 arg, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: cannot infer stub type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (arg_types[0]->kind != MORPHL_TYPE_FUNC) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: stub must be a function");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return arg_types[0];
  }

  // Comparison operators: (any, any) → bool
  if (op_sym == interns_intern(ctx->interns, str_from("$req", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$rneq", 5))) {
    if (arg_count != 2 || !arg_types[0] || !arg_types[1] ||
        arg_types[0]->kind != MORPHL_TYPE_REF || !arg_types[0]->data.ref.is_ref ||
        arg_types[1]->kind != MORPHL_TYPE_REF || !arg_types[1]->data.ref.is_ref) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s expects 2 ref arguments", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_bool(ctx->arena);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$eq", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$neq", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lt", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$gt", 3)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lte", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$gte", 4))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "comparison %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!types_comparable(left, right)) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: types not compatible", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  // Logic operators: bool → bool (or (bool, bool) → bool for $and/$or)
  if (op_sym == interns_intern(ctx->interns, str_from("$and", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$or", 3))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "logic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    for (size_t i = 0; i < 2; ++i) {
      MorphlType* check = unwrap_ref(arg_types[i]);
      if (!check || (check->kind != MORPHL_TYPE_BOOL && check->kind != MORPHL_TYPE_INT)) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: arg %llu must be bool or int", op_name, (unsigned long long)(i + 1));
        morphl_error_emit(NULL, &err);
        return NULL;
      }
    }
    
    return morphl_type_bool(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$not", 4))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$not expects 1 arg, got %llu",
                                   (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* check = unwrap_ref(arg_types[0]);
    if (!check || (check->kind != MORPHL_TYPE_BOOL && check->kind != MORPHL_TYPE_INT)) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$not: argument must be bool or int");
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
      op_sym == interns_intern(ctx->interns, str_from("$div", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$mod", 4))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "arithmetic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_INT ||
        !right || right->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: both arguments must be int", op_name);
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
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "float arithmetic %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_FLOAT ||
        !right || right->kind != MORPHL_TYPE_FLOAT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: both arguments must be float", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_float(ctx->arena);
  }
  
  // Reference equality: ($ref T, $ref T) → bool
  if (op_sym == interns_intern(ctx->interns, str_from("$req", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$rneq", 5))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* left  = arg_types[0];
    MorphlType* right = arg_types[1];
    if (!left || left->kind != MORPHL_TYPE_REF ||
        !right || right->kind != MORPHL_TYPE_REF) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: both arguments must be $ref types", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_bool(ctx->arena);
  }

  // Bitwise operators: (int, int) → int
  if (op_sym == interns_intern(ctx->interns, str_from("$band", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$bor", 4)) ||
      op_sym == interns_intern(ctx->interns, str_from("$bxor", 5)) ||
      op_sym == interns_intern(ctx->interns, str_from("$lshift", 7)) ||
      op_sym == interns_intern(ctx->interns, str_from("$rshift", 7))) {
    
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "bitwise %s expects 2 args, got %llu", op_name, (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* left = unwrap_ref(arg_types[0]);
    MorphlType* right = unwrap_ref(arg_types[1]);
    if (!left || left->kind != MORPHL_TYPE_INT ||
        !right || right->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "%s: both arguments must be int", op_name);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_int(ctx->arena);
  }
  
  if (op_sym == interns_intern(ctx->interns, str_from("$bnot", 5))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$bnot expects 1 arg, got %llu",
                                   (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    MorphlType* check = unwrap_ref(arg_types[0]);
    if (!check || check->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$bnot: argument must be int");
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

  // Trait system
  if (op_sym == interns_intern(ctx->interns, str_from("$traits", 7))) {
    /* $traits { $prop... } — the arg is the traits block; return its type (MORPHL_TYPE_BLOCK
     * with $-prefixed prop fields). Callers can check kind == MORPHL_TYPE_BLOCK to find props. */
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$traits expects 1 block argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return arg_types[0];
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$exit", 5))) {
    if (arg_count != 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$exit: expects exactly 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* exit_arg = unwrap_ref(arg_types[0]);
    if (!exit_arg || exit_arg->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$exit: argument must be of type i32 (integer)");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_never(ctx->arena);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$impl", 5))) {
    /* $impl TraitA typeD [{ overrides }]
     * arg_types[0] = trait type, arg_types[1] = base type,
     * arg_types[2] = override block (optional). */
    if (arg_count < 2 || !arg_types[0] || !arg_types[1]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$impl expects at least 2 arguments (trait, base)");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* trait_type = unwrap_ref(arg_types[0]);
    MorphlType* base_type  = unwrap_ref(arg_types[1]);
    MorphlType* override_type = (arg_count >= 3) ? arg_types[2] : NULL;

    if (!trait_type || trait_type->kind != MORPHL_TYPE_BLOCK) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$impl: first argument must be a traits block");
      morphl_error_emit(NULL, &err);
      return NULL;
    }

    /* Verify override block types against trait property types */
    if (override_type && override_type->kind == MORPHL_TYPE_BLOCK) {
      for (size_t oi = 0; oi < override_type->data.block.prop_count; ++oi) {
        Sym oname = override_type->data.block.prop_names[oi];
        MorphlType* otype = override_type->data.block.prop_types[oi];
        /* Find matching trait property */
        bool found = false;
        for (size_t ti = 0; ti < trait_type->data.block.prop_count; ++ti) {
          if (trait_type->data.block.prop_names[ti] == oname) {
            found = true;
            if (!morphl_type_is_subtype(otype, trait_type->data.block.prop_types[ti])) {
              MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                  "$impl: property override type is incompatible with trait declaration");
              morphl_error_emit(NULL, &err);
              return NULL;
            }
            break;
          }
        }
        if (!found) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
              "$impl: override provides property not declared in trait");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
      }
    }

    /* Build result: base structural fields + merged props (trait defaults + overrides) */
    /* Merge: start with trait props, replace with override where provided */
    size_t total_props = trait_type->data.block.prop_count;
    Sym* merged_names = (Sym*)malloc(total_props * sizeof(Sym));
    MorphlType** merged_types = (MorphlType**)malloc(total_props * sizeof(MorphlType*));
    if (!merged_names || !merged_types) {
      free(merged_names); free(merged_types);
      return NULL;
    }
    for (size_t ti = 0; ti < trait_type->data.block.prop_count; ++ti) {
      merged_names[ti] = trait_type->data.block.prop_names[ti];
      merged_types[ti] = trait_type->data.block.prop_types[ti]; /* default */
      if (override_type && override_type->kind == MORPHL_TYPE_BLOCK) {
        for (size_t oi = 0; oi < override_type->data.block.prop_count; ++oi) {
          if (override_type->data.block.prop_names[oi] == merged_names[ti]) {
            merged_types[ti] = override_type->data.block.prop_types[oi];
            break;
          }
        }
      }
    }
    MorphlType* result = morphl_type_block_with_props(
        ctx->arena,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.field_names : NULL,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.field_types : NULL,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.field_count : 0,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.field_storage : NULL,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.layout_field_names : NULL,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.layout_field_types : NULL,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.layout_field_count : 0,
        base_type->kind == MORPHL_TYPE_BLOCK ? base_type->data.block.layout_field_storage : NULL,
        merged_names, merged_types, NULL, total_props);
    free(merged_names);
    free(merged_types);
    return result;
  }

  // Function definition: $func produces a function type
  if (op_sym == interns_intern(ctx->interns, str_from("$func", 5))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$func expects 2 args, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    // First arg: parameter type(s)
    MorphlType* param_type = arg_types[0];
    if (!param_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$func: cannot infer parameter type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    // Second arg: return type
    MorphlType* return_type = arg_types[1];
    if (!return_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$func: cannot infer return type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    
    return morphl_type_func(ctx->arena, param_type, return_type);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$ret", 4))) {
    if (arg_count != 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$ret expects 1 arg, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }

    MorphlType* ret_type = arg_types[0];
    if (!ctx->expected_return_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$ret: not inside a function");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (ret_type && ret_type->kind != MORPHL_TYPE_UNKNOWN) {
      MorphlType* current_func = type_context_get_current_func(ctx);
      if (ctx->expected_return_type->kind == MORPHL_TYPE_UNKNOWN) {
        MorphlType* concrete_ret = unwrap_ref(ret_type);
        type_context_set_return_type(ctx, concrete_ret);
        if (current_func && current_func->kind == MORPHL_TYPE_FUNC) {
          current_func->data.func.return_type = concrete_ret;
        }
      } else if (!morphl_type_equals(unwrap_ref(ret_type), unwrap_ref(ctx->expected_return_type))) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "return type mismatch: expected different type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
    }
    
    return morphl_type_never(ctx->arena);
  }

  if (op_sym == interns_intern(ctx->interns, str_from("$call", 5))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$call expects 2 args, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    // Function call: first arg is function type
    MorphlType* func_type = unwrap_ref(arg_types[0]);
    // Unwrap a single-element GROUP (e.g. callee wrapped in parentheses: ($member v $greet))
    if (func_type && func_type->kind == MORPHL_TYPE_GROUP &&
        func_type->data.group.elem_count == 1) {
      func_type = unwrap_ref(func_type->data.group.elem_types[0]);
    }
    if (!func_type || func_type->kind != MORPHL_TYPE_FUNC) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$call: first argument must be a function");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return func_type->data.func.return_type;
  }

  // if: $if <cond> <then> [else]  (2 or 3 args)
  if (op_sym == interns_intern(ctx->interns, str_from("$if", 3))) {
    if (arg_count < 2 || arg_count > 3) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$if expects 2-3 args, got %llu", (unsigned long long)arg_count);
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* cond_type = unwrap_ref(arg_types[0]);
    if (!is_truthy_condition_type(cond_type)) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$if: condition must be bool or int");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* then_type = arg_types[1];
    MorphlType* else_type = (arg_count == 3) ? arg_types[2] : NULL;
    /* No else branch → void */
    if (!else_type) return morphl_type_void(ctx->arena);
    /* One branch is $never (divergent) → return the other */
    if (then_type && then_type->kind == MORPHL_TYPE_NEVER) return else_type;
    if (else_type && else_type->kind == MORPHL_TYPE_NEVER) return then_type;
    /* Same type on both branches → return it */
    if (then_type && else_type && morphl_type_equals(then_type, else_type)) return then_type;
    /* Different types → union */
    if (then_type && else_type) {
      MorphlType* variants[2] = { then_type, else_type };
      return morphl_type_union(ctx->arena, variants, 2);
    }
    return then_type ? then_type : else_type;
  }

  
  
  // $array elem-type count — fixed-size array
  if (op_sym == interns_intern(ctx->interns, str_from("$array", 6))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$array: expects 2 arguments");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* elem_type = arg_types[0];
    if (!elem_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$array: cannot resolve element type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    /* Parse count from the literal node */
    AstNode* cnt_arg = (node && node->child_count >= 2) ? node->children[1] : NULL;
    if (!cnt_arg || cnt_arg->kind != AST_LITERAL) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$array: count must be an integer literal");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    char cbuf[32];
    size_t clen = cnt_arg->value.len < sizeof(cbuf) - 1 ? cnt_arg->value.len : sizeof(cbuf) - 1;
    memcpy(cbuf, cnt_arg->value.ptr, clen); cbuf[clen] = '\0';
    char* cend = NULL;
    long long count = strtoll(cbuf, &cend, 10);
    if (cend == cbuf || count <= 0) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$array: count must be a positive integer");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_array(ctx->arena, elem_type, (size_t)count);
  }

  // $index array i — element access; returns elem_type
  if (op_sym == interns_intern(ctx->interns, str_from("$index", 6))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$index: expects 2 arguments");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    const MorphlType* arr_type = arg_types[0];
    while (arr_type && arr_type->kind == MORPHL_TYPE_REF && !arr_type->data.ref.is_ref)
      arr_type = arr_type->data.ref.target;
    if (!arr_type || arr_type->kind != MORPHL_TYPE_ARRAY) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$index: first argument must be an array");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!arg_types[1] || arg_types[1]->kind != MORPHL_TYPE_INT) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$index: index must be integer");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return arr_type->data.array.elem_type;
  }

  // $union V1 V2 ... — tagged union type
  if (op_sym == interns_intern(ctx->interns, str_from("$union", 6))) {
    if (arg_count < 1) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$union: expects at least 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    /* Resolve variant types structurally from the inferred arg types */
    MorphlType** vtypes = (MorphlType**)arena_push(ctx->arena, NULL, arg_count * sizeof(MorphlType*));
    if (!vtypes) return NULL;
    for (size_t i = 0; i < arg_count; ++i) {
      MorphlType* vt = arg_types[i];
      if (!vt) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$union: cannot resolve variant type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      vtypes[i] = vt;
    }
    return morphl_type_union(ctx->arena, vtypes, arg_count);
  }

  // $as expr TargetType — reinterpret cast; result type is the target type
  if (op_sym == interns_intern(ctx->interns, str_from("$as", 3))) {
    if (arg_count != 2) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$as: expects 2 arguments");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    MorphlType* target_type = arg_types[1];
    if (!target_type) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$as: cannot resolve target type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return target_type;
  }

  // $new TypeExpr [init] — instantiates any type; returns the type of TypeExpr
  if (op_sym == interns_intern(ctx->interns, str_from("$new", 4))) {
    if (arg_count < 1 || !arg_types[0]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$new: expects at least 1 argument");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    // The base type is the type of arg[0] (the template/type expression).
    // For primitive templates: $new 0 55 → base = INT; for named types: $new Shape val → base = Shape's type.
    MorphlType* base = unwrap_ref(arg_types[0]);
    if (!base) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$new: cannot resolve base type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    // For 2-arg form, verify init is compatible with base type
    if (arg_count == 2 && arg_types[1]) {
      MorphlType* init_t = unwrap_ref(arg_types[1]);
      // For union base: init must be a variant subtype
      if (base->kind == MORPHL_TYPE_UNION) {
        if (!morphl_type_is_subtype(init_t, base)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$new: init type is not a subtype of union");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
      }
      // For other types: structural subtype or same type
      else if (!morphl_type_is_subtype(init_t, base) && !morphl_type_equals(init_t, base)) {
        // Warn but don't fail — $new is permissive (reinterpret-like)
        MorphlError err = MORPHL_WARN_AT(node, MORPHL_E_TYPE, "$new: init type may not be compatible with base type");
        morphl_error_emit(NULL, &err);
      }
    }
    return base;
  }

  // $never — bottom type
  if (op_sym == interns_intern(ctx->interns, str_from("$never", 6))) {
    return morphl_type_never(ctx->arena);
  }

  // $while cond body — loop expression; always produces void
  if (op_sym == interns_intern(ctx->interns, str_from("$while", 6))) {
    if (arg_count != 2 || !arg_types[0] || !arg_types[1]) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$while expects 2 arguments");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!is_truthy_condition_type(arg_types[0])) {
      MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$while: condition must be bool or int");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return morphl_type_void(ctx->arena);
  }

  // $break / $continue — divergent control flow; type is $never (bottom)
  if (op_sym == interns_intern(ctx->interns, str_from("$break", 6)) ||
      op_sym == interns_intern(ctx->interns, str_from("$continue", 9))) {
    return morphl_type_never(ctx->arena);
  }

  // Unknown or untyped operator
  MorphlError err = MORPHL_WARN_AT(node, MORPHL_E_TYPE, "type inference not implemented for %s", op_name);
  morphl_error_emit(NULL, &err);
  return morphl_type_void(ctx->arena);
}

static MorphlType* morphl_infer_type_of_ast_inner(TypeContext* ctx, AstNode* node) {
  if (!ctx || !node) return NULL;
  
  switch (node->kind) {
    case AST_PROP:
    // for property, we can use logic of decl but prefix the name with $.
    case AST_DECL: {
      if (node->child_count < 2) return NULL;
      AstNode* name_node = node->children[0];
      AstNode* init_node = node->children[1];
      if (node->kind == AST_PROP) {
        // For property, we treat it as declaration of a variable with name prefixed by '$'.
        if (!name_node || name_node->kind != AST_IDENT) return NULL;
        Str prop_name_str = interns_lookup(ctx->interns, name_node->op);
        if (!prop_name_str.ptr) {
          prop_name_str = name_node->value;
        }
        if (!prop_name_str.ptr) return NULL;
        Str var_name_str = str_concat(ctx->arena, str_from("$", 1), prop_name_str);
        // printf("Declaring property '%.*s' as variable '%.*s'\n", (int)prop_name_str.len, prop_name_str.ptr, (int)var_name_str.len, var_name_str.ptr);
        Sym var_sym = interns_intern(ctx->interns, var_name_str);
        if (!var_sym) return NULL;
        name_node->op = var_sym; // Update the name node to use the new symbol with '$' prefix
        name_node->value = var_name_str; // Update the name node's value to the new string with '$' prefix
      }
      if (!name_node || name_node->kind != AST_IDENT) return NULL;
      Sym var_sym = name_node->op;
      if (!var_sym && name_node->value.ptr) {
        var_sym = interns_intern(ctx->interns, name_node->value);
      }
      if (!var_sym) return NULL;
      if (!init_node) return NULL;
      set_storage_defaults(node);
      Sym forward_sym = interns_intern(ctx->interns, str_from("$forward", 8));
      if (init_node->kind == AST_BUILTIN && init_node->op == forward_sym) {
        if (init_node->child_count != 1) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: expected 1 stub expression");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* stub_node = init_node->children[0];
        MorphlType* stub_type = morphl_infer_type_of_ast(ctx, stub_node);
        if (!stub_type) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: cannot infer stub type");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (type_context_check_duplicate_var(ctx, var_sym)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: variable already declared");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (!type_context_define_forward(ctx, var_sym, stub_type)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: duplicate stub in scope");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        apply_storage_metadata(ctx, stub_node, var_sym, stub_type);
        node->contributes_to_shape = stub_node->contributes_to_shape;
        node->contributes_to_layout = stub_node->contributes_to_layout;
        node->storage_is_mutable = stub_node->storage_is_mutable;
        node->storage_residence = stub_node->storage_residence;
        node->extern_symbol = default_extern_symbol(stub_node);
        type_context_define_var(ctx, var_sym, stub_type);
        if (stub_type->kind == MORPHL_TYPE_FUNC) {
          type_context_define_func(ctx, var_sym, stub_type);
        }
        return stub_type;
      }
      bool declared_placeholder = false;
      if (init_node->kind == AST_FUNC ||
          (init_node->kind == AST_BUILTIN && init_node->op &&
           strcmp(op_name_str(init_node->op, ctx->interns), "$func") == 0)) {
        MorphlType* placeholder = morphl_type_func(ctx->arena,
                                                  morphl_type_unknown(ctx->arena),
                                                  morphl_type_unknown(ctx->arena));
        type_context_define_func(ctx, var_sym, placeholder);
        type_context_define_var(ctx, var_sym, placeholder);
        declared_placeholder = true;
        type_context_set_pending_func(ctx, placeholder);
      }

      MorphlType* init_type = NULL;
      Sym extern_sym = interns_intern(ctx->interns, str_from("$extern", 7));
      ForwardEntry* pending_forward = type_context_lookup_forward(ctx, var_sym);
      MorphlType* expected_type = NULL;
      if (pending_forward && !pending_forward->resolved) {
        expected_type = pending_forward->type;
      } else if (type_context_check_duplicate_var(ctx, var_sym)) {
        expected_type = type_context_lookup_var(ctx, var_sym);
      }
      if (init_node->kind == AST_BUILTIN && init_node->op == extern_sym) {
        if (init_node->child_count > 0) {
          for (size_t i = 0; i < init_node->child_count; ++i) {
            if (!init_node->children[i]) continue;
            init_node->children[i]->type = morphl_infer_type_of_ast(ctx, init_node->children[i]);
          }
        }
        init_type = infer_extern_binding_type(ctx, init_node, expected_type, var_sym);
      } else {
        init_type = morphl_infer_type_of_ast(ctx, init_node);
      }
      if (declared_placeholder) {
        type_context_set_pending_func(ctx, NULL);
      }
      if (!init_type) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$decl: cannot infer variable type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      Str decl_name = interns_lookup(ctx->interns, var_sym);
      if (decl_name.len == 4 && memcmp(decl_name.ptr, "main", 4) == 0) {
        MorphlType* current_this = type_context_get_this(ctx);
        bool is_toplevel_decl =
            (ctx->file_type == NULL && current_this == NULL) ||
            (ctx->file_type != NULL && current_this == ctx->file_type);
        if (!is_toplevel_decl) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                          "'main' must be declared at top level");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (!is_main_signature(init_type)) {
          MorphlError err = MORPHL_ERR_AT(
              node, MORPHL_E_TYPE,
              "'main' must have signature () => i32 with no explicit arguments");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
      }

      apply_storage_metadata(ctx, init_node, var_sym, init_type);
      node->contributes_to_shape = init_node->contributes_to_shape;
      node->contributes_to_layout = init_node->contributes_to_layout;
      node->storage_is_mutable = init_node->storage_is_mutable;
      node->storage_residence = init_node->storage_residence;
      node->extern_symbol = default_extern_symbol(init_node);

      if (decl_name.len == 4 && memcmp(decl_name.ptr, "main", 4) == 0 &&
          node->storage_residence == MORPHL_STORAGE_STATIC) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                        "'main' cannot use $static storage");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      ForwardEntry* forward = pending_forward;
      if (forward && !forward->resolved) {
        if (!type_context_define_forward_body(ctx, var_sym, init_type)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: definition mismatch for stub");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return init_type;
      } else if (forward && forward->resolved) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$forward: multiple bodies for stub");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      if (declared_placeholder) {
        (void)type_context_update_var(ctx, var_sym, init_type);
        (void)type_context_update_func(ctx, var_sym, init_type);
        return init_type;
      }

      bool dup = type_context_check_duplicate_var(ctx, var_sym);
      if (dup) {
        MorphlType* existing = type_context_lookup_var(ctx, var_sym);
        if (!existing || !morphl_type_equals(existing, init_type)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$decl: variable already declared");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return existing;
      }
      // Default to const: $decl without explicit qualifier marks the binding const.
      // The stored type is always init_type as-is; constness is tracked via is_const flag.
      // This keeps ref types transparent unless explicitly captured via $ref.
      if (node->kind == AST_DECL) {
        if (!node->storage_is_mutable) {
          type_context_define_const_var(ctx, var_sym, init_type);
        } else {
          type_context_define_var(ctx, var_sym, init_type);
        }
      } else {
        type_context_define_var(ctx, var_sym, init_type);
      }
      return init_type;
    }

    case AST_GROUP: {
      size_t count = node->child_count;
      /* A single-element group is a parenthesized expression — transparent. */
      if (count == 1) {
        return morphl_infer_type_of_ast(ctx, node->children[0]);
      }
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

    case AST_FILE:
    case AST_BLOCK: {
      if (!type_context_push_scope(ctx)) return NULL;
      MorphlType* block_type = morphl_type_block(ctx->arena, NULL, NULL, 0);
      if (!block_type || !type_context_push_this(ctx, block_type)) {
        type_context_pop_scope(ctx);
        return NULL;
      }
      bool pushed_file = false;
      if (node->kind == AST_FILE) {
        if (ctx->file_type) {
          if (!type_context_push_file(ctx, block_type)) {
            type_context_pop_this(ctx);
            type_context_pop_scope(ctx);
            return NULL;
          }
          pushed_file = true;
        } else {
          ctx->file_type = block_type;
        }
        if (!ctx->global_type) {
          refresh_file_intrinsics(ctx, node, block_type,
                                  NULL, NULL, NULL, 0,
                                  NULL, NULL, NULL, 0,
                                  0);
          refresh_global_type(ctx, node, block_type, 0);
        }
      } else if (!ctx->file_type) {
        ctx->file_type = block_type;
      }
      if (!ctx->global_type) {
        if (node->kind == AST_BLOCK) {
          /* AST_BLOCK (not a top-level file): use the block itself as $global */
          ctx->global_type = block_type;
          goto skip_global;
        }
      }
      skip_global:;
      Sym* field_names = NULL;
      MorphlType** field_types = NULL;
      size_t field_count = 0;
      size_t field_cap = 0;
      MorphlMemberStorage* field_storage = NULL;
      Sym* layout_field_names = NULL;
      MorphlType** layout_field_types = NULL;
      MorphlMemberStorage* layout_field_storage = NULL;
      size_t layout_field_count = 0;
      size_t layout_field_cap = 0;
      Sym* prop_names = NULL;
      MorphlType** prop_types = NULL;
      AstNode** prop_values = NULL;  /* value AST nodes for compile-time substitution */
      size_t prop_count = 0;
      size_t prop_cap = 0;
      bool ok = true;
      for (size_t i = 0; i < node->child_count; ++i) {
        AstNode* stmt = node->children[i];
        MorphlType* stmt_type = morphl_infer_type_of_ast(ctx, stmt);
        if (!stmt_type) { ok = false; break; }
        if (!stmt || stmt->child_count < 1) continue;

        bool is_decl = (stmt->kind == AST_DECL);
        bool is_prop = (stmt->kind == AST_PROP);
        if (!is_decl && !is_prop) continue;

        AstNode* name_node = stmt->children[0];
        if (!name_node) { ok = false; break; }
        if (!name_node->op && name_node->value.ptr) {
          name_node->op = interns_intern(ctx->interns, name_node->value);
        }
        if (!name_node->op) { ok = false; break; }

        if (is_decl) {
          if (stmt->contributes_to_shape) {
            if (field_count >= field_cap) {
              size_t new_cap = field_cap ? field_cap * 2 : 4;
              Sym* new_names = (Sym*)realloc(field_names, new_cap * sizeof(Sym));
              MorphlType** new_types = (MorphlType**)realloc(field_types, new_cap * sizeof(MorphlType*));
              MorphlMemberStorage* new_storage =
                (MorphlMemberStorage*)realloc(field_storage, new_cap * sizeof(MorphlMemberStorage));
              if (!new_names || !new_types || !new_storage) { ok = false; break; }
              field_names = new_names;
              field_types = new_types;
              field_storage = new_storage;
              field_cap = new_cap;
            }
            field_names[field_count] = name_node->op;
            field_types[field_count] = stmt_type;
            field_storage[field_count] = morphl_member_storage_make(
              stmt->contributes_to_shape,
              stmt->contributes_to_layout,
              stmt->storage_is_mutable,
              stmt->storage_residence);
            field_count++;
          }
          if (stmt->contributes_to_layout) {
            if (layout_field_count >= layout_field_cap) {
              size_t new_cap = layout_field_cap ? layout_field_cap * 2 : 4;
              Sym* new_names = (Sym*)realloc(layout_field_names, new_cap * sizeof(Sym));
              MorphlType** new_types =
                (MorphlType**)realloc(layout_field_types, new_cap * sizeof(MorphlType*));
              MorphlMemberStorage* new_storage =
                (MorphlMemberStorage*)realloc(layout_field_storage, new_cap * sizeof(MorphlMemberStorage));
              if (!new_names || !new_types || !new_storage) { ok = false; break; }
              layout_field_names = new_names;
              layout_field_types = new_types;
              layout_field_storage = new_storage;
              layout_field_cap = new_cap;
            }
            layout_field_names[layout_field_count] = name_node->op;
            layout_field_types[layout_field_count] = stmt_type;
            layout_field_storage[layout_field_count] = morphl_member_storage_make(
              stmt->contributes_to_shape,
              stmt->contributes_to_layout,
              stmt->storage_is_mutable,
              stmt->storage_residence);
            layout_field_count++;
          }
          Sym* names = field_count ? (Sym*)arena_push(ctx->arena, NULL, field_count * sizeof(Sym)) : NULL;
          MorphlType** types = field_count
            ? (MorphlType**)arena_push(ctx->arena, NULL, field_count * sizeof(MorphlType*)) : NULL;
          MorphlMemberStorage* storage = field_count
            ? (MorphlMemberStorage*)arena_push(ctx->arena, NULL, field_count * sizeof(MorphlMemberStorage)) : NULL;
          Sym* layout_names = layout_field_count
            ? (Sym*)arena_push(ctx->arena, NULL, layout_field_count * sizeof(Sym)) : NULL;
          MorphlType** layout_types = layout_field_count
            ? (MorphlType**)arena_push(ctx->arena, NULL, layout_field_count * sizeof(MorphlType*)) : NULL;
          MorphlMemberStorage* layout_storage = layout_field_count
            ? (MorphlMemberStorage*)arena_push(ctx->arena, NULL, layout_field_count * sizeof(MorphlMemberStorage)) : NULL;
          if ((field_count && (!names || !types || !storage)) ||
              (layout_field_count && (!layout_names || !layout_types || !layout_storage))) {
            ok = false;
            break;
          }
          if (field_count) {
            memcpy(names, field_names, field_count * sizeof(Sym));
            memcpy(types, field_types, field_count * sizeof(MorphlType*));
            memcpy(storage, field_storage, field_count * sizeof(MorphlMemberStorage));
          }
          if (layout_field_count) {
            memcpy(layout_names, layout_field_names, layout_field_count * sizeof(Sym));
            memcpy(layout_types, layout_field_types, layout_field_count * sizeof(MorphlType*));
            memcpy(layout_storage, layout_field_storage,
                   layout_field_count * sizeof(MorphlMemberStorage));
          }
          block_type->data.block.field_names = names;
          block_type->data.block.field_types = types;
          block_type->data.block.field_storage = storage;
          block_type->data.block.field_count = field_count;
          block_type->data.block.layout_field_names = layout_names;
          block_type->data.block.layout_field_types = layout_types;
          block_type->data.block.layout_field_storage = layout_storage;
          block_type->data.block.layout_field_count = layout_field_count;
          if (node->kind == AST_FILE) {
            refresh_file_intrinsics(ctx, node, block_type,
                                    names, types, storage, field_count,
                                    layout_names, layout_types, layout_storage, layout_field_count,
                                    i + 1);
            refresh_global_type(ctx, node, block_type, i + 1);
          }
        } else {
          // Property — does NOT participate in structural subtyping (SPEC §9.2)
          // Resolved at compile time via $member (static substitution).
          if (prop_count >= prop_cap) {
            size_t new_cap = prop_cap ? prop_cap * 2 : 4;
            Sym* new_names = (Sym*)realloc(prop_names, new_cap * sizeof(Sym));
            MorphlType** new_types = (MorphlType**)realloc(prop_types, new_cap * sizeof(MorphlType*));
            AstNode** new_values = (AstNode**)realloc(prop_values, new_cap * sizeof(AstNode*));
            if (!new_names || !new_types || !new_values) { ok = false; break; }
            prop_names = new_names;
            prop_types = new_types;
            prop_values = new_values;
            prop_cap = new_cap;
          }
          // The value node is the second child of the $prop AST node (stmt->children[1]).
          AstNode* val_node = (stmt->child_count >= 2) ? stmt->children[1] : NULL;
          prop_names[prop_count] = name_node->op;
          prop_types[prop_count] = stmt_type;
          prop_values[prop_count] = val_node;
          prop_count++;
          Sym* pnames = (Sym*)arena_push(ctx->arena, NULL, prop_count * sizeof(Sym));
          MorphlType** ptypes = (MorphlType**)arena_push(ctx->arena, NULL, prop_count * sizeof(MorphlType*));
          AstNode** pvals  = (AstNode**)arena_push(ctx->arena, NULL, prop_count * sizeof(AstNode*));
          if (!pnames || !ptypes || !pvals) { ok = false; break; }
          memcpy(pnames, prop_names, prop_count * sizeof(Sym));
          memcpy(ptypes, prop_types, prop_count * sizeof(MorphlType*));
          memcpy(pvals,  prop_values, prop_count * sizeof(AstNode*));
          block_type->data.block.prop_names  = pnames;
          block_type->data.block.prop_types  = ptypes;
          block_type->data.block.prop_values = pvals;
          block_type->data.block.prop_count  = prop_count;
        }
      }
      type_context_pop_this(ctx);
      if (pushed_file) {
        type_context_pop_file(ctx);
      }
      type_context_pop_scope(ctx);
      free(field_names);
      free(field_types);
      free(field_storage);
      free(layout_field_names);
      free(layout_field_types);
      free(layout_field_storage);
      free(prop_names);
      free(prop_types);
      free(prop_values);
      return ok ? block_type : NULL;
    }
    case AST_FUNC: {
      AstNode* param_expr = node->children[0];   // Parameter expression
      AstNode* func_body = node->children[1];    // Function body expression
      
      if (!param_expr || !func_body) return NULL;
      
      // Create a new scope for the function body
      type_context_push_scope(ctx);
      
      // Process parameter expression to register declarations in the new scope
      // This evaluates the parameter expression, which will trigger $decl preprocessor actions
      // that register variables in the current scope
      MorphlType* param_type = morphl_infer_type_of_ast(ctx, param_expr);
      if (!param_type) {
        // If we can't infer the parameter type, still pop the scope but return error
        type_context_pop_scope(ctx);
        MorphlError err = MORPHL_ERR_AT(param_expr, MORPHL_E_TYPE, "$func: cannot infer parameter type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      
      MorphlType* current_func = type_context_take_pending_func(ctx);
      if (!current_func) {
        current_func = morphl_type_func(ctx->arena, param_type, morphl_type_unknown(ctx->arena));
      } else if (current_func->kind == MORPHL_TYPE_FUNC && current_func->data.func.param_count > 0) {
        current_func->data.func.param_types[0] = param_type;
      }
      if (!current_func || !type_context_push_func(ctx, current_func)) {
        type_context_pop_scope(ctx);
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$func: cannot establish function context");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      // Set expected return type to UNKNOWN initially
      // This allows $ret to establish the return type on first encounter
      // and enables recursion (recursive call sees UNKNOWN matching UNKNOWN)
      type_context_set_return_type(ctx, current_func->data.func.return_type);
      
      // Infer return type from function body in the pseudo-scope
      // The body has access to variables declared in the parameter expression
      // If $ret is used, it will establish/validate the return type
      MorphlType* body_type = morphl_infer_type_of_ast(ctx, func_body);
      if (!body_type) {
        type_context_pop_func(ctx);
        type_context_pop_scope(ctx);
        type_context_set_return_type(ctx, NULL);
        MorphlError err = MORPHL_ERR_AT(func_body, MORPHL_E_TYPE, "$func: cannot infer body type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      
      // Get the return type that was established during body inference
      MorphlType* return_type = type_context_get_return_type(ctx);
      
      // If return type is still UNKNOWN (no $ret was used), use body type
      if (return_type && return_type->kind == MORPHL_TYPE_UNKNOWN) {
        return_type = body_type;
      }
      
      if (!return_type) {
        type_context_pop_func(ctx);
        type_context_pop_scope(ctx);
        type_context_set_return_type(ctx, NULL);
        MorphlError err = MORPHL_ERR_AT(func_body, MORPHL_E_TYPE, "$func: cannot determine return type");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      current_func->data.func.return_type = return_type;
      
      // Pop the pseudo-scope
      type_context_pop_func(ctx);
      type_context_pop_scope(ctx);
      
      // Clear return type after function
      type_context_set_return_type(ctx, NULL);
      
      // Create function type with 1 parameter (the parameter expression)
      // The parameter type represents what the function accepts
      return morphl_type_func(ctx->arena, param_type, return_type);
    }

    case AST_BUILTIN:
    case AST_CALL:
    case AST_IF:
    case AST_SET: {
      if (!node->op) return NULL;
      Sym idtstr_sym = interns_intern(ctx->interns, str_from("$idtstr", 7));
      Sym strtid_sym = interns_intern(ctx->interns, str_from("$strtid", 7));
      Sym member_sym = interns_intern(ctx->interns, str_from("$member", 7));
      Sym set_sym = interns_intern(ctx->interns, str_from("$set", 4));
      Sym import_sym = interns_intern(ctx->interns, str_from("$import", 7));
      Sym extern_sym = interns_intern(ctx->interns, str_from("$extern", 7));
      if (node->op == import_sym) {
        if (node->child_count != 1) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$import expects 1 arg");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* module_node =
            node->children[0] ? node->children[0]->import_module : NULL;
        if (!module_node) return NULL;
        if (!type_context_push_file(ctx, NULL)) {
          return NULL;
        }
        if (!type_context_push_global(ctx, NULL)) {
          type_context_pop_file(ctx);
          return NULL;
        }
        MorphlType* module_type = morphl_infer_type_of_ast(ctx, module_node);
        type_context_pop_global(ctx);
        type_context_pop_file(ctx);
        if (!module_type || module_type->kind != MORPHL_TYPE_BLOCK) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$import: module must be a block");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return module_type;
      }
      if (node->op == idtstr_sym) {
        if (node->child_count != 1) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$idtstr expects 1 arg");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* arg = node->children[0];
        if (!arg || arg->kind != AST_IDENT) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$idtstr expects identifier");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return morphl_type_string(ctx->arena);
      }
      if (node->op == strtid_sym) {
        if (node->child_count != 1) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$strtid expects 1 arg");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* arg = node->children[0];
        if (!arg || arg->kind != AST_LITERAL || arg->value.len < 2 ||
            arg->value.ptr[0] != '"' || arg->value.ptr[arg->value.len - 1] != '"') {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$strtid expects string literal");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        return morphl_type_ident(ctx->arena);
      }
      if (node->op == member_sym) {
        if (node->child_count != 2) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$member expects 2 args");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        AstNode* target = node->children[0];
        AstNode* field_node = node->children[1];
        /* field_node can be AST_IDENT (user identifiers) or AST_BUILTIN ($-prefixed names
         * like $argc, $modules, etc. used in $global field access) */
        if (!field_node || (field_node->kind != AST_IDENT && field_node->kind != AST_BUILTIN)) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$member expects identifier field");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        MorphlType* target_type = morphl_infer_type_of_ast(ctx, target);
        if (!target_type) return NULL;
        target_type = unwrap_ref(target_type);
        if (!target_type) return NULL;

        /* resolve field name */
        Sym field_sym = field_node->op;
        if (!field_sym && field_node->value.ptr) {
          field_sym = interns_intern(ctx->interns, field_node->value);
        }
        Str field_name = field_sym ? interns_lookup(ctx->interns, field_sym) : (Str){NULL, 0};

        /* compiler-injected compile-time intrinsics: $$name, $$size, $$type
         * Valid for any expression type; do NOT require block/union target.
         * The target expression is NOT evaluated at runtime (pure compile-time). */
        bool _is_cname = field_name.len == 6 && memcmp(field_name.ptr, "$$name", 6) == 0;
        bool _is_csize = field_name.len == 6 && memcmp(field_name.ptr, "$$size", 6) == 0;
        bool _is_ctype = field_name.len == 6 && memcmp(field_name.ptr, "$$type", 6) == 0;
        bool _is_cop = field_name.len == 4 && memcmp(field_name.ptr, "$$op", 4) == 0;
        bool _is_cpath = field_name.len == 6 && memcmp(field_name.ptr, "$$path", 6) == 0;
        bool _is_cdelim = field_name.len == 7 && memcmp(field_name.ptr, "$$delim", 7) == 0;
        bool _is_cversion = field_name.len == 9 && memcmp(field_name.ptr, "$$version", 9) == 0;
        bool _is_cline = field_name.len == 6 && memcmp(field_name.ptr, "$$line", 6) == 0;
        bool _is_ccol = field_name.len == 5 && memcmp(field_name.ptr, "$$col", 5) == 0;
        bool _is_csyntax = field_name.len == 8 && memcmp(field_name.ptr, "$$syntax", 8) == 0;
        if (_is_csyntax) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
                                          "$$syntax is reserved and not implemented");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        if (_is_cname || _is_csize || _is_ctype || _is_cop || _is_cpath ||
            _is_cdelim || _is_cversion || _is_cline || _is_ccol) {
            /* Infer target type so target->type is populated for vm.c code emission. */
            morphl_infer_type_of_ast(ctx, target);
            return (_is_csize || _is_cline || _is_ccol)
                     ? morphl_type_int(ctx->arena)
                     : morphl_type_string(ctx->arena);
        }

        /* compiler-injected $$data / $$tag fields on union types */
        if (target_type->kind == MORPHL_TYPE_UNION) {
          if (field_name.len == 6 && memcmp(field_name.ptr, "$$data", 6) == 0) {
            /* payload region — expose as empty block type (top of block hierarchy);
             * callers use $as to narrow to a concrete variant */
            return morphl_type_block(ctx->arena, NULL, NULL, 0);
          }
          if (field_name.len == 5 && memcmp(field_name.ptr, "$$tag", 5) == 0) {
            return morphl_type_int(ctx->arena);
          }
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE,
              "$member: union only supports $$data and $$tag fields");
          morphl_error_emit(NULL, &err);
          return NULL;
        }

        if (target_type->kind != MORPHL_TYPE_BLOCK) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$member: target must be block or union");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        for (size_t i = 0; i < target_type->data.block.field_count; ++i) {
          if (target_type->data.block.field_names[i] == field_sym) {
            return target_type->data.block.field_types[i];
          }
        }
        /* Also check props (trait methods accessible via $member on trait-typed variables) */
        for (size_t i = 0; i < target_type->data.block.prop_count; ++i) {
          if (target_type->data.block.prop_names &&
              target_type->data.block.prop_names[i] == field_sym) {
            return target_type->data.block.prop_types ? target_type->data.block.prop_types[i] : NULL;
          }
        }
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$member: field not found");
        morphl_error_emit(NULL, &err);
        return NULL;
      }
      if (node->op == set_sym) {
        if (node->child_count != 2) {
          MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set expects 2 args");
          morphl_error_emit(NULL, &err);
          return NULL;
        }
        MorphlType* target_type = morphl_infer_type_of_ast(ctx, node->children[0]);
        MorphlType* value_type = NULL;
        if (target_type && node->children[1] && node->children[1]->kind == AST_BUILTIN &&
            node->children[1]->op == extern_sym) {
          AstNode* extern_node = node->children[1];
          MorphlType* extern_expected =
            (target_type->kind == MORPHL_TYPE_REF) ? target_type->data.ref.target : target_type;
          for (size_t i = 0; i < extern_node->child_count; ++i) {
            if (!extern_node->children[i]) continue;
            extern_node->children[i]->type = morphl_infer_type_of_ast(ctx, extern_node->children[i]);
          }
          value_type = infer_extern_binding_type(ctx, extern_node, extern_expected, 0);
          apply_storage_metadata(ctx, extern_node, 0, extern_expected);
        } else {
          value_type = morphl_infer_type_of_ast(ctx, node->children[1]);
        }
        if (!target_type || !value_type) return NULL;
        // Check const-declared ident targets (non-ref path)
        if (node->children[0]->kind == AST_IDENT && target_type->kind != MORPHL_TYPE_REF) {
          Sym target_sym = node->children[0]->op;
          if (!target_sym && node->children[0]->value.ptr)
            target_sym = interns_intern(ctx->interns, node->children[0]->value);
          if (target_sym && type_context_is_const_var(ctx, target_sym)) {
            MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set: target is not mutable");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
        }
        if (target_type->kind == MORPHL_TYPE_REF) {
          if (!target_type->data.ref.is_mutable) {
            MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set: target is not mutable");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
          if (value_type->kind == MORPHL_TYPE_REF && value_type->data.ref.is_ref) {
            if (!refs_assignable(target_type, value_type)) {
              MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set: incompatible ref rebinding");
              morphl_error_emit(NULL, &err);
              return NULL;
            }
            return target_type;
          }
          if (!morphl_type_equals(target_type->data.ref.target, value_type)) {
            MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set: type mismatch in assignment");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
          return value_type;
        }
        if (!morphl_type_equals(target_type, value_type)) {
          /* Allow trait assignment: an impl type (BLOCK with fields+props) may be assigned
           * to a trait-typed variable (BLOCK with only props, field_count==0). */
          MorphlType* tgt_uw = unwrap_ref(target_type);
          bool is_trait_assign = tgt_uw && tgt_uw->kind == MORPHL_TYPE_BLOCK &&
                                 tgt_uw->data.block.field_count == 0 &&
                                 tgt_uw->data.block.prop_count > 0 &&
                                 morphl_type_is_subtype(value_type, tgt_uw);
          if (!is_trait_assign) {
            MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "$set: type mismatch in assignment");
            morphl_error_emit(NULL, &err);
            return NULL;
          }
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
        result = morphl_infer_type_for_op(ctx, node, node->op, arg_types, arg_count);
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
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "undefined variable '%.*s'", (int)name.len, name.ptr);
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

      if (node->op) {
        Sym number_kind = interns_intern(ctx->interns, str_from(LEXER_KIND_NUMBER, strlen(LEXER_KIND_NUMBER)));
        Sym float_kind = interns_intern(ctx->interns, str_from(LEXER_KIND_FLOAT, strlen(LEXER_KIND_FLOAT)));
        Sym string_kind = interns_intern(ctx->interns, str_from(LEXER_KIND_STRING, strlen(LEXER_KIND_STRING)));
        if (string_kind && node->op == string_kind) {
          return morphl_type_string(ctx->arena);
        }
        if (float_kind && node->op == float_kind) {
          return morphl_type_float(ctx->arena);
        }
        if (number_kind && node->op == number_kind) {
          return morphl_type_int(ctx->arena);
        }
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
    
    case AST_OVERLOAD:
      if (node->child_count == 0) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "overload has no candidates");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      MorphlErrorSink prev_sink = morphl_error_get_global_sink();
      MorphlErrorSink silent_sink = { morphl_error_swallow, NULL };
      morphl_error_set_global_sink(silent_sink);

      MorphlType* chosen_type = NULL;
      AstNode* chosen = NULL;

      for (size_t i = 0; i < node->child_count; ++i) {
        AstNode* candidate = node->children[i];
        if (!candidate || !candidate->op) continue;

        const OperatorInfo* info = operator_info_lookup(candidate->op);
        if (!info) continue;

        size_t arg_count = candidate->child_count;
        MorphlType** arg_types = NULL;
        if (arg_count > 0) {
          arg_types = (MorphlType**)malloc(arg_count * sizeof(MorphlType*));
          if (!arg_types) continue;
          bool ok = true;
          for (size_t j = 0; j < arg_count; ++j) {
            arg_types[j] = morphl_infer_type_of_ast(ctx, candidate->children[j]);
            if (!arg_types[j]) { ok = false; break; }
          }
          if (!ok) {
            free(arg_types);
            continue;
          }
        }

        MorphlType* candidate_type = morphl_infer_type_for_op(ctx, candidate, candidate->op, arg_types, arg_count);
        free(arg_types);
        if (candidate_type) {
          chosen = candidate;
          chosen_type = candidate_type;
          break;
        }
      }

      morphl_error_set_global_sink(prev_sink);

      if (!chosen) {
        MorphlError err = MORPHL_ERR_AT(node, MORPHL_E_TYPE, "no overload matches");
        morphl_error_emit(NULL, &err);
        return NULL;
      }

      for (size_t i = 0; i < node->child_count; ++i) {
        if (node->children[i] != chosen) {
          ast_free(node->children[i]);
        }
      }
      free(node->children);

      node->kind = chosen->kind;
      node->op = chosen->op;
      node->value = chosen->value;
      node->children = chosen->children;
      node->child_count = chosen->child_count;
      node->child_capacity = chosen->child_capacity;
      node->filename = chosen->filename;
      node->row = chosen->row;
      node->col = chosen->col;

      chosen->children = NULL;
      chosen->child_count = 0;
      chosen->child_capacity = 0;
      ast_free(chosen);

      return chosen_type;

    case AST_UNKNOWN:
    default:
      return morphl_type_void(ctx->arena);
  }
}

MorphlType* morphl_infer_type_of_ast(TypeContext* ctx, AstNode* node) {
  MorphlType* t = morphl_infer_type_of_ast_inner(ctx, node);
  if (node) node->type = t;
  return t;
}
