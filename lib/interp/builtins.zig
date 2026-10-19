//! The bootstrap root block — BOOTSTRAP.md §2.
//!
//! This is **not** the root block of SPEC.md §8, and does not pretend to be.
//! §8 defines the numeric intrinsics *as* `$overload` sets over `(Int,Int)` and
//! `(Float,Float)`, and stage 1 types them that way. Stage 0 drops float
//! arithmetic (§1.2), so here they are the `Int` candidate alone, and the names
//! that exist only for other candidates — `eq` on `Int`, `Str` and `Bool`,
//! `to_int` on a `Str`, `to_str` on an `Int` — accept what the subset has and
//! refuse a `Float` by name. `eq_int`/`eq_str`, `int_to_str` and `str_to_int`
//! are the bootstrap's monomorphic spellings and stay beside them.
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
const lexer = @import("lexer");
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

    // Interned, like every other name (§2.1: an intrinsic is an ordinary
    // shadowable name). Scopes compare names by identity, so an intrinsic
    // defined with a Zig literal would be invisible to source that names it.
    for (&table) |*b| {
        _ = try define(scope, try rt.pool.intern(b.name), .{ .builtin = b });
    }

    // §4.15: "The root block declares `$prop err {$prop tag "err"}` and
    // `$prop none {$prop tag "none"}` so the common forms read `$try x err`
    // and `$try x none`."
    _ = try define(scope, try rt.pool.intern("err"), try tagBlock(rt, "err"));
    _ = try define(scope, try rt.pool.intern("none"), try tagBlock(rt, "none"));

    // §7.6's root `allocator`. Stage 0 never frees (BOOTSTRAP §3), so `$alloc` ignores
    // it; its members are §8's raw-memory intrinsics, which refuse here like the rest of
    // the FFI group, so `allocator.alloc (n)` fails with the subset's message.
    _ = try define(scope, try rt.pool.intern("allocator"), try value.propBlock(rt.arena, &.{
        .{ .name = try rt.pool.intern("alloc"), .value = .{ .builtin = &raw_alloc_b } },
        .{ .name = try rt.pool.intern("free"), .value = .{ .builtin = &raw_free_b } },
    }));

    return scope;
}

fn define(scope: *Scope, name: []const u8, v: Value) Error!void {
    const i = try scope.reserve(name, .{ .start = 0, .end = 0, .line = 0, .col = 0 });
    _ = scope.complete(i, v);
}

fn tagBlock(rt: *Runtime, tag: []const u8) Error!Value {
    return value.propBlock(rt.arena, &.{.{ .name = try rt.pool.intern("tag"), .value = try value.strVal(rt.arena, tag) }});
}

/// `{$prop tag "some" $decl v <x>}` — the shape BOOTSTRAP.md §2 gives
/// `str_to_int`, so that `$try x none` reads naturally at the call site.
pub fn some(rt: *Runtime, v: Value) Error!Value {
    return value.makeBlock(
        rt.arena,
        &.{.{ .name = try rt.pool.intern("v"), .value = v }},
        &.{.{ .name = try rt.pool.intern("tag"), .value = value.litStr("some") }},
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
        .str => |v| v.bytes,
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

/// §8's explicit `Int` arithmetic: wrapping is two's complement modulo 2^64,
/// saturating clamps to `Int`'s range. Neither panics, which is their point.
fn addWrapFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "add_wrap", span)) +% (try wantInt(rt, args, 1, "add_wrap", span)) };
}

fn subWrapFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "sub_wrap", span)) -% (try wantInt(rt, args, 1, "sub_wrap", span)) };
}

fn mulWrapFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "mul_wrap", span)) *% (try wantInt(rt, args, 1, "mul_wrap", span)) };
}

fn addSatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "add_sat", span)) +| (try wantInt(rt, args, 1, "add_sat", span)) };
}

fn subSatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "sub_sat", span)) -| (try wantInt(rt, args, 1, "sub_sat", span)) };
}

fn mulSatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "mul_sat", span)) *| (try wantInt(rt, args, 1, "mul_sat", span)) };
}

/// §8's bitwise operators, on `Int`'s two's complement representation.
fn bandFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "band", span)) & (try wantInt(rt, args, 1, "band", span)) };
}

fn borFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "bor", span)) | (try wantInt(rt, args, 1, "bor", span)) };
}

