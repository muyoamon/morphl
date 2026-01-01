#ifndef MORPHL_AST_AST_H_
#define MORPHL_AST_AST_H_

#include <stddef.h>
#include <stdbool.h>

#include "util/util.h"



/**
 * @brief Kinds of AST nodes supported by the core language.
 */
typedef enum AstKind {
  AST_LITERAL,
  AST_IDENT,
  AST_CALL,
  AST_FUNC,
  AST_IF,
  AST_BLOCK,
  AST_GROUP,
  AST_DECL,
  AST_SET,
  AST_BUILTIN,
  AST_OVERLOAD,
  AST_UNKNOWN
} AstKind;

/**
 * @brief AST node representation.
 *
 * For operator-like nodes, `op` holds the operator symbol (interned Sym).
 * For literal and identifier leaves, `value` holds the source text.
 */
typedef struct AstNode {
  AstKind kind;             /**< Node kind. */
  Sym op;                   /**< Operator/builtin symbol (optional). */
  Str value;                /**< Literal/identifier text when applicable. */
  struct AstNode** children;/**< Child nodes. */
  size_t child_count;       /**< Number of children. */
  size_t child_capacity;    /**< Allocated child slots. */
  const char* filename;     /**< Source filename for diagnostics. */
  size_t row;               /**< 1-based line. */
  size_t col;               /**< 1-based column. */
} AstNode;

AstNode* ast_new(AstKind kind);
AstNode* ast_make_leaf(AstKind kind, Str value, const char* filename, size_t row, size_t col);
bool ast_append_child(AstNode* node, AstNode* child);
void ast_free(AstNode* node);
void ast_print(const AstNode* node, InternTable* interns);



#endif // MORPHL_AST_AST_H_
