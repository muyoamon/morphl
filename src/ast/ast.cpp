#include "ast.h"
#include "../parser/scope.h"
#include <memory>
#include <string>
namespace morphl {
namespace AST {

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
    result += "Identifier: " + ((IdentifierNode *)node)->name_ + "\n";
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
    result += "GROUP:\n";
    for (auto &i : ((GroupNode *)node)->members_) {
      result += toString(i.get(), indent + 1);
    }
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
  switch (node->type_) {
  case AST::INT_LITERALNODE: {
    return std::make_shared<type::PrimitiveType>("int");
  }
  case AST::FLOAT_LITERALNODE: {
    return std::make_shared<type::PrimitiveType>("float");
  }

  case AST::STRING_LITERALNODE: {
    return std::make_shared<type::PrimitiveType>("string");
  }
  case AST::IDENTIFIERNODE: {
    return std::make_shared<type::TypeObject>(type::IDENTIFIER);
  }
  case AST::BLOCKNODE: {
    AST::BlockNode *pBlockNode = (AST::BlockNode *)node;
    type::BlockTypeMembers typeMap;
    for (auto &child : pBlockNode->children_) {
      if (child->type_ == AST::STATEMENTNODE) {
        auto i = static_cast<AST::StatementNode *>(child.get())->child_.get();
        if (i->type_ == AST::BINARYOPNODE) {
          auto binaryOpNode = (AST::BinaryOpNode *)i;
          if (binaryOpNode->opType_ == DECL) {
            auto varName = static_cast<AST::IdentifierNode *>(
                               binaryOpNode->operand1_.get())
                               ->name_;
            typeMap[varName] = getType(binaryOpNode->operand2_.get());
          }
        }
      }
    }
    return std::make_shared<type::BlockType>(typeMap);
  }
  case AST::GROUPNODE: {
    AST::GroupNode *pGroupNode =  (AST::GroupNode *) node;
    type::GroupTypeMembers typeArr;
    for (auto &member : pGroupNode->members_) {
      typeArr.push_back(getType(member.get()));
    }
    return std::make_shared<type::GroupType>(typeArr);
  }
  default:
    return std::make_shared<type::TypeObject>(type::NONE);
  }
}

} // namespace AST
} // namespace morphl
