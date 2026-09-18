//! The bootstrap root block — BOOTSTRAP.md §2.
//!
//! This is **not** the root block of SPEC.md §8, and does not pretend to be.
//! It is monomorphic: §8 defines the numeric intrinsics *as* `$overload` sets
//! over `(Int,Int)` and `(Float,Float)`, and dropping float arithmetic (§1.2)
//! means no overload set ever has to exist at stage 0. Comparison is split into
//! `eq_int`/`eq_str` for the same reason.
//!
//! Everything here is an ordinary shadowable name, never a keyword (§2.1).
//!
//! Still missing, and deliberately: `read_file`, `write_file` and `args`. Those
//! are platform I/O, they need the `Io` plumbing the driver owns, and nothing
//! in stage 0's own test suite needs them. They land with step 4.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const value = @import("value.zig");

const Span = diag.Span;
const Value = value.Value;
const Runtime = value.Runtime;
const Error = value.Error;
const Scope = value.Scope;
const Field = value.Field;

/// Build the root scope: the implicit block every program is wrapped in (§8).
pub fn rootScope(arena: Allocator, rt: *Runtime) Error!*Scope {
    const scope = try Scope.init(arena, null);

    for (&table) |*b| {
        _ = try define(scope, b.name, .{ .builtin = b });
    }

    // §4.15: "The root block declares `$prop err {$prop tag "err"}` and
    // `$prop none {$prop tag "none"}` so the common forms read `$try x err`
    // and `$try x none`."
    _ = try define(scope, "err", try tagBlock(arena, "err"));
    _ = try define(scope, "none", try tagBlock(arena, "none"));

    _ = rt;
    return scope;
}

fn define(scope: *Scope, name: []const u8, v: Value) Error!void {
    const i = try scope.reserve(name, .{ .start = 0, .end = 0, .line = 0, .col = 0 });
    _ = scope.complete(i, v);
}

fn tagBlock(arena: Allocator, tag: []const u8) Error!Value {
    return value.propBlock(arena, &.{.{ .name = "tag", .value = .{ .str = tag } }});
}

/// `{$prop tag "some" $decl v <x>}` — the shape BOOTSTRAP.md §2 gives
/// `str_to_int`, so that `$try x none` reads naturally at the call site.
pub fn some(arena: Allocator, v: Value) Error!Value {
    return value.makeBlock(
        arena,
        &.{.{ .name = "v", .value = v }},
        &.{.{ .name = "tag", .value = .{ .str = "some" } }},
    );
}

// ------------------------------------------------------------ arg helpers

fn wantInt(rt: *Runtime, args: []const Value, i: usize, name: []const u8, span: Span) Error!i64 {
    return switch (args[i]) {
        .int => |v| v,
        else => rt.fail(span, "{s} expects Int for operand {d}, found {s}", .{ name, i + 1, args[i].typeName() }),
    };
}

fn wantStr(rt: *Runtime, args: []const Value, i: usize, name: []const u8, span: Span) Error![]const u8 {
    return switch (args[i]) {
        .str => |v| v,
        else => rt.fail(span, "{s} expects Str for operand {d}, found {s}", .{ name, i + 1, args[i].typeName() }),
    };
}

// -------------------------------------------------------------- intrinsics

/// §3.1/§8: `Int` is 64-bit and **overflow panics**; wrapping and saturating
/// forms are separate explicit intrinsics (not in the bootstrap root block).
fn addFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "add", span);
    const b = try wantInt(rt, args, 1, "add", span);
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return rt.panic(span, "Int overflow in add", .{});
    return .{ .int = r[0] };
}

fn subFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "sub", span);
    const b = try wantInt(rt, args, 1, "sub", span);
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return rt.panic(span, "Int overflow in sub", .{});
    return .{ .int = r[0] };
}

fn mulFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "mul", span);
    const b = try wantInt(rt, args, 1, "mul", span);
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return rt.panic(span, "Int overflow in mul", .{});
    return .{ .int = r[0] };
}

fn divFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "div", span);
    const b = try wantInt(rt, args, 1, "div", span);
    if (b == 0) return rt.panic(span, "division by zero", .{});
    if (a == std.math.minInt(i64) and b == -1) return rt.panic(span, "Int overflow in div", .{});
    return .{ .int = @divTrunc(a, b) };
}

