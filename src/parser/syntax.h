#ifndef MORPHL_PARSER_SYNTAX_H
#define MORPHL_PARSER_SYNTAX_H

#include "../ast/ast.h"
#include "../lexer/lexer.h"
#include "scope.h"
#include <memory>
#include <string>
#include <vector>
namespace morphl {
class Syntax {
  std::vector<Token> syntax_;
  size_t expectedArgumentsSize_;

public:
  Syntax();
  Syntax(const std::string);
  std::vector<std::string> getOperands() const;
  std::unique_ptr<AST::ASTNode> replace(std::vector<std::unique_ptr<AST::ASTNode>>, ScopeManager& context) const;
};
} // namespace morphl

#endif // !MORPHL_PARSER_SYNTAX_H
