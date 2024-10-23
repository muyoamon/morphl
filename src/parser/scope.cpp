#include "scope.h"
#include "type.h"
#include <memory>
#include <string>
namespace morphl {
  void ScopeManager::pushScope() {
    this->scope_.emplace();
  }

  void ScopeManager::popScope() {
    this->scope_.pop();
  }

  void ScopeManager::addScopeObject(ScopeObject o) {
    this->scope_.top().push_back(o);
  }

  std::shared_ptr<type::TypeObject> ScopeManager::getType(std::string name) const {
    auto tempStack = this->scope_;
    while (!tempStack.empty()) {
      for (auto& i:tempStack.top()) {
        if (i.name_ == name) {
          return i.type_;
        }
      }
      tempStack.pop();
    }
    return nullptr;
  }

  ScopeManager::operator std::string() const {
    std::string str = "Program:\n";
    for (auto& i:scope_.top()) {
      const type::TypeObject* pTypeObj = i.type_.get();
      str += i.name_ + ":" + static_cast<std::string>(*pTypeObj) + "\n";
    }
    
    return str;

  }
}
