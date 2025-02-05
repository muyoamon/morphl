#ifndef MORPHL_PARSER_PARSER_H
#define MORPHL_PARSER_PARSER_H
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
  using ASTNodePtr = std::unique_ptr<AST::ASTNode>;
  
  std::string filename_;
  std::vector<Token> tokens_;
  ASTNodePtr astNode_;
  size_t currentPos_;
  size_t currentMacroPrecedence_;
  std::shared_ptr<ScopeManager> scopeManager_;
  std::shared_ptr<macro::MacroManager> macroManager_;

  std::unordered_map<std::string, ASTNodePtr> operands_;

  bool expectToken(const Token expect);
  Token& currentToken();

  // for alias/morph without starting placeholder
  ASTNodePtr parseMacroExpansion();
  // for morph with starting placeholder
  ASTNodePtr parseMacroExpansion(ASTNodePtr&&);

  
  ASTNodePtr parseProgram();
  ASTNodePtr parseBlock();
  ASTNodePtr parseStatement();
  ASTNodePtr parseGroup();
  ASTNodePtr parseExpression();
  ASTNodePtr parseIf();
  ASTNodePtr parseWhile();
  // parse generic binary operation
  ASTNodePtr parseBinaryOp();
  ASTNodePtr parseUnaryOp();
  ASTNodePtr parseLiteral();
  ASTNodePtr parseParen();
  ASTNodePtr parseIdentifier(bool isDecl = false);

  //
  // parse specific operation
  //

  ASTNodePtr parseDeclaration();
  ASTNodePtr parseFunction();
  ASTNodePtr parseCall();
  ASTNodePtr parseMorph();
  ASTNodePtr parseAlias();
  ASTNodePtr parseExtend();
  ASTNodePtr parseMember();
  ASTNodePtr parseIndex();
  ASTNodePtr parseImport();
  ASTNodePtr parseArray();
  ASTNodePtr parseAssign();

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

  Parser &parse(std::unordered_map<std::string, ASTNodePtr>&& =
                    std::unordered_map<std::string, ASTNodePtr>());

  ASTNodePtr astNode() const;
  operator std::string() const;
  void printNode() const;
  const ScopeManager &getScopeManager() const;
  const macro::MacroManager &getMacroManager() const;
};
} // namespace morphl

#endif // !MORPHL_PARSER_PARSER_H
