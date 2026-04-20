#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "backend/vm.h"

/* ─── read helpers ─────────────────────────────────────────────────────────── */

static bool read_u16_le(const uint8_t *buf, size_t len, size_t *pos, uint16_t *out) {
    if (*pos + 2 > len) return false;
    *out = (uint16_t)((uint16_t)buf[*pos] | ((uint16_t)buf[*pos + 1] << 8));
    *pos += 2;
    return true;
}

static bool read_u32_le(const uint8_t *buf, size_t len, size_t *pos, uint32_t *out) {
    if (*pos + 4 > len) return false;
    *out = (uint32_t)buf[*pos]
         | ((uint32_t)buf[*pos + 1] << 8)
         | ((uint32_t)buf[*pos + 2] << 16)
         | ((uint32_t)buf[*pos + 3] << 24);
    *pos += 4;
    return true;
}

static bool read_bytes(const uint8_t *buf, size_t len, size_t *pos, void *dst, size_t n) {
    if (*pos + n > len) return false;
    memcpy(dst, buf + *pos, n);
    *pos += n;
    return true;
}

/* ─── opcode table ─────────────────────────────────────────────────────────── */

typedef enum { OP_NONE, OP_I32, OP_U32, OP_I64, OP_F64, OP_JUMP } OperandKind;

typedef struct {
    const char *name;
    OperandKind operand;
} OpcodeInfo;

/* indexed by opcode byte; entries with name==NULL are unknown */
static const OpcodeInfo opcode_table[256] = {
    [VM_OP_HALT]    = { "HALT",    OP_NONE },
    [VM_OP_ICONST]  = { "ICONST",  OP_I64  },
    [VM_OP_FCONST]  = { "FCONST",  OP_F64  },
    [VM_OP_RNULL]   = { "RNULL",   OP_NONE },
    [VM_OP_IADD]    = { "IADD",    OP_NONE },
    [VM_OP_ISUB]    = { "ISUB",    OP_NONE },
    [VM_OP_IMUL]    = { "IMUL",    OP_NONE },
    [VM_OP_IDIV]    = { "IDIV",    OP_NONE },
    [VM_OP_IMOD]    = { "IMOD",    OP_NONE },
    [VM_OP_FADD]    = { "FADD",    OP_NONE },
    [VM_OP_FSUB]    = { "FSUB",    OP_NONE },
    [VM_OP_FMUL]    = { "FMUL",    OP_NONE },
    [VM_OP_FDIV]    = { "FDIV",    OP_NONE },
    [VM_OP_IEQ]     = { "IEQ",     OP_NONE },
    [VM_OP_INEQ]    = { "INEQ",    OP_NONE },
    [VM_OP_ILT]     = { "ILT",     OP_NONE },
    [VM_OP_IGT]     = { "IGT",     OP_NONE },
    [VM_OP_ILTE]    = { "ILTE",    OP_NONE },
    [VM_OP_IGTE]    = { "IGTE",    OP_NONE },
    [VM_OP_FEQ]     = { "FEQ",     OP_NONE },
    [VM_OP_FNEQ]    = { "FNEQ",    OP_NONE },
    [VM_OP_FLT]     = { "FLT",     OP_NONE },
    [VM_OP_FGT]     = { "FGT",     OP_NONE },
    [VM_OP_FLTE]    = { "FLTE",    OP_NONE },
    [VM_OP_FGTE]    = { "FGTE",    OP_NONE },
    [VM_OP_I2F]     = { "I2F",     OP_NONE },
    [VM_OP_F2I]     = { "F2I",     OP_NONE },
    [VM_OP_ENTER]   = { "ENTER",   OP_U32  },
    [VM_OP_LEAVE]   = { "LEAVE",   OP_U32  },
    [VM_OP_ILOAD]   = { "ILOAD",   OP_I32  },
    [VM_OP_FLOAD]   = { "FLOAD",   OP_I32  },
    [VM_OP_RLOAD]   = { "RLOAD",   OP_I32  },
    [VM_OP_ISTORE]  = { "ISTORE",  OP_I32  },
    [VM_OP_FSTORE]  = { "FSTORE",  OP_I32  },
    [VM_OP_RSTORE]  = { "RSTORE",  OP_I32  },
    [VM_OP_JMP]     = { "JMP",     OP_JUMP },
    [VM_OP_JIF]     = { "JIF",     OP_JUMP },
    [VM_OP_JNULL]   = { "JNULL",   OP_JUMP },
    [VM_OP_RESERVE] = { "RESERVE", OP_U32  },
    [VM_OP_CALL]    = { "CALL",    OP_U32  },
    [VM_OP_RET]     = { "RET",     OP_NONE },
    [VM_OP_CALLF]   = { "CALLF",   OP_I32  },
    [VM_OP_EXIT]    = { "EXIT",    OP_NONE },
    [VM_OP_CALLX]   = { "CALLX",   OP_NONE },
    [VM_OP_ADDREF]  = { "ADDREF",  OP_I32  },
    [VM_OP_DEREF]   = { "DEREF",   OP_NONE },
    [VM_OP_PLOAD]   = { "PLOAD",   OP_I32  },
    [VM_OP_PSTORE]  = { "PSTORE",  OP_I32  },
    [VM_OP_GLOBAL]  = { "GLOBAL",  OP_NONE },
    [VM_OP_ALOAD]   = { "ALOAD",   OP_I32  },
    [VM_OP_ASTORE]  = { "ASTORE",  OP_I32  },
    [VM_OP_SCONST]  = { "SCONST",  OP_U32  },
    [VM_OP_SEQ]     = { "SEQ",     OP_NONE },
    [VM_OP_SNEQ]    = { "SNEQ",    OP_NONE },
    [VM_OP_IBAND]   = { "IBAND",   OP_NONE },
    [VM_OP_IBOR]    = { "IBOR",    OP_NONE },
    [VM_OP_IBXOR]   = { "IBXOR",   OP_NONE },
    [VM_OP_IBNOT]   = { "IBNOT",   OP_NONE },
    [VM_OP_ILSHIFT] = { "ILSHIFT", OP_NONE },
    [VM_OP_IRSHIFT] = { "IRSHIFT", OP_NONE },
    [VM_OP_REQ]     = { "REQ",     OP_NONE },
    [VM_OP_RNEQ]    = { "RNEQ",    OP_NONE },
};

