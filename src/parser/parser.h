#ifndef MORPHL_PARSER_H
#define MORPHL_PARSER_H
#include <memory>
#include <vector>
#include "../lexer/lexer.h"
#include "../ast/ast.h"
namespace morphl {
  class Parser {
    std::vector<Token> tokens_;
    std::shared_ptr<std::unique_ptr<AST::ASTNode>> astNode_;
    size_t currentPos_;
    
    bool expectToken(const Token expect);
    
    std::unique_ptr<AST::ASTNode> parseProgram();
    std::unique_ptr<AST::ASTNode> parseBlock();
    std::unique_ptr<AST::ASTNode> parseStatement();
    std::unique_ptr<AST::ASTNode> parseExpression();
    std::unique_ptr<AST::ASTNode> parseIf();
    std::unique_ptr<AST::ASTNode> parseWhile();
    std::unique_ptr<AST::ASTNode> parseBinaryOp();
    std::unique_ptr<AST::ASTNode> parseUnaryOp();
    std::unique_ptr<AST::ASTNode> parseLiteral();
    std::unique_ptr<AST::ASTNode> parseParen();
    std::unique_ptr<AST::ASTNode> parseIdentifier();

    public:
    Parser(std::vector<Token>);
    Parser(std::string);

    Parser& parse();

    std::shared_ptr<std::unique_ptr<AST::ASTNode>> astNode() const;
    std::string string() const;
    void printNode() const;
    
  };
}

#endif // !MORPHL_PARSER_H

