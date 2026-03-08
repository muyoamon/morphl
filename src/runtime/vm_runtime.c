#include "runtime/runtime.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define MORPHL_VM_MAGIC "MVMB"

enum VmOpcode {
    VM_OP_HALT = 0x00,
    VM_OP_PUSH_NULL = 0x01,
    VM_OP_PUSH_LITERAL = 0x02,
    VM_OP_PUSH_IDENT = 0x03,
    VM_OP_MAKE_GROUP = 0x04,
    VM_OP_SET_SLOT = 0x05,
    VM_OP_OPERATOR = 0x06,
    VM_OP_NODE_META = 0x07,
};

typedef enum {
    VM_VALUE_NULL,
    VM_VALUE_LITERAL,
    VM_VALUE_IDENT,
    VM_VALUE_GROUP,
} VmValueKind;

typedef struct VmValue VmValue;

struct VmValue {
    VmValueKind kind;
    char* text;
    VmValue* items;
    size_t item_count;
};

typedef struct {
    char* name;
    VmValue value;
} VmSlot;

struct MorphlVmProgram {
    uint16_t version_major;
    uint16_t version_minor;
    char** strings;
    uint32_t string_count;
    uint8_t* code;
    uint32_t code_len;
};

struct MorphlVm {
    const MorphlVmProgram* program;
    size_t ip;
    VmValue* stack;
    size_t stack_count;
    size_t stack_capacity;
    VmSlot* slots;
    size_t slot_count;
    size_t slot_capacity;
};

static void vm_value_free(VmValue* value) {
    if (!value) {
        return;
    }
    free(value->text);
    value->text = NULL;
    for (size_t i = 0; i < value->item_count; ++i) {
        vm_value_free(&value->items[i]);
    }
    free(value->items);
    value->items = NULL;
    value->item_count = 0;
    value->kind = VM_VALUE_NULL;
}

static bool vm_value_copy(const VmValue* src, VmValue* dst) {
    memset(dst, 0, sizeof(*dst));
    dst->kind = src->kind;

    if (src->text) {
        size_t n = strlen(src->text);
        dst->text = malloc(n + 1);
        if (!dst->text) {
            return false;
        }
        memcpy(dst->text, src->text, n + 1);
    }

    if (src->item_count > 0) {
        dst->items = calloc(src->item_count, sizeof(VmValue));
        if (!dst->items) {
            vm_value_free(dst);
            return false;
        }

        for (size_t i = 0; i < src->item_count; ++i) {
            if (!vm_value_copy(&src->items[i], &dst->items[i])) {
                for (size_t j = 0; j < i; ++j) {
                    vm_value_free(&dst->items[j]);
                }
                free(dst->items);
                dst->items = NULL;
                vm_value_free(dst);
                return false;
            }
        }
        dst->item_count = src->item_count;
    }

    return true;
}

static bool read_u16(const uint8_t* bytes, size_t len, size_t* off, uint16_t* out) {
    if ((*off + 2) > len) {
        return false;
    }
    *out = (uint16_t)(bytes[*off] | (uint16_t)(bytes[*off + 1] << 8));
    *off += 2;
    return true;
}

static bool read_u32(const uint8_t* bytes, size_t len, size_t* off, uint32_t* out) {
    if ((*off + 4) > len) {
        return false;
    }
    *out = (uint32_t)bytes[*off] |
           ((uint32_t)bytes[*off + 1] << 8) |
           ((uint32_t)bytes[*off + 2] << 16) |
           ((uint32_t)bytes[*off + 3] << 24);
    *off += 4;
    return true;
}

static void report_error(FILE* err_stream, const char* message) {
    FILE* out = err_stream ? err_stream : stderr;
    fprintf(out, "runtime error: %s\n", message);
}

static const VmValue* vm_resolve_value(const MorphlVm* vm, const VmValue* value) {
    if (value->kind != VM_VALUE_IDENT || !value->text) {
        return value;
    }

    for (size_t i = 0; i < vm->slot_count; ++i) {
        if (strcmp(vm->slots[i].name, value->text) == 0) {
            return &vm->slots[i].value;
        }
    }

    return value;
}

static bool vm_stack_push(MorphlVm* vm, const VmValue* value) {
    if (vm->stack_count == vm->stack_capacity) {
        size_t new_capacity = (vm->stack_capacity == 0) ? 16 : vm->stack_capacity * 2;
        VmValue* grown = realloc(vm->stack, new_capacity * sizeof(VmValue));
        if (!grown) {
            return false;
        }
        vm->stack = grown;
        vm->stack_capacity = new_capacity;
    }

    VmValue copy = {0};
    if (!vm_value_copy(value, &copy)) {
        return false;
    }

    vm->stack[vm->stack_count++] = copy;
    return true;
}

