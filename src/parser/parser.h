#ifndef MORPHL_PARSER_H
#define MORPHL_PARSER_H
// #include <memory>
#include "../ast/ast.h"
#include "../lexer/lexer.h"
#include "macroManager.h"
#include "scope.h"
#include <fstream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
namespace morphl {
class Parser {
  std::string filename_;
  std::vector<Token> tokens_;
  std::unique_ptr<AST::ASTNode> astNode_;
  size_t currentPos_;
  std::shared_ptr<ScopeManager> scopeManager_;
  std::shared_ptr<macro::MacroManager> macroManager_;

  std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>> operands_;

  bool expectToken(const Token expect);
  Token& currentToken();

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
  std::unique_ptr<AST::ASTNode> parseMorph();
  std::unique_ptr<AST::ASTNode> parseAlias();
  std::unique_ptr<AST::ASTNode> parseExtend();
  std::unique_ptr<AST::ASTNode> parseMember();
  std::unique_ptr<AST::ASTNode> parseIndex();
  std::unique_ptr<AST::ASTNode> parseImport();
  std::unique_ptr<AST::ASTNode> parseArray();
  std::unique_ptr<AST::ASTNode> parseAssign();

  //
  // scope operation
  //

  void pushScope();
  void popScope();

public:
  Parser(std::vector<Token>,
         std::shared_ptr<ScopeManager> = std::make_shared<ScopeManager>(),
         std::shared_ptr<macro::MacroManager> =
             std::make_shared<macro::MacroManager>());
  Parser(std::string,
         std::shared_ptr<ScopeManager> = std::make_shared<ScopeManager>(),
         std::shared_ptr<macro::MacroManager> =
             std::make_shared<macro::MacroManager>());

  Parser &parse(std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>&& =
                    std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>());

  std::unique_ptr<AST::ASTNode> astNode() const;
  operator std::string() const;
  void printNode() const;
  const ScopeManager &getScopeManager() const;
  const macro::MacroManager &getMacroManager() const;
};
} // namespace morphl

#endif // !MORPHL_PARSER_H
