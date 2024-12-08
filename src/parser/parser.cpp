#include "parser.h"
#include "../error/error.h"
#include "../type/operatorType.h"
#include "../type/type.h"
#include "error.h"
#include "macro.h"
#include "macroManager.h"
#include "scope.h"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <ostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
namespace morphl {

static const Token STATEMENT_END = {SYMBOL, ";"};
static const Token STATEMENT_PRINT = {SYMBOL, "?"};
static const Token BLOCK_START = {SYMBOL, "{"};
static const Token BLOCK_END = {SYMBOL, "}"};
static const Token PAREN_START = {SYMBOL, "("};
static const Token PAREN_END = {SYMBOL, ")"};

Token &Parser::currentToken() { return tokens_[currentPos_]; }

Parser::Parser(std::vector<Token> t, std::shared_ptr<ScopeManager> scopeManager,
               std::shared_ptr<macro::MacroManager> macroManger)
    : tokens_(t), astNode_{nullptr}, currentPos_{0},
      scopeManager_(scopeManager), macroManager_(macroManger) {}

Parser::Parser(std::string file, std::shared_ptr<ScopeManager> scopeManager,
               std::shared_ptr<macro::MacroManager> macroManager)
    : filename_{file}, astNode_{nullptr}, currentPos_{0},
      scopeManager_(scopeManager), macroManager_(macroManager) {
  std::ifstream f(filename_);
  if (!f) {
    error::errorManager.addError(
        {"File \'%\' not found!\n", error::Severity::Critical, filename_});
  }
  std::stringstream ss;
  ss << f.rdbuf();
  Lexer l(ss.str());
  tokens_ = l.tokens();
}

bool Parser::expectToken(const Token expect) {
  auto actual = tokens_[currentPos_];
  if (expect == actual) {
    return true;
  }
  error::errorManager.addError(UnexpectedTokenError(filename_, actual, expect));
  return false;
}

Parser &Parser::parse(
    std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>> &&operands) {
  for (const auto &i : operands) {
    operands_[i.first] = (i.second->clone());
  }
  astNode_ = std::move(parseProgram());
  return *this;
}

std::unique_ptr<AST::ASTNode> Parser::parseProgram() {
  std::vector<std::unique_ptr<AST::ASTNode>> v;
  if (scopeManager_->empty()) {
    this->pushScope();
  }
  while (currentPos_ < tokens_.size() && tokens_[currentPos_].type != EOF_) {
    auto statement = parseStatement();
    if (statement != nullptr) {
      v.push_back(std::move(statement));
    }
  }
  if (v.size() == 1) {
    return std::move(v[0]);
  }
  return std::make_unique<AST::BlockNode>(std::move(v));
}

std::unique_ptr<AST::ASTNode> Parser::parseBlock() {
  // expect {
  expectToken(BLOCK_START);
  auto t = tokens_[currentPos_];
  currentPos_++;
  this->pushScope();
  std::vector<std::unique_ptr<AST::ASTNode>> v;
  while (tokens_[currentPos_] != BLOCK_END &&
         tokens_[currentPos_] != Token({EOF_, ""})) {
    auto statement = parseStatement();
    if (statement != nullptr) {
      v.push_back(std::move(statement));
    }
  }
  if (tokens_[currentPos_].type == EOF_) {
    error::errorManager.addError({filename_, t.row_, t.col_,
                                  error::Severity::Warning,
                                  "Unterminated Block\n"});
  }
  expectToken(BLOCK_END);
  currentPos_++;
  this->popScope();
  return std::make_unique<AST::BlockNode>(std::move(v));
}

std::unique_ptr<AST::ASTNode> Parser::parseStatement() {

  std::unique_ptr<AST::ASTNode> value = nullptr;
  if (tokens_[currentPos_] == STATEMENT_END ||
      tokens_[currentPos_] == STATEMENT_PRINT) {
    currentPos_++;
    return nullptr;
  }
  value = std::move(parseGroup());
  bool isPrint = false;
  if (currentToken() == STATEMENT_END) {
    isPrint = false;
  } else if (currentToken() == STATEMENT_PRINT) {
    isPrint = true;
  } else {
    return value; // return expression if there is no statement end
    // error::errorManager.addError({"Unterminated Statement\n",
    // error::Severity::Warning});
  }
  currentPos_++;
  return std::make_unique<AST::StatementNode>(std::move(value), isPrint);
}

std::unique_ptr<AST::ASTNode> Parser::parseExpression() {
  std::unique_ptr<AST::ASTNode> expression = nullptr;
  {
    struct MacroDetail {
      size_t operandIndex{};
      size_t currentPos{};
    };
    auto lastPos = currentPos_;

    auto macros = macroManager_->getAllMacro();

    std::vector<std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>>
        args(macros.size());
    std::vector<MacroDetail> macroDetails(macros.size());
    size_t syntaxIndex = 0;
    size_t macroIndex = 0;
    size_t lastMatchedMacroIndex = -1;
    macro::Macro lastMatchedMacro;
    MacroDetail lastMatchedMacroDetail;
    std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>
        lastMatchedMacroArgs;

    // first flushed out non-matching macros
    for (auto it = macros.begin(); it != macros.end();) {
      currentPos_ = lastPos;
      if (it->syntax_[syntaxIndex] == currentToken()) {
        currentPos_++;
      } else {
        it = macros.erase(it);
        args.erase(args.begin() + macroIndex);
        macroDetails.erase(macroDetails.begin() + macroIndex);
        continue;
      }
      macroDetails[macroIndex].currentPos = currentPos_;
      macroIndex++;
      it++;
    }
    syntaxIndex++;
    while (macros.size() > 0) {
      macroIndex = 0;
      for (auto it = macros.begin(); it != macros.end();) {
        currentPos_ = macroDetails[macroIndex].currentPos;
        if (syntaxIndex == it->syntax_.size()) {
          lastMatchedMacroIndex = macroIndex;
          lastMatchedMacroDetail = macroDetails[macroIndex];
          lastMatchedMacroArgs = std::move(args[macroIndex]);
          lastMatchedMacro = *it;
          it = macros.erase(it);
          args.erase(args.begin() + macroIndex);
          macroDetails.erase(macroDetails.begin() + macroIndex);
          continue;
        }
        if (it->syntax_[syntaxIndex].type == OPERAND) {
          auto arg = parseExpression();
          if (*arg->getType() ==
              *it->operandTypes_[macroDetails[macroIndex].operandIndex]) {
            args[macroIndex][it->syntax_[syntaxIndex].value] =
                std::move(arg->clone());
            macroDetails[macroIndex].operandIndex++;
          } else {
            it = macros.erase(it);
            args.erase(args.begin() + macroIndex);
            macroDetails.erase(macroDetails.begin() + macroIndex);
            continue;
          }
        } else if (it->syntax_[syntaxIndex] == currentToken()) {
          currentPos_++;
        } else {
          it = macros.erase(it);
          args.erase(args.begin() + macroIndex);
          macroDetails.erase(macroDetails.begin() + macroIndex);
          continue;
        }
        macroDetails[macroIndex].currentPos = currentPos_;
        macroIndex++;
        it++;
      }
      syntaxIndex++;
    }
    if (lastMatchedMacroIndex != -1) {
      currentPos_ = lastMatchedMacroDetail.currentPos;
      if (lastMatchedMacroArgs.size() == 0) {
        auto it = tokens_.erase(tokens_.begin() + lastPos,
                                tokens_.begin() + currentPos_);
        tokens_.insert(it, lastMatchedMacro.expansion_.begin(),
                       lastMatchedMacro.expansion_.end() - 1); // exclude EOF
        currentPos_ = lastPos;
        return parseExpression();
      }
      Parser macroParser(lastMatchedMacro.expansion_, scopeManager_,
                         macroManager_);
      expression = macroParser.parse(std::move(lastMatchedMacroArgs)).astNode();
    } else {
      currentPos_ = lastPos;
    }
  }

  if (currentToken().type == OPERAND) {
    expression = operands_[currentToken().value]->clone();
    currentPos_++;
  } else if (currentToken().type == MORPH) {
    expression = parseMorph();
  } else if (currentToken().type == ALIAS) {
    expression = parseAlias();
  } else if (currentToken().type == IF) {
    expression = parseIf();
  } else if (currentToken().type == WHILE) {
    expression = parseWhile();
  } else if (isBinaryOperator(currentToken())) {
    expression = parseBinaryOp();
  } else if (isUnaryOperator(currentToken())) {
    expression = parseUnaryOp();
  } else if (currentToken() == BLOCK_START) {
    expression = parseBlock();
  } else if (currentToken() == PAREN_START) {
    expression = parseParen();
  } else if (currentToken().type == IDENTIFIER) {
    expression = parseIdentifier();
  } else if (currentToken().type > LITERAL_START &&
             currentToken().type < LITERAL_END) {
    expression = parseLiteral();
  }

  if (expression == nullptr) {
    error::errorManager.addError(
        UnexpectedTokenError(filename_, currentToken()));
  }

  // macro matching
  {
    struct MacroDetail {
      size_t operandIndex{};
      size_t currentPos{};
    };
    auto lastPos = currentPos_;

    auto macros = macroManager_->getAllMacro();

    std::vector<std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>>
        args(macros.size());
    std::vector<MacroDetail> macroDetails(macros.size());
    size_t syntaxIndex = 0;
    size_t macroIndex = 0;
    size_t lastMatchedMacroIndex = -1;
    macro::Macro lastMatchedMacro;
    MacroDetail lastMatchedMacroDetail;
    std::unordered_map<std::string, std::unique_ptr<AST::ASTNode>>
        lastMatchedMacroArgs;
    // first flushed out non-matching macros
    for (auto it = macros.begin(); it != macros.end();) {
      if (it->syntax_[syntaxIndex].type == OPERAND &&
          *expression->getType() ==
              *it->operandTypes_[macroDetails[macroIndex].operandIndex]) {
        args[macroIndex][it->syntax_[syntaxIndex].value] =
            std::move(expression->clone());
        macroDetails[macroIndex].operandIndex++;
      } else {
        it = macros.erase(it);
        args.erase(args.begin() + macroIndex);
        macroDetails.erase(macroDetails.begin() + macroIndex);
        continue;
      }
      macroDetails[macroIndex].currentPos = currentPos_;
      macroIndex++;
      it++;
    }
    syntaxIndex++;
    while (macros.size() > 0) {
      macroIndex = 0;
      for (auto it = macros.begin(); it != macros.end();) {
        currentPos_ = macroDetails[macroIndex].currentPos;
        if (syntaxIndex == it->syntax_.size()) {
          lastMatchedMacroIndex = macroIndex;
          lastMatchedMacroDetail = macroDetails[macroIndex];
          lastMatchedMacroArgs = std::move(args[macroIndex]);
          lastMatchedMacro = *it;
          it = macros.erase(it);
          args.erase(args.begin() + macroIndex);
          macroDetails.erase(macroDetails.begin() + macroIndex);
          continue;
        }
        if (it->syntax_[syntaxIndex].type == OPERAND) {
          auto arg = parseExpression();
          if (*arg->getType() ==
              *it->operandTypes_[macroDetails[macroIndex].operandIndex]) {
            args[macroIndex][it->syntax_[syntaxIndex].value] =
                std::move(arg->clone());
            macroDetails[macroIndex].operandIndex++;
          } else {
            it = macros.erase(it);
            args.erase(args.begin() + macroIndex);
            macroDetails.erase(macroDetails.begin() + macroIndex);
            continue;
          }
        } else if (it->syntax_[syntaxIndex] == currentToken()) {
          currentPos_++;
        } else {
          it = macros.erase(it);
          args.erase(args.begin() + macroIndex);
          macroDetails.erase(macroDetails.begin() + macroIndex);
          continue;
        }
        macroDetails[macroIndex].currentPos = currentPos_;
        macroIndex++;
        it++;
      }
      syntaxIndex++;
    }
    if (lastMatchedMacroIndex != -1) {
      currentPos_ = lastMatchedMacroDetail.currentPos;
      Parser macroParser(lastMatchedMacro.expansion_, scopeManager_,
                         macroManager_);
      expression = macroParser.parse(std::move(lastMatchedMacroArgs)).astNode();
    } else {
      currentPos_ = lastPos;
    }
  }

  return expression;
}

std::unique_ptr<AST::ASTNode> Parser::parseMorph() {
  expectToken({MORPH, "MORPH"});
  auto t = tokens_[currentPos_];
  currentPos_++;

  macro::Macro::Syntax syntax;
  macro::Macro::Syntax expansion;
  int precedence;
  std::shared_ptr<type::TypeObject> operandsType;

  expectToken({SYMBOL, "`"});
  currentPos_++;
  if (tokens_[currentPos_] == Token{SYMBOL, "`"}) {
    error::errorManager.addError(
        {filename_, tokens_[currentPos_].row_, tokens_[currentPos_].col_,
         error::Severity::Critical, "Error: Syntax body cannot be empty.\n"});
  }
  while (tokens_[currentPos_] != Token(SYMBOL, "`")) {
    syntax.push_back(tokens_[currentPos_]);
    currentPos_++;
  }
  expectToken({SYMBOL, "`"});
  currentPos_++;

  if (tokens_[currentPos_].type != INT_LITERAL) {
    error::errorManager.addError(
        {filename_, tokens_[currentPos_].row_, tokens_[currentPos_].col_,
         error::Severity::Critical,
         "Error: Precedence must be integer literal.\n"});
  }
  precedence = stoi(tokens_[currentPos_].value);
  currentPos_++;
  auto expression = parseExpression();
  operandsType = expression->getType();

  expectToken({SYMBOL, "`"});
  currentPos_++;
  while (tokens_[currentPos_] != Token(SYMBOL, "`")) {
    expansion.push_back(tokens_[currentPos_]);
    currentPos_++;
  }
  expansion.push_back(Token(EOF_, ""));
  expectToken({SYMBOL, "`"});
  currentPos_++;

  // TODO: add a check that syntax cannot be sub array of expansion.

  std::vector<std::shared_ptr<type::TypeObject>> opTypeVector;
  if (operandsType->type_ == type::GROUP) {
    opTypeVector = static_cast<type::GroupType *>(operandsType.get())->members_;
  } else {
    opTypeVector.push_back(operandsType);
  }
  macroManager_->addMacro({syntax, expansion, opTypeVector, precedence});
  return std::make_unique<AST::MacroNode>();
}

std::unique_ptr<AST::ASTNode> Parser::parseAlias() {
  expectToken({ALIAS, "ALIAS"});
  currentPos_++;
  std::vector<Token> syntax;
  std::vector<Token> expansion;
  if (currentToken() == Token{SYMBOL, "`"}) {
    currentPos_++;
    if (tokens_[currentPos_] == Token{SYMBOL, "`"}) {
      error::errorManager.addError(
          {filename_, tokens_[currentPos_].row_, tokens_[currentPos_].col_,
           error::Severity::Critical, "Error: Syntax body cannot be empty.\n"});
    }
    while (tokens_[currentPos_] != Token(SYMBOL, "`")) {
      syntax.push_back(tokens_[currentPos_]);
      currentPos_++;
    }
    expectToken({SYMBOL, "`"});
    currentPos_++;

  } else {
    syntax.push_back(currentToken());
    currentPos_++;
  }

  if (currentToken() == Token{SYMBOL, "`"}) {
    currentPos_++;
    while (tokens_[currentPos_] != Token(SYMBOL, "`")) {
      expansion.push_back(tokens_[currentPos_]);
      currentPos_++;
    }
    expectToken({SYMBOL, "`"});
    currentPos_++;

  } else {
    expansion.push_back(currentToken());
    currentPos_++;
  }
  expansion.push_back({EOF_, ""});

  macroManager_->addMacro({syntax, expansion, {}, 0});
  return std::make_unique<AST::MacroNode>();
}

std::unique_ptr<AST::ASTNode> Parser::parseAssign() {
  auto lhsToken = currentToken();
  auto lhs = parseExpression();
  auto rhsToken = currentToken();
  auto rhs = parseExpression();
  if (lhs->assignable_ == false) {
    error::errorManager.addError(
        {filename_, lhsToken.row_, lhsToken.col_, error::Severity::Critical,
         "Error: ASSIGN expected assignable operand.\n"});
  }
  if (*lhs->getTrueType() != *rhs->getTrueType()) {
    error::errorManager.addError(
        {filename_, rhsToken.row_, rhsToken.col_, error::Severity::Critical,
         "Error: Mismatch operand type: (\% != \%).\n",
         static_cast<std::string>(*lhs->getTrueType()),
         static_cast<std::string>(*rhs->getTrueType())});
  }
  return std::make_unique<AST::BinaryOpNode>(ASSIGN, std::move(lhs),
                                             std::move(rhs));
}

std::unique_ptr<AST::ASTNode> Parser::parseImport() {
  auto fileToken = currentToken();
  if (fileToken.type != STRING_LITERAL) {
    error::errorManager.addError({
        filename_, fileToken.row_, fileToken.col_, error::Severity::Critical,
        "Error: IMPORT expected string literal as operand.\n"
        });
  }
  std::filesystem::path filePath = std::filesystem::path(filename_).parent_path();
  filePath /= fileToken.value;
  
  return Parser(filePath.string(), scopeManager_, macroManager_).parse().astNode();

}

std::unique_ptr<AST::ASTNode> Parser::parseIf() {
  expectToken({IF, "IF"});
  auto t = tokens_[currentPos_];
  currentPos_++;
  auto ifBlock = parseGroup();
  if (ifBlock->type_ == AST::GROUPNODE) {
    auto ifGroupPtr = static_cast<AST::GroupNode *>(ifBlock.get());
    if (ifGroupPtr->members_.size() > 2) {
      if (*ifGroupPtr->members_[1]->getType() !=
          *ifGroupPtr->members_[2]->getType()) {
        error::errorManager.addError(
            {filename_, t.row_, t.col_, error::Severity::Critical,
             "Error:Type of if body does not match the type of else body (% != "
             "%)\n",
             static_cast<std::string>(*ifGroupPtr->members_[1]->getType()),
             static_cast<std::string>(*ifGroupPtr->members_[2]->getType())});
      }
    }
    if (ifGroupPtr->members_.size() > 3) {
      error::errorManager.addError(
          {filename_, t.row_, t.col_, error::Severity::Warning,
           "Provide more expression(s) than needed to "
           "IF, the last \% expression(s) will be ignored\n",
           ifGroupPtr->members_.size() - 3});
    }
  }
  return std::make_unique<AST::IfNode>(std::move(ifBlock));
}

std::unique_ptr<AST::ASTNode> Parser::parseWhile() {
  expectToken({WHILE, "WHILE"});
  currentPos_++;
  auto whileBlock = parseGroup();
  if (whileBlock->type_ == AST::GROUPNODE) {
    auto whileGroupPtr = static_cast<AST::GroupNode *>(whileBlock.get());
    if (whileGroupPtr->members_.size() > 2) {
      error::errorManager.addError(
          {"Provide more expression(s) than needed to WHILE, the last \% "
           "expression(s) will be ignored\n",
           error::Severity::Warning, whileGroupPtr->members_.size() - 2});
    }
  }
  return std::make_unique<AST::WhileNode>(std::move(whileBlock));
}

std::unique_ptr<AST::ASTNode> Parser::parseBinaryOp() {
  TokenType type = tokens_[currentPos_].type;
  currentPos_++;
  if (type == EXTEND) {
    return parseExtend();
  }
  if (type == DECL) {
    return parseDeclaration();
  }
  if (type == FUNC) {
    return parseFunction();
  }
  if (type == CALL) {
    return parseCall();
  }
  if (type == MEMBER) {
    return parseMember();
  }
  if (type == ARR) {
    return parseArray();
  }
  if (type == INDEX) {
    return parseIndex();
  }
  if (type == ASSIGN) {
    return parseAssign();
  }
  auto op1Token = currentToken();
  auto operand1 = parseExpression();
  auto op2Token = currentToken();
  auto operand2 = parseExpression();

  auto opTypeDetail = type::operatorTypeMap.at(type);
  if (opTypeDetail.operand1_ != nullptr) {
    if (*operand1->getType() != *opTypeDetail.operand1_) {
      error::errorManager.addError(
          {filename_, op1Token.row_, op1Token.col_, error::Severity::Critical,
           "Error: Type mismatch, expected \%, got \%\n",
           static_cast<std::string>(*opTypeDetail.operand1_),
           static_cast<std::string>(*operand1->getType())});
    }
  }

  if (opTypeDetail.operand2_ != nullptr) {
    if (*operand2->getType() != *opTypeDetail.operand2_) {
      error::errorManager.addError(
          {filename_, op2Token.row_, op2Token.col_, error::Severity::Critical,
           "Error: Type mismatch, expected \%, got \%\n",
           static_cast<std::string>(*opTypeDetail.operand2_),
           static_cast<std::string>(*operand2->getType())});
    }
  }

  return std::make_unique<AST::BinaryOpNode>(type, std::move(operand1),
                                             std::move(operand2));
}

std::unique_ptr<AST::ASTNode> Parser::parseUnaryOp() {
  TokenType type = tokens_[currentPos_].type;
  currentPos_++;
  if (type == IMPORT) {
    return parseImport();
  }
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
    error::errorManager.addError(UnexpectedTokenError(filename_, t));
    return nullptr;
  }
}

