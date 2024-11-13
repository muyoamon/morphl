#include "macroManager.h"
#include "macro.h"
#include <unordered_set>
namespace morphl {
namespace macro {
  void MacroManager::pushScope() {
    scope_.emplace();
  }
  void MacroManager::popScope() {
    scope_.pop();
  }
  void MacroManager::addMacro(Macro m) {
    scope_.top().insert(scope_.top().end(),m);
  }
  std::list<Macro> MacroManager::getAllMacro() const {
    MacroStack temp = scope_;
    std::list<Macro> res;
    while (!temp.empty()) {
      for (const auto& i:temp.top()) {
        res.insert(res.end(),i);
      }
      temp.pop();
    }
    return res;
  }
}
}
