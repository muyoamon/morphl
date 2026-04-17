#include "util/error.h"
#include "util/file.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Global sink
static MorphlErrorSink g_global_sink = { NULL, NULL };

void morphl_error_set_global_sink(MorphlErrorSink sink) {
    g_global_sink = sink;
}

MorphlErrorSink morphl_error_get_global_sink(void) {
    return g_global_sink;
}

void morphl_error_emit(const MorphlErrorSink *sink, const MorphlError *err) {
    if (!err || err->code == MORPHL_EOK) return;
    const MorphlErrorSink *effective_sink = sink;
    if (!effective_sink || !effective_sink->fn) {
        effective_sink = &g_global_sink;
    }
    if (effective_sink && effective_sink->fn) {
        effective_sink->fn(effective_sink->user, err);
        return;
    }
    // Fallback: print to stderr
    char buf[1024];
    (void)morphl_error_format(err, buf, sizeof(buf));
    fputs(buf, stderr);
    fputc('\n', stderr);
}

static const char *sev_str(MorphlSeverity s) {
    switch (s) {
        case MORPHL_SEV_NOTE:  return "note";
        case MORPHL_SEV_WARN:  return "warning";
        case MORPHL_SEV_ERROR: return "error";
        case MORPHL_SEV_FATAL: return "fatal";
        default:           return "error";
    }
}

MorphlError morphl_error_makev(MorphlErrCode code,
                               MorphlSeverity sev,
                               MorphlSpan span,
                               const char *created_file,
                               uint32_t created_line,
                               const char *fmt,
                               va_list ap) {

    
    MorphlError err;
    err.code = code;
    err.sev = sev;
    err.span = span;
    err.created_file = created_file;
    err.created_line = created_line;

    if (!fmt) {
        err.msg[0] = '\0';
        return err;
    }

    vsnprintf(err.msg, sizeof(err.msg), fmt, ap);
    err.msg[sizeof(err.msg) - 1] = '\0';
    return err;
}

MorphlError morphl_error_make(MorphlErrCode code,
                      MorphlSeverity sev,
                      MorphlSpan span,
                      const char *created_file,
                      uint32_t created_line,
                      const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    MorphlError err = morphl_error_makev(code, sev, span, created_file, created_line, fmt, ap);
    va_end(ap);
    return err;
}

size_t morphl_error_format(const MorphlError *err, char *out, size_t out_cap) {
    if (!err || err->code == MORPHL_EOK || !out || out_cap == 0) {
        if (out && out_cap > 0) out[0] = '\0';
        return 0;
    }

    const char *path = err->span.path ? err->span.path : "<unknown>";
    uint32_t line = err->span.line;
    uint32_t col  = err->span.col;

    /* Unknown location: simple one-liner, no source snippet. */
    if (line == 0 || col == 0) {
        int n = snprintf(out, out_cap, "%s: %s[%d]: %s",
                         path, sev_str(err->sev), (int)err->code, err->msg);
        if (n < 0) { out[0] = '\0'; return 0; }
        out[out_cap - 1] = '\0';
        return (size_t)(n >= (int)out_cap ? (int)out_cap - 1 : n);
    }

    /* Known location: Rust/clang-style multi-line output.
     *
     *   path:line:col: severity[code]: message
     *      N | source text here
     *        |         ^~~~
     */

    /* Compute gutter width (number of digits in line number). */
    int gutter = 0;
    { unsigned tmp = (unsigned)line; do { gutter++; tmp /= 10; } while (tmp); }
    if (gutter < 2) gutter = 2; /* minimum 2-char gutter for readability */

    /* Fetch source line (may be NULL if file is unavailable). */
    const char *src_line = morphl_file_get_line(path, line);

    /* Build header: path:line:col: sev[code]: msg */
    char header[512];
    snprintf(header, sizeof(header), "%s:%u:%u: %s[%d]: %s",
             path, (unsigned)line, (unsigned)col,
             sev_str(err->sev), (int)err->code, err->msg);

    size_t written = 0;

    /* Helper to append to out[written..out_cap]. */
#define APPEND(fmt, ...) do { \
    int _n = snprintf(out + written, out_cap - written, fmt, ##__VA_ARGS__); \
    if (_n > 0) written += (size_t)(_n < (int)(out_cap - written) ? _n : (int)(out_cap - written) - 1); \
} while (0)

    APPEND("%s", header);

    if (src_line) {
        /* Source line with gutter:  "   N | text" */
        APPEND("\n%*u | %s", gutter, (unsigned)line, src_line);

        /* Underline line:  "     |         ^~~~" */
        APPEND("\n%*s | ", gutter, "");

        /* Spaces up to (col - 1), then caret, then tildes for span width. */
        uint32_t underline_start = (col > 0) ? col - 1 : 0;
        uint32_t span_len = (err->span.end > err->span.start && err->span.start > 0)
                            ? (err->span.end - err->span.start)
                            : 1;

        for (uint32_t i = 0; i < underline_start && written + 1 < out_cap; i++)
            out[written++] = ' ';
        if (written + 1 < out_cap) out[written++] = '^';
        for (uint32_t i = 1; i < span_len && written + 1 < out_cap; i++)
            out[written++] = '~';

        free((void*)src_line);
    }

#undef APPEND

    if (written < out_cap) out[written] = '\0';
    else out[out_cap - 1] = '\0';
    return written;
}

