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

/// §3.1's `Str`: a pointer and a length, boxed.
///
/// A tagged union is as wide as its widest member, so carrying two words
/// inline made every `Value` 24 bytes — and a census of what blocks actually
/// store says 91% of values are a word or less (an `Int`, a pointer, a tag).
/// Boxing the three slice payloads costs an indirection on the other 9% and
/// saves a word on every value stage 0 allocates, which is 75% of its memory.
///
/// A box is *not* identity: two boxes with the same bytes are the same string,
/// so `equal` compares `bytes` and never the pointer.
pub const Str = struct { bytes: []const u8 };

/// A group's elements, boxed for the same reason.
pub const Group = struct { elems: []Value };

/// A block of `n` `$decl` slots, header and values in one allocation.
///
/// The caller fills `fields()` afterwards — the values cannot be passed in,
/// because their home does not exist until this returns.
pub fn allocBlock(arena: Allocator, shape: *const Shape, n: usize) Allocator.Error!*Block {
    // Words rather than bytes so the alignment rides on the type; measured
    // the same as `alignedAlloc` at a runtime size, and needs no `Alignment`.
    const words = (@sizeOf(Block) + n * @sizeOf(Value) + 7) / 8;
    const raw = try arena.alloc(u64, words);
    const b: *Block = @ptrCast(raw.ptr);
    b.* = .{ .shape = shape };
    return b;
}

/// A `Str` value from bytes the caller already owns — the bytes are not
/// copied, only the box is allocated.
pub fn strVal(arena: Allocator, bytes: []const u8) Allocator.Error!Value {
    const s = try arena.create(Str);
    s.* = .{ .bytes = bytes };
    return .{ .str = s };
}

pub fn groupVal(arena: Allocator, elems: []Value) Allocator.Error!Value {
    const g = try arena.create(Group);
    g.* = .{ .elems = elems };
    return .{ .group = g };
}

/// A `Str` value for bytes known at compile time — the box is static, so a
/// Zig caller handing over a literal allocates nothing.
pub fn litStr(comptime bytes: []const u8) Value {
    const box = struct {
        const s: Str = .{ .bytes = bytes };
    };
    return .{ .str = &box.s };
}

