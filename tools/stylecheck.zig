//! STYLE.md's mechanical rules, checked: no tabs, no trailing whitespace, and at
//! most 100 columns of code and comment per line — a string literal's contents do
//! not count, because STYLE.md lets a string run past the limit when splitting it
//! would only add `concat`s.
//!
//! Usage: stylecheck <dir>... — every `.mpl` file directly in each directory.
//! One `file:line: problem` per violation on stderr, and a non-zero exit if any.

const std = @import("std");
const Io = std.Io;

const width = 100;

/// Columns are characters, not bytes: `§` and `—` are two and three bytes of UTF-8,
/// and a comment full of them would otherwise read as over the limit.
fn chars(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Columns of a line that count: everything outside a string literal's quotes.
/// A `//` outside a string starts a comment, which counts in full.
fn visible(line: []const u8) usize {
    var n: usize = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c & 0xC0 == 0x80) continue;
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_str = false;
                n += 1;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            n += 1;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return n + chars(line[i..]);
        n += 1;
    }
    return n;
}

fn checkFile(err: *Io.Writer, path: []const u8, src: []const u8) !usize {
    var bad: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    var ln: usize = 0;
    while (it.next()) |line| {
        ln += 1;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            try err.print("{s}:{d}: tab\n", .{ path, ln });
            bad += 1;
        }
        if (line.len > 0 and line[line.len - 1] == ' ') {
            try err.print("{s}:{d}: trailing whitespace\n", .{ path, ln });
            bad += 1;
        }
        const v = visible(line);
        if (v > width) {
            try err.print("{s}:{d}: {d} columns, over {d}\n", .{ path, ln, v, width });
            bad += 1;
        }
    }
    return bad;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: Io.Threaded = .init(arena, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var err_buf: [4 * 1024]u8 = undefined;
    var err_writer = Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;

    const args = try init.args.toSlice(arena);
    var bad: usize = 0;
    var files: usize = 0;
    for (args[1..]) |dir_path| {
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walk = dir.iterate();
        while (try walk.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mpl")) continue;
            const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
            const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
            bad += try checkFile(err, path, src);
            files += 1;
        }
    }
    if (bad != 0) try err.print("stylecheck: {d} problem(s) in {d} file(s) (STYLE.md)\n", .{ bad, files });
    try err.flush();
    if (bad != 0) std.process.exit(1);
}
