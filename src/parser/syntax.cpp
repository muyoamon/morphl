#include "syntax.h"
#include "scope.h"
#include <algorithm>
#include <string>
#include <vector>
namespace morphl {
Syntax::Syntax() : syntax_(), expectedArgumentsSize_(0) {}
Syntax::Syntax(const std::string str) {
  size_t operands = 0;
  syntax_ = Lexer(str).tokens();
  for (auto i : syntax_) {
    if (i.type == OPERAND) {
      operands++;
    }
  }
  expectedArgumentsSize_ = operands;
}

std::vector<std::string> Syntax::getOperands() const {
  std::vector<std::string> operands;
  for (auto i : syntax_) {
    if (i.type == OPERAND && std::find(operands.begin(),operands.end(),i.value) != operands.end()) {
      operands.push_back(i.value);
    }
  }
  return operands;
}


std::unique_ptr<AST::ASTNode>
Syntax::replace(std::vector<std::unique_ptr<AST::ASTNode>> args, ScopeManager& context) const {
  if (args.size() != expectedArgumentsSize_) {
    return nullptr;
  }
  auto operands = getOperands();
  

}

} // namespace morphl