fn bxorFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    return .{ .int = (try wantInt(rt, args, 0, "bxor", span)) ^ (try wantInt(rt, args, 1, "bxor", span)) };
}

/// A shift count outside 0..63 panics, as `Int`'s other failures do. `shl` discards
/// the bits shifted out — it is a bit operation, not arithmetic — and `shr` is
/// arithmetic, copying the sign bit in.
fn shiftCount(rt: *Runtime, args: []const Value, name: []const u8, span: Span) Error!u6 {
    const n = try wantInt(rt, args, 1, name, span);
    if (n < 0 or n > 63) return rt.panic(span, "shift count {d} out of range in {s}", .{ n, name });
    return @intCast(n);
}

fn shlFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "shl", span);
    return .{ .int = a << try shiftCount(rt, args, "shl", span) };
}

fn shrFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantInt(rt, args, 0, "shr", span);
    return .{ .int = a >> try shiftCount(rt, args, "shr", span) };
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

/// §8's `eq`, on everything the subset has. A `Float` operand is refused rather
/// than compared: its value is literal *text* here (BOOTSTRAP §1.2), and text
/// equality is not float equality — `1.0` and `1.00` are one number.
fn eqFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    try noFloat(rt, args, "eq", span);
    return switch (args[0]) {
        .int => .{ .bool = (try wantInt(rt, args, 1, "eq", span)) == args[0].int },
        .str => .{ .bool = std.mem.eql(u8, args[0].str.bytes, try wantStr(rt, args, 1, "eq", span)) },
        .bool => |a| switch (args[1]) {
            .bool => |b| .{ .bool = a == b },
            else => rt.fail(span, "eq expects Bool for operand 2, found {s}", .{args[1].typeName()}),
        },
        else => rt.fail(span, "eq expects Int, Str or Bool, found {s}", .{args[0].typeName()}),
    };
}

fn noFloat(rt: *Runtime, args: []const Value, name: []const u8, span: Span) Error!void {
    for (args) |a| if (a == .float)
        return rt.fail(span, "{s} on a Float is outside the bootstrap subset (BOOTSTRAP 1.2)", .{name});
}

/// `to_float` has only a `Float` result, so stage 0 refuses it outright.
fn toFloatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    _ = args;
    return rt.fail(span, "to_float is outside the bootstrap subset (BOOTSTRAP 1.2)", .{});
}

/// §8's `to_int`: from a `Str` it is `str_to_int`.
fn toIntFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    try noFloat(rt, args, "to_int", span);
    return strToIntFn(rt, args, span);
}

/// §8's `to_str`: from an `Int` it is `int_to_str`.
fn toStrFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    try noFloat(rt, args, "to_str", span);
    return intToStrFn(rt, args, span);
}

fn concatFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = try wantStr(rt, args, 0, "concat", span);
    const b = try wantStr(rt, args, 1, "concat", span);
    const out = try rt.arena.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return value.strVal(rt.arena, out);
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
    return value.strVal(rt.arena, s[lo..hi]);
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

/// `from_code (cp)` → `none | some Str` — one code point as a `Str`.
///
/// **This is an addition to SPEC.md §8, not an implementation of it.** §8 gives
/// `byte` to read a byte out of a `Str` but nothing to build a `Str` from a
/// code point, and §3.1 says "There is no character type: a character is a
/// one-code-point substring" — which only helps if the character already
/// exists in some `Str`. Decoding the `\u{…}` escape that §2.1 requires means
/// producing a code point that appears nowhere in the source, so a lexer
/// written in morphl cannot do it with §8's intrinsics alone.
///
/// Validating here is what keeps §3.1's invariant: surrogates and
/// out-of-range values come back as `none` rather than as an invalid `Str`.
/// See BOOTSTRAP.md §7.
fn fromCodeFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const cp = try wantInt(rt, args, 0, "from_code", span);
    const c: u21 = std.math.cast(u21, cp) orelse return tagBlock(rt, "none");
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return tagBlock(rt, "none");
    return some(rt, try value.strVal(rt.arena, try rt.arena.dupe(u8, buf[0..n])));
}

fn intToStrFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const v = try wantInt(rt, args, 0, "int_to_str", span);
    return value.strVal(rt.arena, try std.fmt.allocPrint(rt.arena, "{d}", .{v}));
}

