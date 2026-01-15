#ifndef MORPHL_BACKEND_BACKEND_H_
#define MORPHL_BACKEND_BACKEND_H_

#include <stdbool.h>
#include "ast/ast.h"
#include "util/util.h"

/// @brief Context passed to backend functions
typedef struct {
    AstNode* tree;          ///< The AST to compile
    const char* out_file;   ///< Output file path
} MorphlBackendContext;

enum MorphlBackendType {
    MORPHL_BACKEND_TYPE_C,
};

/// @brief Function pointer type for backend functions, return true on success, false on failure
typedef bool (*MorphlBackendFunc)(MorphlBackendContext* context);

/// @brief Register a backend of the given type
/// @param type The type of backend to register
/// @return true if registration was successful, false otherwise
bool morphl_register_backend(enum MorphlBackendType type);

/// @brief Compile the given context using the set backend
/// @param context The backend context to compile
/// @return true if compilation was successful, false otherwise
bool morphl_compile(MorphlBackendContext* context);

#endif // MORPHL_BACKEND_BACKEND_H_

