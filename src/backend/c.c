#include <stdio.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "util/util.h"
#include "parser/operators.h"


// Forward declaration
static void emit_node_builtin(AstNode *node, char *out_str, size_t *pos);

static void emit_node(AstNode *node, char *out_str, size_t *pos) {
    switch (node->kind) {
        case AST_LITERAL:
            sprintf(out_str + *pos, "%.*s", (int)node->value.len, node->value.ptr);
            *pos += node->value.len;
            break;
        case AST_IDENT:
            // Assuming node->data.ident holds the identifier name
            sprintf(out_str + *pos, "%.*s", (int)node->value.len, node->value.ptr);
            *pos += node->value.len;
            break;
        case AST_BUILTIN:
            // Handle built-in operations
            emit_node_builtin(node, out_str, pos);
            break;
        case AST_DECL:
            // Handle variable/function declarations
            sprintf(out_str + *pos, "/* Declaration */");
            break;
        default:
            sprintf(out_str + *pos, "/* Unsupported AST Node */");
            break;
    }
}


struct OperatorMapping {
    enum Operator op;                    /**< Operator symbol. */
    const char *c_repr_fmt;     /**< C representation format string. */
};

struct OperatorMapping operator_mappings[] = {
    { SYNTAX, "" },
    { IMPORT, "" },
    { PROP, "" },
    { CALL, "" },
    { FUNC, "" },
    { IF, "" },
    { WHILE, "" },
    { SET, "" },
    { DECL, "" },
    { RET, "return $$" },
    { MEMBER, "($$.$$)" },
    { MUT, "" },
    { CONST, "" },
    { INLINE, "" },
    { THIS, "" },
    { FILE_, "" },
    { GLOBAL, "" },
    { IDTSTR, "" },
    { STRTID, "" },
    { FORWARD, "" },
    { BREAK, "break" },
    { CONTINUE, "continue" },
    { GROUP, "" },
    { BLOCK, "" },
    { ADD, "($$ + $$)" },
    { SUB, "($$ - $$)" },
    { MUL, "($$ * $$)" },
    { DIV, "($$ / $$)" },
    { MOD, "($$ % $$)" },
    { REM, "($$ % $$)" },
    { FADD, "($$ + $$)" },
    { FSUB, "($$ - $$)" },
    { FMUL, "($$ * $$)" },
    { FDIV, "($$ / $$)" },
    { EQ, "($$ == $$)" },
    { NEQ, "($$ != $$)" },
    { LT, "($$ < $$)" },
    { GT, "($$ > $$)" },
    { LTE, "($$ <= $$)" },
    { GTE, "($$ >= $$)" },
    { AND, "($$ && $$)" },
    { OR, "($$ || $$)" },
    { NOT, "(!$$)" },
    { BAND, "($$ & $$)" },
    { BOR, "($$ | $$)" },
    { BXOR, "($$ ^ $$)" },
    { BNOT, "(~$$)" },
    { LSHIFT, "($$ << $$)" },
    { RSHIFT, "($$ >> $$)" },
};





static void emit_node_builtin(AstNode *node, char *out_str, size_t *pos) {
    // Find the operator mapping
    const char *fmt = NULL;
    for (size_t i = 0; i < sizeof(operator_mappings) / sizeof(operator_mappings[0]); i++) {
        if (operator_sym_from_enum(operator_mappings[i].op) == node->op) {
            fmt = operator_mappings[i].c_repr_fmt;
            break;
        }
    }
    if (fmt == NULL) {
        sprintf(out_str + *pos, "/* Unknown builtin operator */");
        return;
    }

    // Prepare to replace $$ with child node emissions
    size_t fmt_len = strlen(fmt);
    size_t child_index = 0;
    for (size_t i = 0; i < fmt_len; ) {
        if (fmt[i] == '$' && i + 1 < fmt_len && fmt[i + 1] == '$') {
            // Emit next child node
            if (child_index < node->child_count) {
                emit_node(node->children[child_index], out_str, pos);
                child_index++;
            } else {
                sprintf(out_str + *pos, "/* Missing child */");
            }
            i += 2; // Skip $$
        } else {
            out_str[(*pos)++] = fmt[i++];
        }
    }
}



// compile to C source code
bool morphl_backend_func_c(MorphlBackendContext* context) {

    // open output file for writing
    FILE* out_file = fopen(context->out_file, "w");
    if (out_file == NULL) {
        return false;
    }

    // emit C code from AST
    char out_str[65536];
    size_t pos = 0;
    emit_node(context->tree, out_str, &pos);
    out_str[pos] = '\0';

    // write to output file
    fwrite(out_str, 1, pos, out_file);
    fclose(out_file);
    return true;
}