#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "parser/operators.h"
#include "typing/typing.h"
#include "util/util.h"
#include "typing/type_context.h"

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

typedef void (*emit_func_t)(AstNode *node, EmitBuffer *out);
static size_t indent_level = 0;

static void emit_line(emit_func_t fn, EmitBuffer *out, AstNode *node, const char* extra) {
    emit_indent(out, indent_level);
    fn(node, out);
    if (extra) {
        emit_append(out, extra);
    }
    emit_append(out, "\n");
}

static void emit_node_expr(AstNode *node, EmitBuffer *out);
// static void emit_node_stmt(AstNode *node, EmitBuffer *out, size_t indent);
static void emit_node_builtin(AstNode *node, EmitBuffer *out);
static void emit_group_expr(AstNode *node, EmitBuffer *out);

// forward declaration
static const char *find_decl_type(AstNode *value);

static const char *infer_decl_type(AstNode *value) {
    if (!value) {
        return "void";
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
    // Try to find type from the value node
    const char *type_name = find_decl_type(value);
    if (type_name) {
        return type_name;
    }
    return "void";
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
        case AST_DECL: {
            if (node->child_count >= 2) {
                AstNode *name = node->children[0];
                AstNode *value = node->children[1];
                const char *type_name = infer_decl_type(value);
                if (strcmp(type_name, "void") == 0) {
                    // try to resolve to infered type by name
                    type_name = find_decl_type(name);
                }
                emit_append(out, type_name);
                emit_append(out, " ");
                emit_node_expr(name, out);
                // for now just omit the initialization
                // emit_append(out, " = ");
                // emit_node_expr(value, out);
            } else {
                emit_append(out, "/* malformed decl */");
            }
            break;
            }
        case AST_FUNC:
            emit_append(out, "/* func */0");
            break;
        case AST_IF:
            emit_append(out, "/* if */0");
            break;
        case AST_FILE:  // Treat as block
        case AST_BLOCK:
            // For now, naively emit each child separated by semicolons
            // In future, seperate into struct and scope logic
            emit_append(out, "{\n");
            indent_level++;
            for (size_t i = 0; i < node->child_count; ++i) {
                // Indent child statements
                emit_line(emit_node_expr, out, node->children[i], ";");
            }
            indent_level--;
            emit_indent(out, indent_level);
            emit_append(out, "}");
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

struct TypeEntry {
    Sym name;
    MorphlType type;
};

typedef struct TypeArray {
    Arena arena;
    size_t count;
} TypeArray;

static void type_array_init(TypeArray *arr, size_t initial_capacity) {
    arena_init(&arr->arena, initial_capacity * sizeof(struct TypeEntry));
    arr->count = 0;
}

static void type_array_free(TypeArray *arr) {
    arena_free(&arr->arena);
}

static struct TypeEntry* type_array_get(TypeArray *arr, size_t index) {
    return (struct TypeEntry*)(arr->arena.base + index * sizeof(struct TypeEntry));
}

static void compound_type_check(TypeContext *ctx, TypeArray *type_arr, MorphlType *type) {
    if (morphl_type_is_primitive(type)) {
        return;
    }
    switch (type->kind) {
        case MORPHL_TYPE_BLOCK: {
            MorphlBlockType *block = &type->data.block;
            for (size_t i = 0; i < block->field_count; ++i) {
                MorphlType *field_type = block->field_types[i];
                if (morphl_type_is_primitive(field_type) == false) {
                    Str type_as_str = morphl_type_to_string(field_type, ctx->interns);
                    printf("Detected non-primitive type in block; type: %.*s\n", 
                        (int)type_as_str.len, type_as_str.ptr);
                    free((void*)type_as_str.ptr);
                    
                    // Store type info in type array for later emission
                    struct TypeEntry entry = {
                        .name = block->field_names[i],
                        .type = *field_type,
                    };
                    // If the elem type is block or group, we may need to further decompose
                    compound_type_check(ctx, type_arr, field_type);

                    arena_push(&type_arr->arena, &entry, sizeof(struct TypeEntry));
                    type_arr->count++;
                }
            }
            break;
        }
        case MORPHL_TYPE_GROUP: {
            MorphlGroupType *group = &type->data.group;
            for (size_t i = 0; i < group->elem_count; ++i) {
                MorphlType *elem_type = group->elem_types[i];
                if (morphl_type_is_primitive(elem_type) == false) {
                    Str type_as_str = morphl_type_to_string(elem_type, ctx->interns);
                    printf("Detected non-primitive type in group; type: %.*s\n", 
                        (int)type_as_str.len, type_as_str.ptr);
                    free((void*)type_as_str.ptr);
                    
                    // Store type info in type array for later emission
                    struct TypeEntry entry = {
                        .name = 0, // unnamed
                        .type = *elem_type,
                    };
                    // If the elem type is block or group, we may need to further decompose
                    compound_type_check(ctx, type_arr, elem_type);

                    arena_push(&type_arr->arena, &entry, sizeof(struct TypeEntry));
                    type_arr->count++;
                }
            }
            break;
        }
        case MORPHL_TYPE_FUNC:
            // Check parameter types and return type
            // parameters is always on index 0
            MorphlType *param_type = type->data.func.param_types[0];
            if (morphl_type_is_primitive(param_type) == false) {
                Str type_as_str = morphl_type_to_string(param_type, ctx->interns);
                printf("Detected non-primitive type in func param; type: %.*s\n", 
                    (int)type_as_str.len, type_as_str.ptr);
                free((void*)type_as_str.ptr);
                
                // Store type info in type array for later emission
                struct TypeEntry entry = {
                    .name = 0, // unnamed
                    .type = *param_type,
                };
                // If the param type is block or group, we may need to further decompose
                compound_type_check(ctx, type_arr, param_type);

                arena_push(&type_arr->arena, &entry, sizeof(struct TypeEntry));
                type_arr->count++;
            }
            // do the same for return type
            MorphlType *ret_type = type->data.func.return_type;
            if (morphl_type_is_primitive(ret_type) == false) {
                Str type_as_str = morphl_type_to_string(ret_type, ctx->interns);
                printf("Detected non-primitive type in func return; type: %.*s\n", 
                    (int)type_as_str.len, type_as_str.ptr);
                free((void*)type_as_str.ptr);
                
                // Store type info in type array for later emission
                struct TypeEntry entry = {
                    .name = 0, // unnamed
                    .type = *ret_type,
                };
                // If the return type is block or group, we may need to further decompose
                compound_type_check(ctx, type_arr, ret_type);

                arena_push(&type_arr->arena, &entry, sizeof(struct TypeEntry));
                type_arr->count++;
            }
            break;
        default:
            break;
    }

}

static void ctx_type_check(TypeContext *ctx, TypeArray *type_arr) {
    (void)ctx;
    (void)type_arr;
    // Look into file scope and global scope for non-primitive types
    if (ctx->file_type) {
        // Since file_type contains all global declarations, we need to check each child
        for (size_t i = 0; i < ctx->file_type->data.block.field_count; ++i) {
            MorphlType *field_type = ctx->file_type->data.block.field_types[i];
            if (morphl_type_is_primitive(field_type) == false) {
                Str type_as_str = morphl_type_to_string(field_type, ctx->interns);
                printf("Detected non-primitive type in file scope; type: %.*s\n", 
                    (int)type_as_str.len, type_as_str.ptr);
                free((void*)type_as_str.ptr);
                
                // Store type info in type array for later emission
                struct TypeEntry entry = {
                    .name = ctx->file_type->data.block.field_names[i],
                    .type = *field_type,
                };
                // If the field type is block or group, we may need to further decompose
                compound_type_check(ctx, type_arr, field_type);

                arena_push(&type_arr->arena, &entry, sizeof(struct TypeEntry));
                type_arr->count++;
            }
        }
    }
}

static Str get_ctype_name(MorphlType *type, InternTable *interns, TypeArray *type_arr) {
    if (morphl_type_is_primitive(type)) {
        switch (type->kind) {
            case MORPHL_TYPE_INT:
                return str_from("long long", strlen("long long"));
            case MORPHL_TYPE_FLOAT:
                return str_from("double", strlen("double"));
            case MORPHL_TYPE_BOOL:
                return str_from("bool", strlen("bool"));
            case MORPHL_TYPE_STRING:
                return str_from("const char *", strlen("const char *"));
            case MORPHL_TYPE_VOID:
                return str_from("void", strlen("void"));
            default:
                return str_from("void", strlen("void"));
        }
    } else {
        // traverse type_arr to find the type name
        static char buffer[64];
        for (size_t i = 0; i < type_arr->count; ++i) {
            struct TypeEntry *entry = type_array_get(type_arr, i);
            if (morphl_type_equals(&entry->type, type)) {
                if (entry->name != 0) {
                    // put name in buffer
                    Str type_str = interns_lookup(interns, entry->name);
                    snprintf(buffer, sizeof(buffer), "%.*s", (int)type_str.len, type_str.ptr);
                    
                } else {
                    // unnamed type, put anon<i> in buffer
                    snprintf(buffer, sizeof(buffer), "anon%zu", i);
                    
                }
                // append type kind suffix
                switch (type->kind) {
                    case MORPHL_TYPE_BLOCK:
                        strcat(buffer, "_block_t");
                        break;
                    case MORPHL_TYPE_GROUP:
                        strcat(buffer, "_group_t");
                        break;
                    case MORPHL_TYPE_FUNC:
                        strcat(buffer, "_func_t");
                        break;
                    default:
                        break;
                }
                return str_from(buffer, strlen(buffer));
            }
        }
        // not found, return "void" as fallback
        return str_from("void", strlen("void"));
    }
}

static void emit_type_signature(EmitBuffer *out, TypeArray *type_arr, TypeContext *ctx) {
    for (size_t i = 0; i < type_arr->count; ++i) {
        struct TypeEntry *entry = type_array_get(type_arr, i);
        if (morphl_type_is_primitive(&entry->type)) {
            continue; // skip primitive types
        }
        if (entry->type.kind == MORPHL_TYPE_BLOCK) {
            emit_append(out, "typedef struct {\n");
            indent_level++;
            MorphlBlockType *block = &entry->type.data.block;
            for (size_t j = 0; j < block->field_count; ++j) {
                MorphlType *field_type = block->field_types[j];
                emit_indent(out, indent_level);

                Str type_str = get_ctype_name(field_type, ctx->interns, type_arr);
                emit_append_n(out, type_str.ptr, type_str.len);

                emit_append(out, " ");
                Sym field_sym = block->field_names[j];
                // For simplicity, just print the symbol as is
                emit_append_n(out, interns_lookup(ctx->interns, field_sym).ptr,
                               interns_lookup(ctx->interns, field_sym).len);
                emit_append(out, ";\n");
            }
            indent_level--;
            emit_append(out, "} ");
            
            char type_name[64];
            if (entry->name == 0) {
                // Unnamed, print type name as anon<i>_block_t
                snprintf(type_name, sizeof(type_name), "anon%zu_block_t", i);
            } else {
                // print type name as <name>_block_t
                Str type_str = interns_lookup(ctx->interns, entry->name);
                snprintf(type_name, sizeof(type_name), "%.*s_block_t", 
                        (int)type_str.len,
                        type_str.ptr);
            }
            emit_append(out, type_name);
            emit_append(out, ";\n\n");
        } else if (entry->type.kind == MORPHL_TYPE_GROUP) {
            emit_append(out, "typedef struct {\n");
            indent_level++;
            MorphlGroupType *group = &entry->type.data.group;
            for (size_t j = 0; j < group->elem_count; ++j) {
                MorphlType *elem_type = group->elem_types[j];
                emit_indent(out, indent_level);

                Str type_str = get_ctype_name(elem_type, ctx->interns, type_arr);
                emit_append_n(out, type_str.ptr, type_str.len);

                emit_append(out, " ");
                // Name elements as _0, _1, etc.
                char elem_name[16];
                snprintf(elem_name, sizeof(elem_name), "_%zu", j);
                emit_append(out, " ");
                emit_append(out, elem_name);
                emit_append(out, ";\n");
            }
            indent_level--;
            emit_append(out, "} ");
            // print type name as <name>_group_t
            char type_name[32];
            if (entry->name == 0) {
                // Unnamed, print type name as anon<i>_group_t
                snprintf(type_name, sizeof(type_name), "anon%zu_group_t", i);
            } else {
                // print type name as <name>_group_t
                snprintf(type_name, sizeof(type_name), "%.*s_group_t", 
                        (int)interns_lookup(ctx->interns, entry->name).len,
                        interns_lookup(ctx->interns, entry->name).ptr);
            }
            emit_append(out, type_name);
            emit_append(out, ";\n\n");
        } else if (entry->type.kind == MORPHL_TYPE_FUNC) {
            // Function type
            emit_append(out, "typedef ");
            MorphlType *ret_type = entry->type.data.func.return_type;

            Str type_str = get_ctype_name(ret_type, ctx->interns, type_arr);
            emit_append_n(out, type_str.ptr, type_str.len);
                
            emit_append(out, " (*");
            
            char func_name[32];
            if (entry->name == 0) {
                snprintf(func_name, sizeof(func_name), "anon%zu_func_t", i);
            } else {
                // function name as <name>_func_t
                snprintf(func_name, sizeof(func_name), "%.*s_func_t", 
                        (int)interns_lookup(ctx->interns, entry->name).len,
                        interns_lookup(ctx->interns, entry->name).ptr);
            }
            emit_append(out, func_name);
            emit_append(out, ")(");
            // parameters
            for (size_t j = 0; j < entry->type.data.func.param_count; ++j) {
                if (j > 0) {
                    emit_append(out, ", ");
                }
                MorphlType *param_type = entry->type.data.func.param_types[j];

                Str type_str = get_ctype_name(param_type, ctx->interns, type_arr);
                emit_append_n(out, type_str.ptr, type_str.len);
                    
            }
            emit_append(out, ");\n\n");
        }
    }
}

static TypeArray type_arr;
static InternTable* interns;

static const char *find_decl_type(AstNode *value) {
    if (!value) {
        return NULL;
    }
    if (value->kind == AST_LITERAL) return infer_decl_type(value);
    // try to find from type_arr
    MorphlType *type = NULL;
    // For simplicity, only handle IDENT nodes here
    if (value->kind == AST_IDENT) {
        Str ident_str = value->value;
        for (size_t i = 0; i < type_arr.count; ++i) {
            struct TypeEntry *entry = type_array_get(&type_arr, i);
            Str type_name = interns_lookup(interns, entry->name);
            if (type_name.len == ident_str.len &&
                strncmp(type_name.ptr, ident_str.ptr, ident_str.len) == 0) {
                type = &entry->type;
                break;
            }
        }
    }
    if (type) {
        Str type_str = get_ctype_name(type, interns, &type_arr);
        static char buffer[64];
        snprintf(buffer, sizeof(buffer), "%.*s", (int)type_str.len, type_str.ptr);
        return buffer;
    }
    return NULL;
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
    emit_append(&out, "#include <stdio.h>\n\n");
    // handle type signatures, global variables, function declarations, etc. here
    // TODO: handle non-primitive types from type context
    // TODO: handle unamed types
    type_array_init(&type_arr, 4);
    if (context->tree) {
        ctx_type_check(context->type_context, &type_arr);
        emit_type_signature(&out, &type_arr, context->type_context);
    }
    interns = context->type_context->interns;

    // handle main function
    emit_append(&out, "int main(void) {\n");
    indent_level++;
    if (context->tree && context->tree->kind == AST_BLOCK) {
        emit_line(emit_node_expr, &out, context->tree, "");
    } else if (context->tree) {
        emit_line(emit_node_expr, &out, context->tree, ";");
    }
    indent_level--;
    emit_append(&out, "  return 0;\n}\n");
    out.data[out.pos] = '\0';

    // write to output file
    fwrite(out.data, 1, out.pos, out_file);
    fclose(out_file);
    type_array_free(&type_arr);
    return true;
}
