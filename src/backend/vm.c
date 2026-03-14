#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast.h"
#include "backend/backend.h"
#include "util/util.h"
#include "runtime/runtime.h"

#include "backend/vm.h"







typedef struct VmEmitter {
    VmStringTable strings;
    VmMetadataTable metadata;
    VmBytes code;
    InternTable* interns;
} VmEmitter;

static bool vm_grow(void** ptr, size_t* current_capacity, size_t elem_size, size_t min_count) {
    size_t new_capacity = (*current_capacity == 0) ? 16 : *current_capacity;
    while (new_capacity < min_count) {
        if (new_capacity > (SIZE_MAX / 2)) {
            return false;
        }
        new_capacity *= 2;
    }
    void* grown = realloc(*ptr, new_capacity * elem_size);
    if (!grown) {
        return false;
    }
    *ptr = grown;
    *current_capacity = new_capacity;
    return true;
}

static bool bytes_push(VmBytes* bytes, const void* src, size_t n) {
    if (n == 0) {
        return true;
    }
    size_t required = bytes->len + n;
    if (required > bytes->capacity) {
        if (!vm_grow((void**)&bytes->data, &bytes->capacity, sizeof(uint8_t), required)) {
            return false;
        }
    }
    memcpy(bytes->data + bytes->len, src, n);
    bytes->len += n;
    return true;
}

static bool bytes_push_u8(VmBytes* bytes, uint8_t value) {
    return bytes_push(bytes, &value, sizeof(value));
}

static bool bytes_push_u16_le(VmBytes* bytes, uint16_t value) {
    uint8_t raw[2] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
    };
    return bytes_push(bytes, raw, sizeof(raw));
}

static bool bytes_push_u32_le(VmBytes* bytes, uint32_t value) {
    uint8_t raw[4] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF),
        (uint8_t)((value >> 24) & 0xFF),
    };
    return bytes_push(bytes, raw, sizeof(raw));
}

static bool string_table_add(VmStringTable* table, Str text, uint32_t* out_index) {
    for (size_t i = 0; i < table->count; ++i) {
        VmString* item = &table->items[i];
        if (item->len == text.len && memcmp(item->ptr, text.ptr, text.len) == 0) {
            *out_index = (uint32_t)i;
            return true;
        }
    }

    if (table->count == table->capacity) {
        if (!vm_grow((void**)&table->items, &table->capacity, sizeof(VmString), table->count + 1)) {
            return false;
        }
    }

    char* dup = NULL;
    if (text.len > 0) {
        dup = malloc(text.len);
        if (!dup) {
            return false;
        }
        memcpy(dup, text.ptr, text.len);
    }

    table->items[table->count].ptr = dup;
    table->items[table->count].len = (uint32_t)text.len;
    *out_index = (uint32_t)table->count;
    table->count++;
    return true;
}

static bool metadata_add(VmMetadataTable* table, uint32_t key_index, uint32_t value_index) {
    if (table->count == table->capacity) {
        if (!vm_grow((void**)&table->items, &table->capacity, sizeof(VmMetadata), table->count + 1)) {
            return false;
        }
    }
    table->items[table->count].key_index = key_index;
    table->items[table->count].value_index = value_index;
    table->count++;
    return true;
}

static Str op_name_from_node(const VmEmitter* emitter, const AstNode* node) {
    if (!emitter || !node || !emitter->interns || node->op == 0) {
        return str_from("<none>", 6);
    }
    return interns_lookup(emitter->interns, node->op);
}

static bool is_compile_time_operator(Str op_name) {
    static const char* compile_time_ops[] = {
        "$syntax", "$import", "$prop", "$decl", "$forward", "$file", "$global", "$inline", "$this"
    };

    for (size_t i = 0; i < sizeof(compile_time_ops) / sizeof(compile_time_ops[0]); ++i) {
        const char* candidate = compile_time_ops[i];
        size_t candidate_len = strlen(candidate);
        if (op_name.len == candidate_len && memcmp(op_name.ptr, candidate, candidate_len) == 0) {
            return true;
        }
    }
    return false;
}

