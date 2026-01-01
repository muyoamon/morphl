#include "ast/ast.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static bool ensure_child_capacity(AstNode* node, size_t needed) {
  if (node->child_capacity >= needed) return true;
  size_t new_cap = node->child_capacity ? node->child_capacity * 2 : 4;
  while (new_cap < needed) new_cap *= 2;
  AstNode** resized = (AstNode**)realloc(node->children, new_cap * sizeof(AstNode*));
  if (!resized) return false;
  node->children = resized;
  node->child_capacity = new_cap;
  return true;
}

AstNode* ast_new(AstKind kind) {
  AstNode* n = (AstNode*)calloc(1, sizeof(AstNode));
  if (!n) return NULL;
  n->kind = kind;
  return n;
}

AstNode* ast_make_leaf(AstKind kind, Str value, const char* filename, size_t row, size_t col) {
  AstNode* n = ast_new(kind);
  if (!n) return NULL;
  n->value = value;
  n->filename = filename;
  n->row = row;
  n->col = col;
  return n;
}

bool ast_append_child(AstNode* node, AstNode* child) {
  if (!node || !child) return false;
  if (!ensure_child_capacity(node, node->child_count + 1)) return false;
  node->children[node->child_count++] = child;
  return true;
}

void ast_free(AstNode* node) {
  if (!node) return;
  for (size_t i = 0; i < node->child_count; ++i) {
    ast_free(node->children[i]);
  }
  free(node->children);
  free(node);
}

static const char* kind_name(AstKind kind) {
  switch (kind) {
    case AST_LITERAL: return "literal";
    case AST_IDENT: return "ident";
    case AST_CALL: return "call";
    case AST_FUNC: return "func";
    case AST_IF: return "if";
    case AST_BLOCK: return "block";
    case AST_GROUP: return "group";
    case AST_DECL: return "decl";
    case AST_SET: return "set";
    case AST_BUILTIN: return "builtin";
    case AST_OVERLOAD: return "overload";
    case AST_UNKNOWN: return "unknown";
  }
  return "unknown";
}

static void print_indent(size_t depth) {
  for (size_t i = 0; i < depth; ++i) {
    fputs("  ", stdout);
  }
}

static void print_str(Str s) {
  if (s.ptr && s.len > 0) {
    fwrite(s.ptr, 1, s.len, stdout);
  }
}

static void ast_print_impl(const AstNode* node, InternTable* interns, size_t depth) {
  if (!node) return;
  print_indent(depth);
  fputs(kind_name(node->kind), stdout);

  switch (node->kind) {
    case AST_BUILTIN: {
      if (interns && node->op) {
        Str name = interns_lookup(interns, node->op);
        if (name.ptr) {
          fputs(" (", stdout);
          print_str(name);
          fputs(")", stdout);
          break;
        }
      }
      fprintf(stdout, " (op=%u)", (unsigned)node->op);
      break;
    }
    case AST_LITERAL:
    case AST_IDENT:
      fputs(" ", stdout);
      print_str(node->value);
      break;
    default:
      break;
  }

  if (node->child_count == 0) {
    fputc('\n', stdout);
    return;
  }

  fputs("\n", stdout);
  for (size_t i = 0; i < node->child_count; ++i) {
    ast_print_impl(node->children[i], interns, depth + 1);
  }
}

void ast_print(const AstNode* node, InternTable* interns) {
  ast_print_impl(node, interns, 0);
}