pub const Value = union(enum) {
    /// `()` and `{}` (§2.3).
    unit,
    int: i64,
    /// Float *literal text*. BOOTSTRAP.md §1.2 drops float arithmetic from
    /// stage 0 but not float literals, so these flow through untouched.
    float: *const Str,
    /// Always valid UTF-8 (§3.1); the lexer establishes that invariant.
    str: *const Str,
    /// `true`/`false` are distinct nullary tag types (§3.2).
    bool: bool,
    /// A block: scope, record, module, namespace, trait — all one thing (§3.3).
    block: *Block,
    /// A tuple (§2.3). Always 2+ elements; one-element groups fold away.
    group: *const Group,
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

/// What a block value gets from its *source* rather than from evaluating it.
///
/// Every value built from one block literal has the same field names in the
/// same order — §7.2's layout is the source order and §5.1 makes that order
/// part of the type, so it cannot vary between instances. Props are the same
/// whenever their values are literals (§4.10 makes a prop a compile-time
/// constant). Only the `$decl` values differ per evaluation, so that is all a
/// `Block` carries of its own; the rest is shared and interned per AST node.
pub const Shape = struct {
    /// Source order — this *is* the layout (§7.2), never sorted or reordered.
    names: []const []const u8,
    /// Order-insensitive: props cost no slot.
    props: []Field,
};

pub const Block = struct {
    shape: *const Shape,
    // The `$decl` values follow this header *inline* — one allocation, and no
    // pointer to them. A block value is the single most allocated thing stage 0
    // makes (three quarters of its memory), so both the length word and the
    // pointer word are worth not having: the count is the shape's, and the
    // address is this one plus the header. See `allocBlock`.

    pub inline fn names(self: *const Block) []const []const u8 {
        return self.shape.names;
    }

    pub inline fn fields(self: *const Block) []Value {
        const raw: [*]u8 = @ptrCast(@constCast(self));
        const p: [*]Value = @ptrCast(@alignCast(raw + @sizeOf(Block)));
        return p[0..self.shape.names.len];
    }

    pub fn props(self: *const Block) []Field {
        return self.shape.props;
    }

    pub fn findDecl(self: *const Block, name: []const u8) ?Value {
        for (self.shape.names, self.fields()) |n, v| {
            if (Scope.nameEql(n, name)) return v;
        }
        return null;
    }

    pub fn findProp(self: *const Block, name: []const u8) ?Value {
        for (self.shape.props) |f| if (Scope.nameEql(f.name, name)) return f.value;
        return null;
    }

    /// Projection reaches decls and props uniformly (§4.10: "Access is
    /// uniform: `p.len` and `point.len` both work").
    pub fn find(self: *const Block, name: []const u8) ?Value {
        return self.findDecl(name) orelse self.findProp(name);
    }

    /// The same lookup, by *text* rather than identity.
    ///
    /// For Zig callers holding a string literal — tests and diagnostics —
    /// since an uninterned literal can never be identity-equal to a name that
    /// came from source. Evaluation does not use this and must not: comparing
    /// bytes here is what `perf` found to be 80% of the interpreter.
    pub fn findText(self: *const Block, name: []const u8) ?Value {
        for (self.shape.names, self.fields()) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        for (self.shape.props) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
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
    /// Whether this body can create a closure at all — a `$func`, `$template`
    /// or `$prop` anywhere inside it. When it cannot, nothing can capture the
    /// call's scope, so the scope is provably dead at return and its allocation
    /// can be reused. Computed once per `$func` literal, not per call.
    may_capture: bool = true,
    /// The file this `$func` literal was written in.
    ///
    /// A span says where, but not in which file, and `$import` (§4.14) means a
    /// function is routinely *called* from a file other than the one it was
    /// written in. Without this, an error raised inside an imported function
    /// gets labelled with the importing file's path.
    file: ?[]const u8 = null,
    /// The name this `$func` was declared under, when it had one. Only for
    /// diagnostics and the allocation profile; nothing in evaluation reads it.
    name: ?[]const u8 = null,
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
    /// Set when a `$func` or `$template` value captures this scope — or any
    /// scope below it, since §7.3's capture is of the whole chain by pointer.
    ///
    /// A scope that nothing captured is dead the moment its call returns, and
    /// since nothing is ever freed (§7.6) that is the difference between
    /// reusing one allocation and leaking one per call. Only closures can keep
    /// a scope alive: block *values* hold resolved fields, not scopes.
    captured: bool = false,

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
        return initCapacity(arena, parent, 0);
    }

    /// `slots` is how many `$decl`/`$fwd` slots this scope will hold.
    ///
    /// Sizing exactly matters more than it looks: nothing is ever freed
    /// (§7.6), and `ArrayList` grows geometrically, so a two-parameter call
    /// would reserve eight slots and keep them for the life of the program.
    /// Every call allocates a scope, and a type checker makes millions.
    pub fn initCapacity(arena: Allocator, parent: ?*Scope, slots: usize) Allocator.Error!*Scope {
        const s = try arena.create(Scope);
        s.* = .{ .parent = parent, .arena = arena };
        if (slots != 0) try s.decls.ensureTotalCapacityPrecise(arena, slots);
        return s;
    }

    /// Identifier equality: identity, not bytes.
    ///
    /// Every identifier comes from `lexer.StringPool`, so one text has exactly
    /// one slice and equal names are the *same* slice. `perf` said comparing
    /// bytes here was 80% of the interpreter — it runs once per binding per
    /// scope on every name reference, and identifiers are short enough that
    /// the call into `mem.eql` cost more than the comparison.
    ///
    /// A name that never reached the pool cannot match anything, so a missed
    /// interning shows up as "unknown name" and not as a wrong binding.
    pub inline fn nameEql(a: []const u8, b: []const u8) bool {
        return a.ptr == b.ptr and a.len == b.len;
    }

    pub fn findLocal(self: *Scope, name: []const u8) ?Entry {
        // Later slots shadow earlier ones, so walk backwards. A linear scan is
        // deliberate: a hash index over `decls` was measured and lost in the
        // noise — scopes are small, so the scan is short. What the index did
        // not address, and `perf` later showed to be 80% of the interpreter,
        // is the cost of *each* comparison: see `nameEql`.
        var i = self.decls.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.decls.items[i];
            if (nameEql(slot.name, name)) {
                return if (slot.value) |v| .{ .value = v } else .{ .uninitialized = slot };
            }
        }
        for (self.props) |*p| {
            if (nameEql(p.name, name)) return .{ .prop = p };
        }
        return null;
    }

    /// `findLocal` by *text*, for Zig callers holding a literal. See
    /// `Block.findText`: tests and diagnostics only, never evaluation.
    pub fn findLocalText(self: *Scope, name: []const u8) ?Entry {
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
            if (slot.value == null and nameEql(slot.name, name)) return i;
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
    /// The identifier pool (see `lexer.StringPool`). Every name that enters a
    /// scope or a block goes through it, so `Scope.nameEql` can compare
    /// identity instead of bytes.
    pool: *@import("lexer").StringPool,
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
    return makeBlock(arena, &.{}, props);
}

/// Build a one-off block with its own shape. For Zig callers — the root block
/// (§2) and tests — where there is no AST node to intern a shape against.
pub fn makeBlock(arena: Allocator, decls: []const Field, props: []const Field) Allocator.Error!Value {
    const names = try arena.alloc([]const u8, decls.len);
    for (decls, names) |f, *n| n.* = f.name;
    const shape = try arena.create(Shape);
    shape.* = .{ .names = names, .props = try arena.dupe(Field, props) };
    const b = try allocBlock(arena, shape, decls.len);
    for (decls, b.fields()) |f, *v| v.* = f.value;
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
        .float => |x| b == .float and std.mem.eql(u8, b.float.bytes, x.bytes),
        .str => |x| b == .str and std.mem.eql(u8, b.str.bytes, x.bytes),
        .bool => |x| b == .bool and b.bool == x,
        .block => |x| blk: {
            if (b != .block) break :blk false;
            const y = b.block;
            if (x.names().len != y.names().len or x.props().len != y.props().len) break :blk false;
            for (x.names(), x.fields(), y.names(), y.fields()) |na, va, nb, vb| {
                if (!Scope.nameEql(na, nb)) break :blk false;
                if (!equal(va, vb, depth - 1)) break :blk false;
            }
            for (x.props()) |fa| {
                const other = y.findProp(fa.name) orelse break :blk false;
                if (!equal(fa.value, other, depth - 1)) break :blk false;
            }
            break :blk true;
        },
        .group => |x| blk: {
            if (b != .group or b.group.elems.len != x.elems.len) break :blk false;
            for (x.elems, b.group.elems) |ea, eb| {
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

    const a = try propBlock(arena, &.{.{ .name = "tag", .value = litStr("err") }});
    const b = try propBlock(arena, &.{.{ .name = "tag", .value = litStr("err") }});
    const c = try propBlock(arena, &.{.{ .name = "tag", .value = litStr("none") }});
    try std.testing.expect(equal(a, b, 16));
    try std.testing.expect(!equal(a, c, 16));

    const r1 = try newCell(arena, .{ .int = 1 });
    const r2 = try newCell(arena, .{ .int = 1 });
    try std.testing.expect(equal(r1, r1, 16));
    try std.testing.expect(!equal(r1, r2, 16));
}
