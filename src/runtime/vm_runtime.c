#include "runtime/runtime.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define MORPHL_VM_MAGIC "MVMB"



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

typedef struct {
    uint32_t func_index;    // index of function in program's function table
    size_t ip;              // entry point in code
    size_t base;            // base index in value stack for this call frame
    size_t local_base;      // base index in slot list for this call frame's local variables
    size_t return_ip;       // instruction pointer to return to after call
    size_t return_base;     // base index in value stack to restore after call
    size_t return_local_base; // base index in slot list to restore after call
    uint32_t scope_depth;   // scope depth at time of call, used for unwinding scopes on return or error
} VmCallFrame;

struct MorphlVm {
    const MorphlVmProgram* program;
    size_t ip;                  // instruction pointer
    VmValue* stack;             // Value stack
    size_t stack_count;
    size_t stack_capacity;
    VmSlot* slots;              // Named slots for variables, functions, etc.
    size_t slot_count;
    size_t slot_capacity;
    VmCallFrame* call_frames;   // Call stack
    size_t call_frame_count;
    size_t call_frame_capacity;
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

// Push a value onto the VM stack, growing it if necessary. Returns true on success, false on OOM.
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

// Set a named slot in the VM, growing the slot list if necessary. Returns true on success, false on OOM.
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

static bool vm_return(MorphlVm* vm, FILE* err_stream) {
    // Unwind active scopes in the current call frame
    if (vm->call_frame_count == 0) {
        // No call frame to return from - i.e. return from top-level code. should be handled by caller (e.g. morphl_vm_execute)
        // and not here so throw an error
        report_error(err_stream, "attempted to return from top-level code");
        return false;
    }
    VmCallFrame* frame = &vm->call_frames[vm->call_frame_count - 1];

    // get top value on stack as return value
    VmValue return_value = {0};
    if (!vm_stack_pop(vm, &return_value)) {
        report_error(err_stream, "stack underflow while trying to return value");
        return false;
    }

    // Clean up slots created in this call frame
    while (vm->slot_count > frame->base) {
        vm_value_free(&vm->slots[--vm->slot_count].value);
        free(vm->slots[vm->slot_count].name);
        vm->slots[vm->slot_count].name = NULL;
    }

    // Pop call frame
    vm->call_frame_count--;

    // Jump back to return address
    vm->ip = frame->return_ip;

    // Push return value onto stack
    if (!vm_stack_push(vm, &return_value)) {
        vm_value_free(&return_value);
        report_error(err_stream, "out of memory pushing return value onto stack");
        return false;
    }

    return true;
}

// Call a function by index, pushing a new call frame. Returns true on success, false on error.
// TODO: finish implementing argument passing and function entry point lookup. For now just pushes a new call frame with ip set to 0 so it's possible to call into main function at index 0.
static bool vm_call(MorphlVm* vm, uint32_t func_index, FILE* err_stream) {
    // record return point
    size_t return_ip = vm->ip + 4; // return to instruction after the call
    size_t return_base = vm->stack_count;
    size_t return_local_base = vm->slot_count;

    // allocate new call frame
    if (vm->call_frame_count == vm->call_frame_capacity) {
        size_t new_capacity = (vm->call_frame_capacity == 0) ? 16 : vm->call_frame_capacity * 2;
        VmCallFrame* grown = realloc(vm->call_frames, new_capacity * sizeof(VmCallFrame));
        if (!grown) {
            return false;
        }
        vm->call_frames = grown;
        vm->call_frame_capacity = new_capacity;
    }
    VmCallFrame* frame = &vm->call_frames[vm->call_frame_count++];
    frame->func_index = func_index;
    frame->return_ip = return_ip;
    frame->return_base = return_base;
    frame->return_local_base = return_local_base;
    frame->ip = 0; // will be set to function entry point after we read it from the program
    frame->base = vm->stack_count;
    frame->local_base = vm->slot_count;
    frame->scope_depth = vm->call_frame_count ? vm->call_frames[vm->call_frame_count - 2].scope_depth + 1 : 0;

    // TODO: read function entry point from program's function table using func_index and set frame->ip to it. For now just set to 0 to make it possible to call into main function at index 0.
    frame->ip = 0;

    // TODO: copy arguments from stack to callee's local variable slots
    (void)err_stream;
    

    return true;
}

// Initialize the main call frame and set the instruction pointer to the entry point. Returns true on success, false on error.
static bool vm_init_call_frame(MorphlVm* vm, FILE* err_stream) {
    if (vm->call_frame_count == vm->call_frame_capacity) {
        size_t new_capacity = (vm->call_frame_capacity == 0) ? 16 : vm->call_frame_capacity * 2;
        VmCallFrame* grown = realloc(vm->call_frames, new_capacity * sizeof(VmCallFrame));
        if (!grown) {
            report_error(err_stream, "out of memory allocating call frames");
            return false;
        }
        vm->call_frames = grown;
        vm->call_frame_capacity = new_capacity;
    }
    VmCallFrame* frame = &vm->call_frames[vm->call_frame_count++];
    frame->func_index = 0; // main function is always at index 0
    frame->return_ip = 0;
    frame->base = 0;
    frame->local_base = 0;
    frame->scope_depth = 0;

    frame->ip = vm->ip;

    return true;
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

    for (size_t i = 0; i < vm->call_frame_count; ++i) {
        // no heap allocations in call frames currently, but if we add any in the future we should free them here
    }
    free(vm->call_frames);

    free(vm);
}

morphl_exit_code_t morphl_vm_execute(MorphlVm* vm, FILE* err_stream) {
    if (!vm || !vm->program || !vm->program->code) {
        report_error(err_stream, "invalid VM state");
        return 1;
    }

    // initialize main call frame
    if (!vm_init_call_frame(vm, err_stream)) {
        report_error(err_stream, "failed to initialize call frame");
        return 1;
    }

    while (vm->ip < vm->program->code_len) {
        uint8_t op = vm->program->code[vm->ip++];

        if (op == VM_OP_HALT) {
            return 0;
        }

        if (op == VM_OP_PUSH_NULL) {
            VmValue value = {.kind = VM_VALUE_NULL, .text = NULL, .items = NULL, .item_count = 0};
            if (!vm_stack_push(vm, &value)) {
                report_error(err_stream, "out of memory during PUSH_NULL");
                return 1;
            }
            continue;
        }

        if (op == VM_OP_PUSH_LITERAL || op == VM_OP_PUSH_IDENT) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated PUSH payload");
                return 1;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "string index out of bounds");
                return 1;
            }

