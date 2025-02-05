#ifndef MORPHL_PARSER_MACRO_H
#define MORPHL_PARSER_MACRO_H

#include "../lexer/lexer.h"
#include "../type/type.h"
#include "syntax.h"
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
namespace morphl {
namespace parser {
struct Macro {
  using OperandsType = std::unordered_map<std::string,Syntax>;
  Syntax syntax_;
  Syntax expansion_;
  OperandsType operandTypes_;
  int precedence_;
  Macro() = default; 
  Macro(Syntax s, Syntax e, OperandsType o, int pred)
    :syntax_(s), expansion_(e), operandTypes_(o), precedence_(pred) {}

  operator std::string();
};
std::ostream &operator<<(std::ostream &, Macro m);
bool operator==(const Macro, const Macro);
} // namespace parser
} // namespace morphl

#endif // !MORPHL_PARSER_MACRO_H
