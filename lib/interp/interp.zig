//! Stage 0 evaluator — BOOTSTRAP.md §3 and §5 step 3.
//!
//! Dynamic: no static type checking at all. What makes that possible is the
//! pattern restriction of BOOTSTRAP.md §1.3 — type-only positions (§5.7) hold
//! expressions that are never evaluated, and computing their *types* in general
//! would need the inference engine that stage 1 is supposed to be the only copy
//! of. Restricting patterns to four testable shapes removes that need.
//!
//! Three things here are load-bearing rather than deferrable (BOOTSTRAP.md §3):
//!
//!   * **Tail-call elimination** (§7.7). Loops *are* recursion in morphl, so
//!     without TCE any loop blows the Zig stack. `callFunc` is a trampoline and
//!     `step` is the tail-position evaluator; `eval` handles everything else and
//!     recurses. A call inside a block is never in tail position, which falls
//!     out of blocks being evaluated by `eval` rather than `step`.
//!   * **`$try` unwinding** (§4.15) to the nearest enclosing `$func`, threaded
//!     as a Zig error with a payload. It composes with TCE for free: if A tail
//!     calls B, A's frame is already gone, so returning from B *is* returning
//!     from A.
//!   * **Structural value tags** (§7.5), including prop values, since a prop's
//!     value is part of its block's type identity (§4.10).
//!
//! Nothing is ever freed: every allocation is root-region, which §7.6 blesses
//! as the failure mode of region inference (it widens, never dangles).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const value = @import("value.zig");
const builtins = @import("builtins.zig");

/// TEMPORARY: re-exported so the driver can turn the `read_file` trace on.
pub const builtins_trace_reads = &builtins.trace_reads;

const Span = diag.Span;
const Diagnostics = diag.Diagnostics;
const Node = ast.Node;
const Value = value.Value;
const Scope = value.Scope;
const Func = value.Func;
const Template = value.Template;
const Field = value.Field;
const Error = value.Error;

pub const Loader = @import("loader.zig").Loader;
pub const Platform = @import("platform.zig").Platform;

/// Guards against a Zig stack overflow from runaway *non-tail* recursion.
///
/// Tail calls cost no stack at all — that is the point of the trampoline — so
/// this only ever fires on recursion that genuinely cannot be eliminated. A
/// frame *count* is the wrong unit, since one morphl call spans several Zig
/// frames of varying size; measuring headroom from the stack position at
/// `init` turns a hard crash into a diagnostic regardless of frame size.
/// Safe on an ordinary 8MB thread. A caller that gives the interpreter a bigger
/// stack raises it through `Options.stack_bytes`.
const default_stack_bytes = 4 * 1024 * 1024;

/// §4.9: "there is a fixed instantiation depth limit and exceeding it is an
/// error."
const max_specialize_depth = 64;

/// Bound on structural pattern comparison, since `$new` cells can alias
/// cyclically. Real inferred types nest deeply — a μ-recursive list type
/// reaches well past 32 — so this is generous; the identity short-circuit in
/// `shapeMatches` is what keeps the common case cheap regardless.
const max_shape_depth = 256;

/// A `shape_cache` entry: the shape, whether its props may be reused, and —
/// when they can — the forced `PropSlot` array the evaluating scope borrows
/// instead of building one of its own.
const ShapeEntry = struct {
    shape: *value.Shape,
    props_shared: bool,
    const_props: []Scope.PropSlot = &.{},
};

