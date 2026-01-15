

#include "backend/backend.h"

extern bool morphl_backend_func_c(MorphlBackendContext* context);

static MorphlBackendFunc registered_backend = NULL;


bool morphl_register_backend(enum MorphlBackendType type) {
    switch (type) {
        case MORPHL_BACKEND_TYPE_C:
            // Register the C backend
            registered_backend = morphl_backend_func_c;
            return true;
        default:
            return false;
    }
}


bool morphl_compile(MorphlBackendContext* context) {
    if (registered_backend == NULL) {
        // fallback to C backend if none registered
        registered_backend = morphl_backend_func_c;
    }
    return registered_backend(context);
}