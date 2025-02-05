#include "macro.h"
#include "../error/error.h"
#include <memory>
#include <string>
#include <vector>
namespace morphl {
namespace parser {

Macro::operator std::string() {
  std::string opTypeString = "";
  if (!operandTypes_.empty()) {
    opTypeString = "(";
    for (auto& i:this->operandTypes_) {
      opTypeString += i.first;
      opTypeString += ":";
      opTypeString += tokensString(i.second);
      opTypeString += ", ";
    }
    *(++opTypeString.rbegin()) = ')';
  } 
  // return "";
  return error::formatString("`\%` \% \% `\%`", tokensString(syntax_),
                             precedence_,
                             opTypeString,
                             tokensString(expansion_));
}

std::ostream &operator<<(std::ostream &ostr, Macro m) {
  return ostr << static_cast<std::string>(m);
}

bool operator==(const Macro lhs, const Macro rhs) {
  return lhs.syntax_ == rhs.syntax_ && lhs.operandTypes_ == rhs.operandTypes_;
}

} // namespace parser
} // namespace morphl
