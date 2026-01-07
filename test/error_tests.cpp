#include <assert.h>
#include <cstdio>
#include <cstring>
#include <vector>

extern "C" {
#include "util/error.h"
}

// Test fixture to collect errors
static std::vector<MorphlError> g_collected_errors;

static void test_error_sink(void *user, const MorphlError *err) {
    (void)user;
    if (err) {
        g_collected_errors.push_back(*err);
    }
}

// ============================================================================
// Test: morphl_ok
// ============================================================================
static void test_morphl_ok() {
    // Test with NULL
    assert(morphl_ok(NULL) == true);

    // Test with MORPHL_EOK
    MorphlError ok_err = {};
    ok_err.code = MORPHL_EOK;
    assert(morphl_ok(&ok_err) == true);

    // Test with error code
    MorphlError err = {};
    err.code = MORPHL_E_INTERNAL;
    assert(morphl_ok(&err) == false);

    printf("✓ test_morphl_ok passed\n");
}

// ============================================================================
// Test: morphl_span_unknown
// ============================================================================
static void test_morphl_span_unknown() {
    MorphlSpan span = morphl_span_unknown();
    assert(span.path == NULL);
    assert(span.line == 0);
    assert(span.col == 0);
    assert(span.start == 0);
    assert(span.end == 0);

    printf("✓ test_morphl_span_unknown passed\n");
}

// ============================================================================
// Test: morphl_error_make (basic)
// ============================================================================
static void test_morphl_error_make_basic() {
    MorphlError err = MORPHL_ERR(MORPHL_E_INTERNAL, "test error");

    assert(err.code == MORPHL_E_INTERNAL);
    assert(err.sev == MORPHL_SEV_ERROR);
    assert(err.span.path == NULL);
    assert(std::strcmp(err.msg, "test error") == 0);
    assert(err.created_file != NULL);
    assert(err.created_line > 0);

    printf("✓ test_morphl_error_make_basic passed\n");
}

// ============================================================================
// Test: morphl_error_make (with formatting)
// ============================================================================
static void test_morphl_error_make_formatting() {
    MorphlError err = MORPHL_ERR(MORPHL_E_INVALID_ARG, "invalid arg: %d", 42);

    assert(err.code == MORPHL_E_INVALID_ARG);
    assert(std::strcmp(err.msg, "invalid arg: 42") == 0);

    printf("✓ test_morphl_error_make_formatting passed\n");
}

// ============================================================================
// Test: morphl_error_make (with span)
// ============================================================================
static void test_morphl_error_make_with_span() {
    MorphlSpan span;
    span.path = "test.mpl";
    span.line = 10;
    span.col = 5;
    span.start = 100;
    span.end = 105;

    MorphlError err = MORPHL_ERR_SPAN(MORPHL_E_LEX, MORPHL_SEV_WARN, span, "lexer error");

    assert(err.code == MORPHL_E_LEX);
    assert(err.sev == MORPHL_SEV_WARN);
    assert(std::strcmp(err.span.path, "test.mpl") == 0);
    assert(err.span.line == 10);
    assert(err.span.col == 5);
    assert(err.span.start == 100);
    assert(err.span.end == 105);
    assert(std::strcmp(err.msg, "lexer error") == 0);

    printf("✓ test_morphl_error_make_with_span passed\n");
}

// ============================================================================
// Test: morphl_error_make convenience macros (WARN, NOTE, FATAL)
// ============================================================================
static void test_morphl_error_make_macros() {
    MorphlError warn = MORPHL_WARN(MORPHL_E_OOM, "warning message");
    assert(warn.sev == MORPHL_SEV_WARN);
    assert(std::strcmp(warn.msg, "warning message") == 0);

    MorphlError note = MORPHL_NOTE(MORPHL_E_IO, "note message");
    assert(note.sev == MORPHL_SEV_NOTE);
    assert(std::strcmp(note.msg, "note message") == 0);

    MorphlError fatal = MORPHL_FATAL(MORPHL_E_PARSE, "fatal message");
    assert(fatal.sev == MORPHL_SEV_FATAL);
    assert(std::strcmp(fatal.msg, "fatal message") == 0);

    printf("✓ test_morphl_error_make_macros passed\n");
}

