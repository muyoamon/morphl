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
//! The platform group (`print`, `read_file`, `write_file`, `args`) stands in
//! for what §4.16 says must be library code over `$extern`. Stage 0 has no
//! `$extern`, so these are builtins — but they reach the host through an
//! injected `Platform` rather than touching it directly, so the substitution
//! does not smuggle I/O into the evaluator.

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

/// `read_file (path)` → `none | {$prop tag "some" $decl v Str}`.
///
/// The UTF-8 check is not defensive coding, it is §3.1's invariant: `Str` is
/// *always* valid UTF-8. §4.16 spells out the consequence for data arriving
/// from outside — "bytes received from C become a `Str` only through a
/// validating library function returning `option Str`" — and a file is exactly
/// that case, so unreadable and non-UTF-8 both come back as `none`.
fn readFileFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const path = try wantStr(rt, args, 0, "read_file", span);
    const p = rt.platform orelse
        return rt.fail(span, "read_file is unavailable: no platform was configured", .{});
    const bytes = p.readFile(rt.arena, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return tagBlock(rt.arena, "none"),
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) return tagBlock(rt.arena, "none");
    return some(rt.arena, .{ .str = bytes });
}

/// `write_file (path, contents)` → `() | err`.
///
/// §8 requires failing operations to return a value rather than panic; `err`
/// is the shape §4.15 gives the root block, so a caller writes
/// `$try ($call write_file (p, s)) err` and the error set is inferred.
fn writeFileFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const path = try wantStr(rt, args, 0, "write_file", span);
    const data = try wantStr(rt, args, 1, "write_file", span);
    const p = rt.platform orelse
        return rt.fail(span, "write_file is unavailable: no platform was configured", .{});
    p.writeFile(path, data) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return tagBlock(rt.arena, "err"),
    };
    return .unit;
}

/// `args ()` → an array of `Str`.
///
/// A zero-arity function rather than a value, so a program that never asks
/// pays nothing. Each call builds a fresh array, since §8's arrays are
/// `&mut [T]` and handing out one shared mutable array would let one caller's
/// writes surprise the next.
fn argsFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    _ = args;
    const p = rt.platform orelse
        return rt.fail(span, "args is unavailable: no platform was configured", .{});
    const list = p.args(rt.arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return rt.fail(span, "args could not be read from the host", .{}),
    };
    const a = try rt.arena.create(value.Array);
    a.* = .{ .elems = try rt.arena.alloc(value.Cell, list.len) };
    for (a.elems, list) |*cell, s| cell.* = .{ .value = .{ .str = s } };
    return .{ .array = a };
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
    .{ .name = "read_file", .arity = 1, .func = readFileFn },
    .{ .name = "write_file", .arity = 2, .func = writeFileFn },
    .{ .name = "args", .arity = 0, .func = argsFn },
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
        // Numeric, comparison, strings, conversion, arrays, control.
        "add",        "sub",        "mul",   "div",  "mod",   "neg",   "lt",
        "eq_int",     "eq_str",     "concat", "len", "slice", "byte",
        "int_to_str", "str_to_int", "array", "at",   "alen",  "panic",
        // Shapes (§4.15) and platform.
        "err",        "none",       "print", "read_file", "write_file", "args",
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

/// An in-memory host, so the platform intrinsics are testable without touching
/// a filesystem.
const FakePlatform = struct {
    const Entry = struct { path: []const u8, bytes: []const u8 };

    files: []const Entry,
    argv: []const []const u8 = &.{},
    written: *?Entry = undefined,
    fail_writes: bool = false,

    fn readFile(ctx: *const anyopaque, arena: Allocator, path: []const u8) value.Platform.PlatformError![]const u8 {
        _ = arena;
        const self: *const FakePlatform = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f.bytes;
        return error.Failed;
    }

    fn writeFile(ctx: *const anyopaque, path: []const u8, bytes: []const u8) value.Platform.PlatformError!void {
        const self: *const FakePlatform = @ptrCast(@alignCast(ctx));
        if (self.fail_writes) return error.Failed;
        self.written.* = .{ .path = path, .bytes = bytes };
    }

    fn args(ctx: *const anyopaque, arena: Allocator) value.Platform.PlatformError![]const []const u8 {
        _ = arena;
        const self: *const FakePlatform = @ptrCast(@alignCast(ctx));
        return self.argv;
    }

    fn platform(self: *const FakePlatform) value.Platform {
        return .{
            .ctx = self,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .argsFn = args,
        };
    }
};

test "read_file returns option Str and refuses non-UTF-8 bytes (3.1, 4.16)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const host: FakePlatform = .{ .files = &.{
        .{ .path = "good", .bytes = "hi" },
        .{ .path = "binary", .bytes = "\xff\xfe" },
    } };
    var rt: Runtime = .{
        .arena = arena_state.allocator(),
        .diags = &diags,
        .platform = host.platform(),
    };

    const ok = try readFileFn(&rt, &.{.{ .str = "good" }}, span);
    try std.testing.expectEqualStrings("some", ok.block.findProp("tag").?.str);
    try std.testing.expectEqualStrings("hi", ok.block.findDecl("v").?.str);

    // Missing file and invalid UTF-8 are both `none`, not errors: a Str is
    // always valid UTF-8, so bytes only become one through a validating read.
    const missing = try readFileFn(&rt, &.{.{ .str = "nope" }}, span);
    try std.testing.expectEqualStrings("none", missing.block.findProp("tag").?.str);
    const binary = try readFileFn(&rt, &.{.{ .str = "binary" }}, span);
    try std.testing.expectEqualStrings("none", binary.block.findProp("tag").?.str);
}

test "write_file returns unit or err, and args is an array of Str" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    var sink: ?FakePlatform.Entry = null;
    const host: FakePlatform = .{
        .files = &.{},
        .argv = &.{ "a", "bb" },
        .written = &sink,
    };
    var rt: Runtime = .{
        .arena = arena_state.allocator(),
        .diags = &diags,
        .platform = host.platform(),
    };

    const wrote = try writeFileFn(&rt, &.{ .{ .str = "out" }, .{ .str = "body" } }, span);
    try std.testing.expect(wrote == .unit);
    try std.testing.expectEqualStrings("out", sink.?.path);
    try std.testing.expectEqualStrings("body", sink.?.bytes);

    const failing: FakePlatform = .{ .files = &.{}, .written = &sink, .fail_writes = true };
    rt.platform = failing.platform();
    const failed = try writeFileFn(&rt, &.{ .{ .str = "out" }, .{ .str = "body" } }, span);
    try std.testing.expectEqualStrings("err", failed.block.findProp("tag").?.str);

    rt.platform = host.platform();
    const argv = try argsFn(&rt, &.{}, span);
    try std.testing.expectEqual(@as(usize, 2), argv.array.elems.len);
    try std.testing.expectEqualStrings("bb", argv.array.elems[1].value.str);
}

test "platform intrinsics decline when no host is configured" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    try std.testing.expectError(error.Halt, readFileFn(&rt, &.{.{ .str = "x" }}, span));
    try std.testing.expectError(error.Halt, argsFn(&rt, &.{}, span));
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