/// §8's `str_to_int`: exactly §2.1's integer-literal grammar — an optional `-`, then one
/// or more decimal digits, in `Int`'s range. Zig's `parseInt` also takes `+` and `_`
/// between digits, which no morphl literal has, so the text is checked first: a string
/// that does not spell an integer literal is `none`, not a guess.
fn strToIntFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "str_to_int", span);
    const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (digits.len == 0) return tagBlock(rt, "none");
    for (digits) |c| if (c < '0' or c > '9') return tagBlock(rt, "none");
    const v = std.fmt.parseInt(i64, s, 10) catch {
        return tagBlock(rt, "none");
    };
    return some(rt, .{ .int = v });
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
    const msg: []const u8 = switch (args[0]) {
        .str => |s| s.bytes,
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

/// `eprint (s)`: `print` to stderr. §8 puts both in the per-target platform
/// ("files"), and BOOTSTRAP §2 stands them in as builtins. It exists because
/// `panic` was the only way to stderr and it aborts, so a compiled compiler
/// could not report a warning without putting it in the C on stdout.
fn eprintFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const s = try wantStr(rt, args, 0, "eprint", span);
    if (rt.err_out) |w| {
        w.writeAll(s) catch return rt.fail(span, "eprint failed to write", .{});
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
/// TEMPORARY: set from `MORPHL_TRACE_READS`. Stage 1's `$import` loads a
/// module by calling §8's `read_file`, so one line per call counts how many
/// times each module is actually loaded — which `put_snap` can undo.
pub var trace_reads: bool = false;

fn readFileFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const path = try wantStr(rt, args, 0, "read_file", span);
    if (trace_reads) std.debug.print("READ {s}\n", .{path});
    const p = rt.platform orelse
        return rt.fail(span, "read_file is unavailable: no platform was configured", .{});
    const bytes = p.readFile(rt.arena, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return tagBlock(rt, "none"),
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) return tagBlock(rt, "none");
    return some(rt, try value.strVal(rt.arena, bytes));
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
        error.Failed => return tagBlock(rt, "err"),
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
    for (a.elems, list) |*cell, s| cell.* = .{ .value = try value.strVal(rt.arena, s) };
    return .{ .array = a };
}

/// BOOTSTRAP §2's `run (argv)` → `none | {$prop tag "some" $decl v status}`. The
/// streams are flushed first so the child's output follows what this program has
/// already printed, as the compiled runtime's `mpl_run` does.
fn runFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    const a = switch (args[0]) {
        .array => |x| x,
        else => return rt.fail(span, "run expects an array, found {s}", .{args[0].typeName()}),
    };
    const p = rt.platform orelse
        return rt.fail(span, "run is unavailable: no platform was configured", .{});
    const argv = try rt.arena.alloc([]const u8, a.elems.len);
    for (a.elems, argv) |cell, *o| o.* = switch (cell.value) {
        .str => |s| s.bytes,
        else => return rt.fail(span, "run expects an array of Str", .{}),
    };
    if (rt.out) |w| w.flush() catch {};
    if (rt.err_out) |w| w.flush() catch {};
    const status = p.run(rt.arena, argv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return tagBlock(rt, "none"),
    };
    return some(rt, .{ .int = status });
}

/// §8's FFI addresses exist only for `$extern`, which stage 0 leaves out of the
/// subset (BOOTSTRAP §1.2), so the names are here and refuse.
fn ffiFn(rt: *Runtime, args: []const Value, span: Span) Error!Value {
    _ = args;
    return rt.fail(span, "the FFI intrinsics are outside the bootstrap subset (BOOTSTRAP 1.2)", .{});
}

const raw_alloc_b: value.Builtin = .{ .name = "raw_alloc", .arity = 1, .func = ffiFn };
const raw_free_b: value.Builtin = .{ .name = "raw_free", .arity = 1, .func = ffiFn };