std::unique_ptr<AST::ASTNode> Parser::parseParen() {
  expectToken(PAREN_START);
  currentPos_++;
  if (tokens_[currentPos_] == PAREN_END) {
    currentPos_++;
    return std::make_unique<AST::GroupNode>(
        std::vector<std::unique_ptr<AST::ASTNode>>());
  }
  auto expression = parseGroup();
  expectToken(PAREN_END);
  currentPos_++;
  return expression;
}

std::unique_ptr<AST::ASTNode> Parser::parseDeclaration() {
  auto t = tokens_[currentPos_];
  auto identifier = parseIdentifier(true);
  this->pushScope(); // pseudo-scope for declaration
  auto type = parseExpression();
  if (identifier->type_ != AST::IDENTIFIERNODE) {
    error::errorManager.addError(
        {filename_, t.row_, t.col_, error::Severity::Critical,
         "Error: The first operand must be an identifier\n"});
    return nullptr;
  }
  auto varName = static_cast<AST::IdentifierNode *>(identifier.get())->name_;
  if (scopeManager_->getCurrentScopeType(varName) != nullptr) {
    error::errorManager.addError(
        {filename_, t.row_, t.col_, error::Severity::Critical,
         "Error: Identifier \% is already declared\n", varName});
    return nullptr;
  }
  std::shared_ptr<type::TypeObject> declType;
  // if second operand is identifier
  if (type->type_ == AST::IDENTIFIERNODE) {
    auto name = static_cast<AST::IdentifierNode *>(type.get())->name_;
    auto typeFound = scopeManager_->getType(name);
    if (typeFound == nullptr) {
      error::errorManager.addError({filename_, t.row_, t.col_,
                                    error::Severity::Critical,
                                    "Unknown Type Identifier: %\n", name});
    }
    declType = std::make_shared<type::IdentifierType>(name, typeFound);
  } else {
    declType = type->getType();
  }
  if (declType == nullptr) {
    error::errorManager.addError({"Type Error\n", error::Severity::Critical});
  }
  this->popScope();
  scopeManager_->addScopeObject(
      std::make_shared<IdentifierType>(varName, declType));
  static_cast<AST::IdentifierNode *>(identifier.get())->identifierType_ =
      declType;

  return std::make_unique<AST::DeclarationNode>(varName, std::move(type));
}