static bool vm_stack_pop(MorphlVm* vm, VmValue* out) {
    if (vm->stack_count == 0) {
        return false;
    }

    *out = vm->stack[--vm->stack_count];
    memset(&vm->stack[vm->stack_count], 0, sizeof(VmValue));
    return true;
}

static bool vm_set_slot(MorphlVm* vm, const char* name, const VmValue* value) {
    for (size_t i = 0; i < vm->slot_count; ++i) {
        if (strcmp(vm->slots[i].name, name) == 0) {
            vm_value_free(&vm->slots[i].value);
            return vm_value_copy(value, &vm->slots[i].value);
        }
    }

    if (vm->slot_count == vm->slot_capacity) {
        size_t new_capacity = (vm->slot_capacity == 0) ? 16 : vm->slot_capacity * 2;
        VmSlot* grown = realloc(vm->slots, new_capacity * sizeof(VmSlot));
        if (!grown) {
            return false;
        }
        vm->slots = grown;
        vm->slot_capacity = new_capacity;
    }

    char* dup_name = malloc(strlen(name) + 1);
    if (!dup_name) {
        return false;
    }
    strcpy(dup_name, name);

    VmValue copy = {0};
    if (!vm_value_copy(value, &copy)) {
        free(dup_name);
        return false;
    }

    vm->slots[vm->slot_count].name = dup_name;
    vm->slots[vm->slot_count].value = copy;
    vm->slot_count++;
    return true;
}

static bool vm_value_to_number(const VmValue* value, double* out_num) {
    if (!value || value->kind != VM_VALUE_LITERAL || !value->text) {
        return false;
    }

    char* end = NULL;
    errno = 0;
    double parsed = strtod(value->text, &end);
    if (errno != 0 || end == value->text || *end != '\0') {
        return false;
    }

    *out_num = parsed;
    return true;
}

static bool vm_execute_operator(MorphlVm* vm, const char* op_name, FILE* err_stream) {
    if (strcmp(op_name, "$add") == 0) {
        VmValue rhs = {0};
        VmValue lhs = {0};
        if (!vm_stack_pop(vm, &rhs) || !vm_stack_pop(vm, &lhs)) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "$add requires two operands");
            return false;
        }

        const VmValue* lhs_resolved = vm_resolve_value(vm, &lhs);
        const VmValue* rhs_resolved = vm_resolve_value(vm, &rhs);

        double lhs_num = 0;
        double rhs_num = 0;
        if (!vm_value_to_number(lhs_resolved, &lhs_num) || !vm_value_to_number(rhs_resolved, &rhs_num)) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "$add currently supports numeric literal operands only");
            return false;
        }

        char buffer[64];
        int written = snprintf(buffer, sizeof(buffer), "%.17g", lhs_num + rhs_num);
        if (written <= 0 || (size_t)written >= sizeof(buffer)) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "failed to format $add result");
            return false;
        }

        VmValue result = {
            .kind = VM_VALUE_LITERAL,
            .text = malloc((size_t)written + 1),
            .items = NULL,
            .item_count = 0,
        };
        if (!result.text) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "out of memory building $add result");
            return false;
        }
        memcpy(result.text, buffer, (size_t)written + 1);

        bool ok = vm_stack_push(vm, &result);
        vm_value_free(&result);
        vm_value_free(&rhs);
        vm_value_free(&lhs);
        if (!ok) {
            report_error(err_stream, "out of memory pushing $add result");
        }
        return ok;
    }

    if (strcmp(op_name, "$set") == 0) {
        VmValue rhs = {0};
        VmValue lhs = {0};
        if (!vm_stack_pop(vm, &rhs) || !vm_stack_pop(vm, &lhs)) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "$set requires identifier and value operands");
            return false;
        }

        if (lhs.kind != VM_VALUE_IDENT || !lhs.text) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "$set lhs must be an identifier");
            return false;
        }

        if (!vm_set_slot(vm, lhs.text, &rhs)) {
            vm_value_free(&rhs);
            vm_value_free(&lhs);
            report_error(err_stream, "failed to write slot during $set");
            return false;
        }

        bool ok = vm_stack_push(vm, &rhs);
        vm_value_free(&rhs);
        vm_value_free(&lhs);
        if (!ok) {
            report_error(err_stream, "out of memory pushing $set result");
        }
        return ok;
    }

    {
        FILE* out = err_stream ? err_stream : stderr;
        fprintf(out,
                "runtime error: unsupported operator '%s' (supported in V0.1: $add, $set)\n",
                op_name);
    }
    return false;
}

