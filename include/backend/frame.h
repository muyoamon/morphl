#ifndef MORPHL_BACKEND_FRAME_H_
#define MORPHL_BACKEND_FRAME_H_

#include "util/util.h"
#include <stdbool.h>
#include <stddef.h>

struct MorphlBackendFrameOffset {
  Str name;       // Symbol name 
  size_t size;    // size in bytes
};

struct MorphlBackendFrame {
  struct MorphlBackendFrame* parent;
  struct MorphlBackendFrame* child;

  struct MorphlBackendFrameOffset* offsets;
  size_t offset_count;
  size_t offset_capacity;
};

typedef struct {
  struct MorphlBackendFrame* root;
  struct MorphlBackendFrame* current;
} MorphlBackendFrameInfo;

/** Init/Free */

MorphlBackendFrameInfo morphl_backend_frame_init();

void morphl_backend_frame_free(MorphlBackendFrameInfo* ptr);

/**
 * @brief Get current frame offset
 *
 * @param[in] frameInfo pointer to frame info
 */
struct MorphlBackendFrameOffset* morphl_backend_get_offset(MorphlBackendFrameInfo* frameInfo);

/**
 *
 * Push/Pop
 *
 */

bool morphl_backend_push_frame(MorphlBackendFrameInfo* frameInfo);

bool morphl_backend_pop_frame(MorphlBackendFrameInfo* frameInfo);

/**
 *
 * Add Offset
 *
 */
bool morphl_backend_append_offset(MorphlBackendFrameInfo* frameInfo, struct MorphlBackendFrameOffset offset);



/**
 * @brief find symbol relative to current frame
 *
 * @param[in] frameInfo pointer to frame info
 * @param[in] name symbol name to find
 * @return offset relative to current frame; PTRDIFF_MAX if not found
 */
ptrdiff_t morphl_backend_find_offset(MorphlBackendFrameInfo* frameInfo, Str name);



#endif // MORPHL_BACKEND_FRAME_H_
