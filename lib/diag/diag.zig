//! Spans and diagnostics.
//!
//! Per BOOTSTRAP.md §6: there is no annotation syntax in morphl, so every type
//! in every diagnostic is one the compiler inferred and the user never wrote.
//! Diagnostics must therefore point at *expressions*, which means every token
//! and every AST node carries a span from the very first stage.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte range in one source file, plus the line/column of its start.
///
/// `col` is counted in bytes, not code points: it is a byte offset into the
/// line, which is what a caret-and-underline renderer needs.
pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    col: u32,

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// The span covering both `a` and `b`, taking line/col from `a`.
    /// Used to give a keyword form the extent of its whole subtree.
    pub fn to(a: Span, b: Span) Span {
        return .{
            .start = a.start,
            .end = @max(a.end, b.end),
            .line = a.line,
            .col = a.col,
        };
    }
};

pub const Diagnostic = struct {
    span: Span,
    /// Owned by the `Diagnostics` that produced it, unless `msg_static`.
    msg: []const u8,
    msg_static: bool = false,
};

/// A growable list of errors. Stages report into this and keep going where they
/// can, so one run surfaces more than one mistake.
pub const Diagnostics = struct {
    gpa: Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |d| {
            if (!d.msg_static) self.gpa.free(d.msg);
        }
        self.items.deinit(self.gpa);
    }

    pub fn any(self: *const Diagnostics) bool {
        return self.items.items.len != 0;
    }

    /// Record an error. Deliberately returns void: a failure to allocate a
    /// *message* must not mask the error being reported, and callers are
    /// cleaner without `try` on every diagnostic.
    pub fn add(self: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch {
            self.items.append(self.gpa, .{
                .span = span,
                .msg = "out of memory while formatting this diagnostic",
                .msg_static = true,
            }) catch {};
            return;
        };
        self.items.append(self.gpa, .{ .span = span, .msg = msg }) catch {
            self.gpa.free(msg);
        };
    }

    /// Put diagnostics in source order.
    ///
    /// Stages report as they go, so a lexical error on line 9 can precede a
    /// parse error on line 1. Sorting before rendering means the reader works
    /// top-down through the file instead of jumping around it.
    pub fn sort(self: *Diagnostics) void {
        std.mem.sort(Diagnostic, self.items.items, {}, struct {
            fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
                return a.span.start < b.span.start;
            }
        }.lessThan);
    }

    /// Render as `path:line:col: error: message`, one per line.
    pub fn render(self: *const Diagnostics, w: *std.Io.Writer, path: []const u8) !void {
        for (self.items.items) |d| {
            try w.print("{s}:{d}:{d}: error: {s}\n", .{ path, d.span.line, d.span.col, d.msg });
        }
    }
};

test "spans join" {
    const a: Span = .{ .start = 4, .end = 8, .line = 2, .col = 1 };
    const b: Span = .{ .start = 10, .end = 20, .line = 3, .col = 5 };
    const j = a.to(b);
    try std.testing.expectEqual(@as(u32, 4), j.start);
    try std.testing.expectEqual(@as(u32, 20), j.end);
    try std.testing.expectEqual(@as(u32, 2), j.line);
}

test "diagnostics own their messages" {
    var d = Diagnostics.init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expect(!d.any());
    d.add(.{ .start = 0, .end = 1, .line = 1, .col = 1 }, "unknown keyword '${s}'", .{"nope"});
    try std.testing.expect(d.any());
    try std.testing.expectEqualStrings("unknown keyword '$nope'", d.items.items[0].msg);
}
