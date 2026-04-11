#include <assert.h>
#include <cstdio>
#include <cstring>
#include <climits>

extern "C" {
#include "backend/frame.h"
#include "util/util.h"
}

static Str make_str(const char* s) {
    Str r;
    r.ptr = s;
    r.len = strlen(s);
    return r;
}

static struct MorphlBackendFrameOffset make_off(const char* name, size_t size) {
    struct MorphlBackendFrameOffset o;
    o.name = make_str(name);
    o.size = size;
    return o;
}

// ── Tests ────────────────────────────────────────────────────────────────────

static void test_frame_init_free() {
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(fi.root    != NULL);
    assert(fi.current != NULL);
    assert(fi.root == fi.current);
    assert(fi.current->offset_count == 0);
    morphl_backend_frame_free(&fi);
    assert(fi.root    == NULL);
    assert(fi.current == NULL);
    printf("PASS test_frame_init_free\n");
}

static void test_frame_append_find_single() {
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(morphl_backend_append_offset(&fi, make_off("x", 8)));
    ptrdiff_t off = morphl_backend_find_offset(&fi, make_str("x"));
    assert(off == 0);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_append_find_single\n");
}

static void test_frame_append_find_multiple() {
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(morphl_backend_append_offset(&fi, make_off("x", 8)));
    assert(morphl_backend_append_offset(&fi, make_off("y", 8)));
    assert(morphl_backend_append_offset(&fi, make_off("z", 4)));
    assert(morphl_backend_find_offset(&fi, make_str("x")) == 0);
    assert(morphl_backend_find_offset(&fi, make_str("y")) == 8);
    assert(morphl_backend_find_offset(&fi, make_str("z")) == 16);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_append_find_multiple\n");
}

static void test_frame_find_not_found() {
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(morphl_backend_append_offset(&fi, make_off("x", 8)));
    assert(morphl_backend_find_offset(&fi, make_str("y")) == PTRDIFF_MAX);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_find_not_found\n");
}

static void test_frame_push_pop() {
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    struct MorphlBackendFrame* root = fi.root;
    assert(morphl_backend_push_frame(&fi));
    assert(fi.current != root);
    assert(fi.current->parent == root);
    morphl_backend_pop_frame(&fi);
    assert(fi.current == root);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_push_pop\n");
}

static void test_frame_find_in_parent() {
    // Parent has "x" at offset 0 (size 8).
    // After pushing child frame, find_offset("x") should return a negative offset.
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(morphl_backend_append_offset(&fi, make_off("x", 8)));
    assert(morphl_backend_push_frame(&fi));
    // In the child frame, "x" is behind us — negative offset
    ptrdiff_t off = morphl_backend_find_offset(&fi, make_str("x"));
    assert(off < 0);
    morphl_backend_pop_frame(&fi);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_find_in_parent\n");
}

static void test_frame_nested_scopes() {
    // 3 levels: root has "a"(8), child1 has "b"(8), child2 has "c"(8)
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    assert(morphl_backend_append_offset(&fi, make_off("a", 8)));

    assert(morphl_backend_push_frame(&fi));
    assert(morphl_backend_append_offset(&fi, make_off("b", 8)));

    assert(morphl_backend_push_frame(&fi));
    assert(morphl_backend_append_offset(&fi, make_off("c", 8)));

    // In child2 frame: "c" found at 0 (current frame)
    assert(morphl_backend_find_offset(&fi, make_str("c")) == 0);
    // "b" and "a" found at negative offsets
    assert(morphl_backend_find_offset(&fi, make_str("b")) < 0);
    assert(morphl_backend_find_offset(&fi, make_str("a")) < 0);
    // "b" is closer than "a"
    assert(morphl_backend_find_offset(&fi, make_str("b")) >
           morphl_backend_find_offset(&fi, make_str("a")));

    morphl_backend_pop_frame(&fi);
    morphl_backend_pop_frame(&fi);
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_nested_scopes\n");
}

static void test_frame_capacity_growth() {
    // Append more than the initial capacity (10) to trigger realloc
    MorphlBackendFrameInfo fi = morphl_backend_frame_init();
    char names[20][8];
    for (int i = 0; i < 20; i++) {
        snprintf(names[i], sizeof(names[i]), "v%d", i);
        assert(morphl_backend_append_offset(&fi, make_off(names[i], 8)));
    }
    // Verify all are found at correct cumulative offsets
    for (int i = 0; i < 20; i++) {
        ptrdiff_t expected = (ptrdiff_t)(i * 8);
        ptrdiff_t got = morphl_backend_find_offset(&fi, make_str(names[i]));
        assert(got == expected);
    }
    morphl_backend_frame_free(&fi);
    printf("PASS test_frame_capacity_growth\n");
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(void) {
    test_frame_init_free();
    test_frame_append_find_single();
    test_frame_append_find_multiple();
    test_frame_find_not_found();
    test_frame_push_pop();
    test_frame_find_in_parent();
    test_frame_nested_scopes();
    test_frame_capacity_growth();
    printf("All frame tests passed.\n");
    return 0;
}