pub const Interp = struct {
    arena: Allocator,
    rt: value.Runtime,
    root: *Scope,
    loader: ?Loader = null,

    /// `$import` is load-once per resolved key (§4.14).
    modules: std.StringHashMapUnmanaged(Module) = .empty,

    /// One `Shape` per block *literal*, shared by every value built from it.
    ///
    /// A block value's field names are fixed by its source: §7.2 makes source
    /// order the layout and §5.1 makes that order part of the type, so two
    /// values of one literal cannot differ in them. Props are fixed too when
    /// every initializer is *written* as a literal — §1.1 keeps one to a
    /// literal, a prop-only block, or a `$func`/`$template`, and a cons cell's
    /// `{$prop tag "cons"}` is the first case. Measured on `types.mpl`: 1,734,469 of
    /// the 1,734,504 blocks that have props have all-literal props, and names
    /// plus props were 82% of all block memory.
    ///
    /// Keyed on the item slice's address, which identifies the literal: two
    /// evaluations of one block node share it, two different nodes never do.
    /// A literal whose props are *not* shareable — one holding a `$func`,
    /// which closes over the evaluating scope, or a name, which is that
    /// scope's value — still shares the names: the entry records which case it
    /// is and the odd one out gets a fresh `Shape` pointing at the cached name
    /// array.
    shape_cache: std.AutoHashMapUnmanaged([*]const Node, ShapeEntry) = .empty,
    /// One `Str` box per `Str`/`Float` literal node — see `literalStr`.
    str_box: std.AutoHashMapUnmanaged(*const Node, *value.Str) = .empty,
    call_depth: u32 = 0,
    /// Stack position at `init`, for the headroom check in `callFunc`.
    stack_base: usize = 0,
    /// How much of it that check may spend.
    stack_bytes: usize = default_stack_bytes,
    specialize_depth: u32 = 0,
    /// The value carried by an in-flight `error.TryReturn`.
    try_payload: Value = .unit,
    /// Scopes whose call has returned without anything capturing them.
    scope_pool: std.ArrayListUnmanaged(*Scope) = .empty,
    /// Allocation profile, when the driver asked for one: bytes and calls
    /// attributed to the innermost morphl function at the moment of the
    /// allocation. Nothing is ever freed (§7.6), so bytes allocated *is* peak
    /// memory, and this says which function is responsible for it.
    stats: ?*Stats = null,
    /// Scratch for evaluated call arguments.
    ///
    /// An argument list is dead the moment `bindParams` copies it into the
    /// callee's scope, or the moment an intrinsic returns — but nothing is ever
    /// freed (§7.6), so allocating one per call leaks a few dozen bytes every
    /// time. A stack works because the lists nest exactly like calls do: an
    /// argument that is itself a call pushes above ours and pops back.
    arg_stack: []Value = &.{},
    arg_top: usize = 0,

    pub const Stats = struct {
        backing: Allocator,
        /// Innermost named function currently running.
        current: []const u8 = "(top level)",
        rows: std.StringHashMapUnmanaged(Row) = .empty,
        total: u64 = 0,
        scopes_fresh: u64 = 0,
        scopes_pooled: u64 = 0,
        /// One function to measure *inclusively* — every byte allocated
        /// between its entry and its return, nested calls included. Counted
        /// only for the outermost activation, so recursion is not double
        /// counted. For a function returning a scalar this is exactly the
        /// garbage it produces, since nothing it built can have escaped.
        incl_name: ?[]const u8 = null,
        /// Rank the report by *calls* rather than bytes. A function that scans
        /// without allocating — `find_ty_at`, `same` — is invisible in a
        /// byte-ranked profile however much of the run it is, and stage 0's
        /// time is very nearly proportional to calls (measured: 0.054 µs a
        /// lookup, flat across a 1000x range of program sizes).
        by_calls: bool = false,
        incl_depth: u32 = 0,
        incl_bytes: u64 = 0,
        incl_calls: u64 = 0,
        /// How much of the total is `$new` storage versus block *values*.
        /// Stage 0 heap-allocates every value; compiled, only `$new` is heap
        /// (§4.2) and a value lives in its frame — so this says how much of
        /// the run's allocation is even a candidate for the heap.
        /// Deepest nesting reached, and the stack it cost. The stack unwinds
        /// like any other — this is the high-water mark, not a total.
        max_depth: u32 = 0,
        max_stack: usize = 0,
        cell_bytes: u64 = 0,
        cell_n: u64 = 0,
        blk_bytes: u64 = 0,
        blk_n: u64 = 0,
        /// Where every allocated byte went, by construct — the breakdown the
        /// per-function profile cannot give, since one function allocates
        /// several kinds of thing. This is what identified block values as
        /// 75% of stage 0's memory.
        bucket: Bucket = .other,
        /// How many block values each literal produced.
        ///
        /// The bucket breakdown says *what kind* of thing the memory is; this
        /// says which source construct made it, by field names. It is what
        /// answered "why does emitting the compiler need 2 GB" — 60% of every
        /// block allocated is one literal, `P.list`'s cons cell.
        shape_n: std.AutoHashMapUnmanaged(*const value.Shape, u64) = .empty,
        buckets: [@typeInfo(Bucket).@"enum".fields.len]u64 = @splat(0),

        pub const Bucket = enum {
            other,
            block,
            shape,
            props,
            cell,
            group,
            func,
            template,
            scope,
            slots,
            args,
            builtin,
        };

        pub const Row = struct { bytes: u64 = 0, calls: u64 = 0, allocs: u64 = 0 };

        fn note(self: *Stats, len: usize) void {
            self.total += len;
            self.buckets[@intFromEnum(self.bucket)] += len;
            const e = self.rows.getOrPut(self.backing, self.current) catch return;
            if (!e.found_existing) e.value_ptr.* = .{};
            e.value_ptr.bytes += len;
            e.value_ptr.allocs += 1;
        }

        fn enter(self: *Stats, name: []const u8) void {
            const e = self.rows.getOrPut(self.backing, name) catch return;
            if (!e.found_existing) e.value_ptr.* = .{};
            e.value_ptr.calls += 1;
        }

        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *Stats = @ptrCast(@alignCast(ctx));
            const p = self.backing.rawAlloc(len, a, ra);
            if (p != null) self.note(len);
            return p;
        }
        fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
            const self: *Stats = @ptrCast(@alignCast(ctx));
            return self.backing.rawResize(m, a, n, ra);
        }
        fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            const self: *Stats = @ptrCast(@alignCast(ctx));
            return self.backing.rawRemap(m, a, n, ra);
        }
        fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *Stats = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(m, a, ra);
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        pub fn allocator(self: *Stats) Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        /// Highest first, to stderr.
        const Entry = struct { name: []const u8, row: Row };

        pub fn report(self: *Stats, w: *std.Io.Writer) !void {
            var list: std.ArrayListUnmanaged(Entry) = .empty;
            var it = self.rows.iterator();
            while (it.next()) |e| try list.append(self.backing, .{ .name = e.key_ptr.*, .row = e.value_ptr.* });
            if (self.by_calls) {
                std.mem.sort(Entry, list.items, {}, struct {
                    fn lt(_: void, x: Entry, y: Entry) bool {
                        return x.row.calls > y.row.calls;
                    }
                }.lt);
            } else {
                std.mem.sort(Entry, list.items, {}, struct {
                    fn lt(_: void, x: Entry, y: Entry) bool {
                        return x.row.bytes > y.row.bytes;
                    }
                }.lt);
            }
            try w.print("\n{d:.2} GB allocated in total; bytes are charged to the innermost function running.\n\n", .{
                @as(f64, @floatFromInt(self.total)) / (1024.0 * 1024.0 * 1024.0),
            });
            // A high `fresh` count means scopes are not being recycled, which
            // is the difference between reusing one allocation per call and
            // leaking one (§7.6: nothing is ever freed).
            try w.print("scopes: {d} taken from the pool, {d} allocated fresh\n", .{ self.scopes_pooled, self.scopes_fresh });
            if (self.incl_name) |n| try w.print("inclusive: {d:.2} MB across {d} outermost calls to `{s}`\n", .{
                @as(f64, @floatFromInt(self.incl_bytes)) / (1024.0 * 1024.0), self.incl_calls, n,
            });
            try w.print("deepest nesting: {d} calls, {d:.1} MB of stack at the high-water mark\n", .{
                self.max_depth, @as(f64, @floatFromInt(self.max_stack)) / (1024.0 * 1024.0),
            });
            try w.print("$new storage: {d:.1} MB in {d} cells; block values: {d:.1} MB in {d} blocks\n\n", .{
                @as(f64, @floatFromInt(self.cell_bytes)) / (1024.0 * 1024.0), self.cell_n,
                @as(f64, @floatFromInt(self.blk_bytes)) / (1024.0 * 1024.0), self.blk_n,
            });
            for (std.enums.values(Bucket)) |b| {
                const n = self.buckets[@intFromEnum(b)];
                if (n == 0) continue;
                try w.print("  {s:<10} {d:>8.1} MB  {d:>5.1}%\n", .{
                    @tagName(b),
                    @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0),
                    100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(self.total)),
                });
            }
            try w.print("\n", .{});
            {
                const E2 = struct { shape: *const value.Shape, n: u64 };
                var sl: std.ArrayListUnmanaged(E2) = .empty;
                var it2 = self.shape_n.iterator();
                while (it2.next()) |e| try sl.append(self.backing, .{ .shape = e.key_ptr.*, .n = e.value_ptr.* });
                std.mem.sort(E2, sl.items, {}, struct {
                    fn lt(_: void, x: E2, y: E2) bool { return x.n > y.n; }
                }.lt);
                try w.print("  most-allocated block literals:\n", .{});
                for (sl.items[0..@min(12, sl.items.len)]) |e| {
                    try w.print("    {d:>10}  props={d} {{", .{ e.n, e.shape.props.len });
                    for (e.shape.names, 0..) |nm, i| {
                        if (i != 0) try w.print(" ", .{});
                        try w.print(" {s}", .{nm});
                    }
                    try w.print(" }}\n", .{});
                }
                try w.print("\n", .{});
            }
            try w.print("{s:>9}  {s:>7}  {s:>12}  {s:>12}  {s:>8}  {s}\n", .{ "bytes", "share", "calls", "allocs", "avg", "function" });
            var shown: usize = 0;
            for (list.items) |row| {
                if (shown >= 25) break;
                shown += 1;
                try w.print("{d:>8.2}M  {d:>6.1}%  {d:>12}  {d:>12}  {d:>7.0}B  {s}\n", .{
                    @as(f64, @floatFromInt(row.row.bytes)) / (1024.0 * 1024.0),
                    100.0 * @as(f64, @floatFromInt(row.row.bytes)) / @as(f64, @floatFromInt(self.total)),
                    row.row.calls,
                    row.row.allocs,
                    if (row.row.allocs == 0) 0.0 else @as(f64, @floatFromInt(row.row.bytes)) / @as(f64, @floatFromInt(row.row.allocs)),
                    row.name,
                });
            }
            try w.flush();
        }
    };

    const Module = struct {
        state: enum { loading, done },
        block: Value = .unit,
    };

    pub const Options = struct {
        /// Where `print` goes.
        out: ?*std.Io.Writer = null,
        /// Resolves `$import` (§4.14).
        loader: ?Loader = null,
        /// Backs the platform intrinsics (§4.16's role, minus `$extern`).
        platform: ?Platform = null,
        /// Stack the interpreter may use, which only the caller knows: it is
        /// the caller that chose the thread this runs on.
        stack_bytes: usize = default_stack_bytes,
        /// Collect an allocation profile into this.
        stats: ?*Stats = null,
        /// The identifier pool the source was lexed with (§2.1). Names are
        /// compared by identity, so the root block has to be interned in the
        /// *same* pool as the program — a second pool would make every
        /// intrinsic invisible, since nothing would ever be the same slice.
        ///
        /// Absent means "make one": a caller that has not lexed yet can take
        /// it back off `rt.pool` and lex with that.
        pool: ?*lexer.StringPool = null,
    };

    pub fn init(arena_in: Allocator, diags: *Diagnostics, opts: Options) Error!Interp {
        var probe: u8 = undefined;
        const arena = if (opts.stats) |st| st.allocator() else arena_in;
        const pool = opts.pool orelse blk: {
            const p = try arena.create(lexer.StringPool);
            p.* = .init(arena);
            break :blk p;
        };
        var self: Interp = .{
            .arena = arena,
            .stats = opts.stats,
            .rt = .{
                .arena = arena,
                .diags = diags,
                .out = opts.out,
                .platform = opts.platform,
                .pool = pool,
            },
            .root = undefined,
            .loader = opts.loader,
            .stack_base = @intFromPtr(&probe),
            .stack_bytes = opts.stack_bytes,
        };
        self.root = try builtins.rootScope(arena, &self.rt);
        self.arg_stack = try arena.alloc(Value, 64 * 1024);
        return self;
    }

    /// Evaluate a whole file. §3.3: "A source file is a block."
    pub fn runFile(self: *Interp, file: ast.File) Error!Value {
        return self.evalBlockExprs(file.exprs, self.root, .{
            .start = 0,
            .end = 0,
            .line = 1,
            .col = 1,
        }) catch |err| switch (err) {
            // §4.15: "Outside a `$func` (file top level, prop initializer) it
            // is a compile error."
            error.TryReturn => self.rt.fail(.{ .start = 0, .end = 0, .line = 1, .col = 1 }, "$try outside a $func: it returns from the nearest enclosing function, and there is none here", .{}),
            else => err,
        };
    }

    /// §7.3: capture is of the scope *chain*, so capturing one scope pins every
    /// scope above it. The walk stops at the first already-marked scope, since
    /// marking always proceeds upward.
    fn markCaptured(s: *Scope) void {
        var cur: ?*Scope = s;
        while (cur) |x| {
            if (x.captured) return;
            x.captured = true;
            cur = x.parent;
        }
    }

    fn acquireScope(self: *Interp, parent: *Scope, slots: usize) Error!*Scope {
        if (self.stats) |st| {
            if (self.scope_pool.items.len == 0) st.scopes_fresh += 1 else st.scopes_pooled += 1;
        }
        const b = self.bkt(.scope);
        defer self.unbkt(b);
        if (self.scope_pool.pop()) |s| {
            s.parent = parent;
            s.props = &.{};
            s.captured = false;
            s.decls.clearRetainingCapacity();
            if (slots != 0) try s.decls.ensureTotalCapacityPrecise(self.arena, slots);
            return s;
        }
        return Scope.initCapacity(self.arena, parent, slots);
    }

    /// Charge the next allocations to `b`, returning the bucket to restore. Nested allocations under one site land in that site's bucket,
    /// which is what makes the breakdown add up to the total.
    inline fn bkt(self: *Interp, b: Stats.Bucket) Stats.Bucket {
        if (self.stats) |st| {
            const old = st.bucket;
            st.bucket = b;
            return old;
        }
        return .other;
    }

    inline fn unbkt(self: *Interp, old: Stats.Bucket) void {
        if (self.stats) |st| st.bucket = old;
    }

    /// Reserve `n` argument slots. Falls back to the arena if the scratch is
    /// exhausted, so depth is never a correctness limit.
    fn pushArgs(self: *Interp, n: usize) Error![]Value {
        if (self.arg_top + n <= self.arg_stack.len) {
            const slice = self.arg_stack[self.arg_top..][0..n];
            self.arg_top += n;
            return slice;
        }
        const b = self.bkt(.args);
        defer self.unbkt(b);
        return self.arena.alloc(Value, n);
    }

    fn releaseScope(self: *Interp, s: *Scope) void {
        if (s.captured) return;
        self.scope_pool.append(self.arena, s) catch {};
    }

    /// Can anything in this subtree capture the scope it runs in? Only a
    /// closure can — a `$func` or `$template` literal, or a `$prop`, whose
    /// initializer environment outlives the block.
    fn mayCapture(n: *const Node) bool {
        switch (n.data) {
            .form => |f| switch (f.keyword) {
                // `$prop` is not here: `evalBlockExprs` forces every prop and
                // copies its *value* into the block before returning, so the
                // slots do not outlive the scope. Only a `$func` or `$template`
                // literal keeps the chain alive (§7.3). Counting `$prop` meant
                // no constructor in stage 1 — every one of which builds a
                // `{$prop tag "…" …}` — could ever recycle its scope.
                .func, .template => return true,
                // §5.7: a `$case` pattern is a *type-only position*, never
                // evaluated, so nothing written in it can build a closure. A
                // pattern matching a tag is a block full of `$prop`, and
                // counting those kept the scope of every function that matches
                // on a tag — which in the type checker is most of them — out of
                // the pool.
                .case => return mayCapture(&f.operands[1]),
                else => {},
            },
            else => {},
        }
        for (n.children()) |*c| {
            if (mayCapture(c)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------- names

    const Found = struct { entry: Scope.Entry, owner: *Scope };

    fn find(scope: *Scope, name: []const u8) ?Found {
        var cur: ?*Scope = scope;
        while (cur) |s| {
            if (s.findLocal(name)) |e| return .{ .entry = e, .owner = s };
            cur = s.parent;
        }
        return null;
    }

    fn lookup(self: *Interp, scope: *Scope, name: []const u8, span: Span) Error!Value {
        const found = find(scope, name) orelse
            return self.rt.fail(span, "unknown name '{s}'", .{name});
        return switch (found.entry) {
            .value => |v| v,
            .prop => |p| self.forceProp(p),
            // §4.1: a name may be read from inside its own initializer only
            // from within a `$func` body — i.e. only once the `$decl` has
            // completed. §4.11 says the same for a `$fwd` slot.
            .uninitialized => self.rt.fail(span, "'{s}' is not initialized yet: it may only be read from inside a $func body, after its $decl completes", .{name}),
        };
    }

    /// Props are evaluated lazily and memoized, which is how §4.10's "visible
    /// throughout their block, regardless of order" works without hoisting.
    fn forceProp(self: *Interp, p: *Scope.PropSlot) Error!Value {
        switch (p.state) {
            .done => return p.value,
            .in_progress => return self.rt.fail(p.span, "prop '{s}' depends on itself", .{p.name}),
            .pending => {
                p.state = .in_progress;
                const v = try self.eval(p.expr, p.env);
                // A `$prop` binds through the prop slots rather than through
                // `declare`, so a prop-valued function was staying anonymous
                // and the profile charged every list operation in the program
                // to one "(anonymous $func)" row. §4.10 gives a prop a name
                // like any other member; the profile should use it.
                if (self.stats != null) switch (v) {
                    .func => |f| if (f.name == null) {
                        f.name = p.name;
                    },
                    else => {},
                };
                p.value = v;
                p.state = .done;
                return v;
            },
        }
    }

    // ------------------------------------------------------------ blocks

    /// Evaluate a block body in a fresh scope and return the block value.
    /// A block body run to completion: its scope, with every `$decl` slot
    /// filled and every prop forced. Whether the scope may go back to the pool
    /// is the caller's to act on, because only the caller knows whether what
    /// it takes out of the scope outlives it.
    const RanBlock = struct { scope: *Scope, recyclable: bool };

    fn runBlockExprs(self: *Interp, exprs: []const Node, parent: *Scope) Error!RanBlock {
        const preforced: []Scope.PropSlot = if (self.shape_cache.get(exprs.ptr)) |c| c.const_props else &.{};

        var slots: usize = 0;
        for (exprs) |*e| {
            if (e.isForm(.decl) or e.isForm(.fwd)) slots += 1;
        }
        // A block's scope is dead once its value is built: the value holds
        // copies of the slots, not the scope. The exception is a closure made
        // inside it, which captures the chain — the same test `callFunc` uses
        // for a call's scope. `$prop` counts as capturing, so a block with
        // props keeps its scope, which `collectProps` needs anyway.
        var recyclable = true;
        for (exprs) |*e| {
            if (mayCapture(e)) {
                recyclable = false;
                break;
            }
        }
        const scope = if (recyclable)
            try self.acquireScope(parent, slots)
        else
            try Scope.initCapacity(self.arena, parent, slots);
        // A literal whose props are all constants had its slots forced once,
        // on the first evaluation; borrowing them skips `collectProps` and the
        // `prop_env` it allocates. Every slot is `.done`, so nothing is
        // evaluated against that stale environment again.
        if (preforced.len != 0) scope.props = preforced else try self.collectProps(exprs, scope);

        for (exprs) |*e| try self.evalBlockItem(e, scope);

        // §4.10 makes props compile-time constants "typed together as one
        // system", so force any that nothing read. An unused prop with a bad
        // initializer is still an error.
        for (scope.props) |*p| _ = try self.forceProp(p);

        // §4.11: "A `$fwd` not completed by the end of its block is an error."
        for (scope.decls.items) |slot| {
            if (slot.value == null) {
                return self.rt.fail(slot.span, "$fwd '{s}' was never completed by a $decl in this block", .{slot.name});
            }
        }
        return .{ .scope = scope, .recyclable = recyclable };
    }

    /// Evaluate a block body in a fresh scope and return the block value.
    fn evalBlockExprs(self: *Interp, exprs: []const Node, parent: *Scope, span: Span) Error!Value {
        _ = span;
        const ran = try self.runBlockExprs(exprs, parent);
        const scope = ran.scope;

        const shape = try self.sharedShape(exprs, scope, self.shape_cache.get(exprs.ptr));
        const bb = self.bkt(.block);
        const n = scope.decls.items.len;

        if (self.stats) |st| {
            st.blk_n += 1;
            st.blk_bytes += @sizeOf(value.Block) + n * @sizeOf(Value);
            // A profile is never worth failing a run for, so a full table
            // just stops counting.
            if (st.shape_n.getOrPut(st.backing, shape)) |e| {
                if (!e.found_existing) e.value_ptr.* = 0;
                e.value_ptr.* += 1;
            } else |_| {}
        }
        const b = try value.allocBlock(self.arena, shape, n);
        for (scope.decls.items, b.fields()) |slot, *v| v.* = slot.value.?;
        self.unbkt(bb);
        if (ran.recyclable) self.releaseScope(scope);
        return .{ .block = b };
    }

    /// `{ … $decl out e }.out` — a block literal projected on the spot.
    ///
    /// §3.3 makes this the way to return a computed value, since a block never
    /// yields its last expression, so it is everywhere: 3.8M of the 28.5M
    /// blocks allocated while emitting the compiler, 13% of them, exist only
    /// to be projected once and dropped.
    ///
    /// Nothing can observe such a block. The literal *is* the projection's
    /// target, so no other expression holds it; a `$func` written inside
    /// captures the scope rather than the value (§7.3), and that scope is kept
    /// exactly as it would be otherwise; and §5.3a already stops a frame
    /// reference leaving. So the field is read straight out of the scope and
    /// the block is never built.
    fn projectBlockLiteral(
        self: *Interp,
        exprs: []const Node,
        parent: *Scope,
        field: []const u8,
        span: Span,
    ) Error!Value {
        const ran = try self.runBlockExprs(exprs, parent);
        const scope = ran.scope;

        // §4.10 makes access uniform over `$decl` fields and props, so this
        // has to answer exactly as `Block.find` would: the slots in *source*
        // order — not `findLocal`'s backwards scan, which would pick the last
        // of two slots sharing a name where the block picks the first — and
        // then the props. Every slot is filled by now, so none is pending.
        const found = blk: {
            for (scope.decls.items) |slot| {
                if (Scope.nameEql(slot.name, field)) break :blk slot.value.?;
            }
            for (scope.props) |*p| {
                if (Scope.nameEql(p.name, field)) break :blk try self.forceProp(p);
            }
            return self.rt.fail(span, "block has no field '{s}'", .{field});
        };
        if (ran.recyclable) self.releaseScope(scope);
        return found;
    }

    /// The `Shape` for this block value, shared with every other value built
    /// from the same literal.
    ///
    /// The names always come from the cache. The props do too when every prop
    /// initializer is written as a literal; anything else — a prop-only block,
    /// a `$func`, a name — is built fresh per evaluation, because a `$func`
    /// closes over *this* scope and a name is *this* scope's value.
    fn sharedShape(self: *Interp, exprs: []const Node, scope: *Scope, cached: ?ShapeEntry) Error!*const value.Shape {
        const b = self.bkt(.shape);
        defer self.unbkt(b);
        if (cached) |hit| {
            if (hit.props_shared) return hit.shape;
            return self.freshShape(hit.shape.names, scope);
        }

        const shareable = constProps(exprs);

        const names = try self.arena.alloc([]const u8, scope.decls.items.len);
        for (scope.decls.items, names) |slot, *n| n.* = slot.name;
        if (self.stats) |st| st.blk_bytes += names.len * @sizeOf([]const u8) + @sizeOf(value.Shape);

        const shape = try self.arena.create(value.Shape);
        shape.* = .{ .names = names, .props = try self.propFields(scope) };
        try self.shape_cache.put(self.arena, exprs.ptr, .{
            .shape = shape,
            .props_shared = shareable,
            // Every initializer is a literal node, so the forced slots are
            // the same for every evaluation and can be borrowed wholesale.
            .const_props = if (shareable) scope.props else &.{},
        });
        return shape;
    }

    /// Is every `$prop` initializer in this block a *literal node*?
    ///
    /// The question has to be asked of the source, not of the values: §4.10
    /// lets an initializer name an enclosing scope, so `$prop p x` evaluates
    /// to an `Int` every time and to a *different* `Int` each time. Sharing on
    /// "the values came out as literals" would hand the second evaluation the
    /// first one's props, with no diagnostic. A literal node cannot vary.
    fn constProps(exprs: []const Node) bool {
        for (exprs) |*e| {
            if (!e.isForm(.prop)) continue;
            if (!isLiteral(&e.data.form.operands[1])) return false;
        }
        return true;
    }

    /// A shape of its own for a literal whose props cannot be shared, reusing
    /// the cached names.
    fn freshShape(self: *Interp, names: []const []const u8, scope: *Scope) Error!*const value.Shape {
        const shape = try self.arena.create(value.Shape);
        shape.* = .{ .names = names, .props = try self.propFields(scope) };
        if (self.stats) |st| st.blk_bytes += @sizeOf(value.Shape);
        return shape;
    }

    fn propFields(self: *Interp, scope: *Scope) Error![]Field {
        const b = self.bkt(.props);
        defer self.unbkt(b);
        if (scope.props.len == 0) return &.{};
        const props = try self.arena.alloc(Field, scope.props.len);
        for (scope.props, props) |p, *f| f.* = .{ .name = p.name, .value = p.value };
        if (self.stats) |st| st.blk_bytes += props.len * @sizeOf(Field);
        return props;
    }

    fn collectProps(self: *Interp, exprs: []const Node, scope: *Scope) Error!void {
        const b = self.bkt(.props);
        defer self.unbkt(b);
        var n: usize = 0;
        for (exprs) |*e| if (e.isForm(.prop)) {
            n += 1;
        };
        if (n == 0) return;

        // The environment prop initializers run in: same props, same enclosing
        // scopes, *no* ordered siblings (§4.10).
        const prop_env = try Scope.init(self.arena, scope.parent);

        const slots = try self.arena.alloc(Scope.PropSlot, n);
        var i: usize = 0;
        for (exprs) |*e| {
            if (!e.isForm(.prop)) continue;
            const f = e.data.form;
            const pname = f.operands[0].data.name;
            // §4.1's one binding per name, for props too — and props are
            // *unordered*, so two of a name is not even a first-fit question,
            // it is simply two answers.
            for (slots[0..i]) |prior| {
                if (Scope.nameEql(prior.name, pname)) {
                    return self.rt.fail(
                        e.span,
                        "'{s}' is already a $prop of this block; a name is bound once (4.1) — rename one of them",
                        .{pname},
                    );
                }
            }
            slots[i] = .{
                .name = pname,
                .expr = &f.operands[1],
                .span = e.span,
                .env = prop_env,
            };
            i += 1;
        }
        scope.props = slots;
        // Both scopes share the slot array, so forcing a prop from either side
        // memoizes once.
        prop_env.props = slots;
    }

    fn evalBlockItem(self: *Interp, e: *const Node, scope: *Scope) Error!void {
        if (e.data == .form) {
            const f = e.data.form;
            switch (f.keyword) {
                // Already collected and lazily forced.
                .prop => return,
                // §4.11: reserves an ordered slot *at this position*.
                .fwd => {
                    const name = f.operands[0].data.name;
                    try self.refuseRebinding(scope, name, e.span);
                    _ = try scope.reserve(name, e.span);
                    return;
                },
                .decl => {
                    const b = self.bkt(.slots);
                    defer self.unbkt(b);
                    try self.declare(&f.operands[0], &f.operands[1], scope, e.span);
                    return;
                },
                else => {},
            }
        }
        // §3.3: "Non-`$decl` expressions in a block run for effect and are
        // discarded." A block never yields its last expression.
        _ = try self.eval(e, scope);
    }

    /// §4.1: a name may be bound once in a block.
    ///
    /// Two slots of one name are not shadowing, they are two *fields*, and the
    /// block reads them differently depending on where you stand: inside, a
    /// name is the last slot that binds it, but projecting takes the first,
    /// because §7.2 makes the slots the layout and §4.6 finds a field by
    /// searching it in order. So `{ $decl a 1  $decl a 2  $decl out a }.out`
    /// was 2 while `{ $decl a 1  $decl a 2 }.a` was 1 — one name, two values,
    /// no diagnostic. §4.11 already said "exactly one" for the `$decl` that
    /// completes a `$fwd`; this is the same rule for the rest.
    ///
    /// Shadowing across *nested* blocks is untouched: this looks only at the
    /// slots of the block being built.
    fn refuseRebinding(self: *Interp, scope: *Scope, name: []const u8, span: Span) Error!void {
        for (scope.decls.items) |slot| {
            if (!Scope.nameEql(slot.name, name)) continue;
            return self.rt.fail(
                span,
                "'{s}' is already declared in this block; a name is bound once (4.1) — rename one of them",
                .{name},
            );
        }
        for (scope.props) |p| {
            if (!Scope.nameEql(p.name, name)) continue;
            return self.rt.fail(
                span,
                "'{s}' is already a $prop of this block; a name is bound once (4.1) — rename one of them",
                .{name},
            );
        }
    }

    fn declare(
        self: *Interp,
        name_node: *const Node,
        init_node: *const Node,
        scope: *Scope,
        span: Span,
    ) Error!void {
        const name = name_node.data.name;
        // A `$fwd` for this name makes *that* slot the layout position
        // (§4.11) and this `$decl` completes it; anything else bearing the
        // name is a rebinding, which §4.1 does not allow.
        if (scope.pendingSlot(name) == null) try self.refuseRebinding(scope, name, span);
        // Otherwise append a new one. Either way the slot exists
        // before the initializer runs, which is what gives §4.1
        // self-reference: a `$func` that names itself reads this very slot
        // once the `$decl` completes.
        const index = scope.pendingSlot(name) orelse try scope.reserve(name, span);
        const v = try self.eval(init_node, scope);
        if (self.stats != null) switch (v) {
            .func => |f| if (f.name == null) {
                f.name = name;
            },
            else => {},
        };
        _ = scope.complete(index, v);
    }

    // -------------------------------------------------------- expressions

    /// The boxed value of a `Str` or `Float` literal, made once per node.
    ///
    /// §3.1's two words no longer fit in a `Value`, so a literal needs a box —
    /// and a literal in a loop is evaluated over and over, so allocating one
    /// each time would trade the word this saves for far more. Keyed on the
    /// node, which is exactly one box per literal in the program.
    fn literalStr(self: *Interp, node: *const Node) Error!Value {
        if (self.str_box.get(node)) |hit| {
            return switch (node.data) {
                .float => .{ .float = hit },
                else => .{ .str = hit },
            };
        }
        const bytes = switch (node.data) {
            .float => |t| t,
            .str => |t| t,
            else => unreachable,
        };
        const box = try self.arena.create(value.Str);
        box.* = .{ .bytes = bytes };
        try self.str_box.put(self.arena, node, box);
        return switch (node.data) {
            .float => .{ .float = box },
            else => .{ .str = box },
        };
    }

    /// Evaluate in a **non-tail** position: this recurses.
    pub fn eval(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        switch (node.data) {
            .int => |v| return .{ .int = v },
            .float, .str => return self.literalStr(node),
            .bool_lit => |b| return .{ .bool = b },
            .unit => return .unit,
            .name => |n| return self.lookup(scope, n, node.span),
            .group => |elems| {
                // §5.4: group elements are a position where nothing expects a
                // value, so a reference stays a reference here.
                const gb = self.bkt(.group);
                defer self.unbkt(gb);
                const vals = try self.arena.alloc(Value, elems.len);
                for (elems, vals) |*el, *slot| slot.* = try self.eval(el, scope);
                return value.groupVal(self.arena, vals);
            },
            .block => |exprs| return self.evalBlockExprs(exprs, scope, node.span),
            .proj_name => |p| {
                // A block literal in projection position is never built — see
                // `projectBlockLiteral`.
                if (p.target.data == .block) {
                    return self.projectBlockLiteral(p.target.data.block, scope, p.field, node.span);
                }
                const target = (try self.eval(p.target, scope)).deref();
                return self.projectName(target, p.field, node.span);
            },
            .proj_index => |p| {
                const target = (try self.eval(p.target, scope)).deref();
                return self.projectIndex(target, p.field, node.span);
            },
            .form => return self.evalForm(node, scope),
        }
    }

    fn evalForm(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const f = node.data.form;
        const ops = f.operands;
        return switch (f.keyword) {
            // §4.1: evaluates to the value. Slot creation is `evalBlockItem`'s
            // job; a `$decl` outside a block binds nothing.
            .decl => self.eval(&ops[1], scope),

            // §4.2 and §4.2a: the only ways storage comes into existence. The
            // operand is dereferenced first, so `$new r` is a copy, not an
            // alias. The two differ only in the storage *kind* (§3.5), which
            // is a static distinction — and stage 0 does no static checking
            // and never frees (BOOTSTRAP §3), so here they are one form.
            .new, .alloc => blk: {
                const v = (try self.eval(&ops[0], scope)).deref();
                if (self.stats) |st| {
                    st.cell_n += 1;
                    // What this storage would cost *compiled*: the value lives
                    // in the storage (§4.2), props occupy no space (§7.2), and
                    // a field is one word for a scalar or a reference. A rough
                    // figure, but the right order — stage 0's `Cell` holds a
                    // pointer to a separately allocated block instead.
                    st.cell_bytes += switch (v) {
                        .block => |b| 8 + b.names().len * 8,
                        .group => |g| g.elems.len * 8,
                        else => 8,
                    };
                }
                const cb = self.bkt(.cell);
                defer self.unbkt(cb);
                break :blk value.newCell(self.arena, v);
            },

            // §4.3: `$mut` requires a reference. Stage 0 draws no runtime
            // distinction between `&T` and `&mut T` (§5.3 is static), so this
            // is an identity plus that check.
            .mut => blk: {
                const v = try self.eval(&ops[0], scope);
                if (v != .ref) break :blk self.rt.fail(node.span, "$mut expects storage, found {s}; only $new creates storage", .{v.typeName()});
                break :blk v;
            },

            .set => self.evalSet(node, scope),
            .func => self.makeFunc(node, scope),
            .call => blk: {
                const callee = (try self.eval(&ops[0], scope)).deref();
                const base = self.arg_top;
                defer self.arg_top = base;
                const args = try self.evalArgs(&ops[1], scope);
                break :blk self.callValue(callee, args, node.span);
            },
            .match => blk: {
                const arm = try self.selectArm(node, scope);
                break :blk self.eval(arm, scope);
            },
            .@"if" => blk: {
                const arm = try self.selectIf(node, scope);
                break :blk self.eval(arm, scope);
            },
            .do => blk: {
                _ = try self.eval(&ops[0], scope);
                break :blk self.eval(&ops[1], scope);
            },

            // §4.8a: "The expression **evaluates to `e₁`** ... Elements after
            // the first are never evaluated; only their types are used."
            // Stage 0 therefore never inspects them at all, which is exactly
            // why a recursive type declaration costs the evaluator nothing.
            .@"union" => blk: {
                const members = &ops[0];
                const first = switch (members.data) {
                    .group => |elems| &elems[0],
                    else => members,
                };
                break :blk self.eval(first, scope);
            },

            .template => self.makeTemplate(node, scope),
            .specialize => self.evalSpecialize(node, scope),
            .@"try" => self.evalTry(node, scope),
            .import => self.evalImport(node, scope),

            .prop => self.rt.fail(node.span, "$prop is only valid directly inside a block", .{}),
            .fwd => self.rt.fail(node.span, "$fwd is only valid directly inside a block", .{}),
            .case => self.rt.fail(node.span, "$case is only valid as an arm of $match", .{}),

            // BOOTSTRAP.md §1.2. These parse (the parser covers all of §2.2)
            // but stage 0 declines to run them.
            .@"const" => self.outOfSubset(node.span, "$const", "stage 0 has no read-only views; nothing in stage 1 needs one"),
            .overload => self.outOfSubset(node.span, "$overload", "the bootstrap root block is monomorphic, so no overload set exists"),
            .impl => self.outOfSubset(node.span, "$impl", "traits are not needed to compile a file"),
            .traitsof => self.outOfSubset(node.span, "$traitsof", "traits are not needed to compile a file"),
            .@"extern" => self.outOfSubset(node.span, "$extern", "stage 0 provides the platform as builtins instead (BOOTSTRAP.md §2)"),
        };
    }

    fn outOfSubset(self: *Interp, span: Span, what: []const u8, why: []const u8) Error {
        return self.rt.fail(span, "{s} is outside the bootstrap subset (BOOTSTRAP.md §1.2): {s}", .{ what, why });
    }

    /// §4.4: writes *through* storage. It never rebinds a name and never
    /// replaces a block field.
    fn evalSet(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const ops = node.data.form.operands;
        const target = try self.eval(&ops[0], scope);
        if (target != .ref) {
            return self.rt.fail(
                ops[0].span,
                "$set needs storage on the left, found {s}; a value field cannot be written to — declare it with $new",
                .{target.typeName()},
            );
        }
        const v = (try self.eval(&ops[1], scope)).deref();
        target.ref.value = v;
        return v;
    }

    fn projectName(self: *Interp, target: Value, field: []const u8, span: Span) Error!Value {
        return switch (target) {
            // §4.10: access is uniform over `$decl` fields and props.
            .block => |b| b.find(field) orelse
                self.rt.fail(span, "block has no field '{s}'", .{field}),
            else => self.rt.fail(span, "cannot project '.{s}' from {s}", .{ field, target.typeName() }),
        };
    }

    fn projectIndex(self: *Interp, target: Value, index: u32, span: Span) Error!Value {
        return switch (target) {
            .group => |g| if (index >= 1 and index <= g.elems.len)
                g.elems[index - 1]
            else
                self.rt.fail(span, "group index .{d} is out of range for a group of {d}", .{ index, g.elems.len }),
            else => self.rt.fail(span, "cannot index .{d} into {s}", .{ index, target.typeName() }),
        };
    }

    // ----------------------------------------------------------- functions

    fn makeFunc(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const b = self.bkt(.func);
        defer self.unbkt(b);
        const ops = node.data.form.operands;
        const params_node = &ops[0];

        // §3.4: "`params` is a group of `$decl`s."
        const decls: []const Node = switch (params_node.data) {
            .unit => &.{},
            .group => |elems| elems,
            .form => params_node[0..1], // a single `$decl`, group folded away
            else => return self.rt.fail(params_node.span, "$func parameters must be a group of $decl forms, found {s}", .{@tagName(params_node.data)}),
        };

        const params = try self.arena.alloc(value.Param, decls.len);
        for (decls, params, 0..) |*d, *p, i| {
            if (!d.isForm(.decl)) {
                return self.rt.fail(d.span, "$func parameters must each be a $decl", .{});
            }
            const dops = d.data.form.operands;
            // §3.4 makes the parameter list a group of `$decl`s, so §4.1's one
            // binding per name applies here too: two parameters of one name
            // take two frame slots (§7.2) and the second hides the first, so
            // the argument passed for the first can never be read.
            for (params[0..i]) |prior| {
                if (Scope.nameEql(prior.name, dops[0].data.name)) {
                    return self.rt.fail(
                        d.span,
                        "'{s}' is already a parameter of this $func; a name is bound once (4.1) — rename one of them",
                        .{dops[0].data.name},
                    );
                }
            }
            p.* = .{
                .name = dops[0].data.name,
                .default = &dops[1],
                .wants_storage = isStorageForm(&dops[1]),
            };
        }

        markCaptured(scope);
        const fnc = try self.arena.create(Func);
        fnc.* = .{
            .params = params,
            .body = &ops[1],
            .scope = scope,
            .may_capture = mayCapture(&ops[1]),
            .file = self.rt.diags.current_file,
        };
        return .{ .func = fnc };
    }

    /// Stage 0's approximation of §5.4 transparency: whether a parameter wants
    /// storage is read off the *syntax* of its default, since the real rule is
    /// a type-level one. §5.3 says idiomatic code writes `$mut $new 0` or
    /// `$const $new 0` for exactly these parameters.
    fn isStorageForm(n: *const Node) bool {
        return switch (n.data) {
            .form => |f| switch (f.keyword) {
                .new, .alloc, .mut, .@"const" => true,
                else => false,
            },
            else => false,
        };
    }

    /// §2.4 with §2.3: the *syntactic* shape of the args operand fixes the
    /// argument count, so `$call f (x)` and `$call f x` are both one argument,
    /// while a name bound to a group passed as `$call f g` is also one.
    fn evalArgs(self: *Interp, args_node: *const Node, scope: *Scope) Error![]Value {
        switch (args_node.data) {
            .unit => return &.{},
            .group => |elems| {
                // Evaluate first, then reserve: an argument may itself be a
                // call, and its own scratch must sit above ours, not overlap it.
                const ab = self.bkt(.args);
                defer self.unbkt(ab);
                var tmp: [8]Value = undefined;
                const staged: []Value = if (elems.len <= tmp.len)
                    tmp[0..elems.len]
                else
                    try self.arena.alloc(Value, elems.len);
                for (elems, staged) |*el, *slot| slot.* = try self.eval(el, scope);
                const vals = try self.pushArgs(elems.len);
                @memcpy(vals, staged);
                return vals;
            },
            else => {
                const v = try self.eval(args_node, scope);
                const vals = try self.pushArgs(1);
                vals[0] = v;
                return vals;
            },
        }
    }

    fn callValue(self: *Interp, callee: Value, args: []Value, span: Span) Error!Value {
        switch (callee) {
            .func => |f| return self.callFunc(f, args, span),
            .builtin => |b| {
                const bb = self.bkt(.builtin);
                defer self.unbkt(bb);
                if (b.arity) |n| {
                    if (args.len != n) {
                        return self.rt.fail(span, "{s} takes {d} argument{s}, found {d}", .{
                            b.name, n, if (n == 1) "" else "s", args.len,
                        });
                    }
                }
                // Intrinsics take values, so storage is transparent here (§5.4).
                for (args) |*a| a.* = a.deref();
                return b.func(&self.rt, args, span);
            },
            .template => return self.rt.fail(span, "$call on a template needs an explicit $specialize first (BOOTSTRAP.md §1.1 drops $call-time inference of T)", .{}),
            else => return self.rt.fail(span, "{s} is not callable", .{callee.typeName()}),
        }
    }

    const Step = union(enum) {
        value: Value,
        tail: struct {
            node: *const Node,
            scope: *Scope,
            file: ?[]const u8 = null,
            /// Whether the scope handed over may be captured by its body.
            may_capture: bool = true,
        },
    };

    /// The trampoline. §7.7 makes tail-call elimination mandatory, so a tail
    /// call must *replace* this frame rather than grow the Zig stack.
    fn callFunc(self: *Interp, f0: *Func, args0: []Value, span: Span) Error!Value {
        var probe: u8 = undefined;
        const here = @intFromPtr(&probe);
        const used = if (here < self.stack_base) self.stack_base - here else here - self.stack_base;
        if (used > self.stack_bytes) {
            return self.rt.fail(span, "call depth limit exceeded at {d} nested calls: this recursion is not in tail position, so §7.7 cannot eliminate it", .{self.call_depth});
        }
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.stats) |st| {
            if (self.call_depth > st.max_depth) st.max_depth = self.call_depth;
            if (used > st.max_stack) st.max_stack = used;
        }

        var saved_fn: []const u8 = undefined;
        var incl_at: u64 = 0;
        var incl_outer = false;
        if (self.stats) |st| {
            saved_fn = st.current;
            st.current = f0.name orelse "(anonymous $func)";
            st.enter(st.current);
            if (st.incl_name) |want| if (std.mem.eql(u8, want, st.current)) {
                if (st.incl_depth == 0) {
                    incl_outer = true;
                    incl_at = st.total;
                    st.incl_calls += 1;
                }
                st.incl_depth += 1;
            };
        }
        defer if (self.stats) |st| {
            if (incl_outer) {
                st.incl_bytes += st.total - incl_at;
            }
            if (st.incl_name) |want| if (std.mem.eql(u8, want, st.current)) {
                st.incl_depth -= 1;
            };
            st.current = saved_fn;
        };

        // Diagnostics raised inside this call belong to the file the function
        // was written in, not the one that called it.
        const caller_file = self.rt.diags.current_file;
        defer self.rt.diags.current_file = caller_file;
        self.rt.diags.current_file = f0.file;

        var scope = try self.bindParams(f0, args0, span);
        var body = f0.body;
        // Only a scope whose body provably cannot close over it is recycled.
        var recyclable = !f0.may_capture;

        while (true) {
            const st = self.step(body, scope) catch |err| switch (err) {
                // §4.15: `$try` returns from the nearest enclosing `$func`.
                // If this frame got here by a tail call, the frame it replaced
                // is already gone, so returning here is the right answer for
                // that function too.
                error.TryReturn => {
                    const v = self.try_payload;
                    self.try_payload = .unit;
                    return v;
                },
                else => return err,
            };
            switch (st) {
                .value => |v| {
                    if (recyclable) self.releaseScope(scope);
                    return v;
                },
                .tail => |t| {
                    // The frame this one replaces is gone (§7.7), so unless a
                    // closure captured it, its scope can be reused.
                    if (recyclable and t.scope != scope) self.releaseScope(scope);
                    // Only a tail *call* moves to another scope and so decides
                    // afresh whether it can be recycled. `$do`, `$if` and
                    // `$match` stay in this one and report `may_capture = true`
                    // because they have no callee to ask — taking that at face
                    // value made the first `$match` in a body poison recycling
                    // for the rest of the trampoline, which in stage 1 is
                    // nearly every function.
                    if (t.scope != scope) recyclable = !t.may_capture;
                    body = t.node;
                    scope = t.scope;
                    // A tail call can land in a function from another file.
                    self.rt.diags.current_file = t.file;
                },
            }
        }
    }

    /// Evaluate in a **tail** position. §7.7's tail positions are: a `$func`
    /// body, each arm of a `$match` in tail position, and the second operand of
    /// a `$do` in tail position, transitively. Everything else defers to
    /// `eval`, which is exactly why "a call inside a block is never in tail
    /// position" needs no special case: blocks are `eval`'s business.
    fn step(self: *Interp, node: *const Node, scope: *Scope) Error!Step {
        const cur_file = self.rt.diags.current_file;
        if (node.data == .form) {
            const f = node.data.form;
            const ops = f.operands;
            switch (f.keyword) {
                .do => {
                    _ = try self.eval(&ops[0], scope);
                    return .{ .tail = .{ .node = &ops[1], .scope = scope, .file = cur_file, .may_capture = true } };
                },
                .@"if" => return .{ .tail = .{ .node = try self.selectIf(node, scope), .scope = scope, .file = cur_file, .may_capture = true } },
                .match => return .{ .tail = .{ .node = try self.selectArm(node, scope), .scope = scope, .file = cur_file, .may_capture = true } },
                .call => {
                    const callee = (try self.eval(&ops[0], scope)).deref();
                    const base = self.arg_top;
                    // `bindParams` copies the arguments out, and an intrinsic
                    // has returned by the time this unwinds, so the scratch is
                    // reclaimed either way.
                    defer self.arg_top = base;
                    const args = try self.evalArgs(&ops[1], scope);
                    if (callee == .func) {
                        const callee_scope = try self.bindParams(callee.func, args, node.span);
                        return .{ .tail = .{
                            .node = callee.func.body,
                            .scope = callee_scope,
                            .file = callee.func.file,
                            .may_capture = callee.func.may_capture,
                        } };
                    }
                    return .{ .value = try self.callValue(callee, args, node.span) };
                },
                else => {},
            }
        }
        return .{ .value = try self.eval(node, scope) };
    }

    fn bindParams(self: *Interp, f: *Func, args: []Value, span: Span) Error!*Scope {
        if (args.len > f.params.len) {
            return self.rt.fail(span, "function takes {d} parameter{s}, found {d} argument{s}", .{
                f.params.len,           if (f.params.len == 1) "" else "s",
                args.len, if (args.len == 1) "" else "s",
            });
        }
        const scope = try self.acquireScope(f.scope, f.params.len);
        for (f.params, 0..) |p, i| {
            var v: Value = if (i < args.len)
                args[i]
            else
                // §3.4: "Defaults are evaluated at call time when the argument
                // is omitted" — in the function's own lexical scope.
                try self.eval(p.default, f.scope);

            if (p.wants_storage) {
                if (v != .ref) {
                    // §5.4: "A value is never implicitly converted to storage."
                    return self.rt.fail(span, "parameter '{s}' expects storage, found {s}; write $new at the call site", .{ p.name, v.typeName() });
                }
            } else {
                // §5.4: a reference behaves as its pointee where a value is
                // expected, and a call argument is such a place.
                v = v.deref();
            }
            const idx = try scope.reserve(p.name, span);
            _ = scope.complete(idx, v);
        }
        return scope;
    }

    // ------------------------------------------------------------- matching

    fn selectIf(self: *Interp, node: *const Node, scope: *Scope) Error!*const Node {
        const ops = node.data.form.operands;
        const c = (try self.eval(&ops[0], scope)).deref();
        if (c != .bool) {
            return self.rt.fail(ops[0].span, "$if condition must be Bool, found {s}", .{c.typeName()});
        }
        // §2.2: `$if c a b` is sugar for `$match c ($case true a, $case false b)`.
        return if (c.bool) &ops[1] else &ops[2];
    }

    /// §4.7: arms are tried in order, first fit.
    fn selectArm(self: *Interp, node: *const Node, scope: *Scope) Error!*const Node {
        const ops = node.data.form.operands;
        const scrutinee = (try self.eval(&ops[0], scope)).deref();
        const arms = &ops[1];

        // A single-arm match has the `$case` directly, since `(e)` folds (§2.3).
        if (arms.isForm(.case)) {
            const c = arms.data.form.operands;
            if (try self.patternApplies(&c[0], scrutinee, scope)) return &c[1];
        } else if (arms.data == .group) {
            for (arms.data.group) |*arm| {
                if (!arm.isForm(.case)) {
                    return self.rt.fail(arm.span, "$match arms must be $case forms", .{});
                }
                const c = arm.data.form.operands;
                if (try self.patternApplies(&c[0], scrutinee, scope)) return &c[1];
            }
        } else {
            return self.rt.fail(arms.span, "$match arms must be a group of $case forms", .{});
        }

        // §4.7 requires exhaustiveness, which stage 0 cannot check — hence
        // BOOTSTRAP.md §4.1's rule that every match ends in a catch-all.
        return self.rt.fail(node.span, "no $match arm applied to {s}: $match must be exhaustive (§4.7), so end it with a catch-all $case (BOOTSTRAP.md §4.1)", .{scrutinee.typeName()});
    }

    /// A pattern is a **type-only position** (§5.7): never evaluated, only its
    /// static type used. Stage 0 has no inference, so BOOTSTRAP.md §1.3 limits
    /// patterns to shapes whose test needs none.
    fn patternApplies(
        self: *Interp,
        pat: *const Node,
        scrutinee: Value,
        scope: *Scope,
    ) Error!bool {
        switch (pat.data) {
            // §4.7: "A literal pattern is its base type" — `$case 0` means
            // Int, not the value 0. Dispatch on runtime *values* is `$if` and
            // `eq`, not `$match`.
            .int => return scrutinee == .int,
            .str => return scrutinee == .str,
            .float => return scrutinee == .float,
            .unit => return scrutinee == .unit,

            // §3.2: `true` and `false` are two *distinct nullary tag types*, so
            // unlike Int and Str a boolean pattern tests the exact tag. This is
            // what makes `$if` sugar for `$match` work.
            .bool_lit => |b| return scrutinee == .bool and scrutinee.bool == b,

            // A prop-only block literal — `{$prop tag "cons"}`. Evaluating it
            // is pure: props are compile-time constants (§4.10).
            .block => |exprs| {
                for (exprs) |*e| {
                    if (!e.isForm(.prop)) {
                        return self.rt.fail(e.span, "a block pattern may contain only $prop members (BOOTSTRAP.md §1.3)", .{});
                    }
                }
                // Almost every pattern in stage 1 is `{$prop tag "…"}`, whose
                // props are literals. Building the block to then read one prop
                // back off it is a scope, a prop-slot array and a block per arm
                // *tested* — and a 13-arm `$match` tests most of them. Since
                // `shapeMatches` on a prop-only pattern is exactly "the value
                // is a block carrying these props with these values", the
                // literal case answers that without building anything.
                if (allLiteralProps(exprs)) {
                    if (scrutinee != .block) return false;
                    const blk = scrutinee.block;
                    for (exprs) |*e| {
                        const f = e.data.form;
                        const got = blk.findProp(f.operands[0].data.name) orelse return false;
                        if (!literalEquals(&f.operands[1], got)) return false;
                    }
                    return true;
                }
                const pv = try self.evalBlockExprs(exprs, scope, pat.span);
                return shapeMatches(pv, scrutinee, max_shape_depth);
            },

            // A name. §4.7's catch-all `$match x ($case x …)` needs no special
            // case: the pattern's type is the type of whatever `x` names, so
            // when it names the scrutinee it matches by construction.
            .name => |n| {
                const pv = try self.lookup(scope, n, pat.span);
                return shapeMatches(pv, scrutinee, max_shape_depth);
            },

            else => return self.rt.fail(pat.span, "this pattern is outside the bootstrap subset (BOOTSTRAP.md §1.3): patterns must be a prop-only block, a name, or an Int/Str/Bool literal", .{}),
        }
    }

    /// Is this pattern prop written as a literal? Testing one then needs no
    /// evaluation and therefore no scope.
    fn isLiteral(n: *const Node) bool {
        return switch (n.data) {
            .int, .str, .float, .bool_lit, .unit => true,
            else => false,
        };
    }

    /// Does `got` equal the literal written at `n`?
    ///
    /// Compared against the *node*, so nothing is built — which matters now
    /// that §3.1's two words no longer fit in a `Value` and a `Str` would
    /// otherwise need a box just to be thrown away.
    fn literalEquals(n: *const Node, got: Value) bool {
        return switch (n.data) {
            .int => |v| got == .int and got.int == v,
            .str => |v| got == .str and std.mem.eql(u8, got.str.bytes, v),
            .float => |v| got == .float and std.mem.eql(u8, got.float.bytes, v),
            .bool_lit => |v| got == .bool and got.bool == v,
            .unit => got == .unit,
            else => false,
        };
    }

    fn allLiteralProps(exprs: []const Node) bool {
        for (exprs) |*e| {
            if (!isLiteral(&e.data.form.operands[1])) return false;
        }
        return true;
    }

    /// Does `val` satisfy the *shape* of the example value `pat`?
    ///
    /// This is §5.1 structural subtyping, restricted to what a dynamic value
    /// can answer: an ordered field prefix with depth, prop values compared
    /// exactly, elementwise on groups.
    fn shapeMatches(pat: Value, val: Value, depth: u32) bool {
        if (depth == 0) return false;
        // §4.7's catch-all arm — `$match x ($case x …)` — tests a value against
        // itself. Recognising that by identity makes it O(1) and, more
        // importantly, independent of how deeply the value nests.
        switch (pat) {
            .block => |p| if (val == .block and val.block == p) return true,
            .group => |p| if (val == .group and val.group == p) return true,
            .ref => |p| if (val == .ref and val.ref == p) return true,
            .array => |p| if (val == .array and val.array == p) return true,
            else => {},
        }
        return switch (pat) {
            .unit => val == .unit,
            .int => val == .int,
            .float => val == .float,
            .str => val == .str,
            .bool => |b| val == .bool and val.bool == b,
            .block => |p| blk: {
                if (val != .block) break :blk false;
                const s = val.block;
                // §5.1: "for every prop of `T`, `S` has the same prop with the
                // **same value**". This is the tag test.
                for (p.props()) |pf| {
                    const sf = s.findProp(pf.name) orelse break :blk false;
                    if (!value.equal(pf.value, sf, depth - 1)) break :blk false;
                }
                // §5.1: the pattern's fields must be an ordered *prefix* of the
                // value's — same names at the same positions. Layout is the
                // type, so nothing is matched out of order.
                if (p.names().len > s.names().len) break :blk false;
                const n = p.names().len;
                for (p.names(), p.fields(), s.names()[0..n], s.fields()[0..n]) |pn, pv, sn, sv| {
                    if (!value.Scope.nameEql(pn, sn)) break :blk false;
                    if (!shapeMatches(pv, sv, depth - 1)) break :blk false;
                }
                break :blk true;
            },
            .group => |p| blk: {
                if (val != .group or val.group.elems.len != p.elems.len) break :blk false;
                for (p.elems, val.group.elems) |pe, se| {
                    if (!shapeMatches(pe, se, depth - 1)) break :blk false;
                }
                break :blk true;
            },
            .ref => |p| val == .ref and shapeMatches(p.value, val.ref.value, depth - 1),
            .array => val == .array,
            // Signatures are not comparable without types.
            .func, .builtin => val == .func or val == .builtin,
            .template => val == .template,
        };
    }

    /// §4.15. Evaluates `e`; if its runtime type is a subtype of the pattern,
    /// returns `e` from the nearest enclosing `$func`.
    fn evalTry(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const ops = node.data.form.operands;
        const v = try self.eval(&ops[0], scope);
        if (try self.patternApplies(&ops[1], v.deref(), scope)) {
            self.try_payload = v;
            return error.TryReturn;
        }
        // Otherwise the value is `e`, narrowed to `type(e) & ¬pat` — nothing
        // to do dynamically.
        return v;
    }

    // ---------------------------------------------------------- templates

    fn makeTemplate(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const ops = node.data.form.operands;
        const names_node = &ops[0];
        const generics: [][]const u8 = switch (names_node.data) {
            .name => |n| blk: {
                const one = try self.arena.alloc([]const u8, 1);
                one[0] = n;
                break :blk one;
            },
            .group => |elems| blk: {
                const many = try self.arena.alloc([]const u8, elems.len);
                for (elems, many) |el, *slot| slot.* = el.data.name;
                break :blk many;
            },
            else => return self.rt.fail(names_node.span, "$template expects a name or a group of names", .{}),
        };
        markCaptured(scope);
        const tb = self.bkt(.template);
        defer self.unbkt(tb);
        const t = try self.arena.create(Template);
        t.* = .{ .generics = generics, .body = &ops[1], .scope = scope };
        return .{ .template = t };
    }

    /// §4.9: binds each argument "as if `$decl T arg` were prepended to
    /// `body`", evaluating each argument exactly once, then types the result
    /// with ordinary rules. Stage 0 has no typing, so it just evaluates.
    ///
    /// BOOTSTRAP.md §1.1 requires the `$specialize` to be explicit: `$call` on
    /// a template does not infer `T`, because that would need parameter-default
    /// shape matching.
    fn evalSpecialize(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        const ops = node.data.form.operands;
        const tv = (try self.eval(&ops[0], scope)).deref();
        if (tv != .template) {
            return self.rt.fail(ops[0].span, "$specialize expects a template, found {s}", .{tv.typeName()});
        }
        const t = tv.template;

        const args_node = &ops[1];
        const arg_nodes: []const Node = if (t.generics.len == 1)
            args_node[0..1]
        else switch (args_node.data) {
            .group => |elems| elems,
            else => return self.rt.fail(args_node.span, "$specialize needs {d} arguments for this template", .{t.generics.len}),
        };
        if (arg_nodes.len != t.generics.len) {
            return self.rt.fail(args_node.span, "this template has {d} generic parameter{s}, found {d} argument{s}", .{
                t.generics.len, if (t.generics.len == 1) "" else "s",
                arg_nodes.len,  if (arg_nodes.len == 1) "" else "s",
            });
        }

        if (self.specialize_depth >= max_specialize_depth) {
            return self.rt.fail(node.span, "instantiation depth limit ({d}) exceeded (§4.9)", .{max_specialize_depth});
        }
        self.specialize_depth += 1;
        defer self.specialize_depth -= 1;

        const inner = try Scope.init(self.arena, t.scope);
        for (t.generics, arg_nodes) |name, *arg| {
            const v = try self.eval(arg, scope);
            const idx = try inner.reserve(name, arg.span);
            _ = inner.complete(idx, v);
        }
        return self.eval(t.body, inner);
    }

    // ------------------------------------------------------------- imports

    /// §4.14. Loaded once per resolved file; cycles are an error.
    fn evalImport(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        _ = scope;
        const ops = node.data.form.operands;
        const name = ops[0].data.str;

        const loader = self.loader orelse
            return self.rt.fail(node.span, "$import \"{s}\" but no import resolver is configured", .{name});

        const resolved = loader.resolve(self.arena, name) catch |err| switch (err) {
            error.NotFound => return self.rt.fail(node.span, "cannot resolve $import \"{s}\"", .{name}),
            error.ReadFailed => return self.rt.fail(node.span, "cannot read the file for $import \"{s}\"", .{name}),
            error.OutOfMemory => return error.OutOfMemory,
        };

        if (self.modules.get(resolved.key)) |m| switch (m.state) {
            // §4.14: "Cycles are an error."
            .loading => return self.rt.fail(node.span, "import cycle: \"{s}\" is already being loaded; make one module a $template over the other and let the build tie them", .{name}),
            // §4.14: "Loaded once." All imports of the same resolved file
            // yield the same block, so file-level storage is shared.
            .done => return m.block,
        };

        try self.modules.put(self.arena, resolved.key, .{ .state = .loading });

        // Diagnostics from inside the module must name the module's file.
        const outer_file = self.rt.diags.current_file;
        self.rt.diags.current_file = resolved.key;
        defer self.rt.diags.current_file = outer_file;

        // The *same* pool as the importing file: §4.14 makes all imports of one
        // resolved file yield one module, and names only match across files if
        // they were interned together.
        const tokens = try lexer.tokenize(self.arena, self.arena, resolved.source, self.rt.diags, self.rt.pool);
        const file = try parser.parseFile(self.arena, tokens, self.rt.diags);
        if (self.rt.diags.any()) return error.Halt;

        // §4.14: "A file sees the root block plus what it imports, nothing
        // else" — so the parent is the root block, never the importing scope.
        const block = try self.evalBlockExprs(file.exprs, self.root, node.span);
        try self.modules.put(self.arena, resolved.key, .{ .state = .done, .block = block });
        return block;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    diags: Diagnostics,
    interp: Interp,
    result: Value = .unit,

    fn run(src: []const u8, opts: Interp.Options) !Harness {
        var h: Harness = .{
            .arena_state = .init(testing.allocator),
            .diags = .init(testing.allocator),
            .interp = undefined,
        };
        const arena = h.arena_state.allocator();
        h.interp = try Interp.init(arena, &h.diags, opts);
        // The interpreter's own pool, or the root block's names would be
        // interned somewhere this source cannot see.
        const tokens = try lexer.tokenize(arena, arena, src, &h.diags, h.interp.rt.pool);
        const file = try parser.parseFile(arena, tokens, &h.diags);
        if (h.diags.any()) {
            for (h.diags.items.items) |d| std.debug.print("syntax: {d}:{d}: {s}\n", .{ d.span.line, d.span.col, d.msg });
            return error.SyntaxError;
        }
        h.result = try h.interp.runFile(file);
        return h;
    }

    fn deinit(self: *Harness) void {
        self.diags.deinit();
        self.arena_state.deinit();
    }
};

/// Evaluate `src`, then read a named field out of the resulting file block.
fn evalField(src: []const u8, field: []const u8) !Value {
    var h = try Harness.run(src, .{});
    defer h.deinit();
    const v = h.result.block.findText(field) orelse return error.NoSuchField;
    // Copy out scalars only; the arena dies with the harness.
    return switch (v.deref()) {
        .int, .bool, .unit => v.deref(),
        else => v.deref(),
    };
}

fn expectInt(src: []const u8, field: []const u8, want: i64) !void {
    const v = try evalField(src, field);
    if (v != .int) {
        std.debug.print("expected Int in '{s}', got {s}\n", .{ field, v.typeName() });
        return error.WrongType;
    }
    try testing.expectEqual(want, v.int);
}

fn expectBool(src: []const u8, field: []const u8, want: bool) !void {
    const v = try evalField(src, field);
    try testing.expectEqual(want, v.bool);
}

fn expectFails(src: []const u8, expected_substring: []const u8) !void {
    var h: Harness = .{
        .arena_state = .init(testing.allocator),
        .diags = .init(testing.allocator),
        .interp = undefined,
    };
    defer h.deinit();
    const arena = h.arena_state.allocator();
    h.interp = try Interp.init(arena, &h.diags, .{});
    const tokens = try lexer.tokenize(arena, arena, src, &h.diags, h.interp.rt.pool);
    const file = try parser.parseFile(arena, tokens, &h.diags);
    _ = h.interp.runFile(file) catch {};
    for (h.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, expected_substring) != null) return;
    }
    std.debug.print("no diagnostic containing \"{s}\"; got:\n", .{expected_substring});
    for (h.diags.items.items) |d| std.debug.print("  {s}\n", .{d.msg});
    return error.WrongDiagnostic;
}

