#include "runtime/runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint16_t version_major;
  uint16_t version_minor;
  uint16_t artifact_kind;
  uint32_t global_frame_size;
  VmFunctionMeta* functions;
  uint32_t func_count;
  uint8_t* code;
  uint32_t code_len;
  char** strings;
  uint32_t str_count;
  char** native_syms;
  char** native_sym_modules;
  uint32_t native_sym_count;
  char* module_path;
  uint32_t module_init_func_idx;
  struct {
    char* name;
    uint16_t kind;
    uint16_t flags;
    uint32_t symbol_value;
  } *exports;
  uint32_t export_count;
  struct {
    char* binding_name;
    char* path;
    uint32_t global_slot;
    char** required_funcs;
    uint32_t required_func_count;
  } *imports;
  uint32_t import_count;
  uint32_t relocation_count;
  MorphlVmRelocation* relocations;
} VmObjectFile;

typedef struct {
  VmObjectFile image;
  uint32_t func_base;
  uint32_t code_base;
  uint32_t global_data_delta;
  uint32_t module_slot_offset;
} LinkedObject;

static bool resolve_exported_function_index(const LinkedObject* objects,
                                            size_t object_count,
                                            const char* module_path,
                                            const char* func_name,
                                            uint32_t* out);
static bool resolve_exported_data_offset(const LinkedObject* objects,
                                         size_t object_count,
                                         const char* module_path,
                                         const char* symbol_name,
                                         uint32_t* out);
static bool resolve_module_slot_offset(const LinkedObject* objects,
                                       size_t object_count,
                                       const char* module_path,
                                       uint32_t* out);

static bool read_bytes(const uint8_t* buf, size_t len, size_t* pos, void* out,
                       size_t n) {
  if (*pos + n > len) return false;
  memcpy(out, buf + *pos, n);
  *pos += n;
  return true;
}

static bool read_u16_le(const uint8_t* buf, size_t len, size_t* pos,
                        uint16_t* out) {
  uint8_t raw[2];
  if (!read_bytes(buf, len, pos, raw, 2)) return false;
  *out = (uint16_t)(raw[0] | ((uint16_t)raw[1] << 8));
  return true;
}

static bool read_u32_le(const uint8_t* buf, size_t len, size_t* pos,
                        uint32_t* out) {
  uint8_t raw[4];
  if (!read_bytes(buf, len, pos, raw, 4)) return false;
  *out = (uint32_t)(raw[0] | ((uint32_t)raw[1] << 8) |
                    ((uint32_t)raw[2] << 16) | ((uint32_t)raw[3] << 24));
  return true;
}

static bool read_len_string(const uint8_t* buf, size_t len, size_t* pos,
                            char** out);

static uint32_t read_u32_le_at(const uint8_t* buf, uint32_t off) {
  return (uint32_t)buf[off] | ((uint32_t)buf[off + 1] << 8) |
         ((uint32_t)buf[off + 2] << 16) | ((uint32_t)buf[off + 3] << 24);
}

static uint64_t read_u64_le_at(const uint8_t* buf, uint32_t off) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v |= ((uint64_t)buf[off + i]) << (8 * i);
  return v;
}

static void write_u32_le_at(uint8_t* buf, uint32_t off, uint32_t v) {
  buf[off] = (uint8_t)(v & 0xFF);
  buf[off + 1] = (uint8_t)((v >> 8) & 0xFF);
  buf[off + 2] = (uint8_t)((v >> 16) & 0xFF);
  buf[off + 3] = (uint8_t)((v >> 24) & 0xFF);
}

