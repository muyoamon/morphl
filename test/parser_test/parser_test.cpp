#include <catch2/catch_test_macros.hpp>
#include "../../src/parser/parser.h"
#include "../../src/lexer/lexer.h"

TEST_CASE("Parser: Pure Literal", "[parser]") {
    std::string input = "\"Hello World!\"?";
    morphl::Lexer l(input);
    morphl::parser::Parser parser(l.tokens());

    parser.parse();
    // ... (Add more assertions for member nodes)
}

TEST_CASE("Parser: Pure Expression Statement", "[parser]") {
    std::string input = "ADD 5 2?"; 
    morphl::Lexer l(input);
    morphl::parser::Parser parser(l.tokens());

    parser.parse();

    // ... (Add more assertions for the expression node)
}

TEST_CASE("Parser: Declaration Statement", "[parser]") {
  std::string input = "DECL x 0;";
  morphl::Lexer l(input);
  morphl::parser::Parser parser(l.tokens());

  parser.parse();
}

