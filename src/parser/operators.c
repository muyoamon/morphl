#include "parser/operators.h"
#include "ast/ast.h"
#include "parser/scoped_parser.h"
#include "lexer/lexer.h"
#include "typing/typing.h"
#include "typing/type_context.h"
#include "typing/inference.h"
#include "util/error.h"
#include "util/file.h"
#include "util/fs.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include <string.h>

static MorphlSpan span_from_node(const AstNode* node) {
  if (!node) return morphl_span_unknown();
  return morphl_span_from_loc(node->filename, node->row, node->col);
}

#define MORPHL_ERR_NODE(node, code, fmt, ...) \
  MORPHL_ERR_SPAN((code), MORPHL_SEV_ERROR, span_from_node(node), (fmt), ##__VA_ARGS__)

// Static intern copy
static InternTable *operator_interns = NULL;

// Static table of builtin operators. sym is populated at init.
typedef struct {
  const char* name;
  AstKind ast_kind;
  bool is_preprocessor;
  size_t min_args;
  size_t max_args;
  OperatorPPActionFunc func;
  Sym sym;
  OperatorPPResultPolicy policy;
  enum Operator op_enum;
} OperatorRow;

// Helpers
static const char* unquote_literal(const AstNode* node, char* buf, size_t buf_size) {
  if (!node || node->kind != AST_LITERAL || !node->value.ptr) return NULL;
  if (node->value.len < 2) return NULL;
  if (node->value.ptr[0] != '"' || node->value.ptr[node->value.len - 1] != '"') return NULL;
  size_t n = node->value.len - 2;
  if (n + 1 > buf_size) return NULL;
  memcpy(buf, node->value.ptr + 1, n);
  buf[n] = '\0';
  return buf;
}

// $syntax action: replace current grammar; drop node from AST
static MorphlType* pp_action_syntax(const OperatorInfo* info,
                                    void* global_state,
                                    void* block_state,
                                    AstNode** args,
                                    size_t arg_count) {
  (void)info; (void)block_state;
  if (!global_state || arg_count != 1) return NULL;
  ScopedParserContext* ctx = (ScopedParserContext*)global_state;
  char path[512];
  const char* filename = unquote_literal(args[0], path, sizeof(path));
  if (!filename) return NULL;
  (void)scoped_parser_replace_grammar(ctx, filename);
  return NULL;
}

/* Walk an imported module AST and intern every identifier/literal value so that
 * the AST remains valid after the source buffer is freed.  Also sets node->op
 * for AST_IDENT nodes so the emitter can look up names by Sym. */
static void ast_intern_all_strings(AstNode* node, InternTable* interns) {
  if (!node) return;
  if (node->value.ptr && node->value.len > 0) {
    Sym sym = interns_intern(interns, node->value);
    node->value = interns_lookup(interns, sym);
    if (node->kind == AST_IDENT) node->op = sym;
  }
  for (size_t i = 0; i < node->child_count; i++) {
    ast_intern_all_strings(node->children[i], interns);
  }
}

static struct MorphlImportCacheEntry* import_cache_lookup(
    ScopedParserContext* ctx, Str canonical_path) {
  if (!ctx || !canonical_path.ptr) return NULL;
  for (size_t i = 0; i < ctx->import_cache_count; ++i) {
    if (str_eq(ctx->import_cache_entries[i].canonical_path, canonical_path)) {
      return &ctx->import_cache_entries[i];
    }
  }
  return NULL;
}

static struct MorphlImportCacheEntry* import_cache_store(
    ScopedParserContext* ctx, Str canonical_path, AstNode* module_root) {
  if (!ctx || !canonical_path.ptr || !module_root) return NULL;
  if (ctx->import_cache_count >= ctx->import_cache_cap) {
    size_t new_cap = ctx->import_cache_cap ? ctx->import_cache_cap * 2 : 4;
    struct MorphlImportCacheEntry* resized =
        (struct MorphlImportCacheEntry*)realloc(
            ctx->import_cache_entries,
            new_cap * sizeof(struct MorphlImportCacheEntry));
    if (!resized) return NULL;
    ctx->import_cache_entries = resized;
    ctx->import_cache_cap = new_cap;
  }
  struct MorphlImportCacheEntry* entry =
      &ctx->import_cache_entries[ctx->import_cache_count++];
  entry->canonical_path = canonical_path;
  entry->module_root = module_root;
  return entry;
}

// $import: validate single string argument; keep node for downstream handling
static MorphlType* pp_action_import(const OperatorInfo* info,
                                    void* global_state,
                                    void* block_state,
                                    AstNode** args,
                                    size_t arg_count) {
  (void)info; (void)block_state;
  if (arg_count != 1) return NULL;
  if (!global_state) return NULL;
  ScopedParserContext* ctx = (ScopedParserContext*)global_state;
  char tmp[512];
  const char* filename = unquote_literal(args[0], tmp, sizeof(tmp));
  if (!filename) return NULL;
  Str resolved_path;
  if (fs_is_relative_path(filename) && ctx->filename) {
    resolved_path = fs_get_absolute_path_from_source(filename, ctx->filename);
  } else {
    char* path_copy = strdup(filename);
    if (!path_copy) return NULL;
    resolved_path = str_from(path_copy, strlen(path_copy));
  }
  if (!resolved_path.ptr) return NULL;

  struct MorphlImportCacheEntry* cached = import_cache_lookup(ctx, resolved_path);
  if (cached) {
    if (args[0]->import_module && !args[0]->import_module_shared) {
      ast_free(args[0]->import_module);
    }
    free((void*)args[0]->import_path.ptr);
    args[0]->import_module = cached->module_root;
    args[0]->import_module_shared = true;
    args[0]->import_path =
        str_from(strdup(cached->canonical_path.ptr), cached->canonical_path.len);
    free((void*)resolved_path.ptr);
    if (!args[0]->import_path.ptr) return NULL;
    return NULL;
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!morphl_file_read_all(resolved_path.ptr, &source_buffer, &source_len)) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_PARSE, "$import: failed to read '%s'", resolved_path.ptr);
    morphl_error_emit(NULL, &err);
    free((void*)resolved_path.ptr);
    return NULL;
  }
  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(resolved_path.ptr, str_from(source_buffer, source_len), ctx->interns, &tokens, &token_count)) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_PARSE, "$import: tokenization failed for '%s'", resolved_path.ptr);
    morphl_error_emit(NULL, &err);
    free(source_buffer);
    free((void*)resolved_path.ptr);
    return NULL;
  }

  ScopedParserContext module_ctx;
  if (!scoped_parser_init(&module_ctx, ctx->interns, ctx->arena, resolved_path.ptr)) {
    free(tokens);
    free(source_buffer);
    free((void*)resolved_path.ptr);
    return NULL;
  }

  AstNode* module_root = NULL;
  bool ok = scoped_parse_ast(&module_ctx, tokens, token_count, &module_root);
  scoped_parser_free(&module_ctx);
  /* Intern all identifier/literal strings BEFORE freeing source_buffer and tokens,
   * so that AST value.ptr fields point to stable intern-table memory afterwards. */
  if (ok && module_root) ast_intern_all_strings(module_root, ctx->interns);
  free(tokens);
  free(source_buffer);

  if (!ok || !module_root) {
    free((void*)resolved_path.ptr);
    return NULL;
  }

  // Imported modules should parse to AST_FILE at the root; if not, something is wrong with the source or grammar
  if (module_root->kind != AST_FILE) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_PARSE, "$import: expected file AST, got %d", (int)module_root->kind);
    morphl_error_emit(NULL, &err);
    ast_free(module_root);
    free((void*)resolved_path.ptr);
    return NULL;
  }

  struct MorphlImportCacheEntry* stored =
      import_cache_store(ctx, resolved_path, module_root);
  if (!stored) {
    ast_free(module_root);
    free((void*)resolved_path.ptr);
    return NULL;
  }
  if (args[0]->import_module && !args[0]->import_module_shared) {
    ast_free(args[0]->import_module);
  }
  free((void*)args[0]->import_path.ptr);
  args[0]->import_module = stored->module_root;
  args[0]->import_module_shared = true;
  args[0]->import_path =
      str_from(strdup(stored->canonical_path.ptr), stored->canonical_path.len);
  if (!args[0]->import_path.ptr) {
    return NULL;
  }
  /* Do NOT run type inference here: the return value is always discarded by
   * apply_preprocessor_if_any, and running inference on the module AST using the
   * parent file's type context (without push_global/push_file) would corrupt
   * ctx->global_type / ctx->file_type before the main file's pre-scan runs. */
  return NULL;
}

