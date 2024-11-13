#ifndef MORPHL_TYPE_OPERATORTYPE_H
#define MORPHL_TYPE_OPERATORTYPE_H

#include "../lexer/lexer.h"
#include "type.h"
#include <memory>
#include <unordered_map>
namespace morphl {
namespace type {
struct OperatorType {
  const std::shared_ptr<TypeObject> operand1_{};
  const std::shared_ptr<TypeObject> operand2_{};
  const std::shared_ptr<TypeObject> returnType_{};
};

using OperatorTypeMap = std::unordered_map<TokenType, OperatorType>;
const extern OperatorTypeMap operatorTypeMap;

} // namespace type
} // namespace morphl

#endif // MORPHL_TYPE_OPERATORTYPE_H
