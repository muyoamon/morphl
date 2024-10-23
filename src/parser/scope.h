#ifndef MORPHL_PARSER_SCOPE_H
#define MORPHL_PARSER_SCOPE_H

#include "type.h"
#include <memory>
#include <stack>
#include <string>
#include <vector>
namespace morphl {
  struct ScopeObject {
    std::string name_;
    std::shared_ptr<type::TypeObject> type_;
  };
  class ScopeManager {
    std::stack<std::vector<ScopeObject>> scope_;
    public:
    void pushScope();
    void popScope();

    void addScopeObject(ScopeObject o);
    std::shared_ptr<type::TypeObject> getType(std::string name) const;

    operator std::string() const;
  };
}



#endif // !MORPHL_PARSER_SCOPE_H