std::unique_ptr<AST::ASTNode> Parser::parseArray() {
  auto expression = parseExpression();
  auto sizeToken = currentToken();
  if (sizeToken.type != INT_LITERAL) {
    error::errorManager.addError(
        {filename_, sizeToken.row_, sizeToken.col_, error::Severity::Critical,
         "Error: Array size must be an integer literal\n"});
  }
  currentPos_++;
  return std::make_unique<AST::ArrayNode>(expression->getType(),
                                          stoi(sizeToken.value));
}

std::unique_ptr<AST::ASTNode> Parser::parseIndex() {
  auto containerToken = currentToken();
  auto container = parseExpression();
  auto indexToken = currentToken();
  auto index = parseExpression();
  auto containerType = container->getTrueType();
  if (*index->getTrueType() != *type::PrimitiveType::INTEGER) {
    error::errorManager.addError(
        {filename_, indexToken.row_, indexToken.col_, error::Severity::Critical,
         "Error: INDEX expected the second operand to be integer type.\n"});
  }
  if (containerType->type_ == type::LIST) {
    return std::make_unique<AST::ArrayIndexNode>(std::move(container),
                                                 std::move(index));
  } else if (containerType->type_ == type::GROUP) {
    if (index->type_ != AST::INT_LITERALNODE) {
      error::errorManager.addError({filename_, indexToken.row_, indexToken.col_,
                                    error::Severity::Critical,
                                    "Error: INDEX expected to second operand "
                                    "for Group type to be integer literal.\n"});
    }
    size_t idx = static_cast<AST::IntLiteralNode *>(index.get())->value_;
    size_t groupSize =
        static_cast<type::GroupType *>(containerType.get())->members_.size();
    if (idx >= groupSize) {
      error::errorManager.addError(
          {filename_, indexToken.row_, indexToken.col_,
           error::Severity::Critical,
           "Error: Received index greater than Group size (\%), got: \%\n",
           groupSize, idx});
    }
    return std::make_unique<AST::GroupIndexNode>(std::move(container), idx);
  } else {
    error::errorManager.addError(
        {filename_, containerToken.row_, containerToken.col_,
         error::Severity::Critical,
         "Error: INDEX expect first operand to be either a group or an array"});
    return nullptr;
  }
}

