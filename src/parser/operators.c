#include "parser/operators.h"
#include "parser/scoped_parser.h"
#include "typing/typing.h"
#include "typing/type_context.h"
#include "typing/inference.h"
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

// $call: validate function + arguments
static MorphlType* pp_action_call(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state;
  
  if (arg_count < 1) return NULL;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx) return NULL;
  
  // Arg[0]: the function (identifier or another expr)
  // Arg[1+]: Arguments
  
  AstNode* func_expr = args[0];
  if (!func_expr) return NULL;
  
  // If func_expr is an identifier, look it up
  MorphlType* func_type = NULL;
  if (func_expr->kind == AST_IDENT) {
    // For identifiers, the op field contains the symbol
    if (!func_expr->op) return NULL;
    func_type = type_context_lookup_func(ctx, func_expr->op);
    
    if (!func_type) {
      printf("error: $call: function not defined\n");
      return NULL;
    }
  } else {
    // Infer the type of the function expression
    func_type = morphl_infer_type_of_ast(ctx, func_expr);
    
    if (!func_type) {
      printf("error: $call: cannot infer function type\n");
      return NULL;
    }
  }
  
  // Validate it's a function type
  if (func_type->kind != MORPHL_TYPE_FUNC) {
    printf("error: $call: target is not a function\n");
    return NULL;
  }
  
  // Check argument count
  size_t func_arg_count = func_type->data.func.param_count;
  size_t call_arg_count = (arg_count > 1) ? (arg_count - 1) : 0;
  
  if (call_arg_count != func_arg_count) {
    printf("error: $call: expected %zu arguments, got %zu\n", 
           func_arg_count, call_arg_count);
    return NULL;
  }
  
  // Check argument types
  for (size_t i = 0; i < call_arg_count; ++i) {
    AstNode* arg = args[i + 1];
    MorphlType* arg_type = morphl_infer_type_of_ast(ctx, arg);
    
    if (!arg_type) {
      printf("error: $call: cannot infer type of argument %zu\n", i);
      return NULL;
    }
    
    MorphlType* expected = func_type->data.func.param_types[i];
    if (!morphl_type_equals(arg_type, expected)) {
      printf("error: $call: argument %zu type mismatch\n", i);
      return NULL;
    }
  }
  
  // Return the function's return type
  return func_type->data.func.return_type;
}

// $func: validate parameters block + body block
static MorphlType* pp_action_func(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state; (void)args;
  
  TypeContext* ctx = (TypeContext*)block_state;
  if (!ctx || arg_count < 2) return NULL;
  
  // Arg[0]: parameter list (group of $decl nodes or similar)
  // Arg[1]: function expression/block 
  // The function name should come from context (parent scope knows the name)
  // For now, we'll just ensure the structure is valid
  
  // Future: extract return type by inferring type of body[1]
  // For now, return NULL to indicate not fully implemented
  return NULL;
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
    printf("error: $if: cannot infer condition type\n");
    return NULL;
  }
  
  // Check that condition is boolean
  if (cond_type->kind != MORPHL_TYPE_BOOL) {
    printf("error: $if: condition must be bool\n");
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
    printf("error: $decl: cannot infer variable type\n");
    return NULL;
  }
  
  // Check for duplicate declaration
  if (type_context_check_duplicate_var(ctx, var_sym)) {
    printf("error: $decl: variable already declared\n");
    return NULL;
  }
  
  // Register in type context
  type_context_define_var(ctx, var_sym, var_type);
  
  return var_type;
}

static OperatorRow kBuiltinOps[] = {
  // Structural
  {"$group",  AST_GROUP,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},
  {"$block",  AST_BLOCK,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},

  // Core constructs
  {"$call",   AST_CALL,   false, 1, (size_t)-1, pp_action_call,    0, OP_PP_KEEP_NODE},
  {"$func",   AST_FUNC,   false, 2, 2,          pp_action_func,    0, OP_PP_KEEP_NODE},
  {"$if",     AST_IF,     false, 2, 2,          pp_action_if,      0, OP_PP_KEEP_NODE},
  {"$set",    AST_SET,    false, 2, 2,          NULL,              0, OP_PP_KEEP_NODE},
  {"$decl",   AST_DECL,   true,  2, 2,          pp_action_decl,    0, OP_PP_KEEP_NODE},

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
