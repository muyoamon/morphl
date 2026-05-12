#ifndef MORPHL_AST_AST_H_
#define MORPHL_AST_AST_H_

#include <stddef.h>
#include <stdbool.h>

#include "util/util.h"
#include "typing/typing.h"

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
  AST_PROP,
  AST_SET,
  AST_BUILTIN,
  AST_OVERLOAD,
  AST_FILE,         // Block-like node representing a source file
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
  MorphlType* type;         /**< Resolved type, set by typing pass. NULL until then. */
  bool contributes_to_shape;
  bool contributes_to_layout;
  bool storage_is_mutable;
  MorphlStorageResidence storage_residence;
  Str extern_symbol;
  Str import_path;
  struct AstNode* import_module;
  bool import_module_shared;
  bool overload_has_selection;
  bool overload_select_self;
  size_t overload_selected_index;
  MorphlReprInfo repr;
  struct AstNode* lowered;
} AstNode;

AstNode* ast_new(AstKind kind);
AstNode* ast_make_leaf(AstKind kind, Str value, const char* filename, size_t row, size_t col);
bool ast_append_child(AstNode* node, AstNode* child);
AstNode* ast_clone(const AstNode* node);
void ast_free(AstNode* node);
void ast_print(const AstNode* node, InternTable* interns);


// helper

void ast_replace_ident(AstNode* root, InternTable* interns, Str name, AstNode* _new);
bool ast_shape_equals(const AstNode* a, const AstNode* b);
bool ast_substitute_idents(AstNode** root,
                           const Sym* param_syms,
                           AstNode** replacements,
                           size_t param_count);

#endif // MORPHL_AST_AST_H_
