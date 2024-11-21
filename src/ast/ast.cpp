#include "ast.h"
#include "../parser/scope.h"
#include "../type/operatorType.h"
#include <algorithm>
#include <iterator>
#include <memory>
#include <string>
#include <vector>
namespace morphl {
namespace AST {

std::shared_ptr<type::TypeObject> ASTNode::getTrueType() const {
  auto type = this->getType();
  while (type->type_ == type::IDENTIFIER) {
    type = static_cast<type::IdentifierType *>(type.get())->pType_;
  }
  return type;
}

std::string toString(const ASTNode *node, size_t indent) {
  if (node == nullptr) {
    return "";
  }
  const size_t INDENT_MUL = 2;
  std::string result(indent * INDENT_MUL, ' ');
  switch (node->type_) {
  case PROGRAMNODE:
    result += "Program:\n";
    for (auto &i : ((ProgramNode *)node)->children_) {
      result += toString(i.get(), indent + 1);
    }
    break;
  case BLOCKNODE:
    result += "Block:\n";
    for (auto &i : ((BlockNode *)node)->children_) {
      result += toString(i.get(), indent + 1);
    }
    break;
  case STATEMENTNODE:
    result += ((StatementNode *)node)->isPrint_ ? "Print " : "";
    result += "Statement:\n";
    result += toString(((StatementNode *)node)->child_.get(), indent + 1);
    break;
  case IFNODE:
    result += "If:\n";
    result += toString(((IfNode *)node)->ifBlock_.get(), indent + 1);
    break;
  case WHILENODE:
    result += "While:\n";
    result += toString(((WhileNode *)node)->whileBlock_.get(), indent + 1);
    break;
  case BINARYOPNODE:
    result += "Binary Operation: ";
    result += Lexer::getTokenTypeName(((BinaryOpNode *)node)->opType_);
    result += "\n";
    result += toString(((BinaryOpNode *)node)->operand1_.get(), indent + 1);
    result += toString(((BinaryOpNode *)node)->operand2_.get(), indent + 1);
    break;
  case UNARYOPNODE:
    result += "Unary Operation: ";
    result += Lexer::getTokenTypeName(((UnaryOpNode *)node)->opType_);
    result += "\n";
    result += toString(((UnaryOpNode *)node)->operand_.get(), indent + 1);
    break;
  case IDENTIFIERNODE:
    result += "Identifier: " + ((IdentifierNode *)node)->name_;
    result +=
        " (Type: " +
        static_cast<std::string>(*((IdentifierNode *)node)->identifierType_) +
        ")\n";
    break;
  case INT_LITERALNODE:
    result += "Integer Literal: ";
    result += std::to_string(((IntLiteralNode *)node)->value_);
    result += "\n";
    break;
  case FLOAT_LITERALNODE:
    result += "Float Literal: ";
    result += std::to_string(((FloatLiteralNode *)node)->value_);
    result += "\n";
    break;
  case STRING_LITERALNODE:
    result += "String Literal: ";
    result += ((StringLiteralNode *)node)->value_;
    result += "\n";
    break;
  case GROUPNODE:
    result += "Group:\n";
    for (auto &i : ((GroupNode *)node)->members_) {
      result += toString(i.get(), indent + 1);
    }
    break;
  case FUNCNODE:
    result += "Function:\n";
    result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') + "Operands:\n" +
              toString(((FunctionNode *)node)->argType_.get(), indent + 2);
    result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') + "Return (Type:";
    result +=
        static_cast<std::string>(*((FunctionNode *)node)->value_->getType());
    result += "):\n";
    result += toString(((FunctionNode *)node)->value_.get(), indent + 2);
    break;
  case MACRONODE:
    result += "Macro\n";
    break;
  case ARRAYINDEXNODE:
    result += "Index:\n";
    // result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') + "Parent:\n";
    result += toString(((ArrayIndexNode *)node)->parent_.get(), indent + 1);
    result += std::string(indent + 1 + 1 * INDENT_MUL, ' ') + "Size:\n";
    result +=
        toString(((ArrayIndexNode *)node)->index_.get(), indent + 2) + "\n";
    break;

  case GROUPINDEXNODE:
    result += "Index:\n";
    // result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') + "Parent:\n";
    result += toString(((GroupIndexNode *)node)->parent_.get(), indent + 1);
    result += std::string(indent + 1 + 1 * INDENT_MUL, ' ') +
              "Size: " + std::to_string(((GroupIndexNode *)node)->index_) +
              "\n";
    break;

  case MEMBERNODE:
    result += "Member Access:\n";
    // result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') + "Parent:\n";
    result += toString(((MemberAccessNode *)node)->parent_.get(), indent + 1);
    result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') +
              "Name: " + ((MemberAccessNode *)node)->memberName_ + "\n";
    break;
  case DECLNODE:
    result += "Declaration:\n";
    result += std::string(indent + 1 + 1 * INDENT_MUL, ' ') +
              "Name: " + ((DeclarationNode *)node)->name_ + "\n";
    result +=
        std::string(indent + 1 + 1 * INDENT_MUL, ' ') + "Initial Value:\n";
    result +=
        toString(((DeclarationNode *)node)->initialValue_.get(), indent + 2);
    break;
  case ARRAYNODE:
    result += "Array:\n";
    result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') +
              "Type: " + static_cast<std::string>(*((ArrayNode *)node)->type_) +
              "\n";
    result += std::string(indent + 1 + 2 * INDENT_MUL, ' ') +
              "Size: " + std::to_string(((ArrayNode *)node)->size_) + "\n";
    break;
  default:
    result += "TODO\n";
    break;
  }
  return result;
}
std::ostream &operator<<(std::ostream &ostr, const ASTNode *node) {
  return ostr << toString(node, 0);
}

std::shared_ptr<type::TypeObject> getType(const ASTNode *node) {
  if (!node) {
    return nullptr;
  }
  return node->getType();
}

std::shared_ptr<type::TypeObject> BlockNode::getType() const {
  std::shared_ptr<type::BlockType> blockType =
      std::make_shared<type::BlockType>();
  for (auto &child : children_) {
    auto i = child.get();
    if (child->type_ == AST::STATEMENTNODE) {
      i = static_cast<AST::StatementNode *>(child.get())->child_.get();
    }
    if (i->type_ == AST::DECLNODE) {
      auto node = (AST::DeclarationNode *)i;
      auto varName = node->name_;
      blockType->addMember(varName, node->initialValue_->getType());
    } else if (i->type_ == UNARYOPNODE) {
      auto unaryOpNode = static_cast<UnaryOpNode *>(i);
      if (unaryOpNode->opType_ == RETURN) {
        return unaryOpNode->operand_->getType();
      }
    }
  }
  return blockType;
}

std::shared_ptr<type::TypeObject> ArrayNode::getType() const {
  return std::make_shared<type::ListType>(this->type_, this->size_);
}

std::shared_ptr<type::TypeObject> IdentifierNode::getType() const {
  return identifierType_;
}

std::shared_ptr<type::TypeObject> DeclarationNode::getType() const {
  return initialValue_->getType();
}

std::shared_ptr<type::TypeObject> GroupIndexNode::getType() const {
  return static_cast<type::GroupType *>(parent_->getTrueType().get())
      ->members_[this->index_];
}

std::shared_ptr<type::TypeObject> ArrayIndexNode::getType() const {
  return static_cast<type::ListType *>(parent_->getTrueType().get())
      ->pElementsType_;
}

std::shared_ptr<type::TypeObject> MemberAccessNode::getType() const {
  return static_cast<type::BlockType *>(this->parent_->getTrueType().get())
      ->getType(this->memberName_);
}

std::shared_ptr<type::TypeObject> IntLiteralNode::getType() const {
  return std::make_shared<type::PrimitiveType>("int");
}

std::shared_ptr<type::TypeObject> FloatLiteralNode::getType() const {
  return std::make_shared<type::PrimitiveType>("float");
}

std::shared_ptr<type::TypeObject> StringLiteralNode::getType() const {
  return std::make_shared<type::PrimitiveType>("string");
}

std::shared_ptr<type::TypeObject> GroupNode::getType() const {
  type::GroupTypeMembers typeArr;
  for (auto &member : members_) {
    typeArr.push_back(member->getType());
  }
  return std::make_shared<type::GroupType>(typeArr);
}

std::shared_ptr<type::TypeObject> BinaryOpNode::getType() const {
  if (this->opType_ == EXTEND) {
    auto newType = std::make_shared<type::BlockType>();
    auto type1 = operand1_->getType();
    while (type1->type_ == type::IDENTIFIER) {
      type1 = static_cast<type::IdentifierType *>(type1.get())->pType_;
    }
    if (type1->type_ == type::BLOCK) {
      auto type1Block = static_cast<type::BlockType *>(type1.get());
      for (auto i : type1Block->members_) {
        newType->addMember(i.first, i.second);
      }
    }
    auto type2 = operand2_->getType();
    while (type2->type_ == type::IDENTIFIER) {
      type2 = static_cast<type::IdentifierType *>(type2.get())->pType_;
    }
    if (type2->type_ == type::BLOCK) {
      auto type2Block = static_cast<type::BlockType *>(type2.get());
      for (auto i : type2Block->members_) {
        newType->addMember(i.first, i.second);
      }
    }
    return newType;
  }
  if (this->opType_ == CALL) {
    auto func =
        static_cast<type::FunctionType *>(this->operand1_->getType().get());
    return func->pReturnType_;
  }

  type::OperatorType opType = type::operatorTypeMap.at(this->opType_);
  if (opType.returnType_ == nullptr) {
    return this->operand1_->getType();
  }
  return opType.returnType_;
}

std::shared_ptr<type::TypeObject> UnaryOpNode::getType() const {
  type::OperatorType opType = type::operatorTypeMap.at(this->opType_);
  if (opType.returnType_ == nullptr) {
    return this->operand_->getType();
  }
  return opType.returnType_;
}

std::shared_ptr<type::TypeObject> IfNode::getType() const {
  if (ifBlock_->type_ == GROUPNODE) {
    auto ifGroupPtr = static_cast<GroupNode *>(ifBlock_.get());
    if (ifGroupPtr->members_.size() > 1) {
      return ifGroupPtr->members_[1]->getType();
    }
  }
  return std::make_shared<type::TypeObject>(type::NONE);
}

std::shared_ptr<type::TypeObject> FunctionNode::getType() const {
  return std::make_shared<type::FunctionType>(this->argType_->getType(),
                                              this->value_->getType());
}

} // namespace AST
} // namespace morphl
