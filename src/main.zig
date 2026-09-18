//! morphlc — stage 0 driver.
//!
//! Today it lexes and parses; the evaluator is BOOTSTRAP.md §5 step 3.
//!
//!   morphlc <file.mpl>            print the parsed AST as S-expressions
//!   morphlc --tokens <file.mpl>   print the token stream

const std = @import("std");
const process = std.process;
const Io = std.Io;

const diag = @import("diag");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");

const max_source_bytes = 64 * 1024 * 1024;

const usage =
    \\usage: morphlc [--tokens] <file.mpl>
    \\
    \\  --tokens   print the token stream instead of the AST
    \\
;

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

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var stderr_buf: [4 * 1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = try init.args.toSlice(arena);
    var path: ?[]const u8 = null;
    var dump_tokens = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--tokens")) {
            dump_tokens = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("morphlc: unknown option '{s}'\n\n{s}", .{ arg, usage });
            try err.flush();
            process.exit(2);
        } else if (path != null) {
            try err.writeAll("morphlc: one input file at a time\n");
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

    const tokens = try lexer.tokenize(gpa, arena, source, &diags);
    defer gpa.free(tokens);

    if (dump_tokens) {
        for (tokens) |t| {
            try out.print("{d}:{d}\t", .{ t.span.line, t.span.col });
            try printTokenKind(out, t.kind);
            try out.writeByte('\n');
        }
    } else {
        const parsed = try parser.parseFile(arena, tokens, &diags);
        if (!diags.any()) try parsed.dump(out);
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
}