const table = [_]value.Builtin{
    .{ .name = "add", .arity = 2, .func = addFn },
    .{ .name = "sub", .arity = 2, .func = subFn },
    .{ .name = "mul", .arity = 2, .func = mulFn },
    .{ .name = "div", .arity = 2, .func = divFn },
    .{ .name = "mod", .arity = 2, .func = modFn },
    .{ .name = "neg", .arity = 1, .func = negFn },
    .{ .name = "lt", .arity = 2, .func = ltFn },
    .{ .name = "eq", .arity = 2, .func = eqFn },
    .{ .name = "add_wrap", .arity = 2, .func = addWrapFn },
    .{ .name = "sub_wrap", .arity = 2, .func = subWrapFn },
    .{ .name = "mul_wrap", .arity = 2, .func = mulWrapFn },
    .{ .name = "add_sat", .arity = 2, .func = addSatFn },
    .{ .name = "sub_sat", .arity = 2, .func = subSatFn },
    .{ .name = "mul_sat", .arity = 2, .func = mulSatFn },
    .{ .name = "band", .arity = 2, .func = bandFn },
    .{ .name = "bor", .arity = 2, .func = borFn },
    .{ .name = "bxor", .arity = 2, .func = bxorFn },
    .{ .name = "shl", .arity = 2, .func = shlFn },
    .{ .name = "shr", .arity = 2, .func = shrFn },
    .{ .name = "to_float", .arity = 1, .func = toFloatFn },
    .{ .name = "to_int", .arity = 1, .func = toIntFn },
    .{ .name = "to_str", .arity = 1, .func = toStrFn },
    .{ .name = "eq_int", .arity = 2, .func = eqIntFn },
    .{ .name = "eq_str", .arity = 2, .func = eqStrFn },
    .{ .name = "concat", .arity = 2, .func = concatFn },
    .{ .name = "len", .arity = 1, .func = lenFn },
    .{ .name = "slice", .arity = 3, .func = sliceFn },
    .{ .name = "byte", .arity = 2, .func = byteFn },
    .{ .name = "int_to_str", .arity = 1, .func = intToStrFn },
    .{ .name = "str_to_int", .arity = 1, .func = strToIntFn },
    .{ .name = "from_code", .arity = 1, .func = fromCodeFn },
    .{ .name = "array", .arity = 2, .func = arrayFn },
    .{ .name = "at", .arity = 2, .func = atFn },
    .{ .name = "alen", .arity = 1, .func = alenFn },
    .{ .name = "panic", .arity = 1, .func = panicFn },
    .{ .name = "print", .arity = 1, .func = printFn },
    .{ .name = "eprint", .arity = 1, .func = eprintFn },
    .{ .name = "read_file", .arity = 1, .func = readFileFn },
    .{ .name = "write_file", .arity = 2, .func = writeFileFn },
    .{ .name = "args", .arity = 0, .func = argsFn },
    .{ .name = "run", .arity = 1, .func = runFn },
    .{ .name = "str_ptr", .arity = 1, .func = ffiFn },
    .{ .name = "str_from_ptr", .arity = 2, .func = ffiFn },
    .{ .name = "raw_alloc", .arity = 1, .func = ffiFn },
    .{ .name = "raw_free", .arity = 1, .func = ffiFn },
    .{ .name = "array_ptr", .arity = 1, .func = ffiFn },
    .{ .name = "box_ptr", .arity = 1, .func = ffiFn },
    .{ .name = "unbox", .arity = 2, .func = ffiFn },
};

test "the root block is complete per BOOTSTRAP 2" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena);
    var rt: Runtime = .{ .arena = arena, .diags = &diags, .pool = &pool };

    const scope = try rootScope(arena, &rt);
    for ([_][]const u8{
        // Numeric, comparison, strings, conversion, arrays, control.
        "add",        "sub",        "mul",   "div",  "mod",   "neg",   "lt",
        "eq",         "to_float",   "to_int", "to_str",
        "add_wrap",   "sub_wrap",   "mul_wrap", "add_sat", "sub_sat", "mul_sat",
        "band",       "bor",        "bxor",  "shl",  "shr",
        "eq_int",     "eq_str",     "concat", "len", "slice", "byte",
        "int_to_str", "str_to_int", "from_code", "array", "at", "alen", "panic",
        // Shapes (§4.15) and platform.
        "err",        "none",       "print", "eprint", "read_file", "write_file", "args",
        "run",        "str_ptr",    "str_from_ptr", "array_ptr", "box_ptr", "unbox",
        "raw_alloc",  "raw_free",   "allocator",
    }) |name| {
        if (scope.findLocalText(name) == null) {
            std.debug.print("root block is missing '{s}'\n", .{name});
            return error.MissingIntrinsic;
        }
    }
}