/* ─── parsed file ──────────────────────────────────────────────────────────── */

typedef struct {
    uint16_t        version_major;
    uint16_t        version_minor;
    uint32_t        global_frame_size;
    VmFunctionMeta *functions;
    uint32_t        func_count;
    uint8_t        *code;
    uint32_t        code_len;
    char          **strings;
    uint32_t        str_count;
    char          **native_syms;
    uint32_t        native_sym_count;
} MbcFile;

static void mbc_free(MbcFile *mbc) {
    free(mbc->functions);
    free(mbc->code);
    for (uint32_t i = 0; i < mbc->str_count; i++) free(mbc->strings[i]);
    free(mbc->strings);
    for (uint32_t i = 0; i < mbc->native_sym_count; i++) free(mbc->native_syms[i]);
    free(mbc->native_syms);
}

static bool parse_mbc(const uint8_t *buf, size_t len, MbcFile *mbc) {
    size_t pos = 0;
    memset(mbc, 0, sizeof(*mbc));

    uint8_t magic[4];
    if (!read_bytes(buf, len, &pos, magic, 4)) {
        fprintf(stderr, "error: file too short for magic\n");
        return false;
    }
    if (memcmp(magic, MORPHL_VM_MAGIC, 4) != 0) {
        fprintf(stderr, "error: bad magic (got %02x %02x %02x %02x)\n",
                magic[0], magic[1], magic[2], magic[3]);
        return false;
    }

    if (!read_u16_le(buf, len, &pos, &mbc->version_major) ||
        !read_u16_le(buf, len, &pos, &mbc->version_minor)) {
        fprintf(stderr, "error: truncated header (version)\n");
        return false;
    }
    if (mbc->version_major != MORPHL_VM_VERSION_MAJOR) {
        fprintf(stderr, "warning: version mismatch (file=%u.%u, reader=%u.%u)\n",
                mbc->version_major, mbc->version_minor,
                MORPHL_VM_VERSION_MAJOR, MORPHL_VM_VERSION_MINOR);
    }

    if (!read_u32_le(buf, len, &pos, &mbc->global_frame_size)) {
        fprintf(stderr, "error: truncated header (global frame size)\n");
        return false;
    }

    if (!read_u32_le(buf, len, &pos, &mbc->func_count)) {
        fprintf(stderr, "error: truncated function table count\n");
        return false;
    }
    if (mbc->func_count > 0) {
        mbc->functions = malloc(mbc->func_count * sizeof(VmFunctionMeta));
        if (!mbc->functions) { fprintf(stderr, "error: out of memory\n"); return false; }
        for (uint32_t i = 0; i < mbc->func_count; i++) {
            VmFunctionMeta *fn = &mbc->functions[i];
            if (!read_u32_le(buf, len, &pos, &fn->entry_point) ||
                !read_u32_le(buf, len, &pos, &fn->frame_size)  ||
                !read_u32_le(buf, len, &pos, &fn->param_size)  ||
                !read_u32_le(buf, len, &pos, &fn->flags)) {
                fprintf(stderr, "error: truncated function table at entry %u\n", i);
                return false;
            }
        }
    }

    if (!read_u32_le(buf, len, &pos, &mbc->code_len)) {
        fprintf(stderr, "error: truncated code length\n");
        return false;
    }
    if (mbc->code_len > 0) {
        mbc->code = malloc(mbc->code_len);
        if (!mbc->code) { fprintf(stderr, "error: out of memory\n"); return false; }
        if (!read_bytes(buf, len, &pos, mbc->code, mbc->code_len)) {
            fprintf(stderr, "error: truncated code section\n");
            return false;
        }
    }

    /* string table (optional) */
    if (pos < len) {
        if (!read_u32_le(buf, len, &pos, &mbc->str_count)) {
            fprintf(stderr, "error: truncated string table count\n");
            return false;
        }
        if (mbc->str_count > 0) {
            mbc->strings = calloc(mbc->str_count, sizeof(char *));
            if (!mbc->strings) { fprintf(stderr, "error: out of memory\n"); return false; }
            for (uint32_t i = 0; i < mbc->str_count; i++) {
                uint32_t slen;
                if (!read_u32_le(buf, len, &pos, &slen)) {
                    fprintf(stderr, "error: truncated string length at index %u\n", i);
                    return false;
                }
                mbc->strings[i] = malloc(slen + 1);
                if (!mbc->strings[i]) { fprintf(stderr, "error: out of memory\n"); return false; }
                if (!read_bytes(buf, len, &pos, mbc->strings[i], slen + 1)) {
                    fprintf(stderr, "error: truncated string data at index %u\n", i);
                    return false;
                }
            }
        }
    }

    /* native symbol table (optional) */
    if (pos < len) {
        if (!read_u32_le(buf, len, &pos, &mbc->native_sym_count)) {
            fprintf(stderr, "error: truncated native symbol count\n");
            return false;
        }
        if (mbc->native_sym_count > 0) {
            mbc->native_syms = calloc(mbc->native_sym_count, sizeof(char *));
            if (!mbc->native_syms) { fprintf(stderr, "error: out of memory\n"); return false; }
            for (uint32_t i = 0; i < mbc->native_sym_count; i++) {
                uint32_t nlen;
                if (!read_u32_le(buf, len, &pos, &nlen)) {
                    fprintf(stderr, "error: truncated native symbol length at index %u\n", i);
                    return false;
                }
                mbc->native_syms[i] = malloc(nlen + 1);
                if (!mbc->native_syms[i]) { fprintf(stderr, "error: out of memory\n"); return false; }
                if (!read_bytes(buf, len, &pos, mbc->native_syms[i], nlen + 1)) {
                    fprintf(stderr, "error: truncated native symbol data at index %u\n", i);
                    return false;
                }
            }
        }
    }

    return true;
}

