#include "operatorType.h"
#include "type.h"
#include <memory>
namespace morphl {
namespace type {
const OperatorTypeMap operatorTypeMap{
    {NEG, {PrimitiveType::INTEGER, nullptr, PrimitiveType::INTEGER}},
    {FNEG, {PrimitiveType::FLOAT, nullptr, PrimitiveType::FLOAT}},
    {BNOT, {nullptr, nullptr, nullptr}},
    {NOT, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {EQ, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {NE, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {LT, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {LE, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {GT, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {GE, {nullptr, nullptr, PrimitiveType::INTEGER}},
    {ADD, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, PrimitiveType::INTEGER}},
    {SUB, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, PrimitiveType::INTEGER}},
    {MUL, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, PrimitiveType::INTEGER}},
    {DIV, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, PrimitiveType::INTEGER}},
    {MOD, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, PrimitiveType::INTEGER}},
    {FADD, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, PrimitiveType::FLOAT}},
    {FSUB, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, PrimitiveType::FLOAT}},
    {FMUL, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, PrimitiveType::FLOAT}},
    {FDIV, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, PrimitiveType::FLOAT}},
    {CONCAT, {PrimitiveType::STRING, PrimitiveType::STRING, PrimitiveType::STRING}},
    {BAND, {nullptr, nullptr, nullptr}},
    {BOR, {nullptr, nullptr, nullptr}},
    {LSHIFTR, {nullptr, nullptr, nullptr}},
    {SHIFTR, {nullptr, nullptr, nullptr}},
    {SHIFTL, {nullptr, nullptr, nullptr}},
    {DECL, {nullptr, nullptr, nullptr}},
    {EXTEND, {nullptr, nullptr, nullptr}},
    {ASSIGN, {nullptr, nullptr, nullptr}},
    {RETURN, {nullptr, nullptr, nullptr}},
    {morphl::CONST, {nullptr, nullptr, nullptr}},
    {morphl::REF, {nullptr, nullptr, nullptr}}
};
}
} // namespace morphl
