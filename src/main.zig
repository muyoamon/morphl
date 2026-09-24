//! morphlc — stage 0 driver.
//!
//! Lexes, parses and evaluates (BOOTSTRAP.md §5 steps 1–3). Stage 0 does no
//! static type checking at all; see lib/interp/interp.zig.
//!
//!   morphlc <file.mpl>            print the parsed AST as S-expressions
//!   morphlc --tokens <file.mpl>   print the token stream
//!   morphlc --run <file.mpl>      evaluate the file

const std = @import("std");
const process = std.process;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const diag = @import("diag");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const interp = @import("interp");

const max_source_bytes = 64 * 1024 * 1024;

/// A bump allocator over fixed-size chunks.
///
/// `std.heap.ArenaAllocator` sizes each new chunk at 1.5x everything allocated
/// so far and keeps every earlier one, so the address space it reserves runs to
/// about 2.5x the bytes actually handed out. Stage 0 never frees (BOOTSTRAP
/// §3), so that multiplier lands directly on the `ulimit -v` a whole-file check
/// needs. Fixed chunks make the reservation the bytes plus one chunk.
const ChunkArena = struct {
    child: Allocator,
    head: ?*Chunk = null,
    /// Next free address, and the end of the current chunk.
    ptr: usize = 0,
    end: usize = 0,

    const chunk_size: usize = 64 << 20;

    const Chunk = struct { next: ?*Chunk, size: usize };

    pub fn allocator(self: *ChunkArena) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ChunkArena = @ptrCast(@alignCast(ctx));
        const align_bytes = a.toByteUnits();
        var p = std.mem.alignForward(usize, self.ptr, align_bytes);
        if (p + n > self.end) {
            @branchHint(.cold);
            const want = @max(chunk_size, @sizeOf(Chunk) + align_bytes + n);
            const raw = self.child.rawAlloc(want, .of(Chunk), ra) orelse return null;
            const c: *Chunk = @ptrCast(@alignCast(raw));
            c.* = .{ .next = self.head, .size = want };
            self.head = c;
            self.ptr = @intFromPtr(raw) + @sizeOf(Chunk);
            self.end = @intFromPtr(raw) + want;
            p = std.mem.alignForward(usize, self.ptr, align_bytes);
        }
        self.ptr = p + n;
        return @ptrFromInt(p);
    }

    /// Only the most recent allocation can grow in place — which is the one
    /// that matters, since that is how an `ArrayList` appends.
    fn resize(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *ChunkArena = @ptrCast(@alignCast(ctx));
        if (@intFromPtr(buf.ptr) + buf.len != self.ptr) return new_len <= buf.len;
        if (@intFromPtr(buf.ptr) + new_len > self.end) return false;
        self.ptr = @intFromPtr(buf.ptr) + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, buf, a, new_len, ra)) buf.ptr else null;
    }

    /// Rolls back the most recent allocation; anything else is a no-op (§7.6's
    /// model, and stage 0's: nothing is freed).
    fn free(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *ChunkArena = @ptrCast(@alignCast(ctx));
        if (@intFromPtr(buf.ptr) + buf.len == self.ptr) self.ptr = @intFromPtr(buf.ptr);
    }

    pub fn deinit(self: *ChunkArena) void {
        var it = self.head;
        while (it) |c| {
            const next = c.next;
            self.child.rawFree(@as([*]u8, @ptrCast(c))[0..c.size], .of(Chunk), @returnAddress());
            it = next;
        }
    }
};

/// Stack for the interpreter thread. The guard in `interp.zig` fires well below
/// this, so the size only has to leave that guard room to report rather than
/// let the thread hit the real end of the stack.
///
/// Checking stage 1's largest file peaks at ~170 nested calls and under 2MB, so
/// this is roughly 30x headroom. It was 256MB when the measured depth came from
/// a run with tracing on — and the tracing was the cause: it wraps the
/// recursion in a block, and §7.7 makes a call inside a block a real frame
/// where it was a tail call.
const interp_stack_bytes = 64 * 1024 * 1024;

/// Running the interpreter on a spawned thread, since a thread's stack size is
/// ours to choose and the main thread's is not.
const RunCtx = struct {
    arena: Allocator,
    diags: *diag.Diagnostics,
    file: ast.File,
    opts: interp.Interp.Options,
    stats: ?*interp.Interp.Stats = null,
    failed: ?anyerror = null,

    fn run(self: *RunCtx) void {
        var opts = self.opts;
        opts.stats = self.stats;
        var it = interp.Interp.init(self.arena, self.diags, opts) catch |e| {
            self.failed = e;
            return;
        };
        _ = it.runFile(self.file) catch |e| switch (e) {
            // Both are already recorded as diagnostics; §7.8 makes a panic
            // abort the whole program, with no catch.
            error.Halt, error.Panicked => {},
            error.TryReturn => unreachable, // runFile turns this into a diagnostic
            error.OutOfMemory => self.failed = e,
        };
    }
};