/* ─── printing ─────────────────────────────────────────────────────────────── */

static void print_header(const MbcFile *mbc) {
    printf("--- Header ---\n");
    printf("  Magic:         MVMB\n");
    printf("  Version:       %u.%u\n", mbc->version_major, mbc->version_minor);
    printf("  Global frame:  %u bytes\n", mbc->global_frame_size);
    printf("\n");
}

static void print_functions(const MbcFile *mbc) {
    printf("--- Functions (%u) ---\n", mbc->func_count);
    if (mbc->func_count == 0) {
        printf("  (none)\n");
    } else {
        for (uint32_t i = 0; i < mbc->func_count; i++) {
            const VmFunctionMeta *fn = &mbc->functions[i];
            bool is_native = (fn->flags & MORPHL_FUNC_FLAG_NATIVE) != 0;
            printf("  [%u]", i);
            if (is_native)
                printf("  native_sym=%-4u", fn->entry_point);
            else
                printf("  entry=0x%08x", fn->entry_point);
            printf("  frame=%-5u params=%-5u flags=%s\n",
                   fn->frame_size, fn->param_size,
                   is_native ? "native" : "none");
        }
    }
    printf("\n");
}

/* ─── disassembly helpers ──────────────────────────────────────────────────── */

static int32_t code_read_i32(const uint8_t *code, size_t *pos) {
    uint32_t u = (uint32_t)code[*pos]
               | ((uint32_t)code[*pos + 1] << 8)
               | ((uint32_t)code[*pos + 2] << 16)
               | ((uint32_t)code[*pos + 3] << 24);
    *pos += 4;
    int32_t v;
    memcpy(&v, &u, 4);
    return v;
}

