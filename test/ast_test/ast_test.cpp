#include <catch2/catch_test_macros.hpp>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
#include "../../src/ast/ast.h"
#include "lexer.h"

TEST_CASE("print test", "[AST]") {
  std::vector<std::unique_ptr<morphl::AST::ASTNode>> nodes;
  nodes.push_back(
      std::make_unique<morphl::AST::StatementNode>(
        std::make_unique<morphl::AST::BinaryOpNode>(
          morphl::ADD,
          std::make_unique<morphl::AST::IntLiteralNode>(100),
          std::make_unique<morphl::AST::IntLiteralNode>(123)
          ),
        false
        )
      );
  nodes.push_back(
      std::make_unique<morphl::AST::StatementNode>(
        std::make_unique<morphl::AST::StringLiteralNode>(std::string("Hello World!")),
        true)
      );
  auto program = std::make_unique<morphl::AST::ProgramNode>(std::move(nodes));
  morphl::AST::ASTNode * head = program.get();

  std::cout << head;
}
