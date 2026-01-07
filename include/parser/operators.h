#ifndef MORPHL_PARSER_OPERATORS_H_
#define MORPHL_PARSER_OPERATORS_H_

#include <stdbool.h>
#include <stddef.h>

#include "ast/ast.h"
#include "util/util.h"

// Forward declaration to avoid pulling type system headers here
struct MorphlType;
typedef struct MorphlType MorphlType;

typedef struct OperatorInfo OperatorInfo;

typedef MorphlType* (*OperatorPPActionFunc)(const OperatorInfo* info,
                                            void* global_state,
                                            void* block_state,
                                            AstNode** args,
                                            size_t arg_count);

struct OperatorInfo {
  Sym op;                    // interned operator symbol
  AstKind ast_kind;          // preferred AST kind for this op
  OperatorPPActionFunc func; // optional preprocessing action
  size_t min_args;           // minimum expected operands (hint only)
  size_t max_args;           // maximum expected operands (SIZE_MAX for variadic)
  bool is_preprocessor;      // true for ops like $syntax/$prop/$import
};

/**
 * @brief Initialize operator registry by interning builtin operator names.
 */
bool operator_registry_init(InternTable* interns);

/**
 * @brief Lookup operator metadata by interned symbol.
 */
const OperatorInfo* operator_info_lookup(Sym op);

#endif // MORPHL_PARSER_OPERATORS_H_