static uint32_t code_read_u32(const uint8_t *code, size_t *pos) {
    uint32_t u = (uint32_t)code[*pos]
               | ((uint32_t)code[*pos + 1] << 8)
               | ((uint32_t)code[*pos + 2] << 16)
               | ((uint32_t)code[*pos + 3] << 24);
    *pos += 4;
    return u;
}

static int64_t code_read_i64(const uint8_t *code, size_t *pos) {
    uint64_t u = 0;
    for (int i = 0; i < 8; i++)
        u |= (uint64_t)code[*pos + i] << (8 * i);
    *pos += 8;
    int64_t v;
    memcpy(&v, &u, 8);
    return v;
}

static double code_read_f64(const uint8_t *code, size_t *pos) {
    uint64_t u = 0;
    for (int i = 0; i < 8; i++)
        u |= (uint64_t)code[*pos + i] << (8 * i);
    *pos += 8;
    double v;
    memcpy(&v, &u, 8);
    return v;
}

typedef struct { uint32_t offset; uint32_t idx; } FuncLabel;

static int cmp_func_label(const void *a, const void *b) {
    uint32_t x = ((const FuncLabel *)a)->offset;
    uint32_t y = ((const FuncLabel *)b)->offset;
    return (x > y) - (x < y);
}

static void print_disassembly(const MbcFile *mbc) {
    printf("--- Disassembly (%u bytes) ---\n", mbc->code_len);

    if (mbc->code_len == 0) {
        printf("  (empty)\n\n");
        return;
    }

    /* build sorted label list for non-native functions */
    FuncLabel *labels = malloc(mbc->func_count * sizeof(FuncLabel));
    uint32_t label_count = 0;
    if (labels) {
        for (uint32_t i = 0; i < mbc->func_count; i++) {
            if (!(mbc->functions[i].flags & MORPHL_FUNC_FLAG_NATIVE)) {
                labels[label_count].offset = mbc->functions[i].entry_point;
                labels[label_count].idx    = i;
                label_count++;
            }
        }
        qsort(labels, label_count, sizeof(FuncLabel), cmp_func_label);
    }

    size_t pos = 0;
    uint32_t next_label = 0;

    while (pos < mbc->code_len) {
        /* annotate function entry points */
        while (next_label < label_count &&
               labels[next_label].offset == (uint32_t)pos) {
            printf("\n  <func %u> @ 0x%04zx\n",
                   labels[next_label].idx, pos);
            next_label++;
        }

        size_t instr_off = pos;
        uint8_t op = mbc->code[pos++];
        const OpcodeInfo *info = &opcode_table[op];

        if (info->name == NULL) {
            printf("  %04zx:  <unknown 0x%02x>  (stopping disassembly)\n",
                   instr_off, op);
            break;
        }

        printf("  %04zx:  %-10s", instr_off, info->name);

        bool truncated = false;
        switch (info->operand) {
            case OP_NONE:
                break;
            case OP_I32: {
                if (pos + 4 > mbc->code_len) { truncated = true; break; }
                int32_t v = code_read_i32(mbc->code, &pos);
                printf("  %+d", v);
                break;
            }
            case OP_U32: {
                if (pos + 4 > mbc->code_len) { truncated = true; break; }
                uint32_t v = code_read_u32(mbc->code, &pos);
                /* for SCONST, inline the string value if available */
                if (op == VM_OP_SCONST && v < mbc->str_count)
                    printf("  %u  ; \"%s\"", v, mbc->strings[v]);
                else
                    printf("  %u", v);
                break;
            }
            case OP_I64: {
                if (pos + 8 > mbc->code_len) { truncated = true; break; }
                int64_t v = code_read_i64(mbc->code, &pos);
                printf("  %" PRId64, v);
                break;
            }
            case OP_F64: {
                if (pos + 8 > mbc->code_len) { truncated = true; break; }
                double v = code_read_f64(mbc->code, &pos);
                printf("  %g", v);
                break;
            }
            case OP_JUMP: {
                if (pos + 4 > mbc->code_len) { truncated = true; break; }
                int32_t rel = code_read_i32(mbc->code, &pos);
                uint32_t target = (uint32_t)((int32_t)pos + rel);
                printf("  -> 0x%04x", target);
                break;
            }
        }

        if (truncated) {
            printf("  <truncated>\n");
            break;
        }
        printf("\n");
    }

    free(labels);
    printf("\n");
}