fn modFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "mod", span);
    const b = try wantInt(rt, args, 1, "mod", span);
    if (b == 0) return rt.panic(span, "division by zero in mod", .{});
    if (a == std.math.minInt(i64) and b == -1) return .{ .int = 0 };
    return .{ .int = @rem(a, b) };
}

fn negFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "neg", span);
    if (a == std.math.minInt(i64)) return rt.panic(span, "Int overflow in neg", .{});
    return .{ .int = -a };
}

fn ltFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "lt", span);
    const b = try wantInt(rt, args, 1, "lt", span);
    return .{ .bool = a < b };
}

fn eqIntFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "eq_int", span);
    const b = try wantInt(rt, args, 1, "eq_int", span);
    return .{ .bool = a == b };
}

fn eqStrFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantStr(rt, args, 0, "eq_str", span);
    const b = try wantStr(rt, args, 1, "eq_str", span);
    // §8: `eq` on Str is bytewise, which equals code-point equality under the
    // always-valid-UTF-8 invariant.
    return .{ .bool = std.mem.eql(u8, a, b) };
}

fn concatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantStr(rt, args, 0, "concat", span);
    const b = try wantStr(rt, args, 1, "concat", span);
    const out = try rt.arena.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return .{ .str = out };
}

/// §8: `len` counts **bytes**.
fn lenFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "len", span);
    return .{ .int = @intCast(s.len) };
}

fn isBoundary(s: []const u8, i: usize) bool {
    if (i == s.len) return true;
    return (s[i] & 0xC0) != 0x80;
}

/// §8: byte offsets, and it "panics if an offset splits a code point,
/// preserving the validity invariant".
fn sliceFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "slice", span);
    const i = try wantInt(rt, args, 1, "slice", span);
    const j = try wantInt(rt, args, 2, "slice", span);
    if (i < 0 or j < 0 or i > j or j > @as(i64, @intCast(s.len))) {
        return rt.panic(span, "slice ({d}, {d}) out of range for a Str of {d} bytes", .{ i, j, s.len });
    }
    const lo: usize = @intCast(i);
    const hi: usize = @intCast(j);
    if (!isBoundary(s, lo) or !isBoundary(s, hi)) {
        return rt.panic(span, "slice ({d}, {d}) splits a code point", .{ i, j });
    }
    return .{ .str = s[lo..hi] };
}

/// §8: "`byte (s, i)` reads one byte as `Int`."
fn byteFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "byte", span);
    const i = try wantInt(rt, args, 1, "byte", span);
    if (i < 0 or i >= @as(i64, @intCast(s.len))) {
        return rt.panic(span, "byte index {d} out of range for a Str of {d} bytes", .{ i, s.len });
    }
    return .{ .int = s[@intCast(i)] };
}

fn intToStrFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const v = try wantInt(rt, args, 0, "int_to_str", span);
    return .{ .str = try std.fmt.allocPrint(rt.arena, "{d}", .{v}) };
}

fn strToIntFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "str_to_int", span);
    const v = std.fmt.parseInt(i64, s, 10) catch {
        return tagBlock(rt.arena, "none");
    };
    return some(rt.arena, .{ .int = v });
}

/// §8: "`$call array (n, example)` → `&mut [T]`, contiguous, bounds-checked".
fn arrayFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const n = try wantInt(rt, args, 0, "array", span);
    if (n < 0) return rt.panic(span, "array length {d} is negative", .{n});
    const len: usize = @intCast(n);
    const a = try rt.arena.create(value.Array);
    a.* = .{ .elems = try rt.arena.alloc(value.Cell, len) };
    for (a.elems) |*c| c.* = .{ .value = args[1] };
    return .{ .array = a };
}

/// §8: "`at` → fat `&mut T`". Returning a reference to the element cell is
/// exactly §7.6's "base + index rather than an interior pointer".
fn atFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = switch (args[0]) {
        .array => |x| x,
        else => return rt.fail(span, "at expects an array, found {s}", .{args[0].typeName()}),
    };
    const i = try wantInt(rt, args, 1, "at", span);
    if (i < 0 or i >= @as(i64, @intCast(a.elems.len))) {
        return rt.panic(span, "index {d} out of bounds for an array of {d}", .{ i, a.elems.len });
    }
    return .{ .ref = &a.elems[@intCast(i)] };
}