test "declarations, arithmetic and projection" {
    try expectInt("$decl x 1 $decl y $call add (x, 2)", "y", 3);
    try expectInt("$decl p (1, 2) $decl r p.2", "r", 2);
    try expectInt("$decl b { $decl v 7 } $decl r b.v", "r", 7);
}

test "a block never yields its last expression (3.3)" {
    // The value is the environment; the trailing expression is discarded.
    try expectInt("$decl r { $decl a 1 $call add (a, 1) $decl out 9 }.out", "r", 9);
}

test "$new is the only storage; $decl aliases and $new copies (12)" {
    try expectInt(
        \\$decl n $mut $new 0
        \\$set n ($call add (n, 1))
        \\$decl y n
        \\$decl z $new n
        \\$set n 100
        \\$decl from_alias y
        \\$decl from_copy z
    , "from_alias", 100);
    try expectInt(
        \\$decl n $mut $new 0
        \\$set n 1
        \\$decl z $new n
        \\$set n 100
        \\$decl from_copy z
    , "from_copy", 1);
}

test "$set requires storage, not a value field (4.4)" {
    try expectFails("$decl a 0 $set a 1", "$set needs storage on the left");
    try expectFails("$decl b { $decl a 0 } $set b.a 1", "$set needs storage on the left");
}