static void write_u64_le_at(uint8_t* buf, uint32_t off, uint64_t v) {
  for (int i = 0; i < 8; ++i) buf[off + i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

static bool read_reloc_extra_strings(const uint8_t* buf, size_t len, size_t* pos,
                                     MorphlVmRelocation* reloc) {
  if (!reloc) return false;
  reloc->module_path = NULL;
  reloc->symbol_name = NULL;
  if (!read_len_string(buf, len, pos, &reloc->module_path) ||
      !read_len_string(buf, len, pos, &reloc->symbol_name)) {
    free(reloc->module_path);
    free(reloc->symbol_name);
    reloc->module_path = NULL;
    reloc->symbol_name = NULL;
    return false;
  }
  return true;
}

static void vm_object_free(VmObjectFile* obj) {
  if (!obj) return;
  free(obj->functions);
  free(obj->code);
  if (obj->strings) {
    for (uint32_t i = 0; i < obj->str_count; ++i) free(obj->strings[i]);
  }
  free(obj->strings);
  if (obj->native_syms) {
    for (uint32_t i = 0; i < obj->native_sym_count; ++i)
      free(obj->native_syms[i]);
  }
  free(obj->native_syms);
  if (obj->native_sym_modules) {
    for (uint32_t i = 0; i < obj->native_sym_count; ++i)
      free(obj->native_sym_modules[i]);
  }
  free(obj->native_sym_modules);
  if (obj->imports) {
    for (uint32_t i = 0; i < obj->import_count; ++i) {
      free(obj->imports[i].binding_name);
      free(obj->imports[i].path);
      if (obj->imports[i].required_funcs) {
        for (uint32_t j = 0; j < obj->imports[i].required_func_count; ++j)
          free(obj->imports[i].required_funcs[j]);
      }
      free(obj->imports[i].required_funcs);
    }
  }
  free(obj->imports);
  if (obj->relocations) {
    for (uint32_t i = 0; i < obj->relocation_count; ++i) {
      free(obj->relocations[i].module_path);
      free(obj->relocations[i].symbol_name);
    }
  }
  free(obj->relocations);
  free(obj->module_path);
  if (obj->exports) {
    for (uint32_t i = 0; i < obj->export_count; ++i) free(obj->exports[i].name);
  }
  free(obj->exports);
  memset(obj, 0, sizeof(*obj));
}

static bool read_len_string(const uint8_t* buf, size_t len, size_t* pos,
                            char** out) {
  uint32_t slen = 0;
  if (!read_u32_le(buf, len, pos, &slen)) return false;
  char* bytes = (char*)malloc(slen + 1);
  if (!bytes) return false;
  if (!read_bytes(buf, len, pos, bytes, slen + 1)) {
    free(bytes);
    return false;
  }
  if (bytes[slen] != '\0') {
    free(bytes);
    return false;
  }
  *out = bytes;
  return true;
}

static bool vm_object_load(const char* path, VmObjectFile* out, FILE* err) {
  if (!path || !out) return false;
  memset(out, 0, sizeof(*out));

  FILE* f = fopen(path, "rb");
  if (!f) {
    fprintf(err ? err : stderr, "mpll: cannot open '%s'\n", path);
    return false;
  }
  fseek(f, 0, SEEK_END);
  long fsize = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (fsize <= 0) {
    fclose(f);
    fprintf(err ? err : stderr, "mpll: empty object file '%s'\n", path);
    return false;
  }
  uint8_t* buf = (uint8_t*)malloc((size_t)fsize);
  if (!buf) {
    fclose(f);
    return false;
  }
  if (fread(buf, 1, (size_t)fsize, f) != (size_t)fsize) {
    free(buf);
    fclose(f);
    return false;
  }
  fclose(f);

  size_t pos = 0;
  size_t len = (size_t)fsize;
  uint8_t magic[4];
  if (!read_bytes(buf, len, &pos, magic, 4) ||
      memcmp(magic, MORPHL_VM_MAGIC, 4) != 0) {
    fprintf(err ? err : stderr, "mpll: bad magic in '%s'\n", path);
    free(buf);
    return false;
  }
  if (!read_u16_le(buf, len, &pos, &out->version_major) ||
      !read_u16_le(buf, len, &pos, &out->version_minor) ||
      !read_u16_le(buf, len, &pos, &out->artifact_kind)) {
    free(buf);
    return false;
  }
  if (out->version_major != MORPHL_VM_VERSION_MAJOR) {
    fprintf(err ? err : stderr,
            "mpll: unsupported object version %u.%u in '%s'\n",
            out->version_major, out->version_minor, path);
    free(buf);
    return false;
  }
  if (out->artifact_kind != MORPHL_VM_ARTIFACT_OBJECT) {
    fprintf(err ? err : stderr, "mpll: '%s' is not a VM object file\n", path);
    free(buf);
    return false;
  }
  if (!read_u32_le(buf, len, &pos, &out->global_frame_size) ||
      !read_u32_le(buf, len, &pos, &out->func_count)) {
    free(buf);
    return false;
  }
  if (out->func_count > 0) {
    out->functions = (VmFunctionMeta*)malloc(out->func_count * sizeof(VmFunctionMeta));
    if (!out->functions) {
      free(buf);
      return false;
    }
    for (uint32_t i = 0; i < out->func_count; ++i) {
      if (!read_u32_le(buf, len, &pos, &out->functions[i].entry_point) ||
          !read_u32_le(buf, len, &pos, &out->functions[i].frame_size) ||
          !read_u32_le(buf, len, &pos, &out->functions[i].param_size) ||
          !read_u32_le(buf, len, &pos, &out->functions[i].return_size) ||
          !read_u32_le(buf, len, &pos, &out->functions[i].flags)) {
        free(buf);
        vm_object_free(out);
        return false;
      }
    }
  }
  if (!read_u32_le(buf, len, &pos, &out->code_len)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->code_len > 0) {
    out->code = (uint8_t*)malloc(out->code_len);
    if (!out->code) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    if (!read_bytes(buf, len, &pos, out->code, out->code_len)) {
      free(buf);
      vm_object_free(out);
      return false;
    }
  }

  if (!read_u32_le(buf, len, &pos, &out->str_count)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->str_count > 0) {
    out->strings = (char**)calloc(out->str_count, sizeof(char*));
    if (!out->strings) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    for (uint32_t i = 0; i < out->str_count; ++i) {
      if (!read_len_string(buf, len, &pos, &out->strings[i])) {
        free(buf);
        vm_object_free(out);
        return false;
      }
    }
  }

  if (!read_u32_le(buf, len, &pos, &out->native_sym_count)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->native_sym_count > 0) {
    out->native_syms = (char**)calloc(out->native_sym_count, sizeof(char*));
    out->native_sym_modules = (char**)calloc(out->native_sym_count, sizeof(char*));
    if (!out->native_syms || !out->native_sym_modules) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    for (uint32_t i = 0; i < out->native_sym_count; ++i) {
      if (!read_len_string(buf, len, &pos, &out->native_syms[i]) ||
          !read_len_string(buf, len, &pos, &out->native_sym_modules[i])) {
        free(buf);
        vm_object_free(out);
        return false;
      }
    }
  }

  if (!read_len_string(buf, len, &pos, &out->module_path) ||
      !read_u32_le(buf, len, &pos, &out->module_init_func_idx)) {
    free(buf);
    vm_object_free(out);
    return false;
  }

  /* skip export table */
  if (!read_u32_le(buf, len, &pos, &out->export_count)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->export_count > 0) {
    out->exports = calloc(out->export_count, sizeof(*out->exports));
    if (!out->exports) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    for (uint32_t i = 0; i < out->export_count; ++i) {
      if (!read_u16_le(buf, len, &pos, &out->exports[i].kind) ||
          !read_u16_le(buf, len, &pos, &out->exports[i].flags) ||
          !read_u32_le(buf, len, &pos, &out->exports[i].symbol_value) ||
          !read_len_string(buf, len, &pos, &out->exports[i].name)) {
        free(buf);
        vm_object_free(out);
        return false;
      }
      if (out->exports[i].kind == MORPHL_VM_EXPORT_FUNCTION &&
          out->exports[i].symbol_value == UINT32_MAX) {
        fprintf(err ? err : stderr,
                "mpll: unresolved function export '%s' in '%s'\n",
                out->exports[i].name ? out->exports[i].name : "<unnamed>",
                path);
        free(buf);
        vm_object_free(out);
        return false;
      }
      if (out->exports[i].kind == MORPHL_VM_EXPORT_FUNCTION &&
          out->exports[i].symbol_value >= out->func_count) {
        fprintf(err ? err : stderr,
                "mpll: function export '%s' index %u out of range in '%s'\n",
                out->exports[i].name ? out->exports[i].name : "<unnamed>",
                (unsigned)out->exports[i].symbol_value, path);
        free(buf);
        vm_object_free(out);
        return false;
      }
    }
  }

  if (!read_u32_le(buf, len, &pos, &out->import_count)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->import_count > 0) {
    out->imports = calloc(out->import_count, sizeof(*out->imports));
    if (!out->imports) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    for (uint32_t i = 0; i < out->import_count; ++i) {
      if (!read_len_string(buf, len, &pos, &out->imports[i].binding_name) ||
          !read_len_string(buf, len, &pos, &out->imports[i].path) ||
          !read_u32_le(buf, len, &pos, &out->imports[i].global_slot)) {
        free(buf);
        vm_object_free(out);
        return false;
      }
      if (!read_u32_le(buf, len, &pos, &out->imports[i].required_func_count)) {
        free(buf);
        vm_object_free(out);
        return false;
      }
      if (out->imports[i].required_func_count > 0) {
        out->imports[i].required_funcs =
            calloc(out->imports[i].required_func_count, sizeof(char*));
        if (!out->imports[i].required_funcs) {
          free(buf);
          vm_object_free(out);
          return false;
        }
        for (uint32_t j = 0; j < out->imports[i].required_func_count; ++j) {
          if (!read_len_string(buf, len, &pos,
                               &out->imports[i].required_funcs[j])) {
            free(buf);
            vm_object_free(out);
            return false;
          }
        }
      }
    }
  }

  if (!read_u32_le(buf, len, &pos, &out->relocation_count)) {
    free(buf);
    vm_object_free(out);
    return false;
  }
  if (out->relocation_count > 0) {
    out->relocations = (MorphlVmRelocation*)calloc(
        out->relocation_count, sizeof(MorphlVmRelocation));
    if (!out->relocations) {
      free(buf);
      vm_object_free(out);
      return false;
    }
    for (uint32_t i = 0; i < out->relocation_count; ++i) {
      if (!read_u16_le(buf, len, &pos, &out->relocations[i].kind) ||
          !read_u32_le(buf, len, &pos, &out->relocations[i].code_offset)) {
        free(buf);
        vm_object_free(out);
        return false;
      }
      if (out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32 ||
          out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_I64 ||
          out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_DATA_I32 ||
          out->relocations[i].kind == MORPHL_VM_RELOC_MODULE_SLOT_I32) {
        if (!read_reloc_extra_strings(buf, len, &pos, &out->relocations[i])) {
          free(buf);
          vm_object_free(out);
          return false;
        }
      } else if (out->relocations[i].kind != MORPHL_VM_RELOC_FUNC_INDEX_U32 &&
                 out->relocations[i].kind != MORPHL_VM_RELOC_FUNC_INDEX_I64 &&
                 out->relocations[i].kind != MORPHL_VM_RELOC_GLOBAL_DATA_I32 &&
                 out->relocations[i].kind != MORPHL_VM_RELOC_GLOBAL_DATA_I64 &&
                 out->relocations[i].kind !=
                     MORPHL_VM_RELOC_MODULE_FRAME_BASE_I64 &&
                 out->relocations[i].kind != MORPHL_VM_RELOC_EXTERN_DATA_I32 &&
                 out->relocations[i].kind != MORPHL_VM_RELOC_MODULE_SLOT_I32) {
        fprintf(err ? err : stderr,
                "mpll: unsupported relocation kind %u in '%s'\n",
                (unsigned)out->relocations[i].kind, path);
        free(buf);
        vm_object_free(out);
        return false;
      }
    }
  }

  free(buf);
  return true;
}

static bool write_u16_le(FILE* f, uint16_t v) {
  uint8_t raw[2] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF)};
  return fwrite(raw, 1, 2, f) == 2;
}