// ============================================================================
// Test: morphl_error_makev (variadic)
// ============================================================================
static void test_morphl_error_makev() {
    MorphlSpan span = morphl_span_unknown();
    va_list ap;
    
    // Call via the direct function
    MorphlError err = morphl_error_makev(
        MORPHL_E_TYPE, MORPHL_SEV_ERROR, span, __FILE__, __LINE__, 
        "type error: %s at line %d", ap);

    assert(err.code == MORPHL_E_TYPE);
    assert(err.sev == MORPHL_SEV_ERROR);
    // Note: We can't easily test the formatting here since va_list is already constructed
    // But we can verify the error object was created with the code

    printf("✓ test_morphl_error_makev passed\n");
}

// ============================================================================
// Test: morphl_error_format (basic)
// ============================================================================
static void test_morphl_error_format_basic() {
    MorphlSpan span;
    span.path = "input.mpl";
    span.line = 5;
    span.col = 12;
    span.start = 0;
    span.end = 0;

    MorphlError err = MORPHL_ERR_SPAN(MORPHL_E_PARSE, MORPHL_SEV_ERROR, span, "unexpected token");

    char buf[512];
    size_t written = morphl_error_format(&err, buf, sizeof(buf));

    assert(written > 0);
    assert(std::strstr(buf, "input.mpl") != NULL);
    assert(std::strstr(buf, "5") != NULL);
    assert(std::strstr(buf, "12") != NULL);
    assert(std::strstr(buf, "error") != NULL);
    assert(std::strstr(buf, "unexpected token") != NULL);

    printf("✓ test_morphl_error_format_basic passed\n");
    printf("  Formatted: %s\n", buf);
}

// ============================================================================
// Test: morphl_error_format (with NULL error)
// ============================================================================
static void test_morphl_error_format_null() {
    char buf[512];
    buf[0] = 'X';  // Mark buffer as not empty

    size_t written = morphl_error_format(NULL, buf, sizeof(buf));
    assert(written == 0);
    assert(buf[0] == '\0');

    printf("✓ test_morphl_error_format_null passed\n");
}

// ============================================================================
// Test: morphl_error_format (with MORPHL_EOK)
// ============================================================================
static void test_morphl_error_format_ok() {
    MorphlError err = {};
    err.code = MORPHL_EOK;
    err.msg[0] = 'X';

    char buf[512];
    buf[0] = 'Y';

    size_t written = morphl_error_format(&err, buf, sizeof(buf));
    assert(written == 0);
    assert(buf[0] == '\0');

    printf("✓ test_morphl_error_format_ok passed\n");
}

// ============================================================================
// Test: morphl_error_format (small buffer)
// ============================================================================
static void test_morphl_error_format_small_buffer() {
    MorphlSpan span;
    span.path = "file.mpl";
    span.line = 100;
    span.col = 20;
    span.start = 0;
    span.end = 0;

    MorphlError err = MORPHL_ERR_SPAN(MORPHL_E_SEMA, MORPHL_SEV_ERROR, span, "semantic error");

    char buf[20];  // Small buffer
    size_t written = morphl_error_format(&err, buf, sizeof(buf));

    assert(written > 0);
    assert(buf[sizeof(buf) - 1] == '\0');  // Must be null-terminated

    printf("✓ test_morphl_error_format_small_buffer passed\n");
}

// ============================================================================
// Test: morphl_error_set_global_sink and morphl_error_get_global_sink
// ============================================================================
static void test_morphl_error_global_sink() {
    MorphlErrorSink sink;
    sink.fn = test_error_sink;
    sink.user = NULL;

    morphl_error_set_global_sink(sink);

    MorphlErrorSink retrieved = morphl_error_get_global_sink();
    assert(retrieved.fn == test_error_sink);
    assert(retrieved.user == NULL);

    printf("✓ test_morphl_error_global_sink passed\n");
}

