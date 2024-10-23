#include "parser.h"
#include "scope.h"
#include "type.h"
#include <catch2/internal/catch_result_type.hpp>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>
namespace morphl {
static const Token STATEMENT_END = {SYMBOL, ";"};
static const Token STATEMENT_PRINT = {SYMBOL, "?"};
static const Token BLOCK_START = {SYMBOL, "{"};
static const Token BLOCK_END = {SYMBOL, "}"};
static const Token PAREN_START = {SYMBOL, "("};
static const Token PAREN_END = {SYMBOL, ")"};

Parser::Parser(std::vector<Token> t)
    : tokens_(t), astNode_{nullptr}, currentPos_{0} {}

Parser::Parser(std::string s) : Parser(Lexer(s).tokens()) {}

bool Parser::expectToken(const Token expect) {
  auto actual = tokens_[currentPos_];
  if (expect == actual) {
    return true;
  }
  errorManager_.addError(error::Error("Error: Unexpect Token \%, expected \%\n",
                                      error::Severity::Critical, actual,
                                      expect));
  return false;
}

Parser &Parser::parse() {
  astNode_ = std::make_shared<std::unique_ptr<AST::ASTNode>>(parseProgram());
  return *this;
}

std::unique_ptr<AST::ASTNode> Parser::parseProgram() {
  std::vector<std::unique_ptr<AST::ASTNode>> v;
  scopeManager_.pushScope();
  while (currentPos_ < tokens_.size() && tokens_[currentPos_].type != EOF_) {
    v.push_back(std::move(parseStatement()));
  }
  return std::make_unique<AST::ProgramNode>(std::move(v));
}

std::unique_ptr<AST::ASTNode> Parser::parseBlock() {
  // expect {
  expectToken(BLOCK_START);
  currentPos_++;
  scopeManager_.pushScope();
  std::vector<std::unique_ptr<AST::ASTNode>> v;
  while (tokens_[currentPos_] != BLOCK_END &&
         tokens_[currentPos_] != Token({EOF_, ""})) {
    v.push_back(std::move(parseStatement()));
  }
  if (tokens_[currentPos_].type == EOF_) {
    errorManager_.addError({"Unterminated Block\n", error::Severity::Warning});
  }
  expectToken(BLOCK_END);
  currentPos_++;
  scopeManager_.popScope();
  return std::make_unique<AST::BlockNode>(std::move(v));
}

std::unique_ptr<AST::ASTNode> Parser::parseStatement() {

  std::unique_ptr<AST::ASTNode> value = nullptr;
  if (tokens_[currentPos_] != STATEMENT_END &&
      tokens_[currentPos_] != STATEMENT_PRINT) {
    value = std::move(parseExpression());
  }
  bool isPrint = false;
  auto currToken = tokens_[currentPos_];
  if (currToken == STATEMENT_END) {
    isPrint = false;
  } else if (currToken == STATEMENT_PRINT) {
    isPrint = true;
  } else {
    errorManager_.addError(
        {"Unterminated Statement\n", error::Severity::Warning});
  }
  currentPos_++;
  return std::make_unique<AST::StatementNode>(std::move(value), isPrint);
}

std::unique_ptr<AST::ASTNode> Parser::parseExpression() {
  auto currToken = tokens_[currentPos_];
  std::unique_ptr<AST::ASTNode> expression = nullptr;
  if (currToken.type == IF) {
    expression = parseIf();
  } else if (currToken.type == WHILE) {
    expression = parseWhile();
  } else if (isBinaryOperator(currToken)) {
    expression = parseBinaryOp();
  } else if (isUnaryOperator(currToken)) {
    expression = parseUnaryOp();
  } else if (currToken == BLOCK_START) {
    expression = parseBlock();
  } else if (currToken == PAREN_START) {
    expression = parseParen();
  } else if (currToken.type == IDENTIFIER) {
    expression = parseIdentifier();
  } else if (currToken.type > LITERAL_START && currToken.type < LITERAL_END) {
    expression = parseLiteral();
  }

  if (expression == nullptr) {
    errorManager_.addError({"Error: Unexpected token \%\n", error::Severity::Critical, currToken});
  }

  // no match
  // std::cerr << "Invalid Token: expected expression, got: " << currToken <<
  // "\n";
  return expression;
}

std::unique_ptr<AST::ASTNode> Parser::parseIf() {
  expectToken({IF, "IF"});
  currentPos_++;
  auto ifBlock = parseBlock();
  return std::make_unique<AST::IfNode>(std::move(ifBlock));
}

std::unique_ptr<AST::ASTNode> Parser::parseWhile() {
  expectToken({WHILE, "WHILE"});
  currentPos_++;
  auto whileBlock = parseBlock();
  return std::make_unique<AST::IfNode>(std::move(whileBlock));
}

std::unique_ptr<AST::ASTNode> Parser::parseBinaryOp() {
  TokenType type = tokens_[currentPos_].type;
  currentPos_++;
  if (type == DECL) {
    return parseDeclaration();
  }
  auto operand1 = parseExpression();
  auto operand2 = parseExpression();
  return std::make_unique<AST::BinaryOpNode>(type, std::move(operand1),
                                             std::move(operand2));
}

std::unique_ptr<AST::ASTNode> Parser::parseUnaryOp() {
  TokenType type = tokens_[currentPos_].type;
  currentPos_++;
  auto operand = parseExpression();
  return std::make_unique<AST::UnaryOpNode>(type, std::move(operand));
}

std::unique_ptr<AST::ASTNode> Parser::parseLiteral() {
  Token t = tokens_[currentPos_];
  currentPos_++;
  if (t.type == INT_LITERAL) {
    return std::make_unique<AST::IntLiteralNode>(std::stoi(t.value));
  } else if (t.type == FLOAT_LITERAL) {
    return std::make_unique<AST::FloatLiteralNode>(std::stof(t.value));
  } else if (t.type == STRING_LITERAL) {
    return std::make_unique<AST::StringLiteralNode>(t.value);
  } else {
    errorManager_.addError(error::Error("Error: Unexpected Token \%\n",
                                           error::Severity::Critical, t));
    return nullptr;
  }
}

std::unique_ptr<AST::ASTNode> Parser::parseParen() {
  expectToken(PAREN_START);
  currentPos_++;
  if (tokens_[currentPos_] == PAREN_END) {
    currentPos_++;
    return std::make_unique<AST::ExprGroupNode>(
        std::vector<std::unique_ptr<AST::ASTNode>>());
  }
  auto expression = parseExpression();
  expectToken(PAREN_END);
  currentPos_++;
  return expression;
}

std::unique_ptr<AST::ASTNode> Parser::parseDeclaration() {
  auto identifier = parseExpression();
  auto type = parseExpression();
  if (identifier->type_ != AST::IDENTIFIERNODE) {
    errorManager_.addError({"Error: The first operand must be an identifier\n", error::Severity::Critical});
    return nullptr;
  }
  auto varName = static_cast<AST::IdentifierNode *>(identifier.get())->name_;
  if (scopeManager_.getType(varName) != nullptr) {
    errorManager_.addError({"Error: Identifier \% is already declared\n", error::Severity::Critical, varName});
    return nullptr;
  }
  std::shared_ptr<type::TypeObject> declType;
  if (type->type_ == AST::IDENTIFIERNODE) {
    declType = scopeManager_.getType(
        static_cast<AST::IdentifierNode *>(type.get())->name_);
  } else {
    declType = AST::getType(type.get());
  }
  scopeManager_.addScopeObject({varName, declType});

  return std::make_unique<AST::BinaryOpNode>(DECL, std::move(identifier),
                                             std::move(type));
}

std::unique_ptr<AST::ASTNode> Parser::parseIdentifier() {
  Token t = tokens_[currentPos_];
  currentPos_++;
  return std::make_unique<AST::IdentifierNode>(t.value);
}

std::shared_ptr<std::unique_ptr<AST::ASTNode>> Parser::astNode() const {
  return astNode();
}

Parser::operator std::string() const {
  return AST::toString(astNode_->get(), 0);
}

void Parser::printNode() const { std::cout << astNode_->get(); }

const ScopeManager &Parser::getScopeManager() const { return scopeManager_; }

} // namespace morphl
