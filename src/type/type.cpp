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
  if (this == nullptr) {
    return "NONE";
  }
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
    return static_cast<std::string>(b) + " -> " +
           static_cast<std::string>(*ppf->pReturnType_);
  }
  case IDENTIFIER: {
    auto pi = static_cast<const IdentifierType *>(this);
    return pi->name_ + " AKA " + static_cast<std::string>(*pi->pType_);
    //return static_cast<std::string>(*pi->pType_);
  }
  case CONST: {
    auto pc = static_cast<const ConstType *>(this);
    return "const " + static_cast<std::string>(*pc->pType_);
  }
  default:
    return "Unknown Type";
  }
}

//
//  Type Comparison
//


PrimitiveType::operator TypeComparable() const {
  return TypeComparable{this->typeName_};
}

BlockType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this)};
}

GroupType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this)};
}

ListType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this)};
}

FunctionType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this)};
}

IdentifierType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this->pType_)};
}

ConstType::operator TypeComparable() const {
  return TypeComparable{static_cast<std::string>(*this->pType_)};
}


std::ostream &operator<<(std::ostream &ostr, const TypeObject *t) {
  return ostr << static_cast<std::string>(*t);
}

bool operator==(const TypeObject &lhs, const TypeObject &rhs) {
  if (dynamic_cast<const AnyType*>(&lhs) != nullptr || dynamic_cast<const AnyType*>(&rhs) != nullptr) {
    return true;
  }
  return static_cast<TypeComparable>(lhs).compareString == static_cast<TypeComparable>(rhs).compareString;
}

bool operator!=(const TypeObject &lhs, const TypeObject &rhs) {
  return !(lhs == rhs);
}

const std::shared_ptr<TypeObject> TypeObject::none =
    std::make_shared<TypeObject>(NONE);
const std::shared_ptr<TypeObject> PrimitiveType::INTEGER =
    std::make_shared<PrimitiveType>("int");
const std::shared_ptr<TypeObject> PrimitiveType::FLOAT =
    std::make_shared<PrimitiveType>("float");
const std::shared_ptr<TypeObject> PrimitiveType::STRING =
    std::make_shared<PrimitiveType>("string");

} // namespace type
} // namespace morphl