            VmValue value = {
                .kind = (op == VM_OP_PUSH_LITERAL) ? VM_VALUE_LITERAL : VM_VALUE_IDENT,
                .text = vm->program->strings[idx],
                .items = NULL,
                .item_count = 0,
            };
            if (!vm_stack_push(vm, &value)) {
                report_error(err_stream, "out of memory during PUSH");
                return 1;
            }
            continue;
        }

        if (op == VM_OP_MAKE_GROUP) {
            uint32_t arity = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated MAKE_GROUP payload");
                return 1;
            }
            arity = (uint32_t)vm->program->code[vm->ip] |
                    ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                    ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                    ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if ((size_t)arity > vm->stack_count) {
                report_error(err_stream, "MAKE_GROUP arity exceeds stack depth");
                return 1;
            }

            VmValue group = {.kind = VM_VALUE_GROUP, .text = NULL, .items = NULL, .item_count = arity};
            if (arity > 0) {
                group.items = calloc(arity, sizeof(VmValue));
                if (!group.items) {
                    report_error(err_stream, "out of memory during MAKE_GROUP");
                    return 1;
                }
            }

            for (size_t i = 0; i < arity; ++i) {
                VmValue item = {0};
                if (!vm_stack_pop(vm, &item)) {
                    vm_value_free(&group);
                    report_error(err_stream, "stack underflow during MAKE_GROUP");
                    return 1;
                }
                group.items[arity - i - 1] = item;
            }

            if (!vm_stack_push(vm, &group)) {
                vm_value_free(&group);
                report_error(err_stream, "out of memory pushing group");
                return 1;
            }
            vm_value_free(&group);
            continue;
        }

        if (op == VM_OP_SET_SLOT) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated SET_SLOT payload");
                return 1;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "SET_SLOT index out of bounds");
                return 1;
            }

            VmValue value = {0};
            if (!vm_stack_pop(vm, &value)) {
                report_error(err_stream, "SET_SLOT requires a value on stack");
                return 1;
            }

            bool ok = vm_set_slot(vm, vm->program->strings[idx], &value);
            if (ok) {
                ok = vm_stack_push(vm, &value);
            }
            vm_value_free(&value);
            if (!ok) {
                report_error(err_stream, "failed to assign slot");
                return 1;
            }
            continue;
        }

        if (op == VM_OP_OPERATOR) {
            uint32_t idx = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated OPERATOR payload");
                return 1;
            }
            idx = (uint32_t)vm->program->code[vm->ip] |
                  ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                  ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                  ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (idx >= vm->program->string_count) {
                report_error(err_stream, "OPERATOR index out of bounds");
                return 1;
            }

            if (!vm_execute_operator(vm, vm->program->strings[idx], err_stream)) {
                return 1;
            }
            continue;
        }

        if (op == VM_OP_RET) {
            // if current call frame is main (i.e. call_frame_count == 1), then return from execute with the value on top of the stack as the exit code
            if (vm->call_frame_count == 1) {
                VmValue exit_value = {0};
                if (!vm_stack_pop(vm, &exit_value)) {
                    report_error(err_stream, "stack underflow while trying to read exit code");
                    return 1;
                }

                double exit_num = 0;
                if (!vm_value_to_number(&exit_value, &exit_num) || exit_num < 0 || exit_num > 255) {
                    vm_value_free(&exit_value);
                    report_error(err_stream, "invalid exit code (must be a number between 0 and 255)");
                    return 1;
                }

                vm_value_free(&exit_value);
                return (morphl_exit_code_t)(int)exit_num;
            }

            // otherwise, return from current function
            if (!vm_return(vm, err_stream)) {
                report_error(err_stream, "failed to return from function");
                return 1;
            }
        }

        if (op == VM_OP_CALL) {
            uint32_t func_index = 0;
            if ((vm->ip + 4) > vm->program->code_len) {
                report_error(err_stream, "truncated CALL payload");
                return 1;
            }
            func_index = (uint32_t)vm->program->code[vm->ip] |
                         ((uint32_t)vm->program->code[vm->ip + 1] << 8) |
                         ((uint32_t)vm->program->code[vm->ip + 2] << 16) |
                         ((uint32_t)vm->program->code[vm->ip + 3] << 24);
            vm->ip += 4;

            if (!vm_call(vm, func_index, err_stream)) {
                report_error(err_stream, "failed to call function");
                return 1;
            }
            continue;
        }

        if (op == VM_OP_NODE_META) {
            report_error(err_stream, "NODE_META execution is not supported in V0.1 runtime");
            return 1;
        }

        report_error(err_stream, "unknown opcode");
        return 1;
    }

    report_error(err_stream, "program terminated without HALT");
    return 1;
}

morphl_exit_code_t morphl_vm_run_file(const char* path, FILE* err_stream) {
    MorphlVmProgram* program = NULL;
    if (!morphl_vm_program_load(path, &program)) {
        report_error(err_stream, "failed to load bytecode file");
        return 1;
    }

    MorphlVm* vm = morphl_vm_new(program);
    if (!vm) {
        report_error(err_stream, "failed to initialize VM");
        morphl_vm_program_free(program);
        return 1;
    }

    morphl_exit_code_t ok = morphl_vm_execute(vm, err_stream);
    morphl_vm_free(vm);
    morphl_vm_program_free(program);
    return ok;
}
