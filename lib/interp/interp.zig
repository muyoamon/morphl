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
const max_stack_bytes = 4 * 1024 * 1024;

/// §4.9: "there is a fixed instantiation depth limit and exceeding it is an
/// error."
const max_specialize_depth = 64;

/// Bound on structural pattern comparison, since `$new` cells can alias
/// cyclically.
const max_shape_depth = 32;

pub const Interp = struct {
    arena: Allocator,
    rt: value.Runtime,
    root: *Scope,
    loader: ?Loader = null,

    /// `$import` is load-once per resolved key (§4.14).
    modules: std.StringHashMapUnmanaged(Module) = .empty,
    call_depth: u32 = 0,
    /// Stack position at `init`, for the headroom check in `callFunc`.
    stack_base: usize = 0,
    specialize_depth: u32 = 0,
    /// The value carried by an in-flight `error.TryReturn`.
    try_payload: Value = .unit,

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
    };

    pub fn init(arena: Allocator, diags: *Diagnostics, opts: Options) Error!Interp {
        var probe: u8 = undefined;
        var self: Interp = .{
            .arena = arena,
            .rt = .{
                .arena = arena,
                .diags = diags,
                .out = opts.out,
                .platform = opts.platform,
            },
            .root = undefined,
            .loader = opts.loader,
            .stack_base = @intFromPtr(&probe),
        };
        self.root = try builtins.rootScope(arena, &self.rt);
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
                p.value = v;
                p.state = .done;
                return v;
            },
        }
    }

    // ------------------------------------------------------------ blocks

    /// Evaluate a block body in a fresh scope and return the block value.
    fn evalBlockExprs(self: *Interp, exprs: []const Node, parent: *Scope, span: Span) Error!Value {
        const scope = try Scope.init(self.arena, parent);
        try self.collectProps(exprs, scope);

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

        const decls = try self.arena.alloc(Field, scope.decls.items.len);
        for (scope.decls.items, decls) |slot, *f| {
            f.* = .{ .name = slot.name, .value = slot.value.? };
        }
        const props = try self.arena.alloc(Field, scope.props.len);
        for (scope.props, props) |p, *f| f.* = .{ .name = p.name, .value = p.value };

        _ = span;
        const b = try self.arena.create(value.Block);
        b.* = .{ .decls = decls, .props = props };
        return .{ .block = b };
    }

    fn collectProps(self: *Interp, exprs: []const Node, scope: *Scope) Error!void {
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
            slots[i] = .{
                .name = f.operands[0].data.name,
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
                    _ = try scope.reserve(f.operands[0].data.name, e.span);
                    return;
                },
                .decl => {
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

    fn declare(
        self: *Interp,
        name_node: *const Node,
        init_node: *const Node,
        scope: *Scope,
        span: Span,
    ) Error!void {
        const name = name_node.data.name;
        // A `$fwd` for this name makes *that* slot the layout position
        // (§4.11); otherwise append a new one. Either way the slot exists
        // before the initializer runs, which is what gives §4.1
        // self-reference: a `$func` that names itself reads this very slot
        // once the `$decl` completes.
        const index = scope.pendingSlot(name) orelse try scope.reserve(name, span);
        const v = try self.eval(init_node, scope);
        _ = scope.complete(index, v);
    }

    // -------------------------------------------------------- expressions

    /// Evaluate in a **non-tail** position: this recurses.
    pub fn eval(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
        switch (node.data) {
            .int => |v| return .{ .int = v },
            .float => |t| return .{ .float = t },
            .str => |s| return .{ .str = s },
            .bool_lit => |b| return .{ .bool = b },
            .unit => return .unit,
            .name => |n| return self.lookup(scope, n, node.span),
            .group => |elems| {
                // §5.4: group elements are a position where nothing expects a
                // value, so a reference stays a reference here.
                const vals = try self.arena.alloc(Value, elems.len);
                for (elems, vals) |*el, *slot| slot.* = try self.eval(el, scope);
                return .{ .group = vals };
            },
            .block => |exprs| return self.evalBlockExprs(exprs, scope, node.span),
            .proj_name => |p| {
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

            // §4.2: the only way storage comes into existence. The operand is
            // dereferenced first, so `$new r` is a copy, not an alias.
            .new => value.newCell(self.arena, (try self.eval(&ops[0], scope)).deref()),

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
            .@"const" => self.outOfSubset(node.span, "$const", "stage 0 has no &const, because structural &const upcasts are the only thing needing fat references (§7.4)"),
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
            .group => |elems| if (index >= 1 and index <= elems.len)
                elems[index - 1]
            else
                self.rt.fail(span, "group index .{d} is out of range for a group of {d}", .{ index, elems.len }),
            else => self.rt.fail(span, "cannot index .{d} into {s}", .{ index, target.typeName() }),
        };
    }

    // ----------------------------------------------------------- functions

    fn makeFunc(self: *Interp, node: *const Node, scope: *Scope) Error!Value {
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
        for (decls, params) |*d, *p| {
            if (!d.isForm(.decl)) {
                return self.rt.fail(d.span, "$func parameters must each be a $decl", .{});
            }
            const dops = d.data.form.operands;
            p.* = .{
                .name = dops[0].data.name,
                .default = &dops[1],
                .wants_storage = isStorageForm(&dops[1]),
            };
        }

        const fnc = try self.arena.create(Func);
        fnc.* = .{
            .params = params,
            .body = &ops[1],
            .scope = scope,
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
                .new, .mut, .@"const" => true,
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
                const vals = try self.arena.alloc(Value, elems.len);
                for (elems, vals) |*el, *slot| slot.* = try self.eval(el, scope);
                return vals;
            },
            else => {
                const vals = try self.arena.alloc(Value, 1);
                vals[0] = try self.eval(args_node, scope);
                return vals;
            },
        }
    }

    fn callValue(self: *Interp, callee: Value, args: []Value, span: Span) Error!Value {
        switch (callee) {
            .func => |f| return self.callFunc(f, args, span),
            .builtin => |b| {
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
        tail: struct { node: *const Node, scope: *Scope, file: ?[]const u8 = null },
    };

    /// The trampoline. §7.7 makes tail-call elimination mandatory, so a tail
    /// call must *replace* this frame rather than grow the Zig stack.
    fn callFunc(self: *Interp, f0: *Func, args0: []Value, span: Span) Error!Value {
        var probe: u8 = undefined;
        const here = @intFromPtr(&probe);
        const used = if (here < self.stack_base) self.stack_base - here else here - self.stack_base;
        if (used > max_stack_bytes) {
            return self.rt.fail(span, "call depth limit exceeded at {d} nested calls: this recursion is not in tail position, so §7.7 cannot eliminate it", .{self.call_depth});
        }
        self.call_depth += 1;
        defer self.call_depth -= 1;

        // Diagnostics raised inside this call belong to the file the function
        // was written in, not the one that called it.
        const caller_file = self.rt.diags.current_file;
        defer self.rt.diags.current_file = caller_file;
        self.rt.diags.current_file = f0.file;

        var scope = try self.bindParams(f0, args0, span);
        var body = f0.body;

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
                .value => |v| return v,
                .tail => |t| {
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
                    return .{ .tail = .{ .node = &ops[1], .scope = scope, .file = cur_file } };
                },
                .@"if" => return .{ .tail = .{ .node = try self.selectIf(node, scope), .scope = scope, .file = cur_file } },
                .match => return .{ .tail = .{ .node = try self.selectArm(node, scope), .scope = scope, .file = cur_file } },
                .call => {
                    const callee = (try self.eval(&ops[0], scope)).deref();
                    const args = try self.evalArgs(&ops[1], scope);
                    if (callee == .func) {
                        const callee_scope = try self.bindParams(callee.func, args, node.span);
                        return .{ .tail = .{
                            .node = callee.func.body,
                            .scope = callee_scope,
                            .file = callee.func.file,
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
        const scope = try Scope.init(self.arena, f.scope);
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

    /// Does `val` satisfy the *shape* of the example value `pat`?
    ///
    /// This is §5.1 structural subtyping, restricted to what a dynamic value
    /// can answer: width and depth on blocks, prop values compared exactly,
    /// elementwise on groups.
    fn shapeMatches(pat: Value, val: Value, depth: u32) bool {
        if (depth == 0) return false;
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
                for (p.props) |pf| {
                    const sf = s.findProp(pf.name) orelse break :blk false;
                    if (!value.equal(pf.value, sf, depth - 1)) break :blk false;
                }
                // Width and depth on the ordered fields. Order is ignored for
                // subtyping (§5.1), even though it is part of type equality.
                for (p.decls) |pf| {
                    const sf = s.findDecl(pf.name) orelse break :blk false;
                    if (!shapeMatches(pf.value, sf, depth - 1)) break :blk false;
                }
                break :blk true;
            },
            .group => |p| blk: {
                if (val != .group or val.group.len != p.len) break :blk false;
                for (p, val.group) |pe, se| {
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

        const tokens = try lexer.tokenize(self.arena, self.arena, resolved.source, self.rt.diags);
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
        const tokens = try lexer.tokenize(arena, arena, src, &h.diags);
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
    const v = h.result.block.find(field) orelse return error.NoSuchField;
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
    const tokens = try lexer.tokenize(arena, arena, src, &h.diags);
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
    const b = h.result.block.find("b").?.block;
    try testing.expectEqual(@as(usize, 1), b.decls.len); // only `d` takes a slot
    try testing.expectEqual(@as(usize, 1), b.props.len);
    try testing.expectEqual(@as(i64, 1), b.findProp("p").?.int);
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
    try testing.expectEqualStrings("b", blk.decls[0].name);
    try testing.expectEqualStrings("a", blk.decls[1].name);
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
    const bad = h.result.block.find("bad").?.deref();
    try testing.expectEqualStrings("none", bad.block.findProp("tag").?.str);
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
    try testing.expectEqual(@as(i64, 42), h.result.block.find("good").?.deref().int);
    try testing.expectEqual(@as(i64, 2), h.result.block.find("argc").?.deref().int);
    try testing.expectEqualStrings("one", h.result.block.find("first").?.deref().str);
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
    const r = h.result.block.find("r").?.deref();
    try testing.expectEqualStrings("none", r.block.findProp("tag").?.str);
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
    try testing.expectEqual(@as(i64, 42), h.result.block.find("r").?.deref().int);
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
    try testing.expectEqual(@as(i64, 5), h.result.block.find("r").?.deref().int);
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
    const tokens = try lexer.tokenize(arena, arena, "$decl a $import \"a\"", &h.diags);
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
    const tokens = try lexer.tokenize(arena, arena, "$decl outer_name 1 $decl m $import \"m\"", &h.diags);
    const file = try parser.parseFile(arena, tokens, &h.diags);
    _ = h.interp.runFile(file) catch {};
    var found = false;
    for (h.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "unknown name 'outer_name'") != null) found = true;
    }
    try testing.expect(found);
}
