//! Runtime values for stage 0 — BOOTSTRAP.md §3.
//!
//! Stage 0 evaluates dynamically and does no static type checking, so a value
//! carries its own shape. SPEC.md §7.5 already requires union-typed values to
//! carry a discriminator, and §4.10 makes a prop's *value* part of its block's
//! type identity, so every block carries its props at runtime. That is exactly
//! what the four pattern shapes of BOOTSTRAP.md §1.3 need in order to be
//! testable without inference.
//!
//! Nothing here is ever freed. §7.6 says region inference widens rather than
//! fails, so "every allocation is root-region" is a spec-legal stage 0: it
//! leaks, and leaking is the blessed failure mode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const ast = @import("ast");

const Span = diag.Span;
const Node = ast.Node;
pub const Platform = @import("platform.zig").Platform;

pub const Value = union(enum) {
    /// `()` and `{}` (§2.3).
    unit,
    int: i64,
    /// Float *literal text*. BOOTSTRAP.md §1.2 drops float arithmetic from
    /// stage 0 but not float literals, so these flow through untouched.
    float: []const u8,
    /// Always valid UTF-8 (§3.1); the lexer establishes that invariant.
    str: []const u8,
    /// `true`/`false` are distinct nullary tag types (§3.2).
    bool: bool,
    /// A block: scope, record, module, namespace, trait — all one thing (§3.3).
    block: *Block,
    /// A tuple (§2.3). Always 2+ elements; one-element groups fold away.
    group: []Value,
    func: *Func,
    template: *Template,
    /// Storage created by `$new` (§4.2) — the *only* way storage exists.
    ///
    /// Stage 0 does not distinguish `&T` from `&mut T`: the difference is
    /// entirely static (§5.3), and `$const` is out of the subset. `$mut` is
    /// therefore an identity with a check that its operand is a reference.
    ref: *Cell,
    array: *Array,
    builtin: *const Builtin,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .unit => "unit",
            .int => "Int",
            .float => "Float",
            .str => "Str",
            .bool => "Bool",
            .block => "block",
            .group => "group",
            .func => "function",
            .template => "template",
            .ref => "reference",
            .array => "array",
            .builtin => "intrinsic",
        };
    }

    /// Reach through storage. §5.4: a reference behaves as its pointee
    /// *wherever a value is expected* — call arguments, projection targets,
    /// `$match` scrutinees, `$set`'s right-hand side, `$new`'s operand.
    /// It stays a reference where nothing expects a value, which is why this
    /// is applied at specific sites rather than eagerly.
    pub fn deref(self: Value) Value {
        var v = self;
        // A chain, since `$new r` on a reference-typed cell can nest.
        var guard: u32 = 0;
        while (v == .ref and guard < 1024) : (guard += 1) v = v.ref.value;
        return v;
    }
};

/// One storage location. `$new` makes these and nothing else does.
pub const Cell = struct {
    value: Value,
};

/// A block's fields. `$decl` fields are ordered and form the layout; `$prop`
/// fields are in the namespace and the type but have no layout (§3.3, §4.10).
pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Block = struct {
    /// Source order — this *is* the layout (§7.2), and order is part of type
    /// identity, so it is never sorted or reordered.
    decls: []Field,
    /// Order-insensitive: props cost no slot.
    props: []Field,

    pub fn findDecl(self: *const Block, name: []const u8) ?Value {
        for (self.decls) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    pub fn findProp(self: *const Block, name: []const u8) ?Value {
        for (self.props) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    /// Projection reaches decls and props uniformly (§4.10: "Access is
    /// uniform: `p.len` and `point.len` both work").
    pub fn find(self: *const Block, name: []const u8) ?Value {
        return self.findDecl(name) orelse self.findProp(name);
    }
};

pub const Array = struct {
    /// Elements are cells so that `at` can hand out a reference into the
    /// array — §7.6's "fat reference (base + index)" rather than an interior
    /// pointer.
    elems: []Cell,
};

pub const Func = struct {
    params: []Param,
    body: *const Node,
    /// Captured lexical scope, held by pointer.
    ///
    /// §7.3 says closures capture by copy and that this is unobservable
    /// because bindings are immutable. Stage 0 captures the scope *chain* by
    /// pointer instead, which is observationally identical for immutable
    /// bindings and is additionally what makes §4.1 self-reference work: a
    /// recursive function reads its own name through the very slot that its
    /// `$decl` fills after the closure is built.
    scope: *Scope,
    /// The file this `$func` literal was written in.
    ///
    /// A span says where, but not in which file, and `$import` (§4.14) means a
    /// function is routinely *called* from a file other than the one it was
    /// written in. Without this, an error raised inside an imported function
    /// gets labelled with the importing file's path.
    file: ?[]const u8 = null,
};

pub const Param = struct {
    name: []const u8,
    default: *const Node,
    /// Whether this parameter wants *storage* rather than a value.
    ///
    /// §5.4 decides this from the parameter's type, which stage 0 does not
    /// have. It is approximated syntactically: a default written `$new …`,
    /// `$mut …` or `$const …` wants storage, anything else wants a value.
    /// That matches how §5.3 says parameters are idiomatically written.
    wants_storage: bool,
};

pub const Template = struct {
    /// Generic parameter names (§4.9).
    generics: [][]const u8,
    body: *const Node,
    scope: *Scope,
};

/// A lexical scope: the thing a block *is* (§3.3, §10.1 "a block's value is
/// its environment").
///
/// Two rules from the spec shape this:
///
///   * **No hoisting** (§4.11). `decls` grows in source order and a name is
///     visible only from its own `$decl` onward, so the slot list doubles as
///     the visibility rule.
///   * **Props are visible throughout their block, regardless of order**
///     (§4.10), and are "typed together as one system". They are therefore
///     pre-collected before the block runs and evaluated lazily on first read,
///     which is what makes order-independence work without a hoisting pass.
pub const Scope = struct {
    parent: ?*Scope,
    decls: std.ArrayList(Slot) = .empty,
    props: []PropSlot = &.{},
    arena: Allocator,

    /// An ordered slot. `value == null` means the slot was reserved by `$fwd`
    /// and its completing `$decl` has not run yet (§4.11).
    pub const Slot = struct {
        name: []const u8,
        value: ?Value,
        /// Where the name was introduced, for diagnostics.
        span: Span,
    };

    pub const PropSlot = struct {
        name: []const u8,
        expr: *const Node,
        span: Span,
        /// The scope the initializer is evaluated in.
        ///
        /// §4.10: "A prop initializer may reference other props and enclosing
        /// scopes, but **not** ordered siblings (there is no instance to read
        /// them from)." So this is deliberately *not* the block's own scope: it
        /// is a sibling scope carrying the same props with no `$decl` slots.
        env: *Scope,
        state: enum { pending, in_progress, done } = .pending,
        value: Value = .unit,
    };

    pub const Entry = union(enum) {
        /// A `$decl` slot that has run.
        value: Value,
        /// A `$fwd` slot whose `$decl` has not run yet, or a `$decl` whose own
        /// initializer is still being evaluated (§4.1: readable only from
        /// inside a `$func` body, i.e. only after initialization).
        uninitialized: Slot,
        /// A prop, possibly not yet forced. The caller evaluates it.
        prop: *PropSlot,
    };

    pub fn init(arena: Allocator, parent: ?*Scope) Allocator.Error!*Scope {
        const s = try arena.create(Scope);
        s.* = .{ .parent = parent, .arena = arena };
        return s;
    }

    pub fn findLocal(self: *Scope, name: []const u8) ?Entry {
        // Later slots shadow earlier ones, so walk backwards. A linear scan
        // is deliberate: it was measured against a hash index over `decls` and
        // the difference was lost in the noise, because scopes are small and
        // resolution is not where the time goes.
        var i = self.decls.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.decls.items[i];
            if (std.mem.eql(u8, slot.name, name)) {
                return if (slot.value) |v| .{ .value = v } else .{ .uninitialized = slot };
            }
        }
        for (self.props) |*p| {
            if (std.mem.eql(u8, p.name, name)) return .{ .prop = p };
        }
        return null;
    }

    /// Reserve an ordered slot (`$fwd`, and `$decl` before its initializer
    /// runs) and return its index.
    pub fn reserve(self: *Scope, name: []const u8, span: Span) Allocator.Error!usize {
        try self.decls.append(self.arena, .{ .name = name, .value = null, .span = span });
        return self.decls.items.len - 1;
    }

    /// Complete a reserved slot. Returns false if it was already completed.
    pub fn complete(self: *Scope, index: usize, v: Value) bool {
        if (self.decls.items[index].value != null) return false;
        self.decls.items[index].value = v;
        return true;
    }

    /// The slot reserved by `$fwd` for `name` and still awaiting its `$decl`
    /// (§4.11: "Layout position is the `$fwd`, not the `$decl`").
    pub fn pendingSlot(self: *Scope, name: []const u8) ?usize {
        for (self.decls.items, 0..) |slot, i| {
            if (slot.value == null and std.mem.eql(u8, slot.name, name)) return i;
        }
        return null;
    }
};

/// What an intrinsic is handed. Deliberately *not* the evaluator: intrinsics
/// need to allocate, to report errors and (for `print`) to write, but none of
/// them needs to evaluate morphl, so they cannot accidentally become macros.
pub const Runtime = struct {
    arena: Allocator,
    diags: *diag.Diagnostics,
    out: ?*std.Io.Writer = null,
    /// Supplied by the driver; absent when nothing injected one, in which case
    /// the platform intrinsics decline rather than inventing an answer.
    platform: ?Platform = null,

    pub fn fail(self: *Runtime, span: Span, comptime fmt: []const u8, args: anytype) Error {
        self.diags.add(span, fmt, args);
        return error.Halt;
    }

    pub fn panic(self: *Runtime, span: Span, comptime fmt: []const u8, args: anytype) Error {
        self.diags.add(span, "panic: " ++ fmt, args);
        return error.Panicked;
    }
};

/// Errors that can come out of evaluation.
///
///   * `Halt` — an error already recorded in `Diagnostics`.
///   * `Panicked` — a morphl `panic` (§8): aborts, no catch, no unwinding.
///   * `TryReturn` — `$try` matched; control flow, not failure (§4.15).
pub const Error = error{
    Halt,
    Panicked,
    TryReturn,
    OutOfMemory,
};

pub const Builtin = struct {
    name: []const u8,
    /// `null` means "any arity"; the intrinsic checks for itself.
    arity: ?usize,
    func: *const fn (*Runtime, []const Value, Span) Error!Value,
};

// ------------------------------------------------------------------ helpers

pub fn newCell(arena: Allocator, v: Value) Allocator.Error!Value {
    const cell = try arena.create(Cell);
    cell.* = .{ .value = v };
    return .{ .ref = cell };
}

/// A block of props only — the shape of `err`, `none` and every tag (§4.15).
pub fn propBlock(arena: Allocator, props: []const Field) Allocator.Error!Value {
    const b = try arena.create(Block);
    b.* = .{ .decls = &.{}, .props = try arena.dupe(Field, props) };
    return .{ .block = b };
}

pub fn makeBlock(arena: Allocator, decls: []const Field, props: []const Field) Allocator.Error!Value {
    const b = try arena.create(Block);
    b.* = .{
        .decls = try arena.dupe(Field, decls),
        .props = try arena.dupe(Field, props),
    };
    return .{ .block = b };
}

/// Structural equality, used for comparing prop *values* when testing a tag
/// pattern (§5.1: "for every prop of `T`, `S` has the same prop with the
/// **same value**").
pub fn equal(a: Value, b: Value, depth: u32) bool {
    if (depth == 0) return false;
    return switch (a) {
        .unit => b == .unit,
        .int => |x| b == .int and b.int == x,
        .float => |x| b == .float and std.mem.eql(u8, b.float, x),
        .str => |x| b == .str and std.mem.eql(u8, b.str, x),
        .bool => |x| b == .bool and b.bool == x,
        .block => |x| blk: {
            if (b != .block) break :blk false;
            const y = b.block;
            if (x.decls.len != y.decls.len or x.props.len != y.props.len) break :blk false;
            for (x.decls, y.decls) |fa, fb| {
                if (!std.mem.eql(u8, fa.name, fb.name)) break :blk false;
                if (!equal(fa.value, fb.value, depth - 1)) break :blk false;
            }
            for (x.props) |fa| {
                const other = y.findProp(fa.name) orelse break :blk false;
                if (!equal(fa.value, other, depth - 1)) break :blk false;
            }
            break :blk true;
        },
        .group => |x| blk: {
            if (b != .group or b.group.len != x.len) break :blk false;
            for (x, b.group) |ea, eb| {
                if (!equal(ea, eb, depth - 1)) break :blk false;
            }
            break :blk true;
        },
        .ref => |x| b == .ref and b.ref == x, // reference identity
        .array => |x| b == .array and b.array == x,
        .func => |x| b == .func and b.func == x,
        .template => |x| b == .template and b.template == x,
        .builtin => |x| b == .builtin and b.builtin == x,
    };
}

test "deref follows a chain of references" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inner = try newCell(arena, .{ .int = 7 });
    const outer = try newCell(arena, inner);
    try std.testing.expectEqual(@as(i64, 7), outer.deref().int);
    try std.testing.expect(outer.deref() == .int);
}

test "prop values participate in equality; references compare by identity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try propBlock(arena, &.{.{ .name = "tag", .value = .{ .str = "err" } }});
    const b = try propBlock(arena, &.{.{ .name = "tag", .value = .{ .str = "err" } }});
    const c = try propBlock(arena, &.{.{ .name = "tag", .value = .{ .str = "none" } }});
    try std.testing.expect(equal(a, b, 16));
    try std.testing.expect(!equal(a, c, 16));

    const r1 = try newCell(arena, .{ .int = 1 });
    const r2 = try newCell(arena, .{ .int = 1 });
    try std.testing.expect(equal(r1, r1, 16));
    try std.testing.expect(!equal(r1, r2, 16));
}
