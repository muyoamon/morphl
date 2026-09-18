//! The keyword table: SPEC.md §2.2, verbatim.
//!
//! Every compiler form is `$`-prefixed and has **fixed arity**. That single
//! fact is what lets the parser be a flat table-driven loop with no precedence
//! machinery, no separators and no newline sensitivity (§2.2, closing note).
//!
//! This table covers the whole language, not just the bootstrap subset. Forms
//! that BOOTSTRAP.md §1.2 excludes (`$overload`, `$impl`, `$traitsof`,
//! `$extern`, `$const`) still parse: the subset restricts what stage-1 *source*
//! may use, and the evaluator is what declines to implement them. Parsing them
//! costs nothing and keeps this table checkable against the spec line by line.

const std = @import("std");

pub const Keyword = enum {
    decl,
    prop,
    fwd,
    new,
    mut,
    @"const",
    set,
    func,
    call,
    match,
    case,
    @"if",
    do,
    overload,
    @"union",
    template,
    specialize,
    impl,
    traitsof,
    import,
    @"try",
    @"extern",

    /// The source spelling, including the `$`.
    pub fn text(self: Keyword) []const u8 {
        return switch (self) {
            inline else => |k| "$" ++ @tagName(k),
        };
    }

    pub fn signature(self: Keyword) Signature {
        return signatures[@intFromEnum(self)];
    }

    pub fn arity(self: Keyword) usize {
        return self.signature().len;
    }
};

/// What a given operand slot is allowed to be.
///
/// The spec's arity table names some operands "name" or "string literal"
/// rather than "expression"; enforcing that here turns what would otherwise be
/// a confusing downstream type error into a precise syntax error.
pub const OperandKind = enum {
    /// Any expression.
    expr,
    /// A bare identifier.
    name,
    /// A string literal.
    str_lit,
    /// A name, or a group of names (`$template (A, B) …`).
    names,
};

pub const Signature = []const OperandKind;

/// Indexed by `@intFromEnum(Keyword)`. Order must match the enum.
const signatures = [_]Signature{
    &.{ .name, .expr }, // $decl name e
    &.{ .name, .expr }, // $prop name e
    &.{.name}, // $fwd name          (§4.11: the group form is a future extension)
    &.{.expr}, // $new e
    &.{.expr}, // $mut e
    &.{.expr}, // $const e
    &.{ .expr, .expr }, // $set target e
    &.{ .expr, .expr }, // $func params body
    &.{ .expr, .expr }, // $call f args
    &.{ .expr, .expr }, // $match e arms
    &.{ .expr, .expr }, // $case pat body
    &.{ .expr, .expr, .expr }, // $if c a b
    &.{ .expr, .expr }, // $do e1 e2
    &.{.expr}, // $overload cands
    &.{.expr}, // $union members
    &.{ .names, .expr }, // $template T body
    &.{ .expr, .expr }, // $specialize t args
    &.{ .expr, .expr, .expr }, // $impl T trait override
    &.{.expr}, // $traitsof e
    &.{.str_lit}, // $import "name"
    &.{ .expr, .expr }, // $try e pat
    &.{ .str_lit, .expr }, // $extern "symbol" sig
};

/// Maps a keyword's name *without* the `$` to its tag.
const table = std.StaticStringMap(Keyword).initComptime(.{
    .{ "decl", .decl },
    .{ "prop", .prop },
    .{ "fwd", .fwd },
    .{ "new", .new },
    .{ "mut", .mut },
    .{ "const", .@"const" },
    .{ "set", .set },
    .{ "func", .func },
    .{ "call", .call },
    .{ "match", .match },
    .{ "case", .case },
    .{ "if", .@"if" },
    .{ "do", .do },
    .{ "overload", .overload },
    .{ "union", .@"union" },
    .{ "template", .template },
    .{ "specialize", .specialize },
    .{ "impl", .impl },
    .{ "traitsof", .traitsof },
    .{ "import", .import },
    .{ "try", .@"try" },
    .{ "extern", .@"extern" },
});

pub fn lookup(name_without_dollar: []const u8) ?Keyword {
    return table.get(name_without_dollar);
}

test "every keyword has a signature and round-trips through the table" {
    inline for (std.meta.fields(Keyword)) |f| {
        const kw: Keyword = @enumFromInt(f.value);
        try std.testing.expect(kw.arity() >= 1 and kw.arity() <= 3);
        try std.testing.expectEqual(kw, lookup(f.name).?);
        try std.testing.expectEqualStrings("$" ++ f.name, kw.text());
    }
    try std.testing.expectEqual(@as(usize, signatures.len), std.meta.fields(Keyword).len);
}

test "arities match SPEC.md 2.2" {
    try std.testing.expectEqual(@as(usize, 2), Keyword.decl.arity());
    try std.testing.expectEqual(@as(usize, 1), Keyword.fwd.arity());
    try std.testing.expectEqual(@as(usize, 3), Keyword.@"if".arity());
    try std.testing.expectEqual(@as(usize, 3), Keyword.impl.arity());
    try std.testing.expectEqual(@as(usize, 1), Keyword.traitsof.arity());
}

test "true and false are not keywords" {
    // §2.1: "`true` and `false` are literals, not keywords."
    try std.testing.expect(lookup("true") == null);
    try std.testing.expect(lookup("false") == null);
    // §2.1: intrinsics are ordinary shadowable names, never keywords.
    try std.testing.expect(lookup("add") == null);
    try std.testing.expect(lookup("print") == null);
}
