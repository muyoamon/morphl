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
#include "parser/operators.h"
#include "parser/scoped_parser.h"
#include "lexer/lexer.h"
#include "util/util.h"
#include "ast/ast.h"
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

static AstNode* parse_scoped_source(InternTable* interns,
                                    Arena* arena,
                                    const std::string& path,
                                    ScopedParserContext* out_ctx) {
  assert(scoped_parser_init(out_ctx, interns, arena, path.c_str()));

  std::ifstream in(path, std::ios::binary);
  assert(in.is_open());
  std::stringstream buffer;
  buffer << in.rdbuf();
  std::string source = buffer.str();

  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize(path.c_str(),
                        str_from(source.c_str(), source.size()),
                        interns,
                        &tokens,
                        &token_count));

  AstNode* root = NULL;
  assert(scoped_parse_ast(out_ctx, tokens, token_count, &root));
  free(tokens);
  return root;
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

static void test_parser_ast_build() {
  const char* grammar_src = R"GRAM(rule expr:
    %IDENT => ident
    %NUMBER => number
    $expr lhs "+" $expr[1] rhs => add lhs rhs
end
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 4096);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  const char* source = "foo + 2";
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize("<test>", str_from(source, strlen(source)), interns, &tokens, &token_count));

  AstNode* root = NULL;
  assert(grammar_parse_ast(&grammar, 0, tokens, token_count, &root));
  assert(root != NULL);
  Sym add_sym = interns_intern(interns, str_from("add", 3));
  assert(root->kind == AST_BUILTIN);
  assert(root->op == add_sym);
  assert(root->child_count == 2);
  assert(root->children[0]->kind == AST_IDENT);
  assert(root->children[1]->kind == AST_LITERAL);

  ast_free(root);
  free(tokens);
  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  std::remove(grammar_path.c_str());
}

static void test_float_literal_token_kind() {
  const char* grammar_src = R"GRAM(rule expr:
    %NUMBER => number
end
)GRAM";

  std::string grammar_path = write_temp_file(grammar_src);

  InternTable* interns = interns_new();
  assert(interns != nullptr);

  Arena arena;
  arena_init(&arena, 4096);

  Grammar grammar;
  assert(grammar_load_file(&grammar, grammar_path.c_str(), interns, &arena));

  const char* source = "3.14";
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize("<test>", str_from(source, strlen(source)), interns, &tokens, &token_count));

  AstNode* root = NULL;
  assert(grammar_parse_ast(&grammar, 0, tokens, token_count, &root));
  assert(root != NULL);
  assert(root->kind == AST_LITERAL);

  Sym float_sym = interns_intern(interns, str_from(LEXER_KIND_FLOAT, strlen(LEXER_KIND_FLOAT)));
  assert(root->op == float_sym);

  ast_free(root);
  free(tokens);
  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  std::remove(grammar_path.c_str());
}

static void test_scoped_builtin_ast_locations() {
  InternTable* interns = interns_new();
  assert(interns != nullptr);
  assert(operator_registry_init(interns));

  Arena arena;
  arena_init(&arena, 4096);

  const char* source_path = "unit_test.mpl";
  const char* source = "$add 1 2;";
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize(source_path, str_from(source, strlen(source)), interns, &tokens, &token_count));

  ScopedParserContext ctx;
  assert(scoped_parser_init(&ctx, interns, &arena, source_path));

  AstNode* root = NULL;
  assert(scoped_parse_ast(&ctx, tokens, token_count, &root));
  assert(root != NULL);
  assert(root->kind == AST_FILE);
  assert(root->filename != NULL);
  assert(std::strcmp(root->filename, source_path) == 0);
  assert(root->child_count == 1);
  assert(root->children[0]->filename != NULL);
  assert(std::strcmp(root->children[0]->filename, source_path) == 0);
  assert(root->children[0]->row == 1);
  assert(root->children[0]->col == 1);

  ast_free(root);
  scoped_parser_free(&ctx);
  free(tokens);
  arena_free(&arena);
  interns_free(interns);
}

static void test_scoped_import_preserves_literal_and_reuses_cache() {
  std::string module_path = write_temp_file("$decl value 42;\n");
  std::string source =
      std::string("$decl dep_a $import \"") + module_path + "\";\n" +
      std::string("$decl dep_b $import \"") + module_path + "\";\n";
  std::string source_path = write_temp_file(source.c_str());

  InternTable* interns = interns_new();
  assert(interns != nullptr);
  assert(operator_registry_init(interns));

  Arena arena;
  arena_init(&arena, 4096);

  ScopedParserContext ctx;
  AstNode* root = parse_scoped_source(interns, &arena, source_path, &ctx);
  assert(root != NULL);
  assert(root->kind == AST_FILE);
  assert(root->child_count == 2);
  assert(ctx.import_cache_count == 1);

  AstNode* first_decl = root->children[0];
  AstNode* second_decl = root->children[1];
  assert(first_decl->kind == AST_DECL && first_decl->child_count >= 2);
  assert(second_decl->kind == AST_DECL && second_decl->child_count >= 2);

  AstNode* first_import = first_decl->children[1];
  AstNode* second_import = second_decl->children[1];
  assert(first_import->kind == AST_BUILTIN);
  assert(second_import->kind == AST_BUILTIN);
  assert(first_import->child_count == 1);
  assert(second_import->child_count == 1);

  AstNode* first_arg = first_import->children[0];
  AstNode* second_arg = second_import->children[0];
  assert(first_arg->kind == AST_LITERAL);
  assert(second_arg->kind == AST_LITERAL);
  assert(first_arg->import_path.ptr != NULL);
  assert(second_arg->import_path.ptr != NULL);
  assert(std::strcmp(first_arg->import_path.ptr, module_path.c_str()) == 0);
  assert(std::strcmp(second_arg->import_path.ptr, module_path.c_str()) == 0);
  assert(first_arg->import_module != NULL);
  assert(second_arg->import_module != NULL);
  assert(first_arg->import_module == second_arg->import_module);
  assert(first_arg->import_module->kind == AST_FILE);

  ast_free(root);
  scoped_parser_free(&ctx);
  arena_free(&arena);
  interns_free(interns);
  std::remove(source_path.c_str());
  std::remove(module_path.c_str());
}

int main() {
  test_grammar_loading();
  test_parser_accept_reject();
  test_parser_ast_build();
  test_float_literal_token_kind();
  test_scoped_builtin_ast_locations();
  test_scoped_import_preserves_literal_and_reuses_cache();
  std::puts("All parser tests passed.");
  return 0;
}