const usage =
    \\usage: morphlc [--tokens|--run] <file.mpl> [program args...]
    \\
    \\  --tokens   print the token stream instead of the AST
    \\  --run      evaluate the file instead of printing the AST
    \\
    \\Arguments after <file.mpl> are passed to the program, where the `args`
    \\intrinsic returns them.
    \\
;

/// Resolves `$import "name"` to `<entry file's directory>/name.mpl`.
///
/// §4.14 makes import names logical and hands resolution to the build program
/// ("search roots and an explicit name→file map"). This is the stage-0
/// placeholder for that, and it is why the evaluator takes a resolver rather
/// than opening files itself. Resolving relative to the entry file rather than
/// the process's working directory is what makes a module's imports mean the
/// same thing however morphlc was invoked.
const FileLoader = struct {
    io: Io,
    dir: Io.Dir,
    base: []const u8,

    fn resolve(
        ctx: *const anyopaque,
        arena: Allocator,
        name: []const u8,
    ) interp.Loader.LoadError!interp.Loader.Resolved {
        const self: *const FileLoader = @ptrCast(@alignCast(ctx));
        const path = if (self.base.len == 0)
            try std.fmt.allocPrint(arena, "{s}.mpl", .{name})
        else
            try std.fmt.allocPrint(arena, "{s}/{s}.mpl", .{ self.base, name });
        const source = self.dir.readFileAlloc(self.io, path, arena, .limited(max_source_bytes)) catch
            return error.ReadFailed;
        return .{ .key = path, .source = source };
    }

    fn loader(self: *const FileLoader) interp.Loader {
        return .{ .ctx = self, .resolveFn = resolve };
    }
};

/// The host behind `read_file`, `write_file` and `args`.
///
/// §4.16 makes the platform library code over `$extern` in a per-target root
/// block; stage 0 has no `$extern`, so the driver supplies this instead. It
/// lives here rather than in lib/interp/ so that the evaluator still cannot
/// reach the filesystem on its own.
const HostPlatform = struct {
    io: Io,
    dir: Io.Dir,
    /// Arguments after the input file — what the *morphl program* was passed,
    /// not what morphlc was passed.
    argv: []const []const u8,

    fn readFile(
        ctx: *const anyopaque,
        arena: Allocator,
        path: []const u8,
    ) interp.Platform.PlatformError![]const u8 {
        const self: *const HostPlatform = @ptrCast(@alignCast(ctx));
        return self.dir.readFileAlloc(self.io, path, arena, .limited(max_source_bytes)) catch
            error.Failed;
    }

    fn writeFile(
        ctx: *const anyopaque,
        path: []const u8,
        bytes: []const u8,
    ) interp.Platform.PlatformError!void {
        const self: *const HostPlatform = @ptrCast(@alignCast(ctx));
        self.dir.writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch
            return error.Failed;
    }

    fn args(
        ctx: *const anyopaque,
        arena: Allocator,
    ) interp.Platform.PlatformError![]const []const u8 {
        _ = arena;
        const self: *const HostPlatform = @ptrCast(@alignCast(ctx));
        return self.argv;
    }

    fn platform(self: *const HostPlatform) interp.Platform {
        return .{
            .ctx = self,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .argsFn = args,
        };
    }
};

