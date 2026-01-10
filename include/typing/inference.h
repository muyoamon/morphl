#ifndef MORPHL_TYPING_INFERENCE_H_
#define MORPHL_TYPING_INFERENCE_H_

#include "typing/typing.h"
#include "typing/type_context.h"
#include "util/util.h"
#include "ast/ast.h"
#include <stdbool.h>

/**
 * @brief Type inference for operators.
 *
 * Infers the result type of an operator given its argument types.
 * Returns the inferred type, or NULL on type error.
 *
 * @param ctx TypeContext for error reporting and type allocation
 * @param node AST node for span-aware diagnostics
 * @param op_sym Operator symbol (e.g., $add, $eq, etc.)
 * @param arg_types Array of argument types
 * @param arg_count Number of arguments
 * @return Inferred result type, or NULL on error
 */
MorphlType* morphl_infer_type_for_op(TypeContext* ctx,
                                     const AstNode* node,
                                     Sym op_sym,
                                     MorphlType** arg_types,
                                     size_t arg_count);

/**
 * @brief Infer type from an AST node.
 *
 * Recursively infers the type of an expression AST node.
 * For builtin operators, uses morphl_infer_type_for_op.
 * For identifiers, looks up in scope.
 * For literals, infers literal type.
 *
 * @param ctx TypeContext
 * @param node AST node
 * @return Inferred type, or NULL if type unknown
 */
MorphlType* morphl_infer_type_of_ast(TypeContext* ctx, AstNode* node);

#endif  // MORPHL_TYPING_INFERENCE_H_
