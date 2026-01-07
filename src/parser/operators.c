#include "parser/operators.h"
#include "parser/scoped_parser.h"
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
  (void)info; (void)global_state; (void)block_state;
  if (arg_count < 1) return NULL;
  // Arg[0]: the function (identifier or another expr)
  // Arg[1]: Parameters as group or single expr
  // Future: type checking, overload resolution
  (void)args;
  return NULL;
}

// $func: validate parameters block + body block
static MorphlType* pp_action_func(const OperatorInfo* info,
                                   void* global_state,
                                   void* block_state,
                                   AstNode** args,
                                   size_t arg_count) {
  (void)info; (void)global_state; (void)block_state;
  if (arg_count < 2) return NULL;
  // Arg[0]: parameter list 
  // Arg[1]: function expression/block 
  // Future: validate parameter structure, infer return type
  (void)args;
  return NULL;
}

// $if: validate condition, then-block, else-block structure
static MorphlType* pp_action_if(const OperatorInfo* info,
                                 void* global_state,
                                 void* block_state,
                                 AstNode** args,
                                 size_t arg_count) {
  (void)info; (void)global_state; (void)block_state;
  if (arg_count != 2) return NULL;
  // args[0]: condition expression
  // args[1]: then-else group (allow single-element group for then-only)
  // Future: check condition type is boolean-compatible
  (void)args;
  return NULL;
}

static MorphlType* pp_action_decl(const OperatorInfo* info,
                                 void* global_state,
                                 void* block_state,
                                 AstNode** args,
                                 size_t arg_count) {
  (void)info; (void)global_state; (void)block_state; (void)args; (void)arg_count;
  // Arg[0]: identifier
  // Arg[1]: initial expression
  // Future: handle variable declaration semantics
  return NULL;
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
