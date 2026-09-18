//! AST — the shape of SPEC.md §2 after parsing, and nothing more.
//!
//! The tree is deliberately close to the surface syntax: no desugaring happens
//! here. In particular `$if` is *not* rewritten into `$match` (§2.2 calls it
//! sugar, but rewriting early would make diagnostics point at code the user
//! never wrote — see BOOTSTRAP.md §6).
//!
//! Two normalizations from §2.3 *are* applied, because they are identities in
//! the language rather than choices a later stage could make differently:
//!
//!   * `(e)` is `e` — there is no one-tuple, so a one-element group never
//!     appears in the tree.
//!   * `()` and `{}` are the same value (unit), so both parse to `.unit`.
//!
//! Consequently `.group` always holds at least 2 children and `.block` at
//! least 1. A one-expression *block* is still a block: only groups fold.

const std = @import("std");
const diag = @import("diag");
const kw = @import("keyword");

const Span = diag.Span;
pub const Keyword = kw.Keyword;

pub const Node = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        int: i64,
        /// Source text, not a decoded value (see lexer).
        float: []const u8,
        str: []const u8,
        bool_lit: bool,
        name: []const u8,
        /// `()` and `{}` (§2.3).
        unit,
        /// `(a, b, …)` — 2 or more elements.
        group: []Node,
        /// `{ a b … }` — 1 or more expressions.
        block: []Node,
        proj_name: Projection([]const u8),
        proj_index: Projection(u32),
        /// A `$keyword` form with exactly `kw.arity()` operands.
        form: Form,
    };

    pub const Form = struct {
        keyword: Keyword,
        operands: []Node,
    };

    fn Projection(comptime Field: type) type {
        return struct {
            target: *Node,
            field: Field,
        };
    }

    /// Children in source order. Handy for the walks in `parser.validate`.
    pub fn children(self: *const Node) []const Node {
        return switch (self.data) {
            .group, .block => |xs| xs,
            .form => |f| f.operands,
            .proj_name => |p| p.target[0..1],
            .proj_index => |p| p.target[0..1],
            else => &.{},
        };
    }

    /// Compact S-expression, one line, stable enough to assert against.
    pub fn dump(self: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.data) {
            .int => |v| try w.print("{d}", .{v}),
            .float => |t| try w.writeAll(t),
            .str => |s| try w.print("\"{s}\"", .{s}),
            .bool_lit => |b| try w.writeAll(if (b) "true" else "false"),
            .name => |n| try w.writeAll(n),
            .unit => try w.writeAll("()"),
            .group => |xs| try dumpList(w, "group", xs),
            .block => |xs| try dumpList(w, "block", xs),
            .proj_name => |p| {
                try w.writeAll("(. ");
                try p.target.dump(w);
                try w.print(" {s})", .{p.field});
            },
            .proj_index => |p| {
                try w.writeAll("(. ");
                try p.target.dump(w);
                try w.print(" {d})", .{p.field});
            },
            .form => |f| {
                try w.print("({s}", .{f.keyword.text()});
                for (f.operands) |*op| {
                    try w.writeByte(' ');
                    try op.dump(w);
                }
                try w.writeByte(')');
            },
        }
    }

    fn dumpList(w: *std.Io.Writer, label: []const u8, xs: []Node) std.Io.Writer.Error!void {
        try w.print("({s}", .{label});
        for (xs) |*x| {
            try w.writeByte(' ');
            try x.dump(w);
        }
        try w.writeByte(')');
    }

    /// True when this node is the given keyword form. Used constantly by the
    /// `$case`-placement check and, later, by the evaluator.
    pub fn isForm(self: *const Node, keyword: Keyword) bool {
        return switch (self.data) {
            .form => |f| f.keyword == keyword,
            else => false,
        };
    }
};

/// A parsed source file. §3.3: "A source file is a block."
pub const File = struct {
    /// The file block's expressions, in source order.
    exprs: []Node,

    pub fn dump(self: *const File, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.exprs) |*e| {
            try e.dump(w);
            try w.writeByte('\n');
        }
    }
};

test "dump renders forms, projections and folding" {
    const gpa = std.testing.allocator;
    const s: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    var target: Node = .{ .span = s, .data = .{ .name = "p" } };
    var operands = [_]Node{
        .{ .span = s, .data = .{ .name = "x" } },
        .{ .span = s, .data = .{ .proj_index = .{ .target = &target, .field = 2 } } },
    };
    const form: Node = .{ .span = s, .data = .{ .form = .{ .keyword = .decl, .operands = &operands } } };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try form.dump(&out.writer);
    try std.testing.expectEqualStrings("($decl x (. p 2))", out.written());
}
