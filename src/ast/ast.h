#ifndef MORPHL_AST_H
#define MORPHL_AST_H

#include "../lexer/lexer.h"
#include "../parser/type.h"
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
  STATEMENTNODE,
  IFNODE,
  WHILENODE,
  BINARYOPNODE,
  UNARYOPNODE,
  EXPRGROUPNODE,

  IDENTIFIERNODE,

  //
  //  Literals
  //

  INT_LITERALNODE,
  FLOAT_LITERALNODE,
  STRING_LITERALNODE,

  //
  //  data types
  //

  GROUPNODE,
  ARRAYNODE,

  MORPHNODE,
  ALIASNODE,
};

struct ASTNode {
  ASTNodeType type_;

  ASTNode(ASTNodeType type) : type_(type) {}
  // virtual void print(std::ostream& ostr = std::cout) = delete;
};

struct ProgramNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> children_;

  ProgramNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(PROGRAMNODE), children_(std::move(v)) {}
};

struct BlockNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> children_;

  BlockNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(BLOCKNODE), children_(std::move(v)) {}
};

struct StatementNode : public ASTNode {
  std::unique_ptr<ASTNode> child_;
  bool isPrint_;

  StatementNode(std::unique_ptr<ASTNode> &&child, bool isPrint)
      : ASTNode(STATEMENTNODE), child_(std::move(child)), isPrint_{isPrint} {}
};

struct IfNode : public ASTNode {
  std::unique_ptr<ASTNode> ifBlock_;

  IfNode(std::unique_ptr<ASTNode> &&ifBlock)
      : ASTNode(IFNODE), ifBlock_(std::move(ifBlock)) {}
};

struct WhileNode : public ASTNode {
  std::unique_ptr<ASTNode> whileBlock_;

  WhileNode(std::unique_ptr<ASTNode> &&whileBlock)
      : ASTNode(IFNODE), whileBlock_(std::move(whileBlock)) {}
};

struct BinaryOpNode : public ASTNode {
  TokenType opType_;
  std::unique_ptr<ASTNode> operand1_;
  std::unique_ptr<ASTNode> operand2_;

  BinaryOpNode(TokenType type, std::unique_ptr<ASTNode> &&op1,
               std::unique_ptr<ASTNode> &&op2)
      : ASTNode(BINARYOPNODE), operand1_(std::move(op1)),
        operand2_(std::move(op2)), opType_{type} {}
};

struct UnaryOpNode : public ASTNode {
  TokenType opType_;
  std::unique_ptr<ASTNode> operand_;

  UnaryOpNode(TokenType type, std::unique_ptr<ASTNode> &&op)
      : ASTNode(UNARYOPNODE), operand_(std::move(op)), opType_{type} {}
};


struct IdentifierNode : public ASTNode {
  std::string name_;

  IdentifierNode(std::string name) : ASTNode(IDENTIFIERNODE), name_{name} {}
};

struct IntLiteralNode : public ASTNode {
  int value_;

  IntLiteralNode(int value) : ASTNode(INT_LITERALNODE), value_{value} {}
};

struct FloatLiteralNode : public ASTNode {
  float value_;

  FloatLiteralNode(float value) : ASTNode(FLOAT_LITERALNODE), value_{value} {}
};

struct StringLiteralNode : public ASTNode {
  std::string value_;

  StringLiteralNode(std::string value)
      : ASTNode(STRING_LITERALNODE), value_{value} {}
};

struct GroupNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> members_;

  GroupNode(std::vector<std::unique_ptr<ASTNode>> &&v)
      : ASTNode(GROUPNODE), members_(std::move(v)) {}
};

struct ArrayNode : public ASTNode {
  std::vector<std::unique_ptr<ASTNode>> members_;

  ArrayNode(std::vector<std::unique_ptr<ASTNode>> &&v)
    : ASTNode(ARRAYNODE), members_(std::move(v)) {}
};

std::string toString(const ASTNode *, size_t indent);

std::ostream &operator<<(std::ostream &, const ASTNode *);

std::shared_ptr<type::TypeObject> getType(const ASTNode *);

} // namespace AST
} // namespace morphl
#endif // !MORPHL_AST_H
