#include <catch2/catch_test_macros.hpp>
#include <string>
#include <vector>
#include "../../src/lexer/lexer.h"

TEST_CASE("Lexer: Basic Tokenization", "[lexer]") {
    std::string input = "Point { x: int; y: int; }";
    morphl::Lexer lexer(input);

    std::vector<morphl::Token> expectedTokens = {
        {morphl::IDENTIFIER, "Point"},
        {morphl::SYMBOL, "{"},
        {morphl::IDENTIFIER, "x"},
        {morphl::SYMBOL, ":"},
        {morphl::IDENTIFIER, "int"},
        {morphl::SYMBOL, ";"},
        {morphl::IDENTIFIER, "y"},
        {morphl::SYMBOL, ":"},
        {morphl::IDENTIFIER, "int"},
        {morphl::SYMBOL, ";"},
        {morphl::SYMBOL, "}"},
        {morphl::EOF_, ""}
    };

    std::vector<morphl::Token> actualTokens = lexer.tokens();

    REQUIRE(actualTokens == expectedTokens);
}

TEST_CASE("Lexer: Statement Endings", "[lexer]") {
    std::string input = "x = 5 + 2? y = 10;";
    morphl::Lexer lexer(input);

    std::vector<morphl::Token> expectedTokens = {
        {morphl::IDENTIFIER, "x"},
        {morphl::SYMBOL, "="},
        {morphl::INT_LITERAL, "5"},
        {morphl::SYMBOL, "+"},
        {morphl::INT_LITERAL, "2"},
        {morphl::SYMBOL, "?"},
        {morphl::IDENTIFIER, "y"},
        {morphl::SYMBOL, "="},
        {morphl::INT_LITERAL, "10"},
        {morphl::SYMBOL, ";"},
        {morphl::EOF_, ""}
    };

    std::vector<morphl::Token> actualTokens = lexer.tokens();

    REQUIRE(actualTokens == expectedTokens);
}

TEST_CASE("Lexer: String Literal", "[Lexer]") {
  std::string input = "x = \"Hello!\";";
  morphl::Lexer l(input);

  std::vector<morphl::Token> expectedTokens = {
    {morphl::IDENTIFIER,"x"},
    {morphl::SYMBOL, "="},
    {morphl::STRING_LITERAL, "Hello!"},
    {morphl::SYMBOL, ";"},
    {morphl::EOF_,""}
  };

  std::vector<morphl::Token> actualTokens = l.tokens();

  REQUIRE(actualTokens == expectedTokens);
}

TEST_CASE("Lexer: Float Literal", "[Lexer]") {
  std::string input = "x = 1.123;";
  morphl::Lexer l(input);

  std::vector<morphl::Token> expectedTokens = {
    {morphl::IDENTIFIER,"x"},
    {morphl::SYMBOL, "="},
    {morphl::FLOAT_LITERAL, "1.123"},
    {morphl::SYMBOL, ";"},
    {morphl::EOF_,""}
  };

  std::vector<morphl::Token> actualTokens = l.tokens();

  REQUIRE(actualTokens == expectedTokens);
}

TEST_CASE("Lexer: morph syntax", "[Lexer]") {
  std::string input = "morph keyword while \%condition \%block (\%condition: (), \%block: {} ) {}";
  morphl::Lexer l(input);

  std::vector<morphl::Token> expectedTokens = {
    {morphl::IDENTIFIER, "morph"},
    {morphl::IDENTIFIER, "keyword"},
    {morphl::IDENTIFIER, "while"},
    {morphl::OPERAND, "condition"},
    {morphl::OPERAND, "block"},
    {morphl::SYMBOL, "("},
    {morphl::OPERAND, "condition"},
    {morphl::SYMBOL, ":"},
    {morphl::SYMBOL, "("},
    {morphl::SYMBOL, ")"},
    {morphl::SYMBOL, ","},
    {morphl::OPERAND, "block"},
    {morphl::SYMBOL, ":"},
    {morphl::SYMBOL, "{"},
    {morphl::SYMBOL, "}"},
    {morphl::SYMBOL, ")"},
    {morphl::SYMBOL, "{"},
    {morphl::SYMBOL, "}"},
    {morphl::EOF_, ""}
  };

  auto actualTokens = l.tokens();

  REQUIRE(actualTokens == expectedTokens);
}

TEST_CASE("Lexer: Operator argument check", "[Lexer]") {
  morphl::Token unary = {morphl::TYPE, "TYPE"};
  morphl::Token binary = {morphl::FADD, "FADD"};
  REQUIRE(morphl::isUnaryOperator(unary) == true);
  REQUIRE(morphl::isBinaryOperator(unary) == false);
  REQUIRE(morphl::isUnaryOperator(binary) == false);
  REQUIRE(morphl::isBinaryOperator(binary) == true);
}

TEST_CASE("Lexer: Input with comment", "[Lexer]") {
  std::string input("// something something\n\"Hello\"? 1/1?");
  morphl::Lexer l(input);
  std::vector<morphl::Token> expectedTokens = {
    {morphl::STRING_LITERAL, "Hello"},
    {morphl::SYMBOL, "?"},
    {morphl::INT_LITERAL, "1"},
    {morphl::SYMBOL, "/"},
    {morphl::INT_LITERAL, "1"},
    {morphl::SYMBOL, "?"},
    {morphl::EOF_, ""}
  };
  auto actualTokens = l.tokens();
  REQUIRE(actualTokens == expectedTokens);
}
