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
  if (!scoped_parser_replace_grammar(ctx, filename)) {
    fprintf(stderr, "pp $syntax: failed to load grammar '%s'\n", filename);
  } else {
    Grammar* g = scoped_parser_current_grammar(ctx);
    Str name = g && g->start_rule ? interns_lookup(ctx->interns, g->start_rule) : str_from(NULL, 0);
    fprintf(stderr, "pp $syntax: loaded grammar '%s' (start=%.*s, rules=%zu)\n", filename,
            (int)name.len, name.ptr ? name.ptr : "", g ? g->rule_count : 0);
    if (g) {
      for (size_t i = 0; i < g->rule_count; ++i) {
        Str rn = interns_lookup(ctx->interns, g->rules[i].name);
        fprintf(stderr, "  rule[%zu]=%.*s\n", i, (int)rn.len, rn.ptr ? rn.ptr : "");
      }
    }
  }
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
  // Future: attach properties to current declaration context
  return NULL;
}

static OperatorRow kBuiltinOps[] = {
  // Structural
  {"$group",  AST_GROUP,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},
  {"$block",  AST_BLOCK,  false, 0, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},

  // Core constructs
  {"$call",   AST_CALL,   false, 1, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},
  {"$func",   AST_FUNC,   false, 2, (size_t)-1, NULL,              0, OP_PP_KEEP_NODE},
  {"$if",     AST_IF,     false, 3, 3,           NULL,              0, OP_PP_KEEP_NODE},
  {"$set",    AST_SET,    false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$decl",   AST_DECL,   true,  2, 2,           NULL,              0, OP_PP_KEEP_NODE},

  // Arithmetic (no pp actions yet; type checker will use registry later)
  {"$add",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$sub",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$mul",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$div",    AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fadd",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fsub",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fmul",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},
  {"$fdiv",   AST_BUILTIN,false, 2, 2,           NULL,              0, OP_PP_KEEP_NODE},

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