test "$mut requires a reference (4.3)" {
    try expectFails("$decl x $mut 0", "$mut expects storage");
}

test "the sanity check from SPEC 8: not, from the core" {
    const not = "$decl not $func ($decl b true) $match b ($case true false, $case false true)\n";
    try expectBool(not ++ "$decl r $call not true", "r", false);
    try expectBool(not ++ "$decl r $call not false", "r", true);
    try expectBool(not ++ "$decl r $call not ($call not true)", "r", true);
}

test "$if is $match over the two tag types (3.2)" {
    try expectInt("$decl r $if true 1 2", "r", 1);
    try expectInt("$decl r $if false 1 2", "r", 2);
    try expectFails("$decl r $if 1 1 2", "$if condition must be Bool");
}

test "literal patterns are base types, bool patterns are exact (4.7, 3.2)" {
    // `$case 0` means Int, so it also matches 5.
    try expectInt("$decl r $match 5 ($case 0 111, $case x 222)", "r", 111);
    try expectInt("$decl r $match \"s\" ($case 0 111, $case \"\" 222, $case x 333)", "r", 222);
    // true and false are distinct types, so the arms do not collapse.
    try expectInt("$decl r $match false ($case true 1, $case false 2)", "r", 2);
}

test "tagged blocks dispatch on prop values (4.10, 5.1)" {
    const src =
        \\$decl circle { $prop kind "circle"  $decl r 3 }
        \\$decl square { $prop kind "square"  $decl w 4 }
        \\$decl area $func ($decl s $union (circle, square)) $match s (
        \\  $case {$prop kind "circle"} $call mul (3, $call mul (s.r, s.r)),
        \\  $case {$prop kind "square"} $call mul (s.w, s.w),
        \\  $case s 0
        \\)
        \\$decl a $call area (circle)
        \\$decl b $call area (square)
    ;
    try expectInt(src, "a", 27);
    try expectInt(src, "b", 16);
}

