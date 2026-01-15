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

/**
 * @brief Policy for how a preprocessor op contributes to the AST.
 */
typedef enum OperatorPPResultPolicy {
  OP_PP_KEEP_NODE = 0,  // Keep the node in the AST
  OP_PP_DROP_NODE = 1   // Drop the node after executing side effects
} OperatorPPResultPolicy;

/**
 * @brief Function signature for operator preprocessor actions.
 */
typedef MorphlType* (*OperatorPPActionFunc)(const OperatorInfo* info,
                                            void* global_state,
                                            void* block_state,
                                            AstNode** args,
                                            size_t arg_count);

enum Operator{
  SYNTAX,
  IMPORT,
  PROP,
  CALL,
  FUNC,
  IF,
  WHILE,
  SET,
  DECL,
  RET,
  MEMBER,
  MUT,
  CONST,
  INLINE,
  THIS,
  FILE_,  // FILE is a reserved keyword in C
  GLOBAL,
  IDTSTR,
  STRTID,
  FORWARD,
  BREAK,
  CONTINUE,
  GROUP,
  BLOCK,
  ADD,
  SUB,
  MUL,
  DIV,
  MOD,
  REM,
  FADD,
  FSUB,
  FMUL,
  FDIV,
  EQ,
  NEQ,
  LT,
  GT,
  LTE,
  GTE,
  AND,
  OR,
  NOT,
  BAND,
  BOR,
  BXOR,
  BNOT,
  LSHIFT,
  RSHIFT
};

struct OperatorInfo {
  enum Operator op_enum;     // enum value for this operator
  Sym op;                    // interned operator symbol
  AstKind ast_kind;          // preferred AST kind for this op
  OperatorPPActionFunc func; // optional preprocessing action
  size_t min_args;           // minimum expected operands (hint only)
  size_t max_args;           // maximum expected operands (SIZE_MAX for variadic)
  bool is_preprocessor;      // true for ops like $syntax/$prop/$import
  OperatorPPResultPolicy pp_policy; // policy for AST retention
};

/**
 * @brief Initialize operator registry by interning builtin operator names.
 */
bool operator_registry_init(InternTable* interns);

/**
 * @brief Lookup operator metadata by interned symbol.
 */
const OperatorInfo* operator_info_lookup(Sym op);



#define __VALUE_OF(x) #x
#define OPERATOR_STR(op) ("$" __VALUE_OF(op))

const OperatorInfo* operator_info_from_enum(enum Operator op);
Sym operator_sym_from_enum(enum Operator op);

#endif // MORPHL_PARSER_OPERATORS_H_
