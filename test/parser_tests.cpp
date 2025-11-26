#include <assert.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <unistd.h>

extern "C" {
#include "parser/parser.h"
#include "lexer/lexer.h"
#include "util/util.h"
}

static std::string write_temp_file(const char* contents) {
  char path[] = "/tmp/morphl_test_XXXXXX";
  int fd = mkstemp(path);
  assert(fd != -1 && "mkstemp failed");
  close(fd);
  std::ofstream out(path, std::ios::trunc);
  out << contents;
  out.close();
  return std::string(path);
}

static void test_grammar_loading() {
  const char* grammar_src = R"GRAM(expr := %NUMBER
expr += '+' %NUMBER
expr +=
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 1024);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  assert(grammar.rule_count == 1);
  const GrammarRule& rule = grammar.rules[0];
  assert(rule.production_count == 3);
  assert(rule.productions[0].atom_count == 1);
  assert(rule.productions[1].atom_count == 2);
  assert(rule.productions[2].atom_count == 0);
  assert(grammar.start_rule == rule.name);

  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  std::remove(grammar_path.c_str());
}

static void test_parser_accept_reject() {
  const char* grammar_src = R"GRAM(start := $function
function := %IDENT "(" $params ")" "->" $expr ";"
params := %IDENT $params_tail
params +=
params_tail := "," %IDENT $params_tail
params_tail +=
expr := $term $expr_tail
expr_tail := "+" $term $expr_tail
expr_tail += "-" $term $expr_tail
expr_tail +=
term := $factor $term_tail
term_tail := "*" $factor $term_tail
term_tail += "/" $factor $term_tail
term_tail +=
factor := "(" $expr ")"
factor += %IDENT
factor += %NUMBER
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 4096);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  const char* source = "foo(x, y) -> x + y;";
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize("<test>", str_from(source, strlen(source)), interns, &tokens, &token_count));
  assert(tokens != NULL);
  assert(grammar_parse(&grammar, 0, tokens, token_count));

  const char* bad_source = "foo(x y) -> x;";
  struct token* bad_tokens = NULL;
  size_t bad_count = 0;
  assert(lexer_tokenize("<test>", str_from(bad_source, strlen(bad_source)), interns, &bad_tokens, &bad_count));
  assert(!grammar_parse(&grammar, 0, bad_tokens, bad_count));

  free(tokens);
  free(bad_tokens);
  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  std::remove(grammar_path.c_str());
}

int main() {
  test_grammar_loading();
  test_parser_accept_reject();
  std::puts("All parser tests passed.");
  return 0;
}
