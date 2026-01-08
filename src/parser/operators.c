#include "parser/operators.h"
#include "parser/scoped_parser.h"
#include "typing/typing.h"
#include "typing/type_context.h"
#include "typing/inference.h"
#include "util/error.h"
#include <stdio.h>

#include <string.h>

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

// $import: validate single string argument; keep node for downstream handling
static MorphlType* pp_action_import(const OperatorInfo* info,
                                    void* global_state,
                                    void* block_state,
                                    AstNode** args,
                                    size_t arg_count) {
  (void)info; (void)global_state; (void)block_state;
  if (arg_count != 1) return NULL;
  char tmp[512];
  (void)unquote_literal(args[0], tmp, sizeof(tmp));
  // Future: load module file and attach as block value
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
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: function not defined");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  } else {
    // Infer the type of the function expression
    func_type = morphl_infer_type_of_ast(ctx, func_expr);
    
    if (!func_type) {
      MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: cannot infer function type");
      morphl_error_emit(NULL, &err);
      return NULL;
    }
  }
  
  // Validate it's a function type
  if (func_type->kind != MORPHL_TYPE_FUNC) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: target is not a function");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Functions should have exactly 1 parameter
  if (func_type->data.func.param_count != 1) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: expected 1 parameter, function has %llu",
           func_type->data.func.param_count);
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Infer the type of the provided parameter
  MorphlType* provided_param_type = morphl_infer_type_of_ast(ctx, param_expr);
  if (!provided_param_type) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: cannot infer type of parameter");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Check that provided parameter matches the function's parameter type
  // (later can implement subtyping here)
  MorphlType* expected_param_type = func_type->data.func.param_types[0];
  if (!morphl_type_equals(provided_param_type, expected_param_type)) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$call: parameter type mismatch");
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
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$func: cannot infer parameter type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Infer return type from function body in the pseudo-scope
  // The body has access to variables declared in the parameter expression
  MorphlType* return_type = morphl_infer_type_of_ast(ctx, func_body);
  if (!return_type) {
    type_context_pop_scope(ctx);
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$func: cannot infer return type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Pop the pseudo-scope
  type_context_pop_scope(ctx);
  
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
  if (!ctx || arg_count != 2) return NULL;
  
  // args[0]: condition expression
  // args[1]: then-else group
  
  AstNode* condition = args[0];
  if (!condition) return NULL;
  
  // Infer condition type
  MorphlType* cond_type = morphl_infer_type_of_ast(ctx, condition);
  if (!cond_type) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$if: cannot infer condition type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Check that condition is boolean
  if (cond_type->kind != MORPHL_TYPE_BOOL) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$if: condition must be bool");
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
  if (!name_node->op) return NULL;
  Sym var_sym = name_node->op;
  
  // Infer type of the initial expression
  MorphlType* var_type = morphl_infer_type_of_ast(ctx, init_expr);
  if (!var_type) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$decl: cannot infer variable type");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Check for duplicate declaration
  if (type_context_check_duplicate_var(ctx, var_sym)) {
    MorphlError err = MORPHL_ERR(MORPHL_E_TYPE, "$decl: variable already declared");
    morphl_error_emit(NULL, &err);
    return NULL;
  }
  
  // Register in type context
  type_context_define_var(ctx, var_sym, var_type);
  
  return var_type;
}

static MorphlType* pp_action_member(const OperatorInfo* info,
                                  void* global_state,
                                  void* block_state,
                                  AstNode** args,
                                  size_t arg_count) {
  (void)info; (void)global_state; (void)block_state; (void)args; (void)arg_count;
  // ARG[0]: target object
  // ARG[1]: member name (identifier)
  // Future: implement member access handling
  return NULL;
}

static OperatorRow kBuiltinOps[] = {
  // Structural
  {"$group",  AST_GROUP,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},
  {"$block",  AST_BLOCK,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},

  // Core constructs
  {"$call",   AST_CALL,   false, 2, 2,          pp_action_call,    0, OP_PP_KEEP_NODE},
  {"$func",   AST_FUNC,   false, 2, 2,          pp_action_func,    0, OP_PP_KEEP_NODE},
  {"$if",     AST_IF,     false, 2, 2,          pp_action_if,      0, OP_PP_KEEP_NODE},
  {"$set",    AST_SET,    false, 2, 2,          NULL,              0, OP_PP_KEEP_NODE},
  {"$decl",   AST_DECL,   true,  2, 2,          pp_action_decl,    0, OP_PP_KEEP_NODE},
  {"$member", AST_BUILTIN, false, 2, 2,         pp_action_member,  0, OP_PP_KEEP_NODE},

  // Arithmetic (no pp actions yet; type checker will use registry later)
  {"$add",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$sub",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$mul",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$div",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fadd",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fsub",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fmul",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fdiv",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},

  // Comparison
  {"$eq",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$neq",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$lt",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$gt",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$lte",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$gte",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},

  // Logic
  {"$and",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$or",     AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$not",    AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE},

  // Bitwise
  {"$band",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$bor",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$bxor",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$bnot",   AST_BUILTIN,false, 1, 1,           NULL,              0, OP_PP_KEEP_NODE},
  {"$lshift", AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$rshift", AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},

  // Preprocessor
  {"$syntax", AST_BUILTIN,true,  1, 1,           pp_action_syntax,  0, OP_PP_DROP_NODE},
  {"$import", AST_BUILTIN,true,  1, 1,           pp_action_import,  0, OP_PP_KEEP_NODE},
  {"$prop",   AST_BUILTIN,true,  2, 2,           pp_action_prop,    0, OP_PP_KEEP_NODE},
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
      return &out;
    }
  }
  return NULL;
}