pub fn main(init: process.Init.Minimal) !void {
    var debug_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_gpa.deinit();
    const gpa = debug_gpa.allocator();

    var threaded: Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state: ChunkArena = .{ .child = std.heap.page_allocator };
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var stderr_buf: [4 * 1024]u8 = undefined;
    // **Streaming, not positional.** `writer` defaults to positional writes
    // from an offset of zero, and `MORPHL_PROGRESS` appends to fd 2 with a raw
    // `write` from inside the allocator — where the `Io` instance is out of
    // reach. With a positional writer the final report `pwrite`s back over the
    // start of the file and eats the first heartbeats, which is exactly what
    // happened: 29 of 44 lines vanished under the profile. Streaming shares the
    // file offset, so the two interleave in the order they were written.
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = try init.args.toSlice(arena);
    var path: ?[]const u8 = null;
    var dump_tokens = false;
    var run = false;
    // Everything after the input file belongs to the program, not to morphlc,
    // and is what its `args` intrinsic returns.
    var program_args: []const []const u8 = &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (path != null) {
            const rest = try arena.alloc([]const u8, args.len - i);
            for (args[i..], rest) |a, *slot| slot.* = a;
            program_args = rest;
            break;
        }
        if (std.mem.eql(u8, arg, "--tokens")) {
            dump_tokens = true;
        } else if (std.mem.eql(u8, arg, "--run")) {
            run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("morphlc: unknown option '{s}'\n\n{s}", .{ arg, usage });
            try err.flush();
            process.exit(2);
        } else {
            path = arg;
        }
    }

    const file_path = path orelse {
        try err.writeAll(usage);
        try err.flush();
        process.exit(2);
    };

    const source = Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(max_source_bytes)) catch |e| {
        try err.print("morphlc: cannot read '{s}': {s}\n", .{ file_path, @errorName(e) });
        try err.flush();
        process.exit(1);
    };

    var diags: diag.Diagnostics = .init(gpa);
    defer diags.deinit();

    // One pool for the whole run: §4.14 makes an imported file's names the
    // same names, so they have to be interned together.
    var pool: lexer.StringPool = .init(arena);

    const tokens = try lexer.tokenize(gpa, arena, source, &diags, &pool);
    defer gpa.free(tokens);

    if (dump_tokens) {
        for (tokens) |t| {
            try out.print("{d}:{d}\t", .{ t.span.line, t.span.col });
            try printTokenKind(out, t.kind);
            try out.writeByte('\n');
        }
    } else {
        const parsed = try parser.parseFile(arena, tokens, &diags);
        if (run) {
            if (!diags.any()) {
                const fl: FileLoader = .{
                    .io = io,
                    .dir = Io.Dir.cwd(),
                    .base = Io.Dir.path.dirname(file_path) orelse "",
                };
                const host: HostPlatform = .{
                    .io = io,
                    .dir = Io.Dir.cwd(),
                    .argv = program_args,
                };
                // On its own thread, for the stack: a subtype check descends
                // structurally through a recursive type and that recursion is
                // not in tail position, so §7.7 cannot eliminate it. The main
                // thread's 8MB was enough to run stage 1 but not to *check* it.
                var ctx: RunCtx = .{
                    .arena = arena,
                    .diags = &diags,
                    .file = parsed,
                    .opts = .{
                        .out = out,
                        .pool = &pool,
                        .loader = fl.loader(),
                        .platform = host.platform(),
                        // Leaves the guard room to report rather than let the
                        // thread run off the end of its stack.
                        .stack_bytes = interp_stack_bytes - 16 * 1024 * 1024,
                    },
                };
                // An allocation profile, when asked for. Nothing is ever freed
                // (§7.6), so bytes allocated is peak memory, and the profile
                // says which morphl function spent it.
                var stats: interp.Interp.Stats = .{ .backing = arena };
                if (init.environ.getPosix("MORPHL_STATS") != null) ctx.stats = &stats;
                if (init.environ.getPosix("MORPHL_TRACE_READS") != null) {
                    interp.builtins_trace_reads.* = true;
                }
                if (init.environ.getPosix("MORPHL_NO_PRIM_CACHE") != null) {
                    interp.no_prim_cache_flag.* = true;
                }
                if (init.environ.getPosix("MORPHL_VERIFY_PRIM") != null) {
                    interp.verify_prim_flag.* = true;
                }
                // Megabytes between heartbeats. A final profile cannot say
                // where a capped run *was*; this can.
                if (init.environ.getPosix("MORPHL_PROGRESS")) |mb| {
                    const step = std.fmt.parseInt(u64, mb, 10) catch 64;
                    stats.progress_step = (if (step == 0) 64 else step) * 1024 * 1024;
                    stats.progress_next = stats.progress_step;
                    stats.t0_ns = @TypeOf(stats).monoNs();
                    ctx.stats = &stats;
                }
                if (init.environ.getPosix("MORPHL_CALLS") != null) {
                    stats.by_calls = true;
                    ctx.stats = &stats;
                }
                if (init.environ.getPosix("MORPHL_INCLUSIVE")) |n| {
                    stats.incl_name = n;
                    ctx.stats = &stats;
                }

                const th = try std.Thread.spawn(.{ .stack_size = interp_stack_bytes }, RunCtx.run, .{&ctx});
                th.join();
                if (ctx.stats) |st| try st.report(err);
                if (ctx.failed) |e| return e;
            }
        } else if (!diags.any()) {
            try parsed.dump(out);
        }
    }
    try out.flush();

    if (diags.any()) {
        diags.sort();
        try diags.render(err, file_path);
        try err.print("morphlc: {d} error{s}\n", .{
            diags.items.items.len,
            if (diags.items.items.len == 1) "" else "s",
        });
        try err.flush();
        process.exit(1);
    }
}

fn printTokenKind(w: *Io.Writer, kind: lexer.TokenKind) !void {
    switch (kind) {
        .int => |v| try w.print("int {d}", .{v}),
        .float => |t| try w.print("float {s}", .{t}),
        .str => |s| try w.print("str \"{s}\"", .{s}),
        .name => |n| try w.print("name {s}", .{n}),
        .keyword => |k| try w.print("keyword {s}", .{k.text()}),
        .true_lit => try w.writeAll("true"),
        .false_lit => try w.writeAll("false"),
        .lparen => try w.writeAll("("),
        .rparen => try w.writeAll(")"),
        .lbrace => try w.writeAll("{"),
        .rbrace => try w.writeAll("}"),
        .comma => try w.writeAll(","),
        .proj_name => |f| try w.print("proj .{s}", .{f}),
        .proj_index => |i| try w.print("proj .{d}", .{i}),
        .invalid => try w.writeAll("<invalid>"),
        .eof => try w.writeAll("<eof>"),
    }
}

test {
    // Pull the library modules' tests in when testing this root.
    _ = diag;
    _ = lexer;
    _ = parser;
    _ = ast;
    _ = interp;
}
