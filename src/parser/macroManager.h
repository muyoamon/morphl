#ifndef MORPHL_PARSER_MACROMANAGER_H
#define MORPHL_PARSER_MACROMANAGER_H

#include <list>
#include <stack>
#include <unordered_set>
#include "macro.h"

namespace morphl {
namespace macro {

class MacroManager {
  using MacroStack = std::stack<std::list<Macro>>;
  MacroStack scope_;
  void pushScope();
  void popScope();
  void addMacro(Macro m);
  std::list<Macro> getAllMacro() const;
};
}
}
#endif // !MORPHL_PARSER_MACROMANAGER_H
