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

#endif // MORPHL_PARSER_BUILTIN_PARSER_H_
