#ifndef MORPHL_PARSER_SCOPE_H
#define MORPHL_PARSER_SCOPE_H

#include "../type/type.h"
#include <memory>
#include <stack>
#include <string>
#include <vector>
namespace morphl {
enum class ScopeObjectType { NONE, IDENTIFIER_TYPE, ALIAS, MORPH };
struct ScopeObject {
  ScopeObjectType scopeObjectType_;

  //ScopeObject() : scopeObjectType_(ScopeObjectType::NONE) {}
  ScopeObject(ScopeObjectType scopeObjectType)
      : scopeObjectType_(scopeObjectType) {}
};
struct IdentifierType : public ScopeObject {
  std::string name_;
  std::shared_ptr<type::TypeObject> type_;

  IdentifierType(std::string name, std::shared_ptr<type::TypeObject> type)
      : ScopeObject(ScopeObjectType::IDENTIFIER_TYPE), name_(name),
        type_(type) {}
};
class ScopeManager {
  std::stack<std::vector<std::shared_ptr<ScopeObject>>> scope_;

public:
  void pushScope();
  void popScope();

  void addScopeObject(std::shared_ptr<ScopeObject> p);
  std::shared_ptr<type::TypeObject> getType(std::string name) const;

  operator std::string() const;
};
} // namespace morphl

#endif // !MORPHL_PARSER_SCOPE_H
