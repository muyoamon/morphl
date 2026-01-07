#ifndef MORPHL_PARSER_SCOPED_PARSER_H_
#define MORPHL_PARSER_SCOPED_PARSER_H_

#include <stddef.h>
#include <stdbool.h>

#include "tokens/tokens.h"
#include "ast/ast.h"
#include "parser/parser.h"
#include "util/util.h"

/**
 * @brief Parse context that maintains a grammar stack for scoped $syntax.
 *
 * The grammar stack enables lexically-scoped grammar changes:
 * - At file start, builtin-only grammar is active
 * - `$syntax "file"` replaces the current scope's grammar
 * - Entering a block pushes current grammar; exiting pops it
 * - Each imported file gets its own independent grammar scope
 */
typedef struct ScopedParserContext {
  Grammar** grammar_stack;     /**< Stack of active grammars. */
  size_t grammar_stack_size;   /**< Number of grammars on stack. */
  size_t grammar_stack_cap;    /**< Allocated stack capacity. */
  InternTable* interns;        /**< Shared intern table. */
  Arena* arena;                /**< Arena for grammar string allocations. */
  bool use_builtins;           /**< Whether current scope uses builtin fallback. */
} ScopedParserContext;

/**
 * @brief Initialize a scoped parser context.
 *
 * @param ctx     Context to initialize.
 * @param interns Intern table for symbols.
 * @param arena   Arena for string allocations.
 * @return true on success, false on allocation failure.
 */
bool scoped_parser_init(ScopedParserContext* ctx, InternTable* interns, Arena* arena);

/**
 * @brief Free scoped parser context resources.
 *
 * @param ctx Context to free.
 */
void scoped_parser_free(ScopedParserContext* ctx);

/**
 * @brief Push a new grammar onto the stack (entering a new scope).
 *
 * @param ctx     Parser context.
 * @param grammar Grammar to push (NULL for builtin-only).
 * @return true on success, false on allocation failure.
 */
bool scoped_parser_push_grammar(ScopedParserContext* ctx, Grammar* grammar);

/**
 * @brief Pop the top grammar from the stack (exiting a scope).
 *
 * @param ctx Parser context.
 * @return true if a grammar was popped, false if stack is empty.
 */
bool scoped_parser_pop_grammar(ScopedParserContext* ctx);

/**
 * @brief Replace the current scope's grammar (for $syntax directive).
 *
 * @param ctx          Parser context.
 * @param grammar_path Path to new grammar file.
 * @return true on success, false on load failure.
 */
bool scoped_parser_replace_grammar(ScopedParserContext* ctx, const char* grammar_path);

/**
 * @brief Get the currently active grammar.
 *
 * @param ctx Parser context.
 * @return Current grammar, or NULL if using builtin-only.
 */
Grammar* scoped_parser_current_grammar(ScopedParserContext* ctx);

/**
 * @brief Parse a token stream with scoped grammar support.
 *
 * This parser handles:
 * - Builtin operator fallback when no custom grammar is active
 * - `$syntax "file"` directives that replace the current grammar
 * - Block-level grammar scoping (grammar changes are local to blocks)
 * - Proper handling of nested blocks and imports
 *
 * @param ctx         Parser context with grammar stack.
 * @param tokens      Token stream to parse.
 * @param token_count Number of tokens.
 * @param out_root    On success, receives the root AST node. Caller owns.
 * @return true on success, false on parse error.
 */
bool scoped_parse_ast(ScopedParserContext* ctx,
                     const struct token* tokens,
                     size_t token_count,
                     AstNode** out_root);

#endif // MORPHL_PARSER_SCOPED_PARSER_H_
