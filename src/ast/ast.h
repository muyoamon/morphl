#ifndef MORPHL_AST_H
#define MORPHL_AST_H

#include "../lexer/lexer.h"
#include "../parser/macro.h"
#include "../type/type.h"
#include <algorithm>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <vector>
namespace morphl {
namespace AST {
enum ASTNodeType {
  UNKNOWNNODE,
  PROGRAMNODE,
  BLOCKNODE,
  FUNCNODE,
  C_FUNCNODE,
  STATEMENTNODE,
  IFNODE,
  WHILENODE,
  BINARYOPNODE,
  UNARYOPNODE,
  DECLNODE,
  // EXPRGROUPNODE,

  //
  //  mutable
  //

  IDENTIFIERNODE,
  MEMBERNODE,
  ARRAYINDEXNODE,
  GROUPINDEXNODE,

  //
  //  Literals
  //

  INT_LITERALNODE,
  FLOAT_LITERALNODE,
  STRING_LITERALNODE,
  NONE_LITERALNODE,

  //
  //  data types
  //

  GROUPNODE,
  ARRAYNODE,


  CONSTNODE,
  REFNODE,
  MUTNODE,

  //
  // externals
  //
  
  IMPORTNODE,
  LIBNODE,

  //
  // Macro
  //

  MACRONODE,
};

struct ASTNode {
  ASTNodeType type_;
  bool mutable_;
  std::shared_ptr<type::TypeObject> objectType_ = nullptr;

  ASTNode(ASTNodeType type) : type_(type), mutable_(false) {}
  ASTNode(ASTNodeType type, bool isMutable)
      : type_(type), mutable_(isMutable) {}
  virtual std::unique_ptr<ASTNode> clone() const = 0;
  virtual std::shared_ptr<type::TypeObject> getType(){
    return std::make_shared<type::TypeObject>(type::NONE);
  };
  virtual ~ASTNode() = default;
  std::shared_ptr<type::TypeObject> getTrueType();
  
};

struct ProgramNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> children_;

  ProgramNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(PROGRAMNODE), children_(std::move(v)) {}
  ProgramNode(const ProgramNode &other) : ASTNode(PROGRAMNODE) {
    for (const auto &i : other.children_) {
      children_.push_back(i->clone());
    }
  }
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<ProgramNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct BlockNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> children_;

  BlockNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(BLOCKNODE), children_(std::move(v)) {}
  BlockNode(const BlockNode &other) : ASTNode(BLOCKNODE) {
    for (const auto &i : other.children_) {
      children_.push_back(i->clone());
    }
  }
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<BlockNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct StatementNode : public ASTNode {
  std::unique_ptr<ASTNode> child_;
  bool isPrint_;

  StatementNode(std::unique_ptr<ASTNode> &&child, bool isPrint)
      : ASTNode(STATEMENTNODE), child_(std::move(child)), isPrint_{isPrint} {}
  StatementNode(const StatementNode &other)
      : ASTNode(STATEMENTNODE), child_(other.child_->clone()),
        isPrint_(other.isPrint_) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<StatementNode>(*this);
  }
};

struct IfNode : public ASTNode {
  std::unique_ptr<ASTNode> ifBlock_;