test "a name pattern tests the named value's shape; the scrutinee's own name is the catch-all" {
    // §4.7's catch-all needs no special case.
    try expectInt("$decl x 5 $decl r $match x ($case x 42)", "r", 42);
    // A name bound to a prop-only block is a tag test.
    try expectInt(
        \\$decl nil { $prop tag "nil" }
        \\$decl v { $prop tag "nil" }
        \\$decl r $match v ($case nil 1, $case v 2)
    , "r", 1);
}

test "a non-exhaustive match is a runtime error naming the rule" {
    try expectFails("$decl r $match 5 ($case \"\" 1)", "must be exhaustive");
}

test "$union evaluates only its first member (4.8a)" {
    // The second member is a type-only position: if it were evaluated, the
    // unknown name would be an error.
    try expectInt("$decl s $union (1, this_name_does_not_exist)", "s", 1);
}

test "recursive data types cost the evaluator nothing (4.8a)" {
    // The recursive member names `node` while `node` is still being defined.
    // Stage 0 never looks at it, which is why this needs no knot-tying.
    try expectInt(
        \\$decl nil { $prop tag "nil" }
        \\$decl node $union (nil, { $prop tag "cons"  $decl head 0  $decl tail node })
        \\$decl r $match node ($case {$prop tag "nil"} 1, $case node 2)
    , "r", 1);
}