fn alenFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return switch (args[0]) {
        .array => |a| .{ .int = @intCast(a.elems.len) },
        else => rt.fail(span, "alen expects an array, found {s}", .{args[0].typeName()}),
    };
}

/// §8: `panic` returns `⊥`; it aborts, and there is no catch and no unwinding.
fn panicFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const msg = switch (args[0]) {
        .str => |s| s,
        else => "(non-Str panic operand)",
    };
    return rt.panic(span, "{s}", .{msg});
}

fn printFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "print", span);
    if (rt.out) |w| {
        w.writeAll(s) catch return rt.fail(span, "print failed to write", .{});
    }
    return .unit;
}

const table = [_]value.Builtin{
    .{ .name = "add", .arity = 2, .func = addFn },
    .{ .name = "sub", .arity = 2, .func = subFn },
    .{ .name = "mul", .arity = 2, .func = mulFn },
    .{ .name = "div", .arity = 2, .func = divFn },
    .{ .name = "mod", .arity = 2, .func = modFn },
    .{ .name = "neg", .arity = 1, .func = negFn },
    .{ .name = "lt", .arity = 2, .func = ltFn },
    .{ .name = "eq_int", .arity = 2, .func = eqIntFn },
    .{ .name = "eq_str", .arity = 2, .func = eqStrFn },
    .{ .name = "concat", .arity = 2, .func = concatFn },
    .{ .name = "len", .arity = 1, .func = lenFn },
    .{ .name = "slice", .arity = 3, .func = sliceFn },
    .{ .name = "byte", .arity = 2, .func = byteFn },
    .{ .name = "int_to_str", .arity = 1, .func = intToStrFn },
    .{ .name = "str_to_int", .arity = 1, .func = strToIntFn },
    .{ .name = "array", .arity = 2, .func = arrayFn },
    .{ .name = "at", .arity = 2, .func = atFn },
    .{ .name = "alen", .arity = 1, .func = alenFn },
    .{ .name = "panic", .arity = 1, .func = panicFn },
    .{ .name = "print", .arity = 1, .func = printFn },
};

test "the root block is monomorphic and complete per BOOTSTRAP 2" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var rt: Runtime = .{ .arena = arena, .diags = &diags };

    const scope = try rootScope(arena, &rt);
    for ([_][]const u8{
        "add",    "sub",  "mul",        "div",        "mod",   "neg", "lt",
        "eq_int", "eq_str", "concat",   "len",        "slice", "byte",
        "int_to_str", "str_to_int", "array", "at", "alen", "panic", "print",
        "err",    "none",
    }) |name| {
        if (scope.findLocal(name) == null) {
            std.debug.print("root block is missing '{s}'\n", .{name});
            return error.MissingIntrinsic;
        }
    }
    // §8 defines these as overload sets; the bootstrap block must not have them.
    try std.testing.expect(scope.findLocal("eq") == null);
}

test "overflow and division by zero panic" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    try std.testing.expectError(error.Panicked, addFn(&rt, &.{
        .{ .int = std.math.maxInt(i64) }, .{ .int = 1 },
    }, span));
    try std.testing.expectError(error.Panicked, divFn(&rt, &.{
        .{ .int = 1 }, .{ .int = 0 },
    }, span));
}

test "slice works in bytes and refuses to split a code point" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const s: Value = .{ .str = "héllo" }; // 'é' is two bytes
    try std.testing.expectEqual(@as(i64, 6), (try lenFn(&rt, &.{s}, span)).int);
    try std.testing.expectEqualStrings("h", (try sliceFn(&rt, &.{ s, .{ .int = 0 }, .{ .int = 1 } }, span)).str);
    try std.testing.expectError(error.Panicked, sliceFn(&rt, &.{
        s, .{ .int = 0 }, .{ .int = 2 },
    }, span));
}

test "str_to_int returns the option shape that $try none expects" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const ok = try strToIntFn(&rt, &.{.{ .str = "42" }}, span);
    try std.testing.expectEqualStrings("some", ok.block.findProp("tag").?.str);
    try std.testing.expectEqual(@as(i64, 42), ok.block.findDecl("v").?.int);

    const bad = try strToIntFn(&rt, &.{.{ .str = "4x" }}, span);
    try std.testing.expectEqualStrings("none", bad.block.findProp("tag").?.str);
}
