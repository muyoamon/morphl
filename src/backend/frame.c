
#include "ast/ast.h"
#include "util/error.h"
#include "util/util.h"
#include <backend/frame.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FRAME_INITIAL_OFFSETS_CAPACITY 10

static bool _realloc_offsets(struct MorphlBackendFrame* frame) {
  size_t new_capacity = frame->offset_capacity * 2;
  void* temp = realloc(frame->offsets,
                       sizeof(struct MorphlBackendFrameOffset) * new_capacity);
  if (temp != NULL) {
    frame->offsets = temp;
    frame->offset_capacity = new_capacity;
    return true;
  } else {
    return false;
  }
}

// Create New frame
static struct MorphlBackendFrame * _new_frame() {
  struct MorphlBackendFrame* ptr = malloc(sizeof(struct MorphlBackendFrame));
  if (ptr == NULL) {
    return NULL;
  }
  ptr->child = NULL;
  ptr->parent = NULL;

  ptr->offsets = (struct MorphlBackendFrameOffset *)malloc(
      sizeof(struct MorphlBackendFrameOffset) *
      FRAME_INITIAL_OFFSETS_CAPACITY);
  ptr->offset_count = 0;
  ptr->offset_capacity = FRAME_INITIAL_OFFSETS_CAPACITY;
  
  return ptr;
}

MorphlBackendFrameInfo morphl_backend_frame_init() {
  MorphlBackendFrameInfo frameInfo = {NULL, NULL};
  frameInfo.root = _new_frame();
  frameInfo.current = frameInfo.root;
  return frameInfo;
}

static void _free_frame(struct MorphlBackendFrame *frame) {
  if (frame == NULL) {
    return;
  }
  _free_frame(frame->child);
  free(frame->offsets);
  memset(frame, 0, sizeof(*frame));
}

void morphl_backend_frame_free(MorphlBackendFrameInfo *ptr) {
  _free_frame(ptr->root);
  ptr->current = NULL;
  ptr->root = NULL;
}



/**
 * @brief Get current frame offset
 *
 * @param[in] frameInfo pointer to frame info
 */
struct MorphlBackendFrameOffset *
morphl_backend_get_offset(MorphlBackendFrameInfo *frameInfo) {
  return frameInfo->current->offsets;
}

bool morphl_backend_push_frame(MorphlBackendFrameInfo *frameInfo) {
  struct MorphlBackendFrame* new_frame = _new_frame();
  
  if (new_frame == NULL) {
    return false;
  }

  frameInfo->current->child = new_frame;
  new_frame->parent = frameInfo->current;
  frameInfo->current = new_frame;

  return true;
}

bool morphl_backend_pop_frame(MorphlBackendFrameInfo *frameInfo) {
  struct MorphlBackendFrame* toPop = frameInfo->current;

  frameInfo->current = toPop->parent;
  _free_frame(toPop);
  return true;
}


bool morphl_backend_append_offset(MorphlBackendFrameInfo* frameInfo, struct MorphlBackendFrameOffset offset) {
  if (frameInfo->current->offset_count >= frameInfo->current->offset_capacity) {
    if (!_realloc_offsets(frameInfo->current)) {
      return false;
    }
  }
  struct MorphlBackendFrameOffset* dest =
    frameInfo->current->offsets + frameInfo->current->offset_count;
  *dest = offset;
  frameInfo->current->offset_count++;
  return true;
}


ptrdiff_t morphl_backend_find_offset(MorphlBackendFrameInfo* frameInfo, Str name) {
  ptrdiff_t diff = 0;
  // current frame
  struct MorphlBackendFrame* frame = frameInfo->current;
  // find forward first
  for (size_t i = 0; i < frame->offset_count; i++) {
    if (str_eq(name, frame->offsets[i].name)) {
      return diff;
    }
    diff += frame->offsets[i].size;
  }


  // Not found; find backward through parent frames
  diff = 0;
  frame = frame->parent;
  while (frame != NULL) {
    for (size_t i = frame->offset_count; i != 0; i--) {
      diff -= (ptrdiff_t)frame->offsets[i-1].size;
      if (str_eq(name, frame->offsets[i-1].name)) {
        return diff;
      }
    }
    frame = frame->parent;
  }
  return PTRDIFF_MAX;
}