bool morphl_vm_program_load(const char* path, MorphlVmProgram** out_program) {
    if (!path || !out_program) {
        return false;
    }

    *out_program = NULL;

    FILE* file = fopen(path, "rb");
    if (!file) {
        return false;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return false;
    }

    long file_size = ftell(file);
    if (file_size < 0) {
        fclose(file);
        return false;
    }

    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return false;
    }

    uint8_t* bytes = malloc((size_t)file_size);
    if (!bytes) {
        fclose(file);
        return false;
    }

    bool ok = (fread(bytes, 1, (size_t)file_size, file) == (size_t)file_size);
    fclose(file);
    if (!ok) {
        free(bytes);
        return false;
    }

    MorphlVmProgram* program = calloc(1, sizeof(MorphlVmProgram));
    if (!program) {
        free(bytes);
        return false;
    }

    size_t off = 0;
    if ((size_t)file_size < 4 || memcmp(bytes, MORPHL_VM_MAGIC, 4) != 0) {
        free(bytes);
        morphl_vm_program_free(program);
        return false;
    }
    off += 4;

    uint32_t reserved = 0;
    uint32_t metadata_count = 0;
    if (!read_u16(bytes, (size_t)file_size, &off, &program->version_major) ||
        !read_u16(bytes, (size_t)file_size, &off, &program->version_minor) ||
        !read_u32(bytes, (size_t)file_size, &off, &reserved) ||
        !read_u32(bytes, (size_t)file_size, &off, &program->string_count)) {
        free(bytes);
        morphl_vm_program_free(program);
        return false;
    }

    if (program->string_count > 0) {
        program->strings = calloc(program->string_count, sizeof(char*));
        if (!program->strings) {
            free(bytes);
            morphl_vm_program_free(program);
            return false;
        }
    }

    for (uint32_t i = 0; i < program->string_count; ++i) {
        uint32_t len = 0;
        if (!read_u32(bytes, (size_t)file_size, &off, &len) || (off + len) > (size_t)file_size) {
            free(bytes);
            morphl_vm_program_free(program);
            return false;
        }

        char* text = malloc((size_t)len + 1);
        if (!text) {
            free(bytes);
            morphl_vm_program_free(program);
            return false;
        }
        memcpy(text, bytes + off, len);
        text[len] = '\0';
        off += len;
        program->strings[i] = text;
    }

    if (!read_u32(bytes, (size_t)file_size, &off, &metadata_count)) {
        free(bytes);
        morphl_vm_program_free(program);
        return false;
    }

    for (uint32_t i = 0; i < metadata_count; ++i) {
        uint32_t key = 0;
        uint32_t value = 0;
        if (!read_u32(bytes, (size_t)file_size, &off, &key) ||
            !read_u32(bytes, (size_t)file_size, &off, &value)) {
            free(bytes);
            morphl_vm_program_free(program);
            return false;
        }
    }

    if (!read_u32(bytes, (size_t)file_size, &off, &program->code_len) ||
        (off + program->code_len) > (size_t)file_size) {
        free(bytes);
        morphl_vm_program_free(program);
        return false;
    }

    if (program->code_len > 0) {
        program->code = malloc(program->code_len);
        if (!program->code) {
            free(bytes);
            morphl_vm_program_free(program);
            return false;
        }
        memcpy(program->code, bytes + off, program->code_len);
    }

    free(bytes);
    *out_program = program;
    return true;
}

void morphl_vm_program_free(MorphlVmProgram* program) {
    if (!program) {
        return;
    }

    for (uint32_t i = 0; i < program->string_count; ++i) {
        free(program->strings[i]);
    }
    free(program->strings);
    free(program->code);
    free(program);
}

MorphlVm* morphl_vm_new(const MorphlVmProgram* program) {
    if (!program) {
        return NULL;
    }

    MorphlVm* vm = calloc(1, sizeof(MorphlVm));
    if (!vm) {
        return NULL;
    }
    vm->program = program;
    return vm;
}

void morphl_vm_free(MorphlVm* vm) {
    if (!vm) {
        return;
    }

    for (size_t i = 0; i < vm->stack_count; ++i) {
        vm_value_free(&vm->stack[i]);
    }
    free(vm->stack);

    for (size_t i = 0; i < vm->slot_count; ++i) {
        free(vm->slots[i].name);
        vm_value_free(&vm->slots[i].value);
    }
    free(vm->slots);

    free(vm);
}