// Stage 0's root block and stage 1's `root_env` must name exactly the same
// things.
//
// They are two hand-written lists of the same set — one here as values, one in
// `stage1/infer.mpl` as types — and nothing but this test keeps them in step.
// Four names (`array`, `at`, `alen`, `args`) were missing from stage 1's for
// long enough that every driver reported unknown names against itself, which
// is what a missing entry looks like: stage-1 source calls something the
// checker has never heard of, and only the file that calls it fails.
//
// Stage 0's side is read from `rootScope`, not from `table`, because `err` and
// `none` are §4.15 shapes rather than builtins. Stage 1's side is scraped from
// the text of its `root_env` declaration, so keep the type expressions in
// there to *named* helpers — a string literal written inline would read as a
// name.
test "the two root blocks name the same things" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena);
    var rt: Runtime = .{ .arena = arena, .diags = &diags, .pool = &pool };

    const scope = try rootScope(arena, &rt);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    const src = std.Io.Dir.cwd().readFileAlloc(
        tio,
        "stage1/infer.mpl",
        std.testing.allocator,
        .limited(1 << 22),
    ) catch |e| {
        std.debug.print("cannot read stage1/infer.mpl ({s}); the test needs the build root as cwd\n", .{@errorName(e)});
        return e;
    };
    defer std.testing.allocator.free(src);

    // The `root_env` declaration runs to the next top-level `$decl`.
    const start = std.mem.indexOf(u8, src, "\n$decl root_env") orelse return error.NoRootEnv;
    const rest = src[start + 1 ..];
    const end = std.mem.indexOf(u8, rest, "\n$decl ") orelse rest.len;
    const span = rest[0..end];

    var named: std.StringHashMapUnmanaged(void) = .empty;
    defer named.deinit(std.testing.allocator);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, span, i, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, span, open + 1, '"') orelse break;
        try named.put(std.testing.allocator, span[open + 1 .. close], {});
        i = close + 1;
    }

    var missing: usize = 0;
    for (scope.decls.items) |slot| {
        if (!named.contains(slot.name)) {
            std.debug.print("stage 1's root_env is missing '{s}'\n", .{slot.name});
            missing += 1;
        }
    }
    var it = named.keyIterator();
    while (it.next()) |name| {
        if (scope.findLocalText(name.*) == null) {
            std.debug.print("stage 0's root block is missing '{s}'\n", .{name.*});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "overflow and division by zero panic" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
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
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const s: Value = value.litStr("héllo"); // 'é' is two bytes
    try std.testing.expectEqual(@as(i64, 6), (try lenFn(&rt, &.{s}, span)).int);
    try std.testing.expectEqualStrings("h", (try sliceFn(&rt, &.{ s, .{ .int = 0 }, .{ .int = 1 } }, span)).str.bytes);
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
            .runFn = run,
        };
    }

    /// A test platform starts no processes.
    fn run(ctx: *const anyopaque, arena: Allocator, argv: []const []const u8) value.Platform.PlatformError!i64 {
        _ = ctx;
        _ = arena;
        _ = argv;
        return error.Failed;
    }
};