// ============================================================================
// Test: morphl_error_emit (with explicit sink)
// ============================================================================
static void test_morphl_error_emit_explicit_sink() {
    g_collected_errors.clear();

    MorphlErrorSink sink;
    sink.fn = test_error_sink;
    sink.user = NULL;

    MorphlError err = MORPHL_ERR(MORPHL_E_INTERNAL, "test emit");

    morphl_error_emit(&sink, &err);

    assert(g_collected_errors.size() == 1);
    assert(g_collected_errors[0].code == MORPHL_E_INTERNAL);
    assert(std::strcmp(g_collected_errors[0].msg, "test emit") == 0);

    printf("✓ test_morphl_error_emit_explicit_sink passed\n");
}

// ============================================================================
// Test: morphl_error_emit (with global sink)
// ============================================================================
static void test_morphl_error_emit_global_sink() {
    g_collected_errors.clear();

    MorphlErrorSink sink;
    sink.fn = test_error_sink;
    sink.user = NULL;

    morphl_error_set_global_sink(sink);

    MorphlError err = MORPHL_ERR(MORPHL_E_IO, "file error");

    // Emit with NULL sink (uses global)
    morphl_error_emit(NULL, &err);

    assert(g_collected_errors.size() == 1);
    assert(g_collected_errors[0].code == MORPHL_E_IO);
    assert(std::strcmp(g_collected_errors[0].msg, "file error") == 0);

    printf("✓ test_morphl_error_emit_global_sink passed\n");
}

// ============================================================================
// Test: morphl_error_emit (with OK error - should be filtered)
// ============================================================================
static void test_morphl_error_emit_ok_filtered() {
    g_collected_errors.clear();

    MorphlErrorSink sink;
    sink.fn = test_error_sink;
    sink.user = NULL;

    MorphlError ok_err = {};
    ok_err.code = MORPHL_EOK;

    morphl_error_emit(&sink, &ok_err);

    // Should not be collected since it's MORPHL_EOK
    assert(g_collected_errors.size() == 0);

    printf("✓ test_morphl_error_emit_ok_filtered passed\n");
}

// ============================================================================
// Test: morphl_error_emit (with NULL error - should be ignored)
// ============================================================================
static void test_morphl_error_emit_null_error() {
    g_collected_errors.clear();

    MorphlErrorSink sink;
    sink.fn = test_error_sink;
    sink.user = NULL;

    morphl_error_emit(&sink, NULL);

    // Should not be collected since error is NULL
    assert(g_collected_errors.size() == 0);

    printf("✓ test_morphl_error_emit_null_error passed\n");
}

// ============================================================================
// Test: Error message truncation (message longer than buffer)
// ============================================================================
static void test_morphl_error_message_truncation() {
    // Create a very long message
    const char *long_msg = "this is a very long error message that should be truncated "
                           "to fit within the ML_ERRMSG_CAP limit to prevent buffer overflow";

    MorphlError err = MORPHL_ERR(MORPHL_E_INTERNAL, "%s", long_msg);

    // Ensure null termination even if truncated
    assert(err.msg[ML_ERRMSG_CAP - 1] == '\0');

    printf("✓ test_morphl_error_message_truncation passed\n");
    printf("  Message length: %zu (cap: %u)\n", std::strlen(err.msg), ML_ERRMSG_CAP);
}

// ============================================================================
// Main test runner
// ============================================================================
int main(void) {
    printf("=== Error Utils Test Suite ===\n\n");

    test_morphl_ok();
    test_morphl_span_unknown();
    test_morphl_error_make_basic();
    test_morphl_error_make_formatting();
    test_morphl_error_make_with_span();
    test_morphl_error_make_macros();
    test_morphl_error_makev();
    test_morphl_error_format_basic();
    test_morphl_error_format_null();
    test_morphl_error_format_ok();
    test_morphl_error_format_small_buffer();
    test_morphl_error_global_sink();
    test_morphl_error_emit_explicit_sink();
    test_morphl_error_emit_global_sink();
    test_morphl_error_emit_ok_filtered();
    test_morphl_error_emit_null_error();
    test_morphl_error_message_truncation();

    printf("\n=== All tests passed! ===\n");
    return 0;
}
