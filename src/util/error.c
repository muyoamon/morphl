#include "util/error.h"
#include "util/file.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

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
    char buf[512];
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
        if (out && out_cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }

    const char *path = err->span.path ? err->span.path : "<unknown>";
    uint32_t line = err->span.line;
    uint32_t col  = err->span.col;

    // Format: file:line:col: severity[code]: message
    // If line/col unknown, omit.
    int n = 0;
    if (line == 0 || col == 0) {
        n = snprintf(out, out_cap, "%s: %s[%d]: %s",
                     path,
                     sev_str(err->sev),
                     (int)err->code,
                     err->msg);
    } else {
        // get error line
        const char *error_line = morphl_file_get_line(path, line);
        n = snprintf(out, out_cap, "%s:%u:%u: %s[%d]: %s\n\t%s",
                     path,
                     (unsigned)line,
                     (unsigned)col,
                     sev_str(err->sev),
                     (int)err->code,
                     err->msg,
                     error_line ? error_line : ""
                    );
        free((void*)error_line);
    }

    if (n < 0) {
        out[0] = '\0';
        return 0;
    }

    // Ensure null-termination
    out[out_cap - 1] = '\0';
    return (size_t)((n >= (int)out_cap) ? (int)out_cap - 1 : n);
}