test "props are visible throughout their block regardless of order (4.10)" {
    try expectInt("$decl b { $prop a c  $prop c 7 } $decl r b.a", "r", 7);
    try expectFails("$decl b { $prop a c  $prop c a }", "depends on itself");
}

test "props have no layout but are still projectable (4.10)" {
    var h = try Harness.run("$decl b { $prop p 1  $decl d 2 }", .{});
    defer h.deinit();
    const b = h.result.block.findText("b").?.block;
    try testing.expectEqual(@as(usize, 1), b.names().len); // only `d` takes a slot
    try testing.expectEqual(@as(usize, 1), b.props().len);
    try testing.expectEqual(@as(i64, 1), b.findText("p").?.int);
}

test "a prop initializer may not read an ordered sibling (4.10)" {
    try expectFails("$decl b { $decl d 1  $prop p d }", "unknown name 'd'");
}

test "self-reference: a $func may name itself (4.1)" {
    try expectInt(
        \\$decl fact $func ($decl n 0)
        \\  $if ($call eq_int (n, 0)) 1 ($call mul (n, $call fact ($call sub (n, 1))))
        \\$decl r $call fact 5
    , "r", 120);
}

test "reading a name during its own initializer is an error (4.1)" {
    try expectFails("$decl x x", "not initialized yet");
}

