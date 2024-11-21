#ifndef MORPHL_PARSER_MACROMANAGER_H
#define MORPHL_PARSER_MACROMANAGER_H

#include <list>
#include <stack>
#include <string>
#include <unordered_set>
#include "macro.h"

namespace morphl {
namespace macro {

class MacroManager {
  using MacroStack = std::stack<std::vector<Macro>>;
  MacroStack scope_;
public:
  void addMacro(Macro m);
  std::list<Macro> getAllMacro() const;
  void pushScope();
  void popScope();
  bool empty() const;
  operator std::string() const;
};
}
}
#endif // !MORPHL_PARSER_MACROMANAGER_H
