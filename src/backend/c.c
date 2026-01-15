#include <stdio.h>
#include <string.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "parser/operators.h"

typedef struct EmitBuffer {
    char *data;
    size_t capacity;
    size_t pos;
} EmitBuffer;

static void emit_append(EmitBuffer *out, const char *text) {
    if (!text || out->pos >= out->capacity) {
        return;
    }
    size_t len = strlen(text);
    if (len == 0) {
        return;
    }
    size_t remaining = out->capacity - out->pos - 1;
    if (len > remaining) {
        len = remaining;
    }
    memcpy(out->data + out->pos, text, len);
    out->pos += len;
}

static void emit_append_n(EmitBuffer *out, const char *text, size_t len) {
    if (!text || out->pos >= out->capacity) {
        return;
    }
    if (len == 0) {
        return;
    }
    size_t remaining = out->capacity - out->pos - 1;
    if (len > remaining) {
        len = remaining;
    }
    memcpy(out->data + out->pos, text, len);
    out->pos += len;
}

static void emit_indent(EmitBuffer *out, size_t indent) {
    for (size_t i = 0; i < indent; ++i) {
        emit_append(out, "  ");
    }
}

static void emit_node_expr(AstNode *node, EmitBuffer *out);
static void emit_node_stmt(AstNode *node, EmitBuffer *out, size_t indent);
static void emit_node_builtin(AstNode *node, EmitBuffer *out);
static void emit_group_expr(AstNode *node, EmitBuffer *out);

static const char *infer_decl_type(AstNode *value) {
    if (!value) {
        return "double";
    }
    if (value->kind == AST_LITERAL) {
        if (value->value.len > 0 && value->value.ptr[0] == '"') {
            return "const char *";
        }
        for (size_t i = 0; i < value->value.len; ++i) {
            char c = value->value.ptr[i];
            if (c == '.' || c == 'e' || c == 'E') {
                return "double";
            }
        }
        return "long long";
    }
    return "double";
}

static void emit_node_expr(AstNode *node, EmitBuffer *out) {
    if (!node) {
        emit_append(out, "0");
        return;
    }
    switch (node->kind) {
        case AST_LITERAL:
        case AST_IDENT:
            emit_append_n(out, node->value.ptr, node->value.len);
            break;
        case AST_BUILTIN:
            emit_node_builtin(node, out);
            break;
        case AST_CALL: {
            if (node->child_count >= 1) {
                emit_node_expr(node->children[0], out);
            } else {
                emit_append(out, "/* missing call target */");
            }
            emit_append(out, "(");
            if (node->child_count >= 2) {
                AstNode *param = node->children[1];
                if (param && param->kind == AST_GROUP) {
                    emit_group_expr(param, out);
                } else {
                    emit_node_expr(param, out);
                }
            }
            emit_append(out, ")");
            break;
        }
        case AST_GROUP:
            emit_append(out, "(");
            emit_group_expr(node, out);
            emit_append(out, ")");
            break;
        case AST_SET:
            if (node->child_count >= 2) {
                emit_append(out, "(");
                emit_node_expr(node->children[0], out);
                emit_append(out, " = ");
                emit_node_expr(node->children[1], out);
                emit_append(out, ")");
            } else {
                emit_append(out, "0");
            }
            break;
        case AST_DECL:
            if (node->child_count >= 2) {
                emit_node_expr(node->children[1], out);
            } else {
                emit_append(out, "0");
            }
            break;
        case AST_FUNC:
            emit_append(out, "/* func */0");
            break;
        case AST_IF:
            emit_append(out, "/* if */0");
            break;
        case AST_BLOCK:
            emit_append(out, "/* block */0");
            break;
        default:
            emit_append(out, "0");
            break;
    }
}

static void emit_group_expr(AstNode *node, EmitBuffer *out) {
    if (!node) {
        return;
    }
    for (size_t i = 0; i < node->child_count; ++i) {
        if (i > 0) {
            emit_append(out, ", ");
        }
        emit_node_expr(node->children[i], out);
    }
}

static void emit_node_stmt(AstNode *node, EmitBuffer *out, size_t indent) {
    if (!node) {
        return;
    }
    switch (node->kind) {
        case AST_BLOCK:
            for (size_t i = 0; i < node->child_count; ++i) {
                emit_node_stmt(node->children[i], out, indent);
            }
            break;
        case AST_DECL: {
            emit_indent(out, indent);
            if (node->child_count >= 2) {
                AstNode *name = node->children[0];
                AstNode *value = node->children[1];
                const char *type_name = infer_decl_type(value);
                emit_append(out, type_name);
                emit_append(out, " ");
                emit_node_expr(name, out);
                emit_append(out, " = ");
                emit_node_expr(value, out);
            } else {
                emit_append(out, "/* malformed decl */");
            }
            emit_append(out, ";\n");
            break;
        }
        case AST_SET:
            emit_indent(out, indent);
            if (node->child_count >= 2) {
                emit_node_expr(node->children[0], out);
                emit_append(out, " = ");
                emit_node_expr(node->children[1], out);
            } else {
                emit_append(out, "/* malformed set */");
            }
            emit_append(out, ";\n");
            break;
        default:
            emit_indent(out, indent);
            emit_node_expr(node, out);
            emit_append(out, ";\n");
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





static void emit_node_builtin(AstNode *node, EmitBuffer *out) {
    const char *fmt = NULL;
    for (size_t i = 0; i < sizeof(operator_mappings) / sizeof(operator_mappings[0]); i++) {
        if (operator_sym_from_enum(operator_mappings[i].op) == node->op) {
            fmt = operator_mappings[i].c_repr_fmt;
            break;
        }
    }
    if (fmt == NULL) {
        emit_append(out, "/* Unknown builtin operator */");
        return;
    }

    size_t fmt_len = strlen(fmt);
    size_t child_index = 0;
    for (size_t i = 0; i < fmt_len; ) {
        if (fmt[i] == '$' && i + 1 < fmt_len && fmt[i + 1] == '$') {
            if (child_index < node->child_count) {
                emit_node_expr(node->children[child_index], out);
                child_index++;
            } else {
                emit_append(out, "/* Missing child */");
            }
            i += 2;
        } else {
            emit_append_n(out, &fmt[i], 1);
            i++;
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
    EmitBuffer out = {
        .data = out_str,
        .capacity = sizeof(out_str),
        .pos = 0,
    };
    emit_append(&out, "#include <stdio.h>\n\nint main(void) {\n");
    if (context->tree && context->tree->kind == AST_BLOCK) {
        emit_node_stmt(context->tree, &out, 1);
    } else if (context->tree) {
        emit_node_stmt(context->tree, &out, 1);
    }
    emit_append(&out, "  return 0;\n}\n");
    out.data[out.pos] = '\0';

    // write to output file
    fwrite(out.data, 1, out.pos, out_file);
    fclose(out_file);
    return true;
}