// $prop: validate at least one argument; keep node
static MorphlType* pp_action_prop(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state; (void)block_state; (void)args;
  if (arg_count != 2) return NULL;
  // Arg[0]: property name (identifier)
  // Arg[1]: property value (expression)
  // Future: attach properties to current declaration context
  return NULL;
}

// $call: call a function with parameters
// $call takes exactly 2 args: (1) function, (2) parameter expression
// The parameter expression is matched against the function's parameter type.
// Since functions have 1 parameter (the parameter expression), $call validates
// that the provided parameter matches the function's parameter type.
static MorphlType* pp_action_call(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;
  
  // $call must have exactly 2 arguments
  if (arg_count != 2) return NULL;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx) return NULL;
  
  AstNode* func_expr = args[0];     // The function expression
  AstNode* param_expr = args[1];    // The parameter expression to pass
  
  if (!func_expr || !param_expr) return NULL;
  
  // Resolve function type
  MorphlType* func_type = NULL;
  if (func_expr->kind == AST_IDENT) {
    // For identifiers, the op field contains the symbol
    if (!func_expr->op) return NULL;
    func_type = type_context_lookup_func(ctx, func_expr->op);
    
    if (!func_type) {
      MorphlError err = MORPHL_ERR_NODE(func_expr, MORPHL_E_TYPE, "$call: function not defined");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  } else {
    // Infer the type of the function expression
    func_type = morphl_infer_type_of_ast(ctx, func_expr);
    
    if (!func_type) {
      MorphlError err = MORPHL_ERR_NODE(func_expr, MORPHL_E_TYPE, "$call: cannot infer function type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  }
  
  // Validate it's a function type
  if (func_type->kind != MORPHL_TYPE_FUNC) {
    MorphlError err = MORPHL_ERR_NODE(func_expr, MORPHL_E_TYPE, "$call: target is not a function");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Functions should have exactly 1 parameter
  if (func_type->data.func.param_count != 1) {
    MorphlError err = MORPHL_ERR_NODE(func_expr, MORPHL_E_TYPE, "$call: expected 1 parameter, function has %llu",
           (unsigned long long)func_type->data.func.param_count);
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Infer the type of the provided parameter
  MorphlType* provided_param_type = morphl_infer_type_of_ast(ctx, param_expr);
  if (!provided_param_type) {
    MorphlError err = MORPHL_ERR_NODE(param_expr, MORPHL_E_TYPE, "$call: cannot infer type of parameter");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Check that provided parameter matches the function's parameter type
  // (later can implement subtyping here)
  MorphlType* expected_param_type = func_type->data.func.param_types[0];
  if (!morphl_type_equals(provided_param_type, expected_param_type)) {
    MorphlError err = MORPHL_ERR_NODE(param_expr, MORPHL_E_TYPE, "$call: parameter type mismatch");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Return the function's return type
  return func_type->data.func.return_type;
}

// $func: create pseudo-scope where parameter declarations are exposed to body
// $func takes exactly 2 args: (1) parameter expression (may be $group),
//                              (2) function body expression
// The parameter expression may contain $decl nodes that declare parameters.
// These declarations are exposed to the function body (pseudo-scope).
// Function type has 1 parameter: the parameter expression itself (which may be composite).
// Return type is inferred from the body.
static MorphlType* pp_action_func(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;

  
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2) return NULL;
  
  AstNode* param_expr = args[0];   // Parameter expression (can be $group, $decl, etc.)
  AstNode* func_body = args[1];    // Function body expression
  
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
    MorphlError err = MORPHL_ERR_NODE(param_expr, MORPHL_E_TYPE, "$func: cannot infer parameter type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Set expected return type to UNKNOWN initially
  // This allows $ret to establish the return type on first encounter
  // and enables recursion (recursive call sees UNKNOWN matching UNKNOWN)
  type_context_set_return_type(ctx, morphl_type_unknown(ctx->arena));
  
  // Infer return type from function body in the pseudo-scope
  // The body has access to variables declared in the parameter expression
  // If $ret is used, it will establish/validate the return type
  MorphlType* body_type = morphl_infer_type_of_ast(ctx, func_body);
  if (!body_type) {
    type_context_pop_scope(ctx);
    type_context_set_return_type(ctx, NULL);
    MorphlError err = MORPHL_ERR_NODE(func_body, MORPHL_E_TYPE, "$func: cannot infer body type");
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
    type_context_pop_scope(ctx);
    type_context_set_return_type(ctx, NULL);
    MorphlError err = MORPHL_ERR_NODE(func_body, MORPHL_E_TYPE, "$func: cannot determine return type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Pop the pseudo-scope
  type_context_pop_scope(ctx);
  
  // Clear return type after function
  type_context_set_return_type(ctx, NULL);
  
  // Create function type with 1 parameter (the parameter expression)
  // The parameter type represents what the function accepts
  return morphl_type_func(ctx->arena, param_type, return_type);
}

// $if: validate condition, then-block, else-block structure
static MorphlType* pp_action_if(const OperatorInfo* info,
                                 void* global_state,
                                 void* block_state,
                                 AstNode** args,
                                 size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count < 2 || arg_count > 3) return NULL;

  // args[0]: condition expression
  // args[1]: then expression/block
  // args[2]: (optional) else expression/block
  
  AstNode* condition = args[0];
  if (!condition) return NULL;
  
  // Infer condition type
  MorphlType* cond_type = morphl_infer_type_of_ast(ctx, condition);
  if (!cond_type) {
    MorphlError err = MORPHL_ERR_NODE(condition, MORPHL_E_TYPE, "$if: cannot infer condition type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Check that condition is bool or int (truthy)
  if (cond_type->kind != MORPHL_TYPE_BOOL &&
      cond_type->kind != MORPHL_TYPE_INT) {
    MorphlError err = MORPHL_ERR_NODE(condition, MORPHL_E_TYPE, "$if: condition must be bool or int");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // The then-else block should be validated structurally but we don't type-check it here
  return NULL;
}

static MorphlType* pp_action_decl(const OperatorInfo* info,
                                 void* global_state,
                                 void* block_state,
                                 AstNode** args,
                                 size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count < 2) return NULL;
  
  // Arg[0]: identifier (variable name)
  // Arg[1]: initial expression (type is inferred from this)
  
  AstNode* name_node = args[0];
  AstNode* init_expr = args[1];
  
  if (!name_node || name_node->kind != AST_IDENT) return NULL;
  if (!init_expr) return NULL;
  
  // Extract the symbol from the identifier (op field contains the symbol)
  Sym var_sym = name_node->op;
  if (!var_sym && ctx->interns && name_node->value.ptr) {
    var_sym = interns_intern(ctx->interns, name_node->value);
    name_node->op = var_sym;
  }
  if (!var_sym) return NULL;
  
  // Check for duplicate declaration
  if (type_context_check_duplicate_var(ctx, var_sym)) {
    MorphlError err = MORPHL_ERR_NODE(name_node, MORPHL_E_TYPE, "$decl: variable already declared");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // For function declarations, register early with UNKNOWN type to enable recursion
  // This allows the function to call itself before its body is fully type-checked
  if (init_expr->kind == AST_FUNC || 
      (init_expr->kind == AST_BUILTIN && init_expr->op && 
       ctx->interns && interns_lookup(ctx->interns, init_expr->op).ptr &&
       strcmp(interns_lookup(ctx->interns, init_expr->op).ptr, "$func") == 0)) {
    // Create placeholder function type with UNKNOWN return type
    MorphlType* placeholder = morphl_type_func(ctx->arena, 
                                              morphl_type_unknown(ctx->arena),
                                              morphl_type_unknown(ctx->arena));
    type_context_define_func(ctx, var_sym, placeholder);
    type_context_define_var(ctx, var_sym, placeholder);
  }
  
  // Infer type of the initial expression
  MorphlType* var_type = morphl_infer_type_of_ast(ctx, init_expr);
  if (!var_type) {
    MorphlError err = MORPHL_ERR_NODE(init_expr, MORPHL_E_TYPE, "$decl: cannot infer variable type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Register final type in type context (overwrites placeholder if function)
  type_context_define_var(ctx, var_sym, var_type);
  if (var_type->kind == MORPHL_TYPE_FUNC) {
    type_context_define_func(ctx, var_sym, var_type);
  }
  
  return var_type;
}

static MorphlType* pp_action_set(const OperatorInfo* info,
                                void* global_state,
                                void* block_state,
                                AstNode** args,
                                size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2) return NULL;
  
  AstNode* target = args[0];
  AstNode* value = args[1];
  
  if (!target || !value) return NULL;
  
  // Get target type
  MorphlType* target_type = NULL;
  if (target->kind == AST_IDENT && target->op) {
    target_type = type_context_lookup_var(ctx, target->op);
    if (!target_type) {
      MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$set: variable not declared");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  } else {
    target_type = morphl_infer_type_of_ast(ctx, target);
    if (!target_type) {
      MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$set: cannot infer target type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  }
  
  // Infer value type
  MorphlType* value_type = morphl_infer_type_of_ast(ctx, value);
  if (!value_type) {
    MorphlError err = MORPHL_ERR_NODE(value, MORPHL_E_TYPE, "$set: cannot infer value type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  if (target_type && target_type->kind == MORPHL_TYPE_REF) {
    if (!target_type->data.ref.is_mutable) {
      MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$set: target is not mutable");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    if (!morphl_type_equals(target_type->data.ref.target, value_type)) {
      MorphlError err = MORPHL_ERR_NODE(value, MORPHL_E_TYPE, "$set: type mismatch in assignment");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    return value_type;
  }

  // Check type compatibility
  if (!morphl_type_equals(target_type, value_type)) {
    MorphlError err = MORPHL_ERR_NODE(value, MORPHL_E_TYPE, "$set: type mismatch in assignment");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  return value_type;
}

static MorphlType* pp_action_ret(const OperatorInfo* info,
                                void* global_state,
                                void* block_state,
                                AstNode** args,
                                size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 1) return NULL;
  
  AstNode* ret_expr = args[0];
  if (!ret_expr) return NULL;
  
  // Get expected return type
  MorphlType* expected = type_context_get_return_type(ctx);
  if (!expected) {
    MorphlError err = MORPHL_ERR_NODE(ret_expr, MORPHL_E_TYPE, "$ret: not inside a function");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Infer return expression type
  MorphlType* ret_type = morphl_infer_type_of_ast(ctx, ret_expr);
  if (!ret_type) {
    MorphlError err = MORPHL_ERR_NODE(ret_expr, MORPHL_E_TYPE, "$ret: cannot infer return value type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  if (ret_type->kind != MORPHL_TYPE_UNKNOWN) {
    MorphlType* current_func = type_context_get_current_func(ctx);
    if (expected->kind == MORPHL_TYPE_UNKNOWN) {
      type_context_set_return_type(ctx, ret_type);
      if (current_func && current_func->kind == MORPHL_TYPE_FUNC) {
        current_func->data.func.return_type = ret_type;
      }
    } else if (!morphl_type_equals(ret_type, expected)) {
      MorphlError err = MORPHL_ERR_NODE(ret_expr, MORPHL_E_TYPE, "$ret: return type mismatch");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  }
  
  return ret_type;
}

static MorphlType* pp_action_while(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2) return NULL;
  
  AstNode* condition = args[0];
  AstNode* body = args[1];
  
  if (!condition || !body) return NULL;
  
  // Validate condition type
  MorphlType* cond_type = morphl_infer_type_of_ast(ctx, condition);
  if (!cond_type) {
    MorphlError err = MORPHL_ERR_NODE(condition, MORPHL_E_TYPE, "$while: cannot infer condition type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  if (cond_type->kind != MORPHL_TYPE_BOOL &&
      cond_type->kind != MORPHL_TYPE_INT) {
    MorphlError err = MORPHL_ERR_NODE(condition, MORPHL_E_TYPE, "$while: condition must be bool or int");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Type-check body (for side effects, doesn't produce value)
  morphl_infer_type_of_ast(ctx, body);
  
  return morphl_type_void(ctx->arena);
}

static MorphlType* pp_action_member(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2) return NULL;
  
  AstNode* target = args[0];
  AstNode* field_node = args[1];
  
  if (!target || !field_node || field_node->kind != AST_IDENT || !field_node->op) return NULL;
  
  // Infer type of target expression
  MorphlType* target_type = morphl_infer_type_of_ast(ctx, target);
  if (!target_type) {
    MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$member: cannot infer target type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Only block types have fields
  if (target_type->kind != MORPHL_TYPE_BLOCK) {
    MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$member: target must be a block type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Look up field by name
  Sym field_name = field_node->op;
  for (size_t i = 0; i < target_type->data.block.field_count; ++i) {
    if (target_type->data.block.field_names[i] == field_name) {
      return target_type->data.block.field_types[i];
    }
  }
  
  MorphlError err = MORPHL_ERR_NODE(field_node, MORPHL_E_TYPE, "$member: field not found in block");
  morphl_error_emit(NULL, &err);
  return NULL;
}

static MorphlType* pp_action_mut(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 1) return NULL;
  
  AstNode* target = args[0];
  if (!target) return NULL;
  
  // Infer type of target expression
  MorphlType* target_type = morphl_infer_type_of_ast(ctx, target);
  if (!target_type) {
    MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$mut: cannot infer target type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Create mutable reference type
  return morphl_type_ref(ctx->arena, target_type, true, false);
}

static MorphlType* pp_action_const(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 1) return NULL;
  
  AstNode* target = args[0];
  if (!target) return NULL;
  
  // Infer type of target expression
  MorphlType* target_type = morphl_infer_type_of_ast(ctx, target);
  if (!target_type) {
    MorphlError err = MORPHL_ERR_NODE(target, MORPHL_E_TYPE, "$const: cannot infer target type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Create immutable reference type
  return morphl_type_ref(ctx->arena, target_type, false, false);
}


/* $array elem-type count — allocate a fixed-size array */
static MorphlType* pp_action_array(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2 || !args[0] || !args[1]) return NULL;

  /* Resolve element type structurally from the expression */
  MorphlType* elem_type = morphl_infer_type_of_ast(ctx, args[0]);
  if (!elem_type) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_TYPE, "$array: cannot resolve element type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  /* Count must be an integer literal */
  if (args[1]->kind != AST_LITERAL || !args[1]->value.ptr) {
    MorphlError err = MORPHL_ERR_NODE(args[1], MORPHL_E_TYPE, "$array: count must be an integer literal");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  char buf[32];
  size_t n = args[1]->value.len < sizeof(buf) - 1 ? args[1]->value.len : sizeof(buf) - 1;
  memcpy(buf, args[1]->value.ptr, n);
  buf[n] = '\0';
  char* end = NULL;
  long long count = strtoll(buf, &end, 10);
  if (end == buf || count <= 0) {
    MorphlError err = MORPHL_ERR_NODE(args[1], MORPHL_E_TYPE, "$array: count must be a positive integer");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  return morphl_type_array(ctx->arena, elem_type, (size_t)count);
}

/* $index array index — element access */
static MorphlType* pp_action_index(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2 || !args[0] || !args[1]) return NULL;

  MorphlType* arr_type = morphl_infer_type_of_ast(ctx, args[0]);
  if (!arr_type) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_TYPE, "$index: cannot infer array type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  /* Unwrap qualifiers */
  while (arr_type && arr_type->kind == MORPHL_TYPE_REF && !arr_type->data.ref.is_ref)
    arr_type = arr_type->data.ref.target;
  if (!arr_type || arr_type->kind != MORPHL_TYPE_ARRAY) {
    MorphlError err = MORPHL_ERR_NODE(args[0], MORPHL_E_TYPE, "$index: target is not an array type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  MorphlType* idx_type = morphl_infer_type_of_ast(ctx, args[1]);
  if (!idx_type || idx_type->kind != MORPHL_TYPE_INT) {
    MorphlError err = MORPHL_ERR_NODE(args[1], MORPHL_E_TYPE, "$index: index must be integer");
    morphl_error_emit(NULL, &err);
    return NULL;
  }

  return arr_type->data.array.elem_type;
}

/* $union V1 V2 ... — tagged union type */
static MorphlType* pp_action_union(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count < 1) return NULL;

  MorphlType** variant_types = (MorphlType**)arena_push(ctx->arena, NULL, arg_count * sizeof(MorphlType*));
  if (!variant_types) return NULL;
  for (size_t i = 0; i < arg_count; ++i) {
    if (!args[i]) { variant_types[i] = morphl_type_never(ctx->arena); continue; }
    /* Resolve variant type structurally from the expression */
    MorphlType* vt = morphl_infer_type_of_ast(ctx, args[i]);
    if (!vt) {
      MorphlError err = MORPHL_ERR_NODE(args[i], MORPHL_E_TYPE, "$union: cannot resolve variant type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
    variant_types[i] = vt;
  }
  return morphl_type_union(ctx->arena, variant_types, arg_count);
}

/* $as expr TargetType — reinterpret cast */
static MorphlType* pp_action_as(const OperatorInfo* info,
                                void* global_state,
                                void* block_state,
                                AstNode** args,
                                size_t arg_count) {
  (void)info; (void)global_state;
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count != 2 || !args[0] || !args[1]) return NULL;

  /* Resolve target type structurally from the expression */
  MorphlType* target_type = morphl_infer_type_of_ast(ctx, args[1]);
  if (!target_type) {
    MorphlError err = MORPHL_ERR_NODE(args[1], MORPHL_E_TYPE, "$as: cannot resolve target type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  /* The source expression is accepted as-is; $as is an unchecked reinterpret cast */
  return target_type;
}

static OperatorRow kBuiltinOps[] = {
  // Structural
  {"$group",  AST_GROUP,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE, GROUP},
  {"$block",  AST_BLOCK,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE, BLOCK},

  // Core constructs
  {"$call",   AST_CALL,   false, 2, 2,          pp_action_call,    0, OP_PP_KEEP_NODE, CALL},
  {"$func",   AST_FUNC,   false, 2, 2,          pp_action_func,    0, OP_PP_KEEP_NODE, FUNC},
  {"$if",     AST_IF,     false, 2, 3,          pp_action_if,      0, OP_PP_KEEP_NODE, IF},
  {"$while",  AST_BUILTIN,false, 2, 2,          pp_action_while,   0, OP_PP_KEEP_NODE, WHILE},
  {"$set",    AST_SET,    false, 2, 2,          pp_action_set,     0, OP_PP_KEEP_NODE, SET},
  {"$decl",   AST_DECL,   true,  2, 2,          pp_action_decl,    0, OP_PP_KEEP_NODE, DECL},
  {"$import", AST_BUILTIN,true,  1, 1,          pp_action_import,  0, OP_PP_KEEP_NODE, IMPORT},
  {"$alias",  AST_BUILTIN,true,  2, 2,          NULL,              0, OP_PP_DROP_NODE, ALIAS},
  {"$syntax", AST_BUILTIN,true,  1, 1,          pp_action_syntax,  0, OP_PP_DROP_NODE, SYNTAX},
  {"$prop",   AST_PROP   ,true,  2, 2,          pp_action_prop,    0, OP_PP_KEEP_NODE, PROP},
  {"$ret",    AST_BUILTIN,false, 1, 1,          pp_action_ret,     0, OP_PP_KEEP_NODE, RET},
  {"$member", AST_BUILTIN,false, 2, 2,          pp_action_member,  0, OP_PP_KEEP_NODE, MEMBER},
  {"$mut",    AST_BUILTIN,false, 1, 1,          pp_action_mut,     0, OP_PP_KEEP_NODE, MUT},
  {"$const",  AST_BUILTIN,false, 1, 1,          pp_action_const,   0, OP_PP_KEEP_NODE, CONST},
  {"$static", AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, STATIC},
  {"$inline", AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, INLINE},
  {"$this",   AST_BUILTIN,false, 0, 0,          NULL,              0, OP_PP_KEEP_NODE, THIS},
  {"$parent", AST_BUILTIN,false, 0, 0,          NULL,              0, OP_PP_KEEP_NODE, PARENT},
  {"$file",   AST_BUILTIN,false, 0, 0,          NULL,              0, OP_PP_KEEP_NODE, FILE_},
  {"$global", AST_BUILTIN,false, 0, 0,          NULL,              0, OP_PP_KEEP_NODE, GLOBAL},
  {"$ref",    AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, REF},
  {"$null",   AST_BUILTIN,false, 0, 0,          NULL,              0, OP_PP_KEEP_NODE, NULLREF},
  {"$new",    AST_BUILTIN,false, 1, 2,          NULL,              0, OP_PP_KEEP_NODE, NEW},
  {"$idtstr", AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, IDTSTR},
  {"$strtid", AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, STRTID},
  {"$forward",AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, FORWARD},
  {"$break",  AST_BUILTIN, false, 0, 0,         NULL,              0, OP_PP_KEEP_NODE, BREAK},
  {"$continue",AST_BUILTIN,false, 0, 0,         NULL,              0, OP_PP_KEEP_NODE, CONTINUE},
  {"$defer",  AST_BUILTIN,false, 1, 1,          NULL,              0, OP_PP_KEEP_NODE, DEFER},

  // Arithmetic (no pp actions yet; type checker will use registry later)
  {"$add",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, ADD},
  {"$sub",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, SUB},
  {"$mul",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, MUL},
  {"$div",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, DIV},
  {"$mod",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, MOD},
  {"$rem",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, REM},
  {"$fadd",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, FADD},
  {"$fsub",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, FSUB},
  {"$fmul",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, FMUL},
  {"$fdiv",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, FDIV},

  // Comparison
  {"$eq",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, EQ},
  {"$neq",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, NEQ},
  {"$lt",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, LT},
  {"$gt",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, GT},
  {"$lte",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, LTE},
  {"$gte",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, GTE},

  // Logic
  {"$and",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, AND},
  {"$or",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, OR},
  {"$not",    AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, NOT},

  // Bitwise
  {"$band",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, BAND},
  {"$bor",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, BOR},
  {"$bxor",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, BXOR},
  {"$bnot",   AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, BNOT},
  {"$lshift", AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, LSHIFT},
  {"$rshift", AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, RSHIFT},

  // Reference equality
  {"$req",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, REQ},
  {"$rneq",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, RNEQ},

  // Preprocessor
  {"$syntax", AST_BUILTIN,true,  1, 1,           pp_action_syntax,  0, OP_PP_DROP_NODE, SYNTAX},
  {"$import", AST_BUILTIN,true,  1, 1,           pp_action_import,  0, OP_PP_KEEP_NODE, IMPORT},
  {"$alias",  AST_BUILTIN,true,  2, 2,           NULL,              0, OP_PP_DROP_NODE, ALIAS},

  // Trait system
  {"$traits", AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, TRAITS},
  {"$impl",   AST_BUILTIN,false, 2, 3,           NULL,              0, OP_PP_KEEP_NODE, IMPL},

  // Exit — explicit exit code required: $exit 0;
  {"$exit",   AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, EXIT},
  {"$heap",   AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, HEAP},
  {"$free",   AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, FREE_},

  // Type conversions
  {"$i2f",    AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, I2F},
  {"$f2i",    AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, F2I},

  // Native FFI storage specifier: $extern <type-expr> | $extern <string> <type-expr>
  {"$extern", AST_BUILTIN,false, 1, 2,           NULL,              0, OP_PP_KEEP_NODE, EXTERN},

  // Array types
  {"$array",  AST_BUILTIN, true, 2, 2,           pp_action_array,   0, OP_PP_KEEP_NODE, ARRAY},
  {"$index",  AST_BUILTIN,false, 2, 2,           pp_action_index,   0, OP_PP_KEEP_NODE, INDEX},

  // Union types and reinterpret cast
  {"$union",  AST_BUILTIN, true, 1, (size_t)-1,  pp_action_union,   0, OP_PP_KEEP_NODE, UNION},
  {"$as",     AST_BUILTIN,false, 2, 2,           pp_action_as,      0, OP_PP_KEEP_NODE, AS},

  // overload type 
  {"$overload",AST_BUILTIN,false, 1, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE, OVERLOAD},
  {"$size",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, SIZEOF_REPR},
  {"$align",  AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, ALIGNOF_REPR},
  {"$signed", AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE, SIGNED_REPR},
  {"$unsigned",AST_BUILTIN,false,1, 1,           NULL,              0, OP_PP_KEEP_NODE, UNSIGNED_REPR},
  {"$udiv",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, UDIV},
  {"$umod",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, UMOD},
  {"$ult",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, ULT},
  {"$ugt",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, UGT},
  {"$ulte",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, ULTE},
  {"$ugte",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, UGTE},
  {"$ushr",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE, USHR},
};
static const size_t kBuiltinOpCount = sizeof(kBuiltinOps) / sizeof(kBuiltinOps[0]);

bool operator_registry_init(InternTable* interns) {
  if (!interns) return false;
  for (size_t i = 0; i < kBuiltinOpCount; ++i) {
    Str name = str_from(kBuiltinOps[i].name, strlen(kBuiltinOps[i].name));
    Sym sym = interns_intern(interns, name);
    if (!sym) return false;
    kBuiltinOps[i].sym = sym;
  }
  operator_interns = interns;
  return true;
}

const OperatorInfo* operator_info_lookup(Sym op) {
  if (!op) return NULL;
  for (size_t i = 0; i < kBuiltinOpCount; ++i) {
    if (kBuiltinOps[i].sym == op) {
      static OperatorInfo out;
      out.op = kBuiltinOps[i].sym;
      out.ast_kind = kBuiltinOps[i].ast_kind;
      out.func = kBuiltinOps[i].func;
      out.min_args = kBuiltinOps[i].min_args;
      out.max_args = kBuiltinOps[i].max_args;
      out.is_preprocessor = kBuiltinOps[i].is_preprocessor;
      out.pp_policy = kBuiltinOps[i].policy;
      out.op_enum = kBuiltinOps[i].op_enum;
      return &out;
    }
  }
  return NULL;
}

const OperatorInfo* operator_info_from_enum(enum Operator op) {
  if (op < 0 || (size_t)op >= kBuiltinOpCount) return NULL;
  for (size_t i = 0; i < kBuiltinOpCount; ++i) {
    if (kBuiltinOps[i].op_enum == op) {
      static OperatorInfo out;
      out.op = kBuiltinOps[i].sym;
      out.ast_kind = kBuiltinOps[i].ast_kind;
      out.func = kBuiltinOps[i].func;
      out.min_args = kBuiltinOps[i].min_args;
      out.max_args = kBuiltinOps[i].max_args;
      out.is_preprocessor = kBuiltinOps[i].is_preprocessor;
      out.pp_policy = kBuiltinOps[i].policy;
      out.op_enum = kBuiltinOps[i].op_enum;
      return &out;
    }
  }
  return NULL;
}

Sym operator_sym_from_enum(enum Operator op) {
  const OperatorInfo* info = operator_info_from_enum(op);
  if (!info) return 0;
  return info->op;
}