static bool write_u32_le(FILE* f, uint32_t v) {
  uint8_t raw[4] = {(uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                    (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF)};
  return fwrite(raw, 1, 4, f) == 4;
}

static bool write_len_string(FILE* f, const char* s) {
  uint32_t len = (uint32_t)(s ? strlen(s) : 0);
  char nul = '\0';
  return write_u32_le(f, len) &&
         (len == 0 || fwrite(s, 1, len, f) == len) &&
         fwrite(&nul, 1, 1, f) == 1;
}

static char* dup_cstr(const char* s) {
  size_t len = s ? strlen(s) : 0;
  char* out = (char*)malloc(len + 1);
  if (!out) return NULL;
  if (len > 0) memcpy(out, s, len);
  out[len] = '\0';
  return out;
}

static uint32_t intern_cstr(char*** items, uint32_t* count, const char* s) {
  if (!items || !count || !s) return UINT32_MAX;
  for (uint32_t i = 0; i < *count; ++i) {
    if (strcmp((*items)[i], s) == 0) return i;
  }
  char** grown = (char**)realloc(*items, ((*count) + 1) * sizeof(char*));
  if (!grown) return UINT32_MAX;
  *items = grown;
  (*items)[*count] = dup_cstr(s);
  if (!(*items)[*count]) return UINT32_MAX;
  return (*count)++;
}

static bool patch_sconst_indices(uint8_t* code, uint32_t code_len,
                                 const uint32_t* string_map,
                                 uint32_t string_map_count, FILE* err) {
  uint32_t ip = 0;
  while (ip < code_len) {
    uint8_t op = code[ip++];
    switch (op) {
      case VM_OP_HALT:
      case VM_OP_RNULL:
      case VM_OP_IADD:
      case VM_OP_ISUB:
      case VM_OP_IMUL:
      case VM_OP_IDIV:
      case VM_OP_IMOD:
      case VM_OP_FADD:
      case VM_OP_FSUB:
      case VM_OP_FMUL:
      case VM_OP_FDIV:
      case VM_OP_IEQ:
      case VM_OP_INEQ:
      case VM_OP_ILT:
      case VM_OP_IGT:
      case VM_OP_ILTE:
      case VM_OP_IGTE:
      case VM_OP_FEQ:
      case VM_OP_FNEQ:
      case VM_OP_FLT:
      case VM_OP_FGT:
      case VM_OP_FLTE:
      case VM_OP_FGTE:
      case VM_OP_I2F:
      case VM_OP_F2I:
      case VM_OP_RET:
      case VM_OP_EXIT:
      case VM_OP_FREE:
      case VM_OP_CALLX:
      case VM_OP_DEREF:
      case VM_OP_SEQ:
      case VM_OP_SNEQ:
      case VM_OP_IBAND:
      case VM_OP_IBOR:
      case VM_OP_IBXOR:
      case VM_OP_IBNOT:
      case VM_OP_ILSHIFT:
      case VM_OP_IRSHIFT:
      case VM_OP_IUDIV:
      case VM_OP_IUMOD:
      case VM_OP_IULT:
      case VM_OP_IUGT:
      case VM_OP_IULTE:
      case VM_OP_IUGTE:
      case VM_OP_IURSHIFT:
      case VM_OP_REQ:
      case VM_OP_RNEQ:
      case VM_OP_GLOBAL:
      case VM_OP_INORM1S:
      case VM_OP_INORM1U:
      case VM_OP_INORM2S:
      case VM_OP_INORM2U:
      case VM_OP_INORM4S:
      case VM_OP_INORM4U:
        break;
      case VM_OP_ICONST:
      case VM_OP_FCONST:
        if (ip + 8 > code_len) goto truncated;
        ip += 8;
        break;
      case VM_OP_ENTER:
      case VM_OP_LEAVE:
      case VM_OP_JMP:
      case VM_OP_JIF:
      case VM_OP_JNULL:
      case VM_OP_RESERVE:
      case VM_OP_CALL:
      case VM_OP_CALLF:
      case VM_OP_HEAP:
      case VM_OP_SET_CLEANUP:
      case VM_OP_ADDREF:
      case VM_OP_PLOAD:
      case VM_OP_PSTORE:
      case VM_OP_ILOAD:
      case VM_OP_ILOAD1S:
      case VM_OP_ILOAD1U:
      case VM_OP_ILOAD2S:
      case VM_OP_ILOAD2U:
      case VM_OP_ILOAD4S:
      case VM_OP_ILOAD4U:
      case VM_OP_FLOAD:
      case VM_OP_RLOAD:
      case VM_OP_ISTORE:
      case VM_OP_ISTORE1:
      case VM_OP_ISTORE2:
      case VM_OP_ISTORE4:
      case VM_OP_FSTORE:
      case VM_OP_RSTORE:
      case VM_OP_ALOAD:
      case VM_OP_ALOAD1S:
      case VM_OP_ALOAD1U:
      case VM_OP_ALOAD2S:
      case VM_OP_ALOAD2U:
      case VM_OP_ALOAD4S:
      case VM_OP_ALOAD4U:
      case VM_OP_ASTORE:
      case VM_OP_ASTORE1:
      case VM_OP_ASTORE2:
      case VM_OP_ASTORE4:
        if (ip + 4 > code_len) goto truncated;
        ip += 4;
        break;
      case VM_OP_SCONST: {
        uint32_t off = ip;
        uint32_t idx;
        if (ip + 4 > code_len) goto truncated;
        idx = read_u32_le_at(code, off);
        if (idx >= string_map_count) {
          fprintf(err ? err : stderr,
                  "mpll: SCONST string index %u out of range during link\n",
                  idx);
          return false;
        }
        write_u32_le_at(code, off, string_map[idx]);
        ip += 4;
        break;
      }
      default:
        fprintf(err ? err : stderr, "mpll: unsupported opcode 0x%02x during link\n",
                (unsigned)op);
        return false;
    }
  }
  return true;

truncated:
  fprintf(err ? err : stderr, "mpll: truncated code while scanning relocations\n");
  return false;
}

static bool vm_executable_write_from_object(const char* out_path,
                                            const VmObjectFile* obj,
                                            FILE* err) {
  FILE* f = fopen(out_path, "wb");
  if (!f) {
    fprintf(err ? err : stderr, "mpll: cannot write '%s'\n", out_path);
    return false;
  }
  bool ok = true;
  ok = ok && fwrite(MORPHL_VM_MAGIC, 1, 4, f) == 4;
  ok = ok && write_u16_le(f, obj->version_major);
  ok = ok && write_u16_le(f, obj->version_minor);
  ok = ok && write_u16_le(f, MORPHL_VM_ARTIFACT_EXECUTABLE);
  ok = ok && write_u32_le(f, obj->global_frame_size);
  ok = ok && write_u32_le(f, obj->func_count);
  for (uint32_t i = 0; ok && i < obj->func_count; ++i) {
    ok = ok && write_u32_le(f, obj->functions[i].entry_point);
    ok = ok && write_u32_le(f, obj->functions[i].frame_size);
    ok = ok && write_u32_le(f, obj->functions[i].param_size);
    ok = ok && write_u32_le(f, obj->functions[i].return_size);
    ok = ok && write_u32_le(f, obj->functions[i].flags);
  }
  ok = ok && write_u32_le(f, obj->code_len);
  ok = ok && (obj->code_len == 0 || fwrite(obj->code, 1, obj->code_len, f) == obj->code_len);
  ok = ok && write_u32_le(f, obj->str_count);
  for (uint32_t i = 0; ok && i < obj->str_count; ++i) {
    ok = ok && write_len_string(f, obj->strings[i]);
  }
  ok = ok && write_u32_le(f, obj->native_sym_count);
  for (uint32_t i = 0; ok && i < obj->native_sym_count; ++i) {
    ok = ok && write_len_string(f, obj->native_syms[i]);
    ok = ok && write_len_string(f, obj->native_sym_modules[i] ? obj->native_sym_modules[i] : "");
  }
  fclose(f);
  if (!ok) {
    fprintf(err ? err : stderr, "mpll: failed writing executable '%s'\n",
            out_path);
  }
  return ok;
}

static bool build_linked_image(VmObjectFile* out, LinkedObject* objects,
                               size_t object_count, const char* root_module_path,
                               FILE* err) {
  if (!out || !objects || object_count == 0) return false;
  memset(out, 0, sizeof(*out));
  out->version_major = objects[0].image.version_major;
  out->version_minor = objects[0].image.version_minor;
  out->artifact_kind = MORPHL_VM_ARTIFACT_EXECUTABLE;

  uint32_t total_global_extra = 0;
  out->func_count = 1; /* synthesized executable startup wrapper */
  for (size_t i = 0; i < object_count; ++i) {
    VmObjectFile* obj = &objects[i].image;
    objects[i].global_data_delta = total_global_extra;
    if (obj->global_frame_size > 32)
      total_global_extra += obj->global_frame_size - 32;
    objects[i].func_base = out->func_count;
    objects[i].code_base = out->code_len;
    out->func_count += obj->func_count;
    out->code_len += obj->code_len;
  }
  for (size_t i = 0; i < object_count; ++i) {
    objects[i].module_slot_offset = 32 + total_global_extra + (uint32_t)(i * 8);
  }
  out->global_frame_size = 32 + total_global_extra + (uint32_t)(object_count * 8);

  out->functions =
      (VmFunctionMeta*)calloc(out->func_count, sizeof(VmFunctionMeta));
  out->code = (uint8_t*)malloc(out->code_len);
  if ((out->func_count > 0 && !out->functions) ||
      (out->code_len > 0 && !out->code)) {
    vm_object_free(out);
    return false;
  }

  for (size_t i = 0; i < object_count; ++i) {
    VmObjectFile* obj = &objects[i].image;
    uint32_t* string_map = NULL;
    uint32_t* native_map = NULL;
    uint32_t func_base = objects[i].func_base;
    uint32_t code_base = objects[i].code_base;
    if (obj->str_count > 0) {
      string_map = (uint32_t*)calloc(obj->str_count, sizeof(uint32_t));
      if (!string_map) {
        vm_object_free(out);
        return false;
      }
      for (uint32_t s = 0; s < obj->str_count; ++s) {
        string_map[s] = intern_cstr(&out->strings, &out->str_count, obj->strings[s]);
        if (string_map[s] == UINT32_MAX) {
          free(string_map);
          vm_object_free(out);
          return false;
        }
      }
    }
    if (obj->native_sym_count > 0) {
      native_map = (uint32_t*)calloc(obj->native_sym_count, sizeof(uint32_t));
      if (!native_map) {
        free(string_map);
        vm_object_free(out);
        return false;
      }
      for (uint32_t n = 0; n < obj->native_sym_count; ++n) {
        uint32_t prev_count = out->native_sym_count;
        native_map[n] =
            intern_cstr(&out->native_syms, &out->native_sym_count, obj->native_syms[n]);
        if (native_map[n] == UINT32_MAX) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        if (out->native_sym_modules == NULL) {
          out->native_sym_modules = (char**)calloc(out->native_sym_count, sizeof(char*));
          if (!out->native_sym_modules) {
            free(string_map);
            free(native_map);
            vm_object_free(out);
            return false;
          }
        } else {
          uint32_t old_count = prev_count;
          char** grown = (char**)realloc(out->native_sym_modules,
                                         out->native_sym_count * sizeof(char*));
          if (!grown) {
            free(string_map);
            free(native_map);
            vm_object_free(out);
            return false;
          }
          out->native_sym_modules = grown;
          for (uint32_t gi = old_count; gi < out->native_sym_count; ++gi)
            out->native_sym_modules[gi] = NULL;
        }
        size_t mapped_idx = native_map[n];
        if (mapped_idx < out->native_sym_count &&
            out->native_sym_modules[mapped_idx] == NULL &&
            obj->native_sym_modules && obj->native_sym_modules[n]) {
          out->native_sym_modules[mapped_idx] =
              strdup(obj->native_sym_modules[n]);
          if (!out->native_sym_modules[mapped_idx]) {
            free(string_map);
            free(native_map);
            vm_object_free(out);
            return false;
          }
        }
      }
    }

    memcpy(out->code + code_base, obj->code, obj->code_len);
    if (!patch_sconst_indices(out->code + code_base, obj->code_len, string_map,
                              obj->str_count, err)) {
      free(string_map);
      free(native_map);
      vm_object_free(out);
      return false;
    }

    for (uint32_t r = 0; r < obj->relocation_count; ++r) {
      MorphlVmRelocation reloc = obj->relocations[r];
      uint32_t final_off = code_base + reloc.code_offset;
      if (reloc.kind == MORPHL_VM_RELOC_FUNC_INDEX_U32) {
        if (final_off + 4 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u32_le_at(out->code, final_off,
                        read_u32_le_at(out->code, final_off) + func_base);
      } else if (reloc.kind == MORPHL_VM_RELOC_FUNC_INDEX_I64) {
        if (final_off + 8 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u64_le_at(out->code, final_off,
                        read_u64_le_at(out->code, final_off) + func_base);
      } else if (reloc.kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32 ||
                 reloc.kind == MORPHL_VM_RELOC_EXTERN_FUNC_I64) {
        uint32_t resolved_idx = UINT32_MAX;
        if (!resolve_exported_function_index(objects, object_count,
                                             reloc.module_path,
                                             reloc.symbol_name,
                                             &resolved_idx)) {
          fprintf(err ? err : stderr,
                  "mpll: unresolved external function '%s::%s'\n",
                  reloc.module_path ? reloc.module_path : "<unknown>",
                  reloc.symbol_name ? reloc.symbol_name : "<unknown>");
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        if (reloc.kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32) {
          if (final_off + 4 > out->code_len) {
            free(string_map);
            free(native_map);
            vm_object_free(out);
            return false;
          }
          write_u32_le_at(out->code, final_off, resolved_idx);
        } else {
          if (final_off + 8 > out->code_len) {
            free(string_map);
            free(native_map);
            vm_object_free(out);
            return false;
          }
          write_u64_le_at(out->code, final_off, resolved_idx);
        }
      } else if (reloc.kind == MORPHL_VM_RELOC_GLOBAL_DATA_I32) {
        if (final_off + 4 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u32_le_at(out->code, final_off,
                        read_u32_le_at(out->code, final_off) +
                            objects[i].global_data_delta);
      } else if (reloc.kind == MORPHL_VM_RELOC_GLOBAL_DATA_I64) {
        if (final_off + 8 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u64_le_at(out->code, final_off,
                        read_u64_le_at(out->code, final_off) +
                            objects[i].global_data_delta);
      } else if (reloc.kind == MORPHL_VM_RELOC_MODULE_FRAME_BASE_I64) {
        if (final_off + 8 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u64_le_at(out->code, final_off,
                        read_u64_le_at(out->code, final_off) +
                            (out->global_frame_size -
                             obj->global_frame_size));
      } else if (reloc.kind == MORPHL_VM_RELOC_EXTERN_DATA_I32) {
        uint32_t resolved_off = UINT32_MAX;
        if (!resolve_exported_data_offset(objects, object_count,
                                          reloc.module_path,
                                          reloc.symbol_name,
                                          &resolved_off)) {
          fprintf(err ? err : stderr,
                  "mpll: unresolved external data '%s::%s'\n",
                  reloc.module_path ? reloc.module_path : "<unknown>",
                  reloc.symbol_name ? reloc.symbol_name : "<unknown>");
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        if (final_off + 4 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u32_le_at(out->code, final_off, resolved_off);
      } else if (reloc.kind == MORPHL_VM_RELOC_MODULE_SLOT_I32) {
        uint32_t resolved_off = UINT32_MAX;
        if (!resolve_module_slot_offset(objects, object_count,
                                        reloc.module_path, &resolved_off)) {
          fprintf(err ? err : stderr,
                  "mpll: unresolved module slot '%s'\n",
                  reloc.module_path ? reloc.module_path : "<unknown>");
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        if (final_off + 4 > out->code_len) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        write_u32_le_at(out->code, final_off, resolved_off);
      }
    }

    for (uint32_t fidx = 0; fidx < obj->func_count; ++fidx) {
      VmFunctionMeta fn = obj->functions[fidx];
      if (fn.flags & MORPHL_FUNC_FLAG_NATIVE) {
        if (fn.entry_point >= obj->native_sym_count) {
          free(string_map);
          free(native_map);
          vm_object_free(out);
          return false;
        }
        fn.entry_point = native_map[fn.entry_point];
      } else {
        fn.entry_point += code_base;
      }
      out->functions[func_base + fidx] = fn;
    }

    free(string_map);
    free(native_map);
  }

  {
    uint32_t wrapper_entry = out->code_len;
    size_t wrapper_cap = 1 + 1 + 8 + 1 + 4 +
                         object_count * (1 + 1 + 8 + 1 + 4) +
                         object_count * (1 + 4 + 1 + 4) + 1;
    uint8_t* wrapper = (uint8_t*)malloc(wrapper_cap);
    size_t wp = 0;
    bool saw_root = false;
    if (!wrapper) {
      vm_object_free(out);
      return false;
    }
    for (size_t i = 0; i < object_count; ++i) {
      if (objects[i].image.module_path && root_module_path &&
          strcmp(objects[i].image.module_path, root_module_path) == 0) {
        saw_root = true;
        break;
      }
    }
    if (!saw_root) {
      fprintf(err ? err : stderr,
              "mpll: internal error: root module '%s' missing from linked image\n",
              root_module_path ? root_module_path : "<unknown>");
      free(wrapper);
      vm_object_free(out);
      return false;
    }
    wrapper[wp++] = VM_OP_GLOBAL;
    wrapper[wp++] = VM_OP_ICONST;
    write_u64_le_at(wrapper, (uint32_t)wp, out->global_frame_size);
    wp += 8;
    wrapper[wp++] = VM_OP_ASTORE;
    write_u32_le_at(wrapper, (uint32_t)wp, 24);
    wp += 4;
    for (size_t i = 0; i < object_count; ++i) {
      uint32_t module_base = objects[i].global_data_delta + 32;
      wrapper[wp++] = VM_OP_GLOBAL;
      wrapper[wp++] = VM_OP_ICONST;
      write_u64_le_at(wrapper, (uint32_t)wp, module_base);
      wp += 8;
      wrapper[wp++] = VM_OP_ASTORE;
      write_u32_le_at(wrapper, (uint32_t)wp, objects[i].module_slot_offset);
      wp += 4;
    }
    for (size_t i = 0; i < object_count; ++i) {
      uint32_t init_idx = objects[i].func_base + objects[i].image.module_init_func_idx;
      wrapper[wp++] = VM_OP_RESERVE;
      write_u32_le_at(wrapper, (uint32_t)wp, 8);
      wp += 4;
      wrapper[wp++] = VM_OP_CALL;
      write_u32_le_at(wrapper, (uint32_t)wp, init_idx);
      wp += 4;
    }
    wrapper[wp++] = VM_OP_HALT;

    uint8_t* grown = (uint8_t*)realloc(out->code, out->code_len + wp);
    if (!grown) {
      free(wrapper);
      vm_object_free(out);
      return false;
    }
    out->code = grown;
    memcpy(out->code + out->code_len, wrapper, wp);
    free(wrapper);
    out->code_len += (uint32_t)wp;
    out->functions[0].entry_point = wrapper_entry;
    out->functions[0].frame_size = 0;
    out->functions[0].param_size = 0;
    out->functions[0].flags = 0;
  }

  return true;
}

static ptrdiff_t find_object_index_by_module_path(const VmObjectFile* objects,
                                                  size_t object_count,
                                                  const char* module_path) {
  if (!objects || !module_path) return -1;
  for (size_t i = 0; i < object_count; ++i) {
    if (objects[i].module_path &&
        strcmp(objects[i].module_path, module_path) == 0) {
      return (ptrdiff_t)i;
    }
  }
  return -1;
}

static bool object_has_exported_function(const VmObjectFile* obj,
                                         const char* func_name) {
  if (!obj || !func_name) return false;
  for (uint32_t i = 0; i < obj->export_count; ++i) {
    if (obj->exports[i].kind != MORPHL_VM_EXPORT_FUNCTION ||
        !obj->exports[i].name) {
      continue;
    }
    if (strcmp(obj->exports[i].name, func_name) == 0) return true;
  }
  return false;
}

static bool resolve_exported_function_index(const LinkedObject* objects,
                                            size_t object_count,
                                            const char* module_path,
                                            const char* func_name,
                                            uint32_t* out) {
  if (!objects || !module_path || !func_name || !out) return false;
  for (size_t i = 0; i < object_count; ++i) {
    const VmObjectFile* obj = &objects[i].image;
    if (!obj->module_path || strcmp(obj->module_path, module_path) != 0)
      continue;
    for (uint32_t ei = 0; ei < obj->export_count; ++ei) {
      if (obj->exports[ei].kind != MORPHL_VM_EXPORT_FUNCTION ||
          !obj->exports[ei].name)
        continue;
      if (strcmp(obj->exports[ei].name, func_name) == 0) {
        *out = objects[i].func_base + obj->exports[ei].symbol_value;
        return true;
      }
    }
  }
  return false;
}

static bool resolve_exported_data_offset(const LinkedObject* objects,
                                         size_t object_count,
                                         const char* module_path,
                                         const char* symbol_name,
                                         uint32_t* out) {
  if (!objects || !module_path || !symbol_name || !out) return false;
  for (size_t i = 0; i < object_count; ++i) {
    const VmObjectFile* obj = &objects[i].image;
    if (!obj->module_path || strcmp(obj->module_path, module_path) != 0)
      continue;
    for (uint32_t ei = 0; ei < obj->export_count; ++ei) {
      if (!(obj->exports[ei].flags & MORPHL_VM_EXPORT_FLAG_STATIC) ||
          !obj->exports[ei].name) {
        continue;
      }
      if (strcmp(obj->exports[ei].name, symbol_name) == 0) {
        *out = objects[i].global_data_delta + obj->exports[ei].symbol_value;
        return true;
      }
    }
  }
  return false;
}

static bool resolve_module_slot_offset(const LinkedObject* objects,
                                       size_t object_count,
                                       const char* module_path,
                                       uint32_t* out) {
  if (!objects || !module_path || !out) return false;
  for (size_t i = 0; i < object_count; ++i) {
    if (!objects[i].image.module_path ||
        strcmp(objects[i].image.module_path, module_path) != 0) {
      continue;
    }
    *out = objects[i].module_slot_offset;
    return true;
  }
  return false;
}

static bool topo_visit_modules(const VmObjectFile* objects, size_t object_count,
                               const bool* reachable, size_t idx,
                               uint8_t* marks, size_t* order,
                               size_t* order_count, FILE* err) {
  if (!objects || !reachable || !marks || !order || !order_count) return false;
  if (!reachable[idx]) return true;
  if (marks[idx] == 2) return true;
  if (marks[idx] == 1) {
    fprintf(err ? err : stderr,
            "mpll: cyclic module dependency involving '%s'\n",
            objects[idx].module_path ? objects[idx].module_path : "<unknown>");
    return false;
  }
  marks[idx] = 1;
  for (uint32_t i = 0; i < objects[idx].import_count; ++i) {
    const char* import_path = objects[idx].imports[i].path;
    ptrdiff_t dep_idx =
        find_object_index_by_module_path(objects, object_count, import_path);
    if (dep_idx < 0) continue;
    if (!topo_visit_modules(objects, object_count, reachable, (size_t)dep_idx,
                            marks, order, order_count, err)) {
      return false;
    }
  }
  marks[idx] = 2;
  order[(*order_count)++] = idx;
  return true;
}

bool morphl_vm_link_files(const char* out_path, const char* const* input_paths,
                          size_t input_count, FILE* err_stream) {
  if (!out_path || !input_paths || input_count == 0) return false;

  VmObjectFile* unique_objects =
      (VmObjectFile*)calloc(input_count, sizeof(VmObjectFile));
  bool* reachable = (bool*)calloc(input_count, sizeof(bool));
  if (!unique_objects || !reachable) {
    free(unique_objects);
    free(reachable);
    return false;
  }
  size_t unique_count = 0;

  for (size_t i = 0; i < input_count; ++i) {
    VmObjectFile obj = {0};
    if (!vm_object_load(input_paths[i], &obj, err_stream)) {
      for (size_t j = 0; j < unique_count; ++j) vm_object_free(&unique_objects[j]);
      free(unique_objects);
      free(reachable);
      return false;
    }
    bool duplicate = false;
    for (size_t j = 0; j < unique_count; ++j) {
      if (unique_objects[j].module_path && obj.module_path &&
          strcmp(unique_objects[j].module_path, obj.module_path) == 0) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      vm_object_free(&obj);
      continue;
    }
    unique_objects[unique_count++] = obj;
  }

  bool ok = (unique_count > 0);
  if (ok) {
    reachable[0] = true;
    bool changed = true;
    while (changed) {
      changed = false;
      for (size_t i = 0; i < unique_count; ++i) {
        if (!reachable[i]) continue;
        for (uint32_t ii = 0; ii < unique_objects[i].import_count; ++ii) {
          const char* import_path = unique_objects[i].imports[ii].path;
          for (size_t j = 0; j < unique_count; ++j) {
            if (reachable[j] || !unique_objects[j].module_path || !import_path)
              continue;
            if (strcmp(unique_objects[j].module_path, import_path) == 0) {
              reachable[j] = true;
              changed = true;
            }
          }
        }
      }
    }

    for (size_t i = 0; i < unique_count && ok; ++i) {
      if (!reachable[i]) continue;
      for (uint32_t ii = 0; ii < unique_objects[i].import_count; ++ii) {
        const char* import_path = unique_objects[i].imports[ii].path;
        ptrdiff_t dep_idx = -1;
        bool found = false;
        for (size_t j = 0; j < unique_count; ++j) {
          if (!unique_objects[j].module_path || !import_path) continue;
          if (strcmp(unique_objects[j].module_path, import_path) == 0) {
            found = true;
            dep_idx = (ptrdiff_t)j;
            break;
          }
        }
        if (!found) {
          fprintf(err_stream ? err_stream : stderr,
                  "mpll: missing object for imported module '%s' required by '%s'\n",
                  import_path ? import_path : "<unknown>",
                  unique_objects[i].module_path ? unique_objects[i].module_path
                                                : "<unknown>");
          ok = false;
          break;
        }
        for (uint32_t fi = 0; fi < unique_objects[i].imports[ii].required_func_count; ++fi) {
          const char* func_name = unique_objects[i].imports[ii].required_funcs[fi];
          if (!object_has_exported_function(&unique_objects[dep_idx], func_name)) {
            fprintf(err_stream ? err_stream : stderr,
                    "mpll: module '%s' required by '%s' does not export function '%s'\n",
                    import_path ? import_path : "<unknown>",
                    unique_objects[i].module_path ? unique_objects[i].module_path
                                                  : "<unknown>",
                    func_name ? func_name : "<unknown>");
            ok = false;
            break;
          }
        }
        if (!ok) break;
      }
    }

    for (size_t i = 1; i < unique_count; ++i) {
      if (!reachable[i]) {
        fprintf(err_stream ? err_stream : stderr,
                "mpll: unrelated object '%s' is not reachable from root module '%s'\n",
                unique_objects[i].module_path ? unique_objects[i].module_path
                                              : "<unknown>",
                unique_objects[0].module_path ? unique_objects[0].module_path
                                              : "<unknown>");
        ok = false;
        break;
      }
    }
  }

  if (ok) {
    size_t linked_count = 0;
    for (size_t i = 0; i < unique_count; ++i) {
      if (reachable[i]) linked_count++;
    }
    size_t* topo_order = (size_t*)calloc(linked_count, sizeof(size_t));
    uint8_t* topo_marks = (uint8_t*)calloc(unique_count, sizeof(uint8_t));
    LinkedObject* linked =
        (LinkedObject*)calloc(linked_count, sizeof(LinkedObject));
    VmObjectFile merged = {0};
    if (!linked || !topo_order || !topo_marks) {
      ok = false;
    } else {
      size_t order_count = 0;
      ok = topo_visit_modules(unique_objects, unique_count, reachable, 0,
                              topo_marks, topo_order, &order_count,
                              err_stream);
      if (ok && order_count != linked_count) {
        fprintf(err_stream ? err_stream : stderr,
                "mpll: internal error building module order\n");
        ok = false;
      }
      for (size_t i = 0; ok && i < linked_count; ++i) {
        linked[i].image = unique_objects[topo_order[i]];
      }
      ok = build_linked_image(&merged, linked, linked_count,
                              unique_objects[0].module_path, err_stream) &&
           vm_executable_write_from_object(out_path, &merged, err_stream);
      vm_object_free(&merged);
    }
    free(linked);
    free(topo_order);
    free(topo_marks);
  }

  for (size_t i = 0; i < unique_count; ++i) vm_object_free(&unique_objects[i]);
  free(unique_objects);
  free(reachable);
  return ok;
}