static bool emit_opcode(VmEmitter* emitter, uint8_t opcode) {
    return bytes_push_u8(&emitter->code, opcode);
}

static bool emit_opcode_u32(VmEmitter* emitter, uint8_t opcode, uint32_t imm) {
    return emit_opcode(emitter, opcode) && bytes_push_u32_le(&emitter->code, imm);
}

static bool emit_set_slot(VmEmitter* emitter, Str name) {
    uint32_t name_idx = 0;
    if (!string_table_add(&emitter->strings, name, &name_idx)) {
        return false;
    }
    return emit_opcode_u32(emitter, VM_OP_SET_SLOT, name_idx);
}

static bool emit_node(VmEmitter* emitter, AstNode* node) {
    if (!node) {
        return emit_opcode(emitter, VM_OP_PUSH_NULL);
    }

    switch (node->kind) {
        case AST_LITERAL: {
            uint32_t idx = 0;
            if (!string_table_add(&emitter->strings, node->value, &idx)) {
                return false;
            }
            return emit_opcode_u32(emitter, VM_OP_PUSH_LITERAL, idx);
        }
        case AST_IDENT: {
            uint32_t idx = 0;
            if (!string_table_add(&emitter->strings, node->value, &idx)) {
                return false;
            }
            return emit_opcode_u32(emitter, VM_OP_PUSH_IDENT, idx);
        }
        case AST_GROUP:
            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }
            return emit_opcode_u32(emitter, VM_OP_MAKE_GROUP, (uint32_t)node->child_count);
        case AST_CALL: {
            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }
            uint32_t idx = 0;
            if (!string_table_add(&emitter->strings, str_from("$call", 5), &idx)) {
                return false;
            }

            // TODO: handle function table
            return emit_opcode_u32(emitter, VM_OP_CALL, idx);
        }
        case AST_DECL: {
            AstNode* rhs = (node->child_count > 1) ? node->children[1] : NULL;
            if (!emit_node(emitter, rhs)) {
                return false;
            }
            Str name = str_from("<anonymous>", 11);
            if (node->child_count > 0 && node->children[0] && node->children[0]->kind == AST_IDENT) {
                name = node->children[0]->value;
            }
            return emit_set_slot(emitter, name);
        }
        case AST_SET: {
            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }
            uint32_t idx = 0;
            if (!string_table_add(&emitter->strings, str_from("$set", 4), &idx)) {
                return false;
            }
            return emit_opcode_u32(emitter, VM_OP_OPERATOR, idx);
        }
        case AST_BUILTIN: {
            Str op_name = op_name_from_node(emitter, node);

            if (is_compile_time_operator(op_name)) {
                if (op_name.len == 5 && memcmp(op_name.ptr, "$decl", 5) == 0) {
                    AstNode* rhs = (node->child_count > 1) ? node->children[1] : NULL;
                    if (!emit_node(emitter, rhs)) {
                        return false;
                    }

                    Str name = str_from("<anonymous>", 11);
                    if (node->child_count > 0 && node->children[0] && node->children[0]->kind == AST_IDENT) {
                        name = node->children[0]->value;
                    }
                    return emit_set_slot(emitter, name);
                }

                for (size_t i = 0; i < node->child_count; ++i) {
                    if (!emit_node(emitter, node->children[i])) {
                        return false;
                    }
                }
                return true;
            }

            // if '$ret', evaluate return expression then emit RET opcode with no operand 
            if (op_name.len == 4 && memcmp(op_name.ptr, "$ret", 4) == 0) {
                return emit_node(emitter, node->children[0]) && emit_opcode(emitter, VM_OP_RET);
            }

            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }

            uint32_t idx = 0;
            if (!string_table_add(&emitter->strings, op_name, &idx)) {
                return false;
            }
            return emit_opcode_u32(emitter, VM_OP_OPERATOR, idx);
        }
        case AST_FILE:
        case AST_BLOCK:
            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }
            return true;
        default: {
            uint32_t op_idx = 0;
            Str op_name = op_name_from_node(emitter, node);
            if (!string_table_add(&emitter->strings, op_name, &op_idx)) {
                return false;
            }
            if (!emit_opcode(emitter, VM_OP_NODE_META) ||
                !bytes_push_u8(&emitter->code, (uint8_t)node->kind) ||
                !bytes_push_u32_le(&emitter->code, op_idx) ||
                !bytes_push_u32_le(&emitter->code, (uint32_t)node->child_count)) {
                return false;
            }
            for (size_t i = 0; i < node->child_count; ++i) {
                if (!emit_node(emitter, node->children[i])) {
                    return false;
                }
            }
            return true;
        }
    }
}

