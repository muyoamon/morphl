#ifndef MORPHL_PARSER_H
#define MORPHL_PARSER_H
#include <memory>
#include <vector>
#include "../lexer/lexer.h"
#include "../ast/ast.h"
#include "../error/error.h"
#include "scope.h"
namespace morphl {
  class Parser {
    std::vector<Token> tokens_;
    std::shared_ptr<std::unique_ptr<AST::ASTNode>> astNode_;
    size_t currentPos_;
    ScopeManager scopeManager_;
    error::ErrorManager errorManager_;
    
    bool expectToken(const Token expect);
    
    std::unique_ptr<AST::ASTNode> parseProgram();
    std::unique_ptr<AST::ASTNode> parseBlock();
    std::unique_ptr<AST::ASTNode> parseStatement();
    std::unique_ptr<AST::ASTNode> parseExpression();
    std::unique_ptr<AST::ASTNode> parseIf();
    std::unique_ptr<AST::ASTNode> parseWhile();
    // parse generic binary operation
    std::unique_ptr<AST::ASTNode> parseBinaryOp();
    std::unique_ptr<AST::ASTNode> parseUnaryOp();
    std::unique_ptr<AST::ASTNode> parseLiteral();
    std::unique_ptr<AST::ASTNode> parseParen();
    std::unique_ptr<AST::ASTNode> parseIdentifier();

    //
    // parse specific operation
    //
    std::unique_ptr<AST::ASTNode> parseDeclaration();

    public:
    Parser(std::vector<Token>);
    Parser(std::string);

    Parser& parse();

    std::shared_ptr<std::unique_ptr<AST::ASTNode>> astNode() const;
    operator std::string() const;
    void printNode() const;
    const ScopeManager& getScopeManager() const;
    
  };
}

#endif // !MORPHL_PARSER_H

