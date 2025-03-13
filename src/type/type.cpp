#include "type.h"
#include <cstdint>
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

UniqueType::operator std::string() const {
  return std::to_string
    (reinterpret_cast<const uintptr_t>(this))
    + " -> " + static_cast<std::string>(*this->pType_);
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



//
//  Type Comparison
//

bool PrimitiveType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const PrimitiveType*>(&t);
  if (!other) {
    return false;
  }
  return this->typeName_ == other->typeName_;
}


bool BlockType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const BlockType*>(&t);
  if (!other) {
    return false;
  }
  for (auto i: this->members_) {
    try {
      if (*other->membersMap_.at(i.first) != *i.second) {
        return false;
      }
    } catch (...) {
      return false;
    }
  }
  return true;
}

bool GroupType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const GroupType*>(&t);
  if (!other) {
    return false;
  }
  for (auto i = 0; i != this->members_.size(); i++) {
    if (*this->members_[i] != *other->members_[i]) {
      return false;
    }
  }
  return true;
}

bool ListType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const ListType*>(&t);
  if (!other) {
    return false;
  }
  return *this->pElementsType_ == *other->pElementsType_ && this->size_ <= other->size_;
}

bool FunctionType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const FunctionType*>(&t);
  if (!other) {
    return false;
  }
  return *this->pOperandsType_ == *other->pOperandsType_ &&
    *this->pReturnType_ == *this->pReturnType_;
}

bool IdentifierType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const IdentifierType*>(&t);
  if (!other) {
    return false;
  }

  return this->pType_->accept(*other);
}


bool UniqueType::accept(const TypeObject& t) const {
  const auto other = dynamic_cast<const UniqueType*>(&t);
  if (!other) {
    return false;
  }

  return this->pType_->accept(*other);
}

bool UniqueType::operator==(const TypeObject& t) const {
  return this == &t;
}

std::ostream &operator<<(std::  ostream &ostr, const TypeObject *t) {
  return ostr << static_cast<std::string>(*t);
}

bool TypeObject::operator==(const TypeObject& other) const {
  return this->accept(other) && other.accept(*this);
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