bool morphl_vm_execute(MorphlVm* vm, FILE* err_stream) {
    if (!vm || !vm->program || !vm->program->code) {
        report_error(err_stream, "invalid VM state");
        return false;
    }

    while (vm->ip < vm->program->code_len) {
        uint8_t op = vm->program->code[vm->ip++];

        if (op == VM_OP_HALT) {
            return true;
        }

        if (op == VM_OP_PUSH_NULL) {
            VmValue value = {.kind = VM_VALUE_NULL, .text = NULL, .items = NULL, .item_count = 0};
            if (!vm_stack_push(vm, &value)) {
                report_error(err_stream, "out of memory during PUSH_NULL");
                return false;
            }
            continue;
        }

        if (op == VM_OP_PUSH_LITERAL || op == VM_OP_PUSH_IDENT) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated PUSH payload");
                return false;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "string index out of bounds");
                return false;
            }

            VmValue value = {
                .kind = (op == VM_OP_PUSH_LITERAL) ? VM_VALUE_LITERAL : VM_VALUE_IDENT,
                .text = vm->program->strings[idx],
                .items = NULL,
                .item_count = 0,
            };
            if (!vm_stack_push(vm, &value)) {
                report_error(err_stream, "out of memory during PUSH");
                return false;
            }
            continue;
        }

        if (op == VM_OP_MAKE_GROUP) {
            uint32_t arity = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated MAKE_GROUP payload");
                return false;
            }
            arity = (uint32_t)vm->program->code[vm->ip] |
                    ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                    ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                    ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if ((size_t)arity > vm->stack_count) {
                report_error(err_stream, "MAKE_GROUP arity exceeds stack depth");
                return false;
            }

            VmValue group = {.kind = VM_VALUE_GROUP, .text = NULL, .items = NULL, .item_count = arity};
            if (arity > 0) {
                group.items = calloc(arity, sizeof(VmValue));
                if (!group.items) {
                    report_error(err_stream, "out of memory during MAKE_GROUP");
                    return false;
                }
            }

            for (size_t i = 0; i < arity; ++i) {
                VmValue item = {0};
                if (!vm_stack_pop(vm, &item)) {
                    vm_value_free(&group);
                    report_error(err_stream, "stack underflow during MAKE_GROUP");
                    return false;
                }
                group.items[arity - i - 1] = item;
            }

            if (!vm_stack_push(vm, &group)) {
                vm_value_free(&group);
                report_error(err_stream, "out of memory pushing group");
                return false;
            }
            vm_value_free(&group);
            continue;
        }

        if (op == VM_OP_SET_SLOT) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated SET_SLOT payload");
                return false;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "SET_SLOT index out of bounds");
                return false;
            }

            VmValue value = {0};
            if (!vm_stack_pop(vm, &value)) {
                report_error(err_stream, "SET_SLOT requires a value on stack");
                return false;
            }

            bool ok = vm_set_slot(vm, vm->program->strings[idx], &value);
            if (ok) {
                ok = vm_stack_push(vm, &value);
            }
            vm_value_free(&value);
            if (!ok) {
                report_error(err_stream, "failed to assign slot");
                return false;
            }
            continue;
        }

        if (op == VM_OP_OPERATOR) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated OPERATOR payload");
                return false;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "OPERATOR index out of bounds");
                return false;
            }

            if (!vm_execute_operator(vm, vm->program->strings[idx], err_stream)) {
                return false;
            }
            continue;
        }

        if (op == VM_OP_NODE_META) {
            report_error(err_stream, "NODE_META execution is not supported in V0.1 runtime");
            return false;
        }

        report_error(err_stream, "unknown opcode");
        return false;
    }

    report_error(err_stream, "program terminated without HALT");
    return false;
}

bool morphl_vm_run_file(const char* path, FILE* err_stream) {
    MorphlVmProgram* program = NULL;
    if (!morphl_vm_program_load(path, &program)) {
        report_error(err_stream, "failed to load bytecode file");
        return false;
    }

    MorphlVm* vm = morphl_vm_new(program);
    if (!vm) {
        report_error(err_stream, "failed to initialize VM");
        morphl_vm_program_free(program);
        return false;
    }

    bool ok = morphl_vm_execute(vm, err_stream);
    morphl_vm_free(vm);
    morphl_vm_program_free(program);
    return ok;
}