test "mutual recursion with $fwd (4.11, 12)" {
    const src =
        \\$fwd odd
        \\$decl even $func ($decl n 0) $if ($call eq_int (n, 0)) true  ($call odd  ($call sub (n, 1)))
        \\$decl odd  $func ($decl n 0) $if ($call eq_int (n, 0)) false ($call even ($call sub (n, 1)))
        \\$decl a $call even 10
        \\$decl b $call even 7
    ;
    try expectBool(src, "a", true);
    try expectBool(src, "b", false);
}

test "$fwd keeps the layout position of the $fwd, not the $decl (4.11)" {
    var h = try Harness.run(
        \\$fwd b
        \\$decl a 1
        \\$decl b 2
    , .{});
    defer h.deinit();
    const blk = h.result.block;
    try testing.expectEqualStrings("b", blk.names()[0]);
    try testing.expectEqualStrings("a", blk.names()[1]);
}

test "an uncompleted $fwd is an error (4.11)" {
    try expectFails("$fwd never $decl other 1", "never completed by a $decl");
}

test "no hoisting: a $func cannot read a later non-$func name (10.5)" {
    try expectFails("$decl f $func () later $decl r $call f () $decl later 1", "unknown name 'later'");
}

test "tail-call elimination is mandatory: a loop runs to a large count (7.7)" {
    // A recursive evaluator would need ~200k Zig frames for this; the
    // trampoline uses one. `$do` is what puts the recursive call after the
    // effect in tail position (§4.8b).
    try expectInt(
        \\$decl count $func ($decl n 0, $decl acc 0)
        \\  $if ($call eq_int (n, 0)) acc ($call count ($call sub (n, 1), $call add (acc, 1)))
        \\$decl r $call count (200000, 0)
    , "r", 200000);
}

test "the while loop from SPEC 12, driving mutable storage" {
    try expectInt(
        \\$decl while $func ($decl cond $func () true, $decl body $func () {})
        \\  $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}
        \\$decl i $mut $new 0
        \\$decl total $mut $new 0
        \\$decl done $call while (
        \\  $func () ($call lt (i, 1000)),
        \\  $func () ($do ($set total ($call add (total, i))) ($set i ($call add (i, 1))))
        \\)
        \\$decl r total
    , "r", 499500);
}

test "a call inside a block is never in tail position (7.7)" {
    // Non-tail recursion is bounded by the depth guard rather than crashing.
    try expectFails(
        \\$decl deep $func ($decl n 0) { $decl r $if ($call eq_int (n, 0)) 0 ($call deep ($call sub (n, 1))) }.r
        \\$decl x $call deep 100000
    , "call depth limit");
}

test "$try returns from the nearest enclosing $func (4.15)" {
    const src =
        \\$decl first_digit $func ($decl s "")
        \\  { $decl v $try ($call str_to_int ($call slice (s, 0, 1))) none
        \\    $decl out v.v }.out
        \\$decl ok $call first_digit "7"
        \\$decl bad $call first_digit "x"
    ;
    try expectInt(src, "ok", 7);
    // On the `none` branch the function returns the `none` block itself.
    var h = try Harness.run(src, .{});
    defer h.deinit();
    const bad = h.result.block.findText("bad").?.deref();
    try testing.expectEqualStrings("none", bad.block.findText("tag").?.str.bytes);
}

test "$try skips blocks and projections on its way out (4.15)" {
    // The $try is nested two blocks deep; it still exits the function.
    try expectInt(
        \\$decl f $func ($decl x 0)
        \\  { $decl inner { $decl a $try err err  $decl b 1 }
        \\    $decl out 99 }.out
        \\$decl marker 1
    , "marker", 1);
}

test "$try outside a $func is an error (4.15)" {
    try expectFails("$decl a $try err err", "$try outside a $func");
}

test "transparency: a reference derefs where a value is expected (5.4)" {
    // `n` is `&mut Int` but `add` takes values.
    try expectInt("$decl n $mut $new 5 $decl r $call add (n, 1)", "r", 6);
    // A parameter written `$mut $new 0` wants storage, so it keeps the alias
    // and writes through it.
    try expectInt(
        \\$decl bump $func ($decl cell $mut $new 0) $set cell ($call add (cell, 1))
        \\$decl n $mut $new 41
        \\$decl ignored $call bump (n)
        \\$decl r n
    , "r", 42);
    // §5.4: "A value is never implicitly converted to storage."
    try expectFails(
        \\$decl bump $func ($decl cell $mut $new 0) $set cell 1
        \\$decl r $call bump (0)
    , "expects storage");
}

test "group elements keep their references (5.4)" {
    try expectInt(
        \\$decl n $mut $new 1
        \\$decl pair (n, 2)
        \\$set n 50
        \\$decl r pair.1
    , "r", 50);
}

test "closures capture by copy of an immutable binding, but storage still aliases (7.3)" {
    try expectInt(
        \\$decl make $func ($decl cell $mut $new 0) $func () cell
        \\$decl n $mut $new 3
        \\$decl get $call make (n)
        \\$decl before $call get ()
        \\$decl ignored $set n 9
        \\$decl r $call get ()
    , "r", 9);
}

test "a prop initialized from an enclosing scope is not shared between evaluations (4.10)" {
    // Two values of one block literal share a `Shape`, which carries the
    // props — but only when every initializer is written as a *literal*.
    // §4.10 lets one name an enclosing scope, and `tag` here evaluates to an
    // `Int` both times and to a different `Int` each time, so deciding the
    // sharing from the values rather than the source would hand the second
    // block the first block's prop, silently.
    try expectInt(
        \\$decl box $func ($decl x 0) { $prop tag x }
        \\$decl a $call box (1)
        \\$decl b $call box (2)
        \\$decl r $call add (a.tag, b.tag)
    , "r", 3);
}

test "a prop that is a literal is shared, and still reads as itself (4.10)" {
    try expectInt(
        \\$decl box $func ($decl x 0) { $prop tag 7 $decl v x }
        \\$decl a $call box (1)
        \\$decl b $call box (2)
        \\$decl r $call add ($call add (a.tag, b.tag), $call add (a.v, b.v))
    , "r", 17);
}

test "a block literal in projection position is never built (3.3)" {
    // §3.3 makes `{ … $decl out e }.out` the way to return a computed value,
    // so `projectBlockLiteral` reads the slot and skips the block. These pin
    // what it has to answer identically to building one.

    // A prop, not a slot: §4.10 makes access uniform over both.
    try expectInt("$decl r { $prop tag 7  $decl v 1 }.tag", "r", 7);

    // A closure projected out of a literal still reads that literal's scope —
    // §7.3 captures the chain, and the scope is what is kept, not the block.
    try expectInt(
        \\$decl f { $decl a 5  $decl out $func () a }.out
        \\$decl r $call f ()
    , "r", 5);

    // Storage projected out still aliases (§5.4).
    try expectInt(
        \\$decl c { $decl cell $mut $alloc 1  $decl out cell }.out
        \\$decl w $set c 9
        \\$decl r c
    , "r", 9);

    // Shadowing across nested blocks is untouched, and the inner name wins.
    try expectInt("$decl r { $decl a 1  $decl out { $decl a 2  $decl o a }.o }.out", "r", 2);
}

