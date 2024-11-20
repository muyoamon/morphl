#ifndef MORPHL_PARSER_MACRO_H
#define MORPHL_PARSER_MACRO_H

#include "../lexer/lexer.h"
#include "../type/type.h"
#include <memory>
#include <vector>
namespace morphl {
namespace macro {
struct Macro {
  using Syntax = std::vector<Token>;
  Syntax syntax_;
  Syntax expansion_;
  std::vector<std::shared_ptr<type::TypeObject>> operandTypes_;
  int precedence_;
  Macro() = default;
  Macro(Syntax s, Syntax e, std::vector<std::shared_ptr<type::TypeObject>> o, int pred)
    :syntax_(s), expansion_(e), operandTypes_(o), precedence_(pred) {}

  operator std::string();
};
std::ostream &operator<<(std::ostream &, Macro m);
} // namespace macro
} // namespace morphl

#endif // !MORPHL_PARSER_MACRO_H
