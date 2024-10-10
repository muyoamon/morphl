#include "ast.h"
#include <memory>
#include <string>
namespace morphl {
namespace AST {

  std::string string(const ASTNode * node, size_t indent) {
    if (node == nullptr) {
      return "";
    }
    const size_t INDENT_MUL = 2;
    std::string result(indent*INDENT_MUL, ' ');
    switch (node->type_) {
      case PROGRAMNODE: 
        result += "Program:\n";
        for (auto& i:((ProgramNode*)node)->children_) {
          result += string(i.get(), indent+1);
        }
        break;
      case BLOCKNODE:
        result += "Block:\n";
        for (auto& i:((BlockNode*)node)->children_) {
          result += string(i.get(), indent+1);
        }
        break;
      case STATEMENTNODE:
        result += ((StatementNode*)node)->isPrint_ ? "Print " : "";
        result += "Statement:\n";
        result += string(((StatementNode*)node)->child_.get(), indent + 1);
        break;
      case IFNODE:
        result += "If:\n";
        result += string(((IfNode*)node)->ifBlock_.get(), indent + 1);
        break;
      case WHILENODE:
        result += "While:\n";
        result += string(((WhileNode*)node)->whileBlock_.get(), indent + 1);
        break;
      case BINARYOPNODE:
        result += "Binary Operation: ";
        result += Lexer::getTokenTypeName(((BinaryOpNode*) node)->opType_);
        result += "\n";
        result += string(((BinaryOpNode*)node)->operand1_.get(), indent + 1);
        result += string(((BinaryOpNode*)node)->operand2_.get(), indent + 1);
        break;
      case UNARYOPNODE:
        result += "Unary Operation: ";
        result += Lexer::getTokenTypeName(((UnaryOpNode*) node)->opType_);
        result += "\n";
        result += string(((UnaryOpNode*)node)->operand_.get(), indent + 1);
        break;
      case IDENTIFIERNODE:
        result += "Identifier: " + ((IdentifierNode*) node)->name_ + "\n";
        break;
      case INT_LITERALNODE:
        result += "Integer Literal: ";
        result += std::to_string(((IntLiteralNode*) node)->value_);
        result += "\n";
        break;
      case FLOAT_LITERALNODE:
        result += "Float Literal: ";
        result += std::to_string(((FloatLiteralNode*) node)->value_);
        result += "\n";
        break;
      case STRING_LITERALNODE:
        result += "String Literal: ";
        result += ((StringLiteralNode*) node)->value_;
        result += "\n";
        break;
      default:
        result += "TODO\n";
        break;
    }
    return result;
  }
  std::ostream& operator<<(std::ostream& ostr, const ASTNode * node) {
    return ostr << string(node, 0);
  }

}
}
