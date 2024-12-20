#include "macroManager.h"
#include "macro.h"
#include <string>
#include <unordered_set>
namespace morphl {
namespace macro {
void MacroManager::pushScope() { scope_.emplace(); }
void MacroManager::popScope() { scope_.pop(); }

bool MacroManager::empty() const { return this->scope_.empty(); }
void MacroManager::addMacro(Macro m) { scope_.top().push_back(m); }
std::list<Macro> MacroManager::getAllMacro() const {
  MacroStack temp = scope_;
  std::list<Macro> res;
  while (!temp.empty()) {
    auto it = res.begin();
    for (const auto &i : temp.top()) {
      res.insert(it, i);
    }
    temp.pop();
  }
  res.sort([](Macro x, Macro y) { return x.precedence_ < y.precedence_; });
  return res;
}
MacroManager::operator std::string() const {
  std::string res = "Current Scope Macro:\n";
  auto macros = getAllMacro();
  for (auto i : macros) {
    res += static_cast<std::string>(i) + "\n";
  }
  return res;
}
} // namespace macro
} // namespace morphl
