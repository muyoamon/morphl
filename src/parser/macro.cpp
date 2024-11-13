#include "macro.h"
#include "../ast/ast.h"
#include "../error/error.h"
#include <memory>
#include <string>
#include <vector>
namespace morphl {
namespace macro {
  Macro::operator std::string() {
    return "";
    //return error::formatString("`\%` \%\%`\%`", syntax_, precedence_, operandTypes_, expansion_);
  }

  std::ostream& operator<<(std::ostream& ostr, Macro m) {
    return ostr << static_cast<std::string>(m);
  }
} // namespace macro
} // namespace morphl
