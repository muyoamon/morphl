#include <assert.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <cstdlib>
#include <ctime>
#include <sstream>

extern "C" {
#include "parser/parser.h"
#include "lexer/lexer.h"
#include "util/util.h"
}

static std::string write_temp_file(const char* contents) {
  const char* tmpdir = std::getenv("TMP");
  if (!tmpdir) tmpdir = std::getenv("TEMP");
#ifdef _WIN32
  const char* fallback = "C:/Windows/Temp";
#else
  const char* fallback = "/tmp";
#endif
  if (!tmpdir) tmpdir = fallback;

  std::srand((unsigned)std::time(nullptr) ^ (unsigned)(uintptr_t)&tmpdir);

  for (int attempt = 0; attempt < 16; ++attempt) {
    std::ostringstream name;
    name << tmpdir;
#ifdef _WIN32
    name << "/";
#else
    name << "/";
#endif
    name << "morphl_test_" << std::rand() << ".tmp";
    std::string path = name.str();

    std::ofstream out(path, std::ios::trunc);
    if (!out.is_open()) continue;
    out << contents;
    out.close();
    return path;
  }

  assert(false && "failed to open temp file");
  return std::string();
}

static void test_grammar_loading() {
  const char* grammar_src = R"GRAM(rule expr:
    $expr lhs "+" %IDENT rhs => $extend lhs rhs
    $term => $lift
end

rule term:
    %NUMBER => $num
end
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 1024);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  assert(grammar.rule_count == 2);
  const GrammarRule& expr_rule = grammar.rules[0];
  assert(expr_rule.production_count == 2);
  assert(expr_rule.productions[0].starts_with_expr);
  assert(expr_rule.productions[0].atoms[0].min_bp == 0);
  assert(expr_rule.productions[1].atom_count == 1);
  assert(!expr_rule.productions[1].starts_with_expr);
  assert(grammar.start_rule == expr_rule.name);

  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  std::remove(grammar_path.c_str());
}

static void test_parser_accept_reject() {
  const char* grammar_src = R"GRAM(rule expr:
    %IDENT => $id
    %NUMBER => $num
    "(" $expr ")" => $group
    "-" $expr[30] rhs => $neg rhs
    $expr lhs "+" $expr[1] rhs => $add lhs rhs
    $expr lhs "-" $expr[1] rhs => $sub lhs rhs
    $expr[10] lhs "*" $expr[11] rhs => $mul lhs rhs
    $expr[10] lhs "/" $expr[11] rhs => $div lhs rhs
    $expr[1] lhs "^" $expr rhs => $pow lhs rhs
    $expr[40] base "!" => $fact base
end
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 4096);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  const char* source = "-foo + 2 ^ 3 ^ 4 * 5!";
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize("<test>", str_from(source, strlen(source)), interns, &tokens, &token_count));
  assert(tokens != NULL);
  assert(grammar_parse(&grammar, 0, tokens, token_count));

  const char* bad_source = "foo +";
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
