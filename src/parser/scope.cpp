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

  void ScopeManager::addScopeObject(std::shared_ptr<ScopeObject> p) {
    this->scope_.top().push_back(p);
  }

  std::shared_ptr<type::TypeObject> ScopeManager::getType(std::string name) const {
    auto tempStack = this->scope_;
    while (!tempStack.empty()) {
      for (auto& i:tempStack.top()) {
        if (i->scopeObjectType_ == ScopeObjectType::IDENTIFIER_TYPE) {
          auto idType = static_cast<IdentifierType*>(i.get());
          if (idType->name_ == name) {
            return idType->type_;
          }
        }
      }
      tempStack.pop();
    }
    return nullptr;
  }

  ScopeManager::operator std::string() const {
    std::string str = "Program:\n";
    for (auto& i:scope_.top()) {
      if (i->scopeObjectType_ == ScopeObjectType::IDENTIFIER_TYPE) {
        const type::TypeObject* pTypeObj = static_cast<IdentifierType*>(i.get())->type_.get();
        str += static_cast<IdentifierType*>(i.get())->name_ + ":" + static_cast<std::string>(*pTypeObj) + "\n";
      }
    }
    
    return str;

  }
}