std::unique_ptr<AST::ASTNode> Parser::parseIdentifier(bool isDecl) {
  Token t = tokens_[currentPos_];
  currentPos_++;
  auto identifierNode = std::make_unique<AST::IdentifierNode>(t.value);
  identifierNode->identifierType_ = scopeManager_->getType(t.value);
  if (!isDecl) {
    if (identifierNode->identifierType_ == nullptr) {
      error::errorManager.addError(
          {filename_, t.row_, t.col_, error::Severity::Warning,
           "Use of undeclared variable '\%'\n", identifierNode->name_});
    }
  }
  return identifierNode;
}

std::unique_ptr<AST::ASTNode> Parser::parseFunction() {
  this->pushScope();
  auto operandsType = parseExpression();
  auto value = parseExpression();
  this->popScope();
  return std::make_unique<AST::FunctionNode>(std::move(operandsType),
                                             std::move(value));
}

std::unique_ptr<AST::ASTNode> Parser::parseCall() {
  auto t = tokens_[currentPos_];
  auto func = parseExpression();
  auto funcType = func->getType();
  while (funcType->type_ == type::IDENTIFIER) {
    funcType = static_cast<type::IdentifierType *>(funcType.get())->pType_;
  }
  if (funcType->type_ != type::FUNC) {
    error::errorManager.addError({
        filename_,
        t.row_,
        t.col_,
        error::Severity::Critical,
        "Error: Used CALL on non-function object\n",
    });
    return nullptr;
  }
  auto args = parseExpression();
  auto funcNodePtr = static_cast<type::FunctionType *>(func->getType().get());
  auto funcArgsType = funcNodePtr->pOperandsType_;
  auto callArgsType = args->getType();
  if (*funcArgsType != *callArgsType) {
    error::errorManager.addError(
        {filename_, t.row_, t.col_, error::Severity::Critical,
         "Error: Argument(s) type mismatch, got: %, expected: %\n",
         static_cast<std::string>(*args->getType()),
         static_cast<std::string>(*funcNodePtr->pOperandsType_)});
  }
  return std::make_unique<AST::BinaryOpNode>(CALL, std::move(func),
                                             std::move(args));
}

