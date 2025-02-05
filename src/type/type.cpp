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
  return "None Type";
}

PrimitiveType::operator std::string() const {
  return this->typeName_;
}

GroupType::operator std::string() const {
  std::string res = "(";
  res += delimiterInsert(this->members_.begin(), this->members_.end(), [](std::shared_ptr<TypeObject> p) -> std::string{
      return static_cast<std::string>(*p);
      });
  return res + ")";
}

ListType::operator std::string() const {
  return static_cast<std::string>(*this->pElementsType_) + "[" + std::to_string(this->size_) + "]";
}

FunctionType::operator std::string() const {
  return static_cast<std::string>(*this->pOperandsType_) + " -> " + static_cast<std::string>(*this->pReturnType_);
}

IdentifierType::operator std::string() const {
  return this->name_ + " AKA " + static_cast<std::string>(*this->pType_);
}

ConstType::operator std::string() const {
  return "const " + static_cast<std::string>(*this->pType_);
}

BlockType::operator std::string() const {
    std::string res = "{";
    res += delimiterInsert(
        this->members_.begin(), this->members_.end(),
        [](std::pair<const std::string, std::shared_ptr<TypeObject>> p)
            -> std::string {
          return p.first + ":" + static_cast<std::string>(*p.second);
        });
    return res + "}";

}

AnyType::operator std::string() const {
  return "Any Type";
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
