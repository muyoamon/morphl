#include <catch2/catch_test_macros.hpp>
#include "../../src/parser/parser.h"

TEST_CASE("Parser: Basic Class Declaration", "[parser]") {
    std::string input = "class Point { x: int; y: int; }";
    morphl::Parser parser(input);

    auto program = parser.parse();
    REQUIRE(program != nullptr);
    REQUIRE(program->statements.size() == 2);
    REQUIRE(program->statements[0]->type == morphl::AST::CLASS_DECLARATION);
    auto classDecl = static_cast<morphl::AST::ClassDeclaration*>(program->statements[0].get());
    REQUIRE(classDecl->name == "Point");
    REQUIRE(classDecl->members.size() == 2);
    // ... (Add more assertions for member nodes)
}

TEST_CASE("Parser: Pure Expression Statement", "[parser]") {
    std::string input = "5 + 2?"; 
    morphl::Parser parser(input);

    auto program = parser.parse();
    REQUIRE(program != nullptr);
    REQUIRE(program->statements.size() == 2); // one for print, one for nullptr
    REQUIRE(program->statements[0]->type == morphl::AST::PRINT);
    // ... (Add more assertions for the expression node)
}

TEST_CASE("Parser: Assignment as Expression", "[parser]") {
    std::string input = "x = 5 + 2;";
    morphl::Parser parser(input);

    auto program = parser.parse();
    REQUIRE(program != nullptr);
    REQUIRE(program->statements.size() == 2);
    // ... (Add more assertions for the assignment node)
}
