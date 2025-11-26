#ifndef MORPHL_PARSER_PARSER_H_
#define MORPHL_PARSER_PARSER_H_

#include <stddef.h>
#include <stdbool.h>

#include "tokens/tokens.h"

/**
 * @brief Specifies the kind of atom a grammar production can contain.
 */
typedef enum GrammarAtomKind {
  GRAMMAR_ATOM_LITERAL,   /**< A literal token lexeme to match. */
  GRAMMAR_ATOM_RULE,      /**< A reference to another grammar rule (e.g. `$name`). */
  GRAMMAR_ATOM_TOKEN_KIND /**< A token-kind match (e.g. `%IDENT`). */
} GrammarAtomKind;

/**
 * @brief A single production atom, either a literal token, a rule reference, or
 * a token-kind match.
 */
typedef struct GrammarAtom {
  GrammarAtomKind kind; /**< The atom type. */
  Sym symbol;           /**< Rule name or token kind, depending on @ref kind. */
  Str literal;          /**< Literal token text for GRAMMAR_ATOM_LITERAL. */
} GrammarAtom;

/**
 * @brief A production rule represented as a sequence of atoms.
 */
typedef struct Production {
  GrammarAtom* atoms;      /**< Ordered atoms in this production. */
  size_t atom_count;       /**< Number of atoms. */
  size_t atom_capacity;    /**< Allocated atom slots. */
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
 * Grammar files support the following syntax:
 * - `name := ...` declares a rule and replaces any previous productions.
 * - `name += ...` appends an additional production to an existing rule.
 * - `$other` inserts a reference to another rule named `other`.
 * - `%KIND` matches a token kind by name (for example `%IDENT`).
 * - Bare words or quoted strings match literal token lexemes.
 * - Empty productions are allowed by omitting atoms after the operator.
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

#endif // MORPHL_PARSER_PARSER_H_