test "from_code builds one code point and validates it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const a = try fromCodeFn(&rt, &.{.{ .int = 65 }}, span);
    try std.testing.expectEqualStrings("A", a.block.findText("v").?.str.bytes);
    const emoji = try fromCodeFn(&rt, &.{.{ .int = 0x1F600 }}, span);
    try std.testing.expectEqualStrings("\u{1F600}", emoji.block.findText("v").?.str.bytes);

    // A surrogate and an out-of-range value must not produce an invalid Str.
    for ([_]i64{ 0xD800, 0x110000, -1 }) |bad| {
        const r = try fromCodeFn(&rt, &.{.{ .int = bad }}, span);
        try std.testing.expectEqualStrings("none", r.block.findText("tag").?.str.bytes);
    }
}

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
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{
        .arena = arena_state.allocator(),
        .diags = &diags,
        .pool = &pool,
        .platform = host.platform(),
    };

    const ok = try readFileFn(&rt, &.{value.litStr("good")}, span);
    try std.testing.expectEqualStrings("some", ok.block.findText("tag").?.str.bytes);
    try std.testing.expectEqualStrings("hi", ok.block.findText("v").?.str.bytes);

    // Missing file and invalid UTF-8 are both `none`, not errors: a Str is
    // always valid UTF-8, so bytes only become one through a validating read.
    const missing = try readFileFn(&rt, &.{value.litStr("nope")}, span);
    try std.testing.expectEqualStrings("none", missing.block.findText("tag").?.str.bytes);
    const binary = try readFileFn(&rt, &.{value.litStr("binary")}, span);
    try std.testing.expectEqualStrings("none", binary.block.findText("tag").?.str.bytes);
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
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{
        .arena = arena_state.allocator(),
        .diags = &diags,
        .pool = &pool,
        .platform = host.platform(),
    };

    const wrote = try writeFileFn(&rt, &.{ value.litStr("out"), value.litStr("body") }, span);
    try std.testing.expect(wrote == .unit);
    try std.testing.expectEqualStrings("out", sink.?.path);
    try std.testing.expectEqualStrings("body", sink.?.bytes);

    const failing: FakePlatform = .{ .files = &.{}, .written = &sink, .fail_writes = true };
    rt.platform = failing.platform();
    const failed = try writeFileFn(&rt, &.{ value.litStr("out"), value.litStr("body") }, span);
    try std.testing.expectEqualStrings("err", failed.block.findText("tag").?.str.bytes);

    rt.platform = host.platform();
    const argv = try argsFn(&rt, &.{}, span);
    try std.testing.expectEqual(@as(usize, 2), argv.array.elems.len);
    try std.testing.expectEqualStrings("bb", argv.array.elems[1].value.str.bytes);
}

test "platform intrinsics decline when no host is configured" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    try std.testing.expectError(error.Halt, readFileFn(&rt, &.{value.litStr("x")}, span));
    try std.testing.expectError(error.Halt, argsFn(&rt, &.{}, span));
}

test "str_to_int returns the option shape that $try none expects" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    const ok = try strToIntFn(&rt, &.{value.litStr("42")}, span);
    try std.testing.expectEqualStrings("some", ok.block.findText("tag").?.str.bytes);
    try std.testing.expectEqual(@as(i64, 42), ok.block.findText("v").?.int);

    const bad = try strToIntFn(&rt, &.{value.litStr("4x")}, span);
    try std.testing.expectEqualStrings("none", bad.block.findText("tag").?.str.bytes);

    // §2.1's literal grammar and nothing more: no separator, no `+`, no bare sign; the
    // bottom of the range does parse.
    inline for (.{ "1_0", "+5", "-", "", " 5" }) |t| {
        const r = try strToIntFn(&rt, &.{value.litStr(t)}, span);
        try std.testing.expectEqualStrings("none", r.block.findText("tag").?.str.bytes);
    }
    const lo = try strToIntFn(&rt, &.{value.litStr("-9223372036854775808")}, span);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), lo.block.findText("v").?.int);
}

test "eq, to_int and to_str take the subset's candidates and refuse a Float" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    var pool: lexer.StringPool = .init(arena_state.allocator());
    var rt: Runtime = .{ .arena = arena_state.allocator(), .diags = &diags, .pool = &pool };
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .col = 1 };

    try std.testing.expect((try eqFn(&rt, &.{ .{ .int = 3 }, .{ .int = 3 } }, span)).bool);
    try std.testing.expect(!(try eqFn(&rt, &.{ value.litStr("a"), value.litStr("b") }, span)).bool);
    try std.testing.expect((try eqFn(&rt, &.{ .{ .bool = false }, .{ .bool = false } }, span)).bool);
    try std.testing.expectEqualStrings("12", (try toStrFn(&rt, &.{.{ .int = 12 }}, span)).str.bytes);
    const n = try toIntFn(&rt, &.{value.litStr("7")}, span);
    try std.testing.expectEqual(@as(i64, 7), n.block.findText("v").?.int);

    const f: Value = .{ .float = value.litStr("1.5").str };
    try std.testing.expectError(error.Halt, eqFn(&rt, &.{ f, f }, span));
    try std.testing.expectError(error.Halt, toStrFn(&rt, &.{f}, span));
    try std.testing.expectError(error.Halt, toFloatFn(&rt, &.{.{ .int = 1 }}, span));
}
