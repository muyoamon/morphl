#ifndef MORPHL_PARSER_BUILTIN_PARSER_H_
#define MORPHL_PARSER_BUILTIN_PARSER_H_

#include <stdbool.h>
#include <stddef.h>

#include "tokens/tokens.h"
#include "ast/ast.h"

/**
 * @brief Parse a token stream using builtin operator rules only.
 *
 * This fallback parser handles the core builtin operators ($decl, $add, etc.)
 * without requiring a grammar file. All builtins use prefix notation with
 * natural nesting.
 *
 * Supported builtins:
 * - Declarations: $decl, $alias
 * - Functions: $func, $call, $ret
 * - Control flow: $if
 * - Storage: $mut, $const, $inline
 * - Arithmetic: $add, $sub, $mul, $div
 * - Float arithmetic: $fadd, $fsub, $fmul, $fdiv
 * - Binary: $band, $bor, $bnot, $lshift, $rshift
 * - Logic: $and, $or, $not
 * - Comparison: $eq, $neq, $gt, $lt, $gte, $lte
 * - Compound: $group, $block, $tuple
 * - Import: $import, $syntax
 * - Meta: $idtstr, $strtid
 * - Namespace: $this, $file, $global, $member
 * - Subtyping: $trait, $impl, $prop, $as
 *
 * @param tokens      Token stream to parse.
 * @param token_count Number of tokens.
 * @param interns     Intern table for symbol names.
 * @param out_root    On success, receives the root AST node. Caller owns and must free.
 * @return true on success, false on parse error.
 */
bool builtin_parse_ast(const struct token* tokens,
                       size_t token_count,
                       InternTable* interns,
                       AstNode** out_root);

/**
 * @brief Parse a single expression using builtin operators with cursor tracking.
 *
 * This function parses one expression starting at *cursor and advances the cursor
 * past the consumed tokens. Useful for incremental parsing within a larger stream.
 *
 * @param tokens      Token stream to parse.
 * @param token_count Number of tokens.
 * @param cursor      Current position; updated to point past the parsed expression.
 * @param interns     Intern table for symbol names.
 * @param out_node    On success, receives the parsed AST node. Caller owns and must free.
 * @return true on success, false on parse error.
 */
bool builtin_parse_expr(const struct token* tokens,
                        size_t token_count,
                        size_t* cursor,
                        InternTable* interns,
                        AstNode** out_node);

#endif // MORPHL_PARSER_BUILTIN_PARSER_H_
