#include "parser/operators.h"

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
} OperatorRow;

static OperatorRow kBuiltinOps[] = {
  {"$group", AST_GROUP, false, 0, (size_t)-1, NULL, 0},
  {"$block", AST_BLOCK, false, 0, (size_t)-1, NULL, 0},
  {"$syntax", AST_BUILTIN, true, 1, 1, NULL, 0},
  {"$decl", AST_BUILTIN, true, 2, 2, NULL, 0},
  {"$import", AST_BUILTIN, true, 1, 1, NULL, 0},
  {"$prop", AST_BUILTIN, true, 1, 1, NULL, 0},
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
      return &out;
    }
  }
  return NULL;
}