test "a name is bound once in a block (4.1)" {
    // Two slots of one name are two *fields*, not shadowing, and the block
    // used to read them differently depending on where you stood: `a` inside
    // was the last slot, `.a` from outside was the first. §4.11 already said
    // "exactly one" for the `$decl` completing a `$fwd`.
    try expectFails("$decl r { $decl a 1  $decl a 2  $decl out a }.out", "'a' is already declared in this block");
    try expectFails("$decl a 1 $decl a 2", "'a' is already declared in this block");
    try expectFails("$decl r { $prop a 1  $decl a 2  $decl out a }.out", "'a' is already a $prop of this block");
    try expectFails("$decl r { $fwd a  $decl a 1  $fwd a  $decl out a }.out", "'a' is already declared in this block");
    try expectFails("$decl r { $prop a 1  $prop a 2  $decl out 0 }.out", "'a' is already a $prop of this block");
    // §3.4 makes a parameter list a group of `$decl`s, so the rule reaches it.
    try expectFails("$decl f $func ($decl a 0, $decl a 0) a", "'a' is already a parameter of this $func");

    // A `$fwd` and the one `$decl` that completes it are one slot, not two.
    try expectInt("$decl r { $fwd a  $decl b $func () a  $decl a 7  $decl out $call b () }.out", "r", 7);

    // Shadowing an enclosing binding is a different block, so it stays legal —
    // including the intrinsic-aliasing idiom `$decl isub sub`.
    try expectInt("$decl a 1 $decl r { $decl a 2  $decl out a }.out", "r", 2);
}

test "projecting a name a block literal does not have still fails (4.10)" {
    try expectFails("$decl r { $decl a 1 }.b", "block has no field 'b'");
}

test "$call arity comes from the syntactic group (2.4)" {
    try expectInt("$decl f $func ($decl a 0) a $decl r $call f 5", "r", 5);
    try expectInt("$decl f $func ($decl a 0) a $decl r $call f (5)", "r", 5);
    try expectInt("$decl f $func ($decl a 0, $decl b 0) $call add (a, b) $decl r $call f (2, 3)", "r", 5);
    // Defaults fill omitted arguments, at call time (§3.4).
    try expectInt("$decl f $func ($decl a 0, $decl b 7) $call add (a, b) $decl r $call f 1", "r", 8);
    try expectFails("$decl f $func ($decl a 0) a $decl r $call f (1, 2)", "takes 1 parameter");
}

test "templates need an explicit $specialize (4.9, BOOTSTRAP 1.1)" {
    try expectInt("$decl id $template T $func ($decl x T) x $decl r $call ($specialize id 0) 5", "r", 5);
    try expectFails("$decl id $template T $func ($decl x T) x $decl r $call id 5", "needs an explicit $specialize");
}

test "a template argument is evaluated once and bound by name (4.9)" {
    try expectInt(
        \\$decl pair_of $template T { $decl a T  $decl b T }
        \\$decl p $specialize pair_of 4
        \\$decl r $call add (p.a, p.b)
    , "r", 8);
    try expectInt(
        \\$decl two $template (A, B) $call add (A, B)
        \\$decl r $specialize two (3, 4)
    , "r", 7);
}

test "arrays are bounds-checked and `at` hands out storage (8)" {
    try expectInt(
        \\$decl a $call array (3, 0)
        \\$decl ignored $set ($call at (a, 1)) 42
        \\$decl r $call at (a, 1)
    , "r", 42);
    try expectInt("$decl a $call array (4, 0) $decl r $call alen a", "r", 4);
    try expectFails("$decl a $call array (2, 0) $decl r $call at (a, 5)", "out of bounds");
}

test "Int overflow panics rather than wrapping (3.1)" {
    try expectFails("$decl r $call add (9223372036854775807, 1)", "Int overflow");
}

test "excluded forms decline with a pointer to the subset" {
    try expectFails("$decl x $overload (1, 2)", "outside the bootstrap subset");
    try expectFails("$decl x $const $new 0", "outside the bootstrap subset");
    try expectFails("$decl x $traitsof {}", "outside the bootstrap subset");
    try expectFails("$decl x $extern \"puts\" 0", "outside the bootstrap subset");
}

test "patterns outside the subset are refused by name" {
    try expectFails("$decl r $match 1 ($case ($call add (1, 2)) 1)", "outside the bootstrap subset");
    try expectFails("$decl r $match 1 ($case { $decl d 1 } 1)", "only $prop members");
}

test "the subset expresses a recursive list with tag dispatch and TCE" {
    // This is the BOOTSTRAP.md §5 gate that matters most: §12's list is
    // generic and self-specializing, which §1.1 excludes, so the question is
    // whether the *subset* can still hold a compiler's data structures.
    const list =
        \\$decl nil  { $prop tag "nil" }
        \\$decl node $union (nil, { $prop tag "cons"  $decl head 0  $decl tail node })
        \\$decl cons $func ($decl h 0, $decl t node) { $prop tag "cons"  $decl head h  $decl tail t }
        \\$decl sum $func ($decl xs node, $decl acc 0) $match xs (
        \\  $case {$prop tag "cons"} $call sum (xs.tail, $call add (acc, xs.head)),
        \\  $case xs acc
        \\)
        \\$decl length $func ($decl xs node, $decl acc 0) $match xs (
        \\  $case {$prop tag "cons"} $call length (xs.tail, $call add (acc, 1)),
        \\  $case xs acc
        \\)
        \\$decl reverse $func ($decl xs node, $decl acc node) $match xs (
        \\  $case {$prop tag "cons"} $call reverse (xs.tail, $call cons (xs.head, acc)),
        \\  $case xs acc
        \\)
        \\$decl upto $func ($decl n 0, $decl acc node)
        \\  $if ($call eq_int (n, 0)) acc ($call upto ($call sub (n, 1), $call cons (n, acc)))
        \\
    ;
    try expectInt(list ++ "$decl r $call length ($call upto (6, nil), 0)", "r", 6);
    try expectInt(list ++ "$decl r $call sum ($call upto (6, nil), 0)", "r", 21);
    try expectInt(list ++ "$decl r $call sum ($call reverse ($call upto (6, nil), nil), 0)", "r", 21);
    // Long enough that only real tail-call elimination survives it.
    try expectInt(list ++ "$decl r $call sum ($call upto (20000, nil), 0)", "r", 200010000);
    // The head of a reversed [1..6] is 6 — the list is really being rebuilt.
    try expectInt(list ++ "$decl r ($call reverse ($call upto (6, nil), nil)).head", "r", 6);
}

// -------------------------------------------------------------- platform

const FakeHost = struct {
    contents: []const u8,

    fn readFile(ctx: *const anyopaque, arena: Allocator, path: []const u8) Platform.PlatformError![]const u8 {
        _ = arena;
        const self: *const FakeHost = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, "known")) return error.Failed;
        return self.contents;
    }

    fn writeFile(ctx: *const anyopaque, path: []const u8, bytes: []const u8) Platform.PlatformError!void {
        _ = ctx;
        _ = path;
        _ = bytes;
    }

    fn args(ctx: *const anyopaque, arena: Allocator) Platform.PlatformError![]const []const u8 {
        _ = ctx;
        _ = arena;
        return &.{ "one", "two" };
    }

    fn platform(self: *const FakeHost) Platform {
        return .{
            .ctx = self,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .argsFn = args,
        };
    }
};

test "read_file's option threads through $try, and args through the array intrinsics" {
    const host: FakeHost = .{ .contents = "42" };
    const src =
        \\$decl load $func ($decl p "")
        \\  { $decl c $try ($call read_file (p)) none
        \\    $decl out ($call str_to_int (c.v)).v }.out
        \\$decl good $call load ("known")
        \\$decl argc $call alen ($call args ())
        \\$decl first $call at ($call args (), 0)
    ;
    var h = try Harness.run(src, .{ .platform = host.platform() });
    defer h.deinit();
    try testing.expectEqual(@as(i64, 42), h.result.block.findText("good").?.deref().int);
    try testing.expectEqual(@as(i64, 2), h.result.block.findText("argc").?.deref().int);
    try testing.expectEqualStrings("one", h.result.block.findText("first").?.deref().str.bytes);
}

test "a missing file comes back as none, not as a failure" {
    const host: FakeHost = .{ .contents = "x" };
    var h = try Harness.run(
        \\$decl load $func ($decl p "")
        \\  { $decl c $try ($call read_file (p)) none
        \\    $decl out "read" }.out
        \\$decl r $call load ("absent")
    , .{ .platform = host.platform() });
    defer h.deinit();
    // `$try` fired, so the function returned the `none` block itself.
    const r = h.result.block.findText("r").?.deref();
    try testing.expectEqualStrings("none", r.block.findText("tag").?.str.bytes);
}

// -------------------------------------------------------------- imports

const MapLoader = struct {
    files: []const struct { name: []const u8, source: []const u8 },

    fn resolve(ctx: *const anyopaque, arena: Allocator, name: []const u8) Loader.LoadError!Loader.Resolved {
        _ = arena;
        const self: *const MapLoader = @ptrCast(@alignCast(ctx));
        for (self.files) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                return .{ .key = f.name, .source = f.source };
            }
        }
        return error.NotFound;
    }

    fn loader(self: *const MapLoader) Loader {
        return .{ .ctx = self, .resolveFn = resolve };
    }
};

test "$import evaluates a file as a block (4.14)" {
    const modules: MapLoader = .{ .files = &.{
        .{ .name = "m", .source = "$decl answer 42" },
    } };
    var h = try Harness.run("$decl m $import \"m\" $decl r m.answer", .{ .loader = modules.loader() });
    defer h.deinit();
    try testing.expectEqual(@as(i64, 42), h.result.block.findText("r").?.deref().int);
}

test "$import is load-once, so file-level storage is shared (4.14)" {
    const modules: MapLoader = .{ .files = &.{
        .{ .name = "counter", .source = "$decl cell $mut $new 0" },
    } };
    var h = try Harness.run(
        \\$decl a $import "counter"
        \\$decl b $import "counter"
        \\$decl ignored $set a.cell 5
        \\$decl r b.cell
    , .{ .loader = modules.loader() });
    defer h.deinit();
    // Same block, so the write through `a` is visible through `b`.
    try testing.expectEqual(@as(i64, 5), h.result.block.findText("r").?.deref().int);
}

test "import cycles are an error (4.14)" {
    const modules: MapLoader = .{ .files = &.{
        .{ .name = "a", .source = "$decl b $import \"b\"" },
        .{ .name = "b", .source = "$decl a $import \"a\"" },
    } };
    var h: Harness = .{
        .arena_state = .init(testing.allocator),
        .diags = .init(testing.allocator),
        .interp = undefined,
    };
    defer h.deinit();
    const arena = h.arena_state.allocator();
    h.interp = try Interp.init(arena, &h.diags, .{ .loader = modules.loader() });
    const tokens = try lexer.tokenize(arena, arena, "$decl a $import \"a\"", &h.diags, h.interp.rt.pool);
    const file = try parser.parseFile(arena, tokens, &h.diags);
    _ = h.interp.runFile(file) catch {};
    var found = false;
    for (h.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "import cycle") != null) found = true;
    }
    try testing.expect(found);
}

test "a module sees the root block, not the importing scope (4.14)" {
    const modules: MapLoader = .{ .files = &.{
        .{ .name = "m", .source = "$decl r outer_name" },
    } };
    var h: Harness = .{
        .arena_state = .init(testing.allocator),
        .diags = .init(testing.allocator),
        .interp = undefined,
    };
    defer h.deinit();
    const arena = h.arena_state.allocator();
    h.interp = try Interp.init(arena, &h.diags, .{ .loader = modules.loader() });
    const tokens = try lexer.tokenize(arena, arena, "$decl outer_name 1 $decl m $import \"m\"", &h.diags, h.interp.rt.pool);
    const file = try parser.parseFile(arena, tokens, &h.diags);
    _ = h.interp.runFile(file) catch {};
    var found = false;
    for (h.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "unknown name 'outer_name'") != null) found = true;
    }
    try testing.expect(found);
}
