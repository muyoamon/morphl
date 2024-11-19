#ifndef MORPHL_PARSER_H
#define MORPHL_PARSER_H
//#include <memory>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
#include "../lexer/lexer.h"
#include "../ast/ast.h"
#include "macroManager.h"
#include "scope.h"
namespace morphl {
  class Parser {
    std::string filename_;
    std::vector<Token> tokens_;
    std::unique_ptr<AST::ASTNode> astNode_;
    size_t currentPos_;
    std::shared_ptr<ScopeManager> scopeManager_;
    std::shared_ptr<macro::MacroManager> macroManager_;

    std::vector<std::unique_ptr<AST::ASTNode>> operands_;
    std::vector<std::string> operandNames_;
    
    bool expectToken(const Token expect);
    
    std::unique_ptr<AST::ASTNode> parseProgram();
    std::unique_ptr<AST::ASTNode> parseBlock();
    std::unique_ptr<AST::ASTNode> parseStatement();
    std::unique_ptr<AST::ASTNode> parseGroup();
    std::unique_ptr<AST::ASTNode> parseExpression();
    std::unique_ptr<AST::ASTNode> parseIf();
    std::unique_ptr<AST::ASTNode> parseWhile();
    // parse generic binary operation
    std::unique_ptr<AST::ASTNode> parseBinaryOp();
    std::unique_ptr<AST::ASTNode> parseUnaryOp();
    std::unique_ptr<AST::ASTNode> parseLiteral();
    std::unique_ptr<AST::ASTNode> parseParen();
    std::unique_ptr<AST::ASTNode> parseIdentifier(bool isDecl = false);

    //
    // parse specific operation
    //

    std::unique_ptr<AST::ASTNode> parseDeclaration();
    std::unique_ptr<AST::ASTNode> parseFunction();
    std::unique_ptr<AST::ASTNode> parseCall();
    public:
    Parser(std::vector<Token>, std::shared_ptr<ScopeManager> = std::make_shared<ScopeManager>());
    Parser(std::string, std::shared_ptr<ScopeManager> = std::make_shared<ScopeManager>());

    Parser& parse(std::vector<std::unique_ptr<AST::ASTNode>> = std::vector<std::unique_ptr<AST::ASTNode>>());

    std::unique_ptr<AST::ASTNode> astNode() const;
    operator std::string() const;
    void printNode() const;
    const ScopeManager& getScopeManager() const;
    
  };
}

#endif // !MORPHL_PARSER_H