std::unique_ptr<AST::ASTNode> Parser::parseExtend() {
  auto op1Token = currentToken();
  auto op1 = parseExpression();
  if (op1->getTrueType()->type_ != type::BLOCK) {
    error::errorManager.addError(
        {filename_, op1Token.row_, op1Token.col_, error::Severity::Critical,
         "Error: EXTEND expected first operand to be a block, got \%\n",
         op1->getTrueType()});
  }
  auto op2Token = currentToken();
  auto op2 = parseExpression();
  if (op2->getTrueType()->type_ != type::BLOCK) {
    error::errorManager.addError(
        {filename_, op2Token.row_, op2Token.col_, error::Severity::Critical,
         "Error: EXTEND expected second operand to be a block, got \%\n",
         op2->getTrueType()});
  }
  return std::make_unique<AST::BinaryOpNode>(EXTEND, std::move(op1),
                                             std::move(op2));
}

std::unique_ptr<AST::ASTNode> Parser::parseMember() {
  auto op1Token = currentToken();
  auto op1 = parseExpression();
  if (op1->getTrueType()->type_ != type::BLOCK) {
    error::errorManager.addError(
        {filename_, op1Token.row_, op1Token.col_, error::Severity::Critical,
         "Error: MEMBER expected first operand to be a block, got \%\n",
         op1->getTrueType()});
  }
  auto op2Token = currentToken();
  if (op2Token.type != IDENTIFIER) {
    error::errorManager.addError(
        {filename_, op2Token.row_, op2Token.col_, error::Severity::Critical,
         "Error: MEMBER expected second operand to be an identifier.\n"});
  }
  auto op2 = std::make_unique<AST::IdentifierNode>(op2Token.value);
  currentPos_++;
  auto blockType = static_cast<type::BlockType *>(op1->getTrueType().get());
  auto memberName = op2Token.value;
  if (blockType->getType(memberName) == nullptr) {
    error::errorManager.addError(
        {filename_, op2Token.row_, op2Token.col_, error::Severity::Critical,
         "Error: Cannot find member '%'\n", memberName});
  }

  return std::make_unique<AST::MemberAccessNode>(std::move(op1), memberName);
}

