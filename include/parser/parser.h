#ifndef MORPHL_PARSER_PARSER_H_
#define MORPHL_PARSER_PARSER_H_

#include <stddef.h>
#include <stdbool.h>

#include "tokens/tokens.h"
#include "ast/ast.h"

/**
 * @brief Specifies the kind of atom a grammar production can contain.
 */
typedef enum GrammarAtomKind {
  GRAMMAR_ATOM_LITERAL,    /**< A literal token lexeme to match. */
  GRAMMAR_ATOM_TOKEN_KIND, /**< A token-kind match (e.g. `%IDENT`). */
  GRAMMAR_ATOM_RULE,       /**< A recursive rule reference with optional binding power. */
  GRAMMAR_ATOM_REPEAT      /**< A grouped subpattern with repetition (e.g. $( "," $expr )+ ). */
} GrammarAtomKind;

/**
 * @brief A single production atom, either a literal token, a rule reference, or
 * a token-kind match.
 */
typedef struct GrammarAtom {
  GrammarAtomKind kind; /**< The atom type. */
  Sym symbol;           /**< Token/rule symbol for @ref GRAMMAR_ATOM_TOKEN_KIND and @ref GRAMMAR_ATOM_RULE. */
  Str literal;          /**< Literal token text for @ref GRAMMAR_ATOM_LITERAL. */
  size_t min_bp;        /**< Minimum binding power for @ref GRAMMAR_ATOM_RULE. */
  Sym capture;          /**< Optional capture name (interned). */

  /* Repeat-specific fields (used when kind == GRAMMAR_ATOM_REPEAT) */
  struct GrammarAtom* subatoms;    /**< Inline grouped subpattern atoms. */
  size_t subatom_count;     /**< Number of subpattern atoms. */
  size_t subatom_capacity;  /**< Allocated subpattern atom slots. */
  size_t min_occurs;        /**< Minimum repetitions (0,1, etc.). */
  size_t max_occurs;        /**< Maximum repetitions (SIZE_MAX for unbounded). */
} GrammarAtom;

/**
 * @brief A production rule represented as a sequence of atoms.
 * Supports overloading via multiple template alternatives (separated by `|` in grammar).
 */
typedef struct Production {
  GrammarAtom* atoms;          /**< Ordered atoms in this production. */
  size_t atom_count;           /**< Number of atoms. */
  size_t atom_capacity;        /**< Allocated atom slots. */
  Str* templates;              /**< Array of template alternatives (candidates). */
  size_t template_count;       /**< Number of template alternatives. */
  size_t template_capacity;    /**< Allocated template slots. */
  bool starts_with_expr;       /**< True when the first atom recurses into the same rule. */
} Production;

/**
 * @brief A named grammar rule with one or more productions.
 */
typedef struct GrammarRule {
  Sym name;                /**< Interned rule name. */
  Production* productions; /**< Production list. */
  size_t production_count; /**< Number of productions. */
  size_t production_cap;   /**< Allocated production slots. */
} GrammarRule;

/**
 * @brief Dynamic grammar loaded from a text description.
 *
 * Grammar files support a rule-oriented syntax:
 *
 * ```
 * rule <name>:
 *   <pattern1> => <template1>
 *   <pattern2> => <template2>
 * end
 * ```
 *
 * Patterns are whitespace-separated tokens consisting of literal matches (bare
 * words or quoted strings), token-kind matches (`%IDENT`), and recursive rule
 * references. A rule placeholder is written `$name[n]` where *name* is a rule
 * identifier and *n* is the minimum binding power to parse for that operand.
 * Omitting the square-bracket suffix defaults the binding power to zero.
 * Associativity is expressed by using different binding powers for left and
 * right operands of an operator.
 * The text after `=>` is captured as a template string for downstream
 * expansion; the parser does not interpret template contents directly.
 */
typedef struct Grammar {
  GrammarRule* rules;      /**< Rule list. */
  size_t rule_count;       /**< Number of rules. */
  size_t rule_cap;         /**< Allocated rule slots. */
  Sym start_rule;          /**< Start symbol (first rule seen). */
  InternTable* names;      /**< Intern table for rule/kind names. */
} Grammar;

/**
 * @brief Load a grammar from a text file.
 *
 * @param grammar Destination grammar structure to populate.
 * @param path    Path to the grammar description file.
 * @param interns Intern table used to intern rule names and token kinds.
 * @param arena   Arena used to store literal strings for the lifetime of the grammar.
 * @return true on success, false on parse or allocation failure.
 */
bool grammar_load_file(Grammar* grammar,
                       const char* path,
                       InternTable* interns,
                       Arena* arena);

/**
 * @brief Release grammar allocations.
 *
 * Literal strings are owned by the provided arena; only dynamic arrays are
 * freed here.
 */
void grammar_free(Grammar* grammar);

/**
 * @brief Parse a token stream according to the supplied grammar.
 *
 * This routine performs a depth-first search over productions, consuming tokens
 * when atoms match. For literal atoms the token lexeme must match exactly;
 * token-kind atoms match by kind symbol; rule atoms recursively invoke the
 * referenced rule. The parse succeeds only when the start rule consumes all
 * tokens supplied.
 *
 * @param grammar     Grammar to use.
 * @param start_rule  Optional start symbol; when zero the grammar's first rule
 *                    is used.
 * @param tokens      Token stream to parse.
 * @param token_count Number of tokens in the stream.
 * @return true when the entire token sequence is accepted.
 */
bool grammar_parse(const Grammar* grammar,
                   Sym start_rule,
                   const struct token* tokens,
                   size_t token_count);

/**
 * @brief Parse a token stream and produce an AST (experimental).
 *
 * Currently returns a boolean success indicator and, on success, sets
 * *out_root to the parsed tree. The AST shape is subject to change as
 * the language evolves. Caller owns the returned AST and must free it
 * with ast_free().
 */
bool grammar_parse_ast(const Grammar* grammar,
                       Sym start_rule,
                       const struct token* tokens,
                       size_t token_count,
                       AstNode** out_root);

#endif // MORPHL_PARSER_PARSER_H_
