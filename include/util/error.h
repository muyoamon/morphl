#ifndef MORPHL_UTIL_ERROR_H_
#define MORPHL_UTIL_ERROR_H_

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ----------------------------
// Severity / categories
// ----------------------------

typedef enum MorphlSeverity {
    MORPHL_SEV_NOTE = 0,
    MORPHL_SEV_WARN = 1,
    MORPHL_SEV_ERROR = 2,
    MORPHL_SEV_FATAL = 3
} MorphlSeverity;

// Keep codes stable for tooling/tests.
// Reserve ranges by subsystem if you want (lexer=1000s, parser=2000s, etc.)
typedef enum MorphlErrCode {
    MORPHL_EOK = 0,

    // Generic
    MORPHL_E_INTERNAL        = 1,
    MORPHL_E_OOM             = 2,
    MORPHL_E_INVALID_ARG     = 3,
    MORPHL_E_IO              = 4,

    // Frontend (examples)
    MORPHL_E_LEX             = 1000,
    MORPHL_E_PARSE           = 2000,
    MORPHL_E_TYPE            = 3000,
    MORPHL_E_SEMA            = 4000
} MorphlErrCode;

// ----------------------------
// Source locations
// ----------------------------

typedef struct MorphlSpan {
    // Optional file path for diagnostics; can be NULL.
    const char *path;

    // 1-based line/col are common for UI; 0 means "unknown".
    uint32_t line;
    uint32_t col;

    // Optional byte offsets (0 means "unknown")
    uint32_t start;
    uint32_t end;
} MorphlSpan;

static inline MorphlSpan morphl_span_unknown(void) {
    MorphlSpan s;
    s.path = NULL;
    s.line = 0;
    s.col = 0;
    s.start = 0;
    s.end = 0;
    return s;
}

static inline MorphlSpan morphl_span_from_loc(const char *path, size_t line, size_t col) {
    MorphlSpan s;
    s.path = path;
    s.line = (line > UINT32_MAX) ? UINT32_MAX : (uint32_t)line;
    s.col = (col > UINT32_MAX) ? UINT32_MAX : (uint32_t)col;
    s.start = 0;
    s.end = 0;
    return s;
}

// ----------------------------
// Error object
// ----------------------------

#ifndef ML_ERRMSG_CAP
#define ML_ERRMSG_CAP 256u
#endif

typedef struct MorphlError {
    MorphlErrCode code;
    MorphlSeverity sev;

    // Where the diagnostic points in the *user's* source:
    MorphlSpan span;

    // Where the error was created (for debugging the compiler itself):
    const char *created_file;
    uint32_t created_line;

    char msg[ML_ERRMSG_CAP];
} MorphlError;

static inline bool morphl_ok(const MorphlError *e) {
    return e == NULL || e->code == MORPHL_EOK;
}

// ----------------------------
// Sink: route all errors through one place
// ----------------------------

typedef void (*MorphlErrorSinkFn)(void *user, const MorphlError *err);

typedef struct MorphlErrorSink {
    MorphlErrorSinkFn fn;       // Callback function
    void *user;                 // User data pointer
} MorphlErrorSink;

// Set a global sink
void morphl_error_set_global_sink(MorphlErrorSink sink);
MorphlErrorSink morphl_error_get_global_sink(void);

// Emit an error to a sink
void morphl_error_emit(const MorphlErrorSink *sink, const MorphlError *err);
// ----------------------------
// Builders / formatting
// ----------------------------

MorphlError morphl_error_make(MorphlErrCode code,
                      MorphlSeverity sev,
                      MorphlSpan span,
                      const char *created_file,
                      uint32_t created_line,
                      const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 6, 7)))
#endif
;

MorphlError morphl_error_makev(MorphlErrCode code,
                       MorphlSeverity sev,
                       MorphlSpan span,
                       const char *created_file,
                       uint32_t created_line,
                       const char *fmt,
                       va_list ap);

// Format into a caller-provided buffer
// Returns number of chars written (excluding trailing '\0').
size_t morphl_error_format(const MorphlError *err, char *out, size_t out_cap);

// ----------------------------
// Convenience macros
// ----------------------------

#define MORPHL_ERR_SPAN(code, sev, span, fmt, ...) \
    morphl_error_make((code), (sev), (span), __FILE__, (uint32_t)__LINE__, (fmt), ##__VA_ARGS__)

#define MORPHL_ERR(code, fmt, ...)   MORPHL_ERR_SPAN((code), MORPHL_SEV_ERROR, morphl_span_unknown(), (fmt), ##__VA_ARGS__)
#define MORPHL_WARN(code, fmt, ...)  MORPHL_ERR_SPAN((code), MORPHL_SEV_WARN,  morphl_span_unknown(), (fmt), ##__VA_ARGS__)
#define MORPHL_NOTE(code, fmt, ...)  MORPHL_ERR_SPAN((code), MORPHL_SEV_NOTE,  morphl_span_unknown(), (fmt), ##__VA_ARGS__)
#define MORPHL_FATAL(code, fmt, ...) MORPHL_ERR_SPAN((code), MORPHL_SEV_FATAL, morphl_span_unknown(), (fmt), ##__VA_ARGS__)

#define MORPHL_ERR_FROM(code, fmt, span, ...)   MORPHL_ERR_SPAN((code), MORPHL_SEV_ERROR, (span), (fmt), ##__VA_ARGS__)
#define MORPHL_WARN_FROM(code, fmt, span, ...)  MORPHL_ERR_SPAN((code), MORPHL_SEV_WARN,  (span), (fmt), ##__VA_ARGS__)
#define MORPHL_NOTE_FROM(code, fmt, span, ...)  MORPHL_ERR_SPAN((code), MORPHL_SEV_NOTE,  (span), (fmt), ##__VA_ARGS__)
#define MORPHL_FATAL_FROM(code, fmt, span, ...) MORPHL_ERR_SPAN((code), MORPHL_SEV_FATAL, (span), (fmt), ##__VA_ARGS__)

// Early-return helper macro
#define MORPHL_RETURN_IF_ERR(err_expr) do { \
    MorphlError _e = (err_expr);           \
    if (_e.code != MORPHL_EOK) return _e;  \
} while (0)

// ----------------------------
// Tiny result pattern
// ----------------------------

#define MorphlResult(T) struct { bool ok; T value; MorphlError err; }

#define MORPHL_RESULT_OK(T, v)   ((MorphlResult(T)){ .ok = true,  .value = (v), .err = { .code = MORPHL_EOK } })
#define MORPHL_RESULT_ERR(T, e)  ((MorphlResult(T)){ .ok = false, .value = (T){0}, .err = (e) })


#endif // MORPHL_UTIL_ERROR_H_
