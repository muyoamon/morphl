#include "type.h"
#include <memory>
#include <ostream>
#include <string>
#include <utility>
namespace morphl {
namespace type {

template <class InputIt, class UnaryFunction>
static std::string delimiterInsert(InputIt begin, InputIt end,
                                   UnaryFunction f) {
  if (begin == end) {
    return "";
  }
  std::string res = f(*begin);
  auto it = begin;
  for (it++; it != end; it++) {
    res += ",";
    res += f(*it);
  }
  return res;
}

TypeObject::operator std::string() const {
  switch (this->type_) {
  case PRIMITIVE: {
    auto pp = static_cast<const PrimitiveType *>(this);
    return pp->typeName_;
  }
  case BLOCK: {
    auto pb = static_cast<const BlockType *>(this);
    std::string res = "{";
    res += delimiterInsert(
        pb->members_.begin(), pb->members_.end(),
        [](std::pair<const std::string, std::shared_ptr<TypeObject>> p)
            -> std::string {
          return p.first + ":" + static_cast<std::string>(*p.second);
        });
    return res + "}";
  }
  case GROUP: {
    auto pg = static_cast<const GroupType *>(this);
    std::string res = "(";
    res += delimiterInsert(pg->members_.begin(), pg->members_.end(),
                           [](std::shared_ptr<TypeObject> p) -> std::string {
                             return static_cast<std::string>(*p);
                           });
    return res + ")";
  }
  case LIST: {
    auto pl = static_cast<const ListType *>(this);
    return static_cast<std::string>(*pl->pElementsType_) + "[" +
           std::to_string(pl->size_) + "]";
  }
  case FUNC: {
    auto pf = static_cast<const FunctionType *>(this);
    return static_cast<std::string>(*pf->pOperandsType_) + " -> " +
           static_cast<std::string>(*pf->pReturnType_);
  }
  case PSEUDO_FUNC: {
    auto pb = static_cast<const BlockType *>(this);
    BlockType b(pb->members_);
    auto ppf = static_cast<const PseudoFunctionType *>(this);
    return static_cast<std::string>(b) + " -> " + static_cast<std::string>(*ppf->pReturnType_);
  }
  case IDENTIFIER: {
    auto pi = static_cast<const IdentifierType *>(this);
    return pi->name_ + " AKA " + static_cast<std::string>(*pi->pType_);
  }
  default:
    return "Unknown Type";
  }
}

std::ostream &operator<<(std::ostream &ostr, const TypeObject *t) {
  return ostr << static_cast<std::string>(*t);
}

bool operator==(const TypeObject lhs, const TypeObject rhs) {
  if (lhs.type_ == IDENTIFIER) {
    return *static_cast<const IdentifierType *>(&lhs) == rhs;
  }
  if (rhs.type_ == IDENTIFIER) {
    return *static_cast<const IdentifierType *>(&rhs) == lhs;
  }
  return static_cast<std::string>(lhs) == static_cast<std::string>(rhs);
}

} // namespace type
} // namespace morphl