  IfNode(std::unique_ptr<ASTNode> &&ifBlock)
      : ASTNode(IFNODE), ifBlock_(std::move(ifBlock)) {}
  IfNode(const IfNode &other)
      : ASTNode(IFNODE), ifBlock_(other.ifBlock_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<IfNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct WhileNode : public ASTNode {
  std::unique_ptr<ASTNode> whileBlock_;

  WhileNode(std::unique_ptr<ASTNode> &&whileBlock)
      : ASTNode(WHILENODE), whileBlock_(std::move(whileBlock)) {}
  WhileNode(const WhileNode &other)
      : ASTNode(WHILENODE), whileBlock_(other.whileBlock_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<WhileNode>(*this);
  }
};

struct BinaryOpNode : public ASTNode {
  TokenType opType_;
  std::unique_ptr<ASTNode> operand1_;
  std::unique_ptr<ASTNode> operand2_;

  BinaryOpNode(TokenType type, std::unique_ptr<ASTNode> &&op1,
               std::unique_ptr<ASTNode> &&op2)
      : ASTNode(BINARYOPNODE), operand1_(std::move(op1)),
        operand2_(std::move(op2)), opType_{type} {}
  BinaryOpNode(const BinaryOpNode &other)
      : ASTNode(BINARYOPNODE), opType_(other.opType_),
        operand1_(other.operand1_->clone()),
        operand2_(other.operand2_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<BinaryOpNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct UnaryOpNode : public ASTNode {
  TokenType opType_;
  std::unique_ptr<ASTNode> operand_;

  UnaryOpNode(TokenType type, std::unique_ptr<ASTNode> &&op)
      : ASTNode(UNARYOPNODE), operand_(std::move(op)), opType_{type} {}
  UnaryOpNode(const UnaryOpNode &other)
      : ASTNode(UNARYOPNODE), opType_(other.opType_),
        operand_(other.operand_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<UnaryOpNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct IdentifierNode : public ASTNode {
  std::string name_;

  IdentifierNode(std::string name)
      : ASTNode(IDENTIFIERNODE, false), name_{name} {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<IdentifierNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct MemberAccessNode : public ASTNode {
  std::unique_ptr<ASTNode> parent_;
  std::string memberName_;

  MemberAccessNode(std::unique_ptr<ASTNode> &&parent, std::string name)
      : ASTNode(MEMBERNODE, parent->mutable_), parent_(std::move(parent)),
        memberName_(name) {}
  MemberAccessNode(const MemberAccessNode &other)
      : ASTNode(MEMBERNODE, other.mutable_), parent_(other.parent_->clone()),
        memberName_(other.memberName_) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<MemberAccessNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct GroupIndexNode : public ASTNode {
  std::unique_ptr<ASTNode> parent_;
  size_t index_;

  GroupIndexNode(std::unique_ptr<ASTNode> &&parent, size_t index)
      : ASTNode(GROUPINDEXNODE, parent->mutable_), parent_(std::move(parent)),
        index_(index) {}
  GroupIndexNode(const GroupIndexNode &other)
      : ASTNode(GROUPINDEXNODE, other.mutable_), parent_(other.parent_->clone()),
        index_(other.index_) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<GroupIndexNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct ArrayIndexNode : public ASTNode {
  std::unique_ptr<ASTNode> parent_;
  std::unique_ptr<ASTNode> index_;

  ArrayIndexNode(std::unique_ptr<ASTNode> &&parent, std::unique_ptr<ASTNode> index)
      : ASTNode(ARRAYINDEXNODE, parent->mutable_), parent_(std::move(parent)),
        index_(std::move(index)) {}
  ArrayIndexNode(const ArrayIndexNode &other)
      : ASTNode(ARRAYINDEXNODE, other.mutable_), parent_(other.parent_->clone()),
        index_(other.index_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<ArrayIndexNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};


struct IntLiteralNode : public ASTNode {
  int value_;

  IntLiteralNode(int value) : ASTNode(INT_LITERALNODE), value_{value} {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<IntLiteralNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct FloatLiteralNode : public ASTNode {
  float value_;

  FloatLiteralNode(float value) : ASTNode(FLOAT_LITERALNODE), value_{value} {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<FloatLiteralNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct StringLiteralNode : public ASTNode {
  std::string value_;

  StringLiteralNode(std::string value)
      : ASTNode(STRING_LITERALNODE), value_{value} {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<StringLiteralNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct GroupNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> members_;

  GroupNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(GROUPNODE), members_(std::move(v)) {}
  GroupNode(const GroupNode &other) : ASTNode(GROUPNODE) {
    for (const auto &i : other.members_) {
      members_.push_back(i->clone());
    }
  }
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<GroupNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct ArrayNode : public ASTNode {
  std::shared_ptr<type::TypeObject> type_;
  size_t size_;

  ArrayNode(std::shared_ptr<type::TypeObject> type, size_t size)
      : ASTNode(ARRAYNODE), type_(type), size_(size) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<ArrayNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct FunctionNode : public ASTNode {
  std::unique_ptr<ASTNode> argType_;
  std::unique_ptr<ASTNode> value_;

  FunctionNode(std::unique_ptr<ASTNode> &&arg, std::unique_ptr<ASTNode> &&val)
      : ASTNode(FUNCNODE), argType_(std::move(arg)), value_(std::move(val)) {}
  FunctionNode(const FunctionNode &other)
      : ASTNode(FUNCNODE), argType_(std::move(other.argType_->clone())),
        value_(std::move(other.value_->clone())) {}

  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<FunctionNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct DeclarationNode : public ASTNode {
  std::string name_;
  std::unique_ptr<ASTNode> initialValue_;

  DeclarationNode(std::string name, std::unique_ptr<ASTNode> &&init)
      : ASTNode(DECLNODE, init->mutable_), name_(name), initialValue_(std::move(init)) {}
  DeclarationNode(const DeclarationNode &other)
      : ASTNode(DECLNODE, other.mutable_), name_(other.name_),
        initialValue_(other.initialValue_->clone()) {}
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<DeclarationNode>(*this);
  }

  std::shared_ptr<type::TypeObject> getType() override;
};

struct MacroNode : ASTNode {

  MacroNode() : ASTNode(MACRONODE) {}
  MacroNode(const MacroNode &other) : ASTNode(MACRONODE) {}

  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<MacroNode>(*this);
  }
};

struct ImportNode : ASTNode {
  std::filesystem::path path_;

  ImportNode() : ASTNode(IMPORTNODE) {}
  ImportNode(const std::filesystem::path path) : ASTNode(IMPORTNODE), path_(path) {}

  std::unique_ptr<AST::ASTNode> clone() const override {
    return std::make_unique<ImportNode>(*this);
  }
  std::shared_ptr<type::TypeObject> getType() override;
};

struct RefNode : ASTNode {
  std::unique_ptr<ASTNode> val_;

  RefNode() : ASTNode(REFNODE) {}
  RefNode(std::unique_ptr<ASTNode>&& node) : ASTNode(REFNODE, node->mutable_), val_(std::move(node)) {} 
  std::unique_ptr<ASTNode> clone() const override {
    return std::make_unique<RefNode>(std::move(this->val_->clone()));
  }
  std::shared_ptr<type::TypeObject> getType() override;
};
/**/
/*struct ConstNode : ASTNode {*/
/*  std::unique_ptr<ASTNode> val_;*/
/**/
/*  ConstNode() : ASTNode(CONSTNODE, false) {}*/
/*  ConstNode(std::unique_ptr<ASTNode>&& node) : ASTNode(CONSTNODE, false), val_(std::move(node)) {} */
/*  std::unique_ptr<ASTNode> clone() const override {*/
/*    return std::make_unique<ConstNode>(std::move(this->val_->clone()));*/
/*  }*/
/*  std::shared_ptr<type::TypeObject> getType() const override;*/
/*};*/
/**/
/*struct MutNode : ASTNode {*/
/*  std::unique_ptr<ASTNode> val_;*/
/**/
/*  MutNode() : ASTNode(MUTNODE, false) {}*/
/*  MutNode(std::unique_ptr<ASTNode>&& node) : ASTNode(CONSTNODE, false), val_(std::move(node)) {} */
/*  std::unique_ptr<ASTNode> clone() const override {*/
/*    return std::make_unique<MutNode>(std::move(this->val_->clone()));*/
/*  }*/
/*  std::shared_ptr<type::TypeObject> getType() const override;*/
/*};*/
/**/






std::string toString(const ASTNode *, size_t indent);

std::ostream &operator<<(std::ostream &, const ASTNode *);

std::shared_ptr<type::TypeObject> getType(const ASTNode *);

} // namespace AST
} // namespace morphl
#endif // !MORPHL_AST_H