std::unique_ptr<AST::ASTNode> Parser::parseGroup() {
  auto expression = parseExpression();
  // current token after expression
  if (tokens_[currentPos_] == Token(SYMBOL, ",")) {
    std::vector<std::unique_ptr<AST::ASTNode>> groupMember;
    groupMember.push_back(std::move(expression));
    while (tokens_[currentPos_] == Token(SYMBOL, ",")) {
      currentPos_++;
      expression = parseExpression();
      if (expression->type_ == AST::GROUPNODE) {
        auto innerGroup = static_cast<AST::GroupNode *>(expression.get());
        groupMember.insert(
            groupMember.end(),
            std::make_move_iterator(innerGroup->members_.begin()),
            std::make_move_iterator(innerGroup->members_.end()));
      } else {
        groupMember.push_back(std::move(expression));
      }
    }
    expression = std::make_unique<AST::GroupNode>(std::move(groupMember));
  }
  return expression;
}

std::unique_ptr<AST::ASTNode> Parser::astNode() const {
  return astNode_->clone();
}

Parser::operator std::string() const {
  return AST::toString(astNode_.get(), 0);
}

void Parser::pushScope() {
  scopeManager_->pushScope();
  macroManager_->pushScope();
}

void Parser::popScope() {
  scopeManager_->popScope();
  macroManager_->popScope();
}

void Parser::printNode() const { std::cout << astNode_.get(); }

const ScopeManager &Parser::getScopeManager() const { return *scopeManager_; }

const macro::MacroManager &Parser::getMacroManager() const {
  return *macroManager_;
}
} // namespace morphl