static void print_strings(const MbcFile *mbc) {
    printf("--- Strings (%u) ---\n", mbc->str_count);
    if (mbc->str_count == 0) {
        printf("  (none)\n");
    } else {
        for (uint32_t i = 0; i < mbc->str_count; i++)
            printf("  [%u]  \"%s\"\n", i, mbc->strings[i]);
    }
    printf("\n");
}

static void print_native_syms(const MbcFile *mbc) {
    printf("--- Native Symbols (%u) ---\n", mbc->native_sym_count);
    if (mbc->native_sym_count == 0) {
        printf("  (none)\n");
    } else {
        for (uint32_t i = 0; i < mbc->native_sym_count; i++)
            printf("  [%u]  %s\n", i, mbc->native_syms[i]);
    }
    printf("\n");
}

/* ─── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: mbc_reader <file.mbc>\n");
        return 1;
    }
    const char *path = argv[1];

    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (fsize <= 0) {
        fprintf(stderr, "error: empty or unreadable file\n");
        fclose(f);
        return 1;
    }

    uint8_t *buf = malloc((size_t)fsize);
    if (!buf) {
        fprintf(stderr, "error: out of memory\n");
        fclose(f);
        return 1;
    }
    if (fread(buf, 1, (size_t)fsize, f) != (size_t)fsize) {
        fprintf(stderr, "error: read failed\n");
        free(buf);
        fclose(f);
        return 1;
    }
    fclose(f);

    MbcFile mbc;
    if (!parse_mbc(buf, (size_t)fsize, &mbc)) {
        free(buf);
        return 1;
    }
    free(buf);

    printf("=== MBC File: %s ===\n\n", path);
    print_header(&mbc);
    print_functions(&mbc);
    print_disassembly(&mbc);
    print_strings(&mbc);
    print_native_syms(&mbc);

    mbc_free(&mbc);
    return 0;
}