static bool emit_metadata(VmEmitter* emitter) {
    uint32_t key_idx = 0;
    uint32_t val_idx = 0;

    if (!string_table_add(&emitter->strings, str_from("backend", 7), &key_idx) ||
        !string_table_add(&emitter->strings, str_from("morphl-vm-bytecode", 18), &val_idx) ||
        !metadata_add(&emitter->metadata, key_idx, val_idx)) {
        return false;
    }

    if (!string_table_add(&emitter->strings, str_from("format_version", 14), &key_idx) ||
        !string_table_add(&emitter->strings, str_from("1.0", 3), &val_idx) ||
        !metadata_add(&emitter->metadata, key_idx, val_idx)) {
        return false;
    }

    if (!string_table_add(&emitter->strings, str_from("operators", 9), &key_idx) ||
        !string_table_add(&emitter->strings, str_from("runtime-verbatim", 16), &val_idx) ||
        !metadata_add(&emitter->metadata, key_idx, val_idx)) {
        return false;
    }

    return true;
}

static void emitter_free(VmEmitter* emitter) {
    for (size_t i = 0; i < emitter->strings.count; ++i) {
        free(emitter->strings.items[i].ptr);
    }
    free(emitter->strings.items);
    free(emitter->metadata.items);
    free(emitter->code.data);
    memset(emitter, 0, sizeof(*emitter));
}

bool morphl_backend_func_vm(MorphlBackendContext* context) {
    if (!context || !context->out_file) {
        return false;
    }

    VmEmitter emitter;
    memset(&emitter, 0, sizeof(emitter));
    emitter.interns = (context->type_context ? context->type_context->interns : NULL);

    if (!emit_node(&emitter, context->tree) || !emit_opcode(&emitter, VM_OP_HALT) || !emit_metadata(&emitter)) {
        emitter_free(&emitter);
        return false;
    }

    FILE* out = fopen(context->out_file, "wb");
    if (!out) {
        emitter_free(&emitter);
        return false;
    }

    VmBytes file = {0};
    bool ok = true;

    ok = ok && bytes_push(&file, MORPHL_VM_MAGIC, 4);
    ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MAJOR);
    ok = ok && bytes_push_u16_le(&file, MORPHL_VM_VERSION_MINOR);
    ok = ok && bytes_push_u32_le(&file, 0);

    ok = ok && bytes_push_u32_le(&file, (uint32_t)emitter.strings.count);
    for (size_t i = 0; ok && i < emitter.strings.count; ++i) {
        ok = ok && bytes_push_u32_le(&file, emitter.strings.items[i].len);
        ok = ok && bytes_push(&file, emitter.strings.items[i].ptr, emitter.strings.items[i].len);
    }

    ok = ok && bytes_push_u32_le(&file, (uint32_t)emitter.metadata.count);
    for (size_t i = 0; ok && i < emitter.metadata.count; ++i) {
        ok = ok && bytes_push_u32_le(&file, emitter.metadata.items[i].key_index);
        ok = ok && bytes_push_u32_le(&file, emitter.metadata.items[i].value_index);
    }

    ok = ok && bytes_push_u32_le(&file, (uint32_t)emitter.code.len);
    ok = ok && bytes_push(&file, emitter.code.data, emitter.code.len);

    if (ok) {
        ok = (fwrite(file.data, 1, file.len, out) == file.len);
    }

    fclose(out);
    free(file.data);
    emitter_free(&emitter);
    return ok;
}
