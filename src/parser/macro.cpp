#include "macro.h"
#include "../error/error.h"
#include <memory>
#include <string>
#include <vector>
namespace morphl {
namespace macro {

Macro::operator std::string() {
  // return "";
  return error::formatString("`\%` \% \% `\%`", tokensString(syntax_),
                             precedence_,
                             std::make_shared<type::GroupType>(operandTypes_),
                             tokensString(expansion_));
}

std::ostream &operator<<(std::ostream &ostr, Macro m) {
  return ostr << static_cast<std::string>(m);
}

bool operator==(const Macro lhs, const Macro rhs) {
  return lhs.syntax_ == rhs.syntax_ && lhs.operandTypes_ == rhs.operandTypes_;
}

} // namespace macro
} // namespace morphl
