#ifndef MORPHL_TYPE_TYPE_H
#define MORPHL_TYPE_TYPE_H

#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace morphl {
namespace type {

enum Type {
  NONE,
  PRIMITIVE,
  BLOCK, // container of any type with named members
  GROUP, // container of any type without named members
  LIST,  // conainter of one type without named members
  FUNC,

  CONST,

  PSEUDO_FUNC, // block with either operands or returns.
  IDENTIFIER   // not a type, used to define that type is referenced from
               // identifier.
};

struct TypeComparable {
  const std::string compareString;
};

struct TypeObject {
  Type type_;
  TypeObject() : type_{NONE} {}
  TypeObject(Type t) : type_{t} {}
  operator std::string() const;
  // virtual bool operator==(TypeObject) const = 0;
  static const std::shared_ptr<TypeObject> none;
  virtual operator TypeComparable() const {return TypeComparable();}
};


using BlockTypeMembers =
    std::vector<std::pair<std::string, std::shared_ptr<TypeObject>>>;
using GroupTypeMembers = std::vector<std::shared_ptr<TypeObject>>;

struct PrimitiveType : public TypeObject {
  std::string typeName_;

  PrimitiveType(std::string typeName)
      : TypeObject(PRIMITIVE), typeName_{typeName} {}
  operator TypeComparable() const override;
  static const std::shared_ptr<TypeObject> INTEGER;
  static const std::shared_ptr<TypeObject> FLOAT;
  static const std::shared_ptr<TypeObject> STRING;
};

struct BlockType : public TypeObject {
  BlockTypeMembers members_;
  std::unordered_map<std::string, std::shared_ptr<TypeObject>> membersMap_;
  BlockType(BlockTypeMembers members = {})
      : TypeObject(BLOCK), members_{members} {}

  operator TypeComparable() const override;
  void addMember(std::string name, std::shared_ptr<TypeObject> type) {
    std::pair<std::string, std::shared_ptr<TypeObject>> member{name, type};
    members_.push_back(member);
    membersMap_[name] = type;
  }

  void appendMembers(BlockType other) {
    members_.insert(members_.end(), other.members_.begin(), other.members_.end());
    membersMap_.insert(other.membersMap_.begin(), other.membersMap_.end());
  }

  std::shared_ptr<TypeObject> getType(std::string name) {
    if (membersMap_.find(name) == membersMap_.end()) {
      return nullptr;
    }
    return membersMap_[name];
  }
};

struct GroupType : public TypeObject {
  GroupTypeMembers members_;

  GroupType() : TypeObject(GROUP) {}
  GroupType(GroupTypeMembers members) : TypeObject(GROUP), members_{members} {}
  operator TypeComparable() const override;
};

struct ListType : public TypeObject {
  std::shared_ptr<TypeObject> pElementsType_;
  size_t size_;

  ListType(std::shared_ptr<TypeObject> t, size_t size)
      : TypeObject(LIST), pElementsType_(t), size_(size) {}
  operator TypeComparable() const override;
};

struct FunctionType : public TypeObject {
  std::shared_ptr<TypeObject> pOperandsType_;
  std::shared_ptr<TypeObject> pReturnType_;

  operator TypeComparable() const override;
  FunctionType(std::shared_ptr<TypeObject> pOperandsType,
               std::shared_ptr<TypeObject> pReturnType)
      : TypeObject(FUNC), pOperandsType_(pOperandsType),
        pReturnType_(pReturnType) {}
};

struct PseudoFunctionType : public BlockType {
  std::shared_ptr<TypeObject> pReturnType_;

  operator TypeComparable() const override;
  PseudoFunctionType(BlockTypeMembers members,
                     std::shared_ptr<TypeObject> pReturnType)
      : BlockType(members), pReturnType_{pReturnType} {
    type_ = PSEUDO_FUNC;
  }
};

struct IdentifierType : public TypeObject {
  std::string name_;
  std::shared_ptr<TypeObject> pType_;

  operator TypeComparable() const override;
  IdentifierType(std::string name, std::shared_ptr<TypeObject> pType)
      : TypeObject(IDENTIFIER), name_(name), pType_(pType) {}
};

struct ConstType : public TypeObject {
  std::shared_ptr<TypeObject> pType_;

  operator TypeComparable() const override;
  ConstType(std::shared_ptr<TypeObject> pType) : TypeObject(CONST), pType_(pType) {}
};

std::ostream &operator<<(std::ostream &ostr, const TypeObject *t);

bool operator==(const TypeObject &, const TypeObject &);

bool operator!=(const TypeObject &, const TypeObject &);
} // namespace type
} // namespace morphl

#endif // !MORPHL_TYPE_TYPE_H
