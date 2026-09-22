//! Lexer — SPEC.md §2.1, BOOTSTRAP.md §5 step 1.
//!
//! Differences from the pre-Draft-4 lexer on the `zig_rewrite` branch, all of
//! them required by the current spec:
//!
//!   * Whitespace and comments are trivia; they are not emitted as tokens.
//!   * `;` is trivia too. §2.1 makes it an optional separator with *no
//!     meaning*, so dropping it here means no later stage has to know it exists.
//!   * `$` is no longer an identifier character. Keywords are `$name` and
//!     identifiers may not start with `$` (§2.1), so a `$` always begins a
//!     compiler form and is resolved against the keyword table immediately.
//!   * `true`/`false` get their own token kinds: they are literals, not
//!     keywords and not shadowable names (§2.1, §3.2).
//!   * Float literals are kept as their **source text**. BOOTSTRAP.md §1.2
//!     drops float arithmetic from stage 0 but not float literals; carrying the
//!     text lets the backend emit it without stage 0 owning a decimal parser.
//!
//! Lexing never stops at the first error: an invalid token is reported and
//! emitted as `.invalid` so one run can surface several mistakes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const kw = @import("keyword");

const Span = diag.Span;
const Diagnostics = diag.Diagnostics;
const Keyword = kw.Keyword;

pub const TokenKind = union(enum) {
    /// Integer literal. A leading `-` is part of the literal (§2.1); there are
    /// no infix operators for it to belong to.
    int: i64,
    /// Float literal, as written in source. See the note above.
    float: []const u8,
    /// String literal with escapes already decoded. Owned by the arena passed
    /// to `tokenize`, *not* a slice of the source.
    str: []const u8,
    /// Identifier. A slice of the source.
    name: []const u8,
    /// `$name`, resolved against the §2.2 table.
    keyword: Keyword,
    true_lit,
    false_lit,
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    /// `.field`
    proj_name: []const u8,
    /// `.1` — a group index, 1-based (§2.1).
    proj_index: u32,
    /// A lexical error, already reported. Present so lexing can continue.
    invalid,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,
};

/// Identifier interning.
///
/// Every identifier the lexer produces is replaced by *the* slice for that
/// text, so two names are equal exactly when their slices are. `perf` said 80%
/// of stage 0 was `std.mem.eql` on identifier bytes, called once per binding
/// per scope on every name reference; a pointer comparison costs nothing and
/// scopes stop caring how long a name is.
///
/// A name that never reaches this pool simply fails to resolve — a pointer can
/// only be equal to itself, so a missed interning is a loud "unknown name",
/// never a wrong match. That is why the pool is threaded rather than
/// best-effort: `tokenize` takes one, and so does the root block.
pub const StringPool = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,
    arena: Allocator,

    pub fn init(arena: Allocator) StringPool {
        return .{ .arena = arena };
    }

    /// The canonical slice for `text`, copying it into the pool's arena the
    /// first time. The copy matters: a name lexed from one file's source must
    /// outlive that source and be shared with every other file (§4.14).
    pub fn intern(self: *StringPool, text: []const u8) Allocator.Error![]const u8 {
        const gop = try self.map.getOrPut(self.arena, text);
        if (!gop.found_existing) {
            const owned = try self.arena.dupe(u8, text);
            gop.key_ptr.* = owned;
        }
        return gop.key_ptr.*;
    }
};

/// Tokenize `src`.
///
/// `gpa` allocates the returned slice (caller frees). `arena` holds decoded
/// string literals, so it must outlive the tokens; so must `src`, since names
/// are slices into it.
pub fn tokenize(
    gpa: Allocator,
    arena: Allocator,
    src: []const u8,
    diags: *Diagnostics,
    pool: *StringPool,
) Allocator.Error![]Token {
    var lx: Lexer = .{ .src = src, .arena = arena, .diags = diags, .pool = pool };
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    while (true) {
        const tok = try lx.next();
        try tokens.append(gpa, tok);
        if (tok.kind == .eof) break;
    }
    return tokens.toOwnedSlice(gpa);
}

pub const Lexer = struct {
    src: []const u8,
    arena: Allocator,
    diags: *Diagnostics,
    pool: *StringPool,
    pos: u32 = 0,
    line: u32 = 1,
    /// Byte offset of the start of the current line, for computing columns.
    line_start: u32 = 0,

    fn col(self: *const Lexer, at: u32) u32 {
        return at - self.line_start + 1;
    }

    fn spanFrom(self: *const Lexer, start: u32, start_line: u32, start_col: u32) Span {
        return .{ .start = start, .end = self.pos, .line = start_line, .col = start_col };
    }

    fn peek(self: *const Lexer) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peekAt(self: *const Lexer, off: u32) ?u8 {
        const i = self.pos + off;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn advance(self: *Lexer) void {
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.line_start = self.pos + 1;
        }
        self.pos += 1;
    }

    /// Whitespace, `;`, and both comment forms (§2.1).
    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n', ';' => self.advance(),
                '/' => {
                    if (self.peekAt(1) == @as(u8, '/')) {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.advance();
                    } else if (self.peekAt(1) == @as(u8, '*')) {
                        const open = self.pos;
                        const open_line = self.line;
                        const open_col = self.col(open);
                        self.advance();
                        self.advance();
                        // Non-nesting (§2.1): the first `*/` closes it.
                        while (true) {
                            if (self.pos >= self.src.len) {
                                self.diags.add(.{
                                    .start = open,
                                    .end = self.pos,
                                    .line = open_line,
                                    .col = open_col,
                                }, "unterminated block comment", .{});
                                return;
                            }
                            if (self.src[self.pos] == '*' and self.peekAt(1) == @as(u8, '/')) {
                                self.advance();
                                self.advance();
                                break;
                            }
                            self.advance();
                        }
                    } else return;
                },
                else => return,
            }
        }
    }

    pub fn next(self: *Lexer) Allocator.Error!Token {
        self.skipTrivia();
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col(start);

        if (self.pos >= self.src.len) {
            return .{ .kind = .eof, .span = self.spanFrom(start, start_line, start_col) };
        }

        const c = self.src[self.pos];
        const simple: ?TokenKind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            else => null,
        };
        if (simple) |kind| {
            self.advance();
            return .{ .kind = kind, .span = self.spanFrom(start, start_line, start_col) };
        }

        if (c == '$') return self.lexKeyword(start, start_line, start_col);
        if (c == '"') return self.lexString(start, start_line, start_col);
        if (c == '.') return try self.lexProjection(start, start_line, start_col);
        if (isDigit(c) or (c == '-' and isDigitOpt(self.peekAt(1)))) {
            return self.lexNumber(start, start_line, start_col);
        }
        if (isIdentStart(c)) return try self.lexName(start, start_line, start_col);

        self.advance();
        const span = self.spanFrom(start, start_line, start_col);
        if (std.ascii.isPrint(c)) {
            self.diags.add(span, "unexpected character '{c}'", .{c});
        } else {
            self.diags.add(span, "unexpected byte 0x{X:0>2}", .{c});
        }
        return .{ .kind = .invalid, .span = span };
    }

    fn lexName(self: *Lexer, start: u32, start_line: u32, start_col: u32) Allocator.Error!Token {
        while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) self.advance();
        const text = self.src[start..self.pos];
        const span = self.spanFrom(start, start_line, start_col);
        if (std.mem.eql(u8, text, "true")) return .{ .kind = .true_lit, .span = span };
        if (std.mem.eql(u8, text, "false")) return .{ .kind = .false_lit, .span = span };
        return .{ .kind = .{ .name = try self.pool.intern(text) }, .span = span };
    }

    fn lexKeyword(self: *Lexer, start: u32, start_line: u32, start_col: u32) Token {
        self.advance(); // '$'
        const name_start = self.pos;
        while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) self.advance();
        const name = self.src[name_start..self.pos];
        const span = self.spanFrom(start, start_line, start_col);
        if (name.len == 0) {
            self.diags.add(span, "expected a keyword name after '$'", .{});
            return .{ .kind = .invalid, .span = span };
        }
        if (kw.lookup(name)) |k| return .{ .kind = .{ .keyword = k }, .span = span };
        self.diags.add(span, "unknown keyword '${s}'", .{name});
        return .{ .kind = .invalid, .span = span };
    }

    fn lexNumber(self: *Lexer, start: u32, start_line: u32, start_col: u32) Token {
        if (self.src[self.pos] == '-') self.advance();
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.advance();

        // A `.` continues the number only when a digit follows it; otherwise it
        // is a projection, so `1.2` is a float and `(a, b).1` is an index.
        if (self.peek() == @as(u8, '.') and isDigitOpt(self.peekAt(1))) {
            self.advance();
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.advance();
            const text = self.src[start..self.pos];
            return .{ .kind = .{ .float = text }, .span = self.spanFrom(start, start_line, start_col) };
        }

        const text = self.src[start..self.pos];
        const span = self.spanFrom(start, start_line, start_col);
        const v = std.fmt.parseInt(i64, text, 10) catch {
            self.diags.add(span, "integer literal '{s}' does not fit in Int (64-bit)", .{text});
            return .{ .kind = .invalid, .span = span };
        };
        return .{ .kind = .{ .int = v }, .span = span };
    }

    fn lexProjection(self: *Lexer, start: u32, start_line: u32, start_col: u32) Allocator.Error!Token {
        self.advance(); // '.'
        const field_start = self.pos;
        if (isDigitOpt(self.peek())) {
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.advance();
            const text = self.src[field_start..self.pos];
            const span = self.spanFrom(start, start_line, start_col);
            const v = std.fmt.parseInt(u32, text, 10) catch {
                self.diags.add(span, "group index '{s}' is too large", .{text});
                return .{ .kind = .invalid, .span = span };
            };
            if (v == 0) {
                self.diags.add(span, "group indices start at .1, not .0", .{});
                return .{ .kind = .invalid, .span = span };
            }
            return .{ .kind = .{ .proj_index = v }, .span = span };
        }
        if (isIdentStartOpt(self.peek())) {
            while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) self.advance();
            const text = self.src[field_start..self.pos];
            // A field name is compared against block field names, so it is
            // interned like any other identifier.
            return .{ .kind = .{ .proj_name = try self.pool.intern(text) }, .span = self.spanFrom(start, start_line, start_col) };
        }
        const span = self.spanFrom(start, start_line, start_col);
        self.diags.add(span, "expected a field name or group index after '.'", .{});
        return .{ .kind = .invalid, .span = span };
    }

    /// String literal with `\n \t \\ \"` and `\u{…}` (§2.1), validated as UTF-8.
    fn lexString(self: *Lexer, start: u32, start_line: u32, start_col: u32) Allocator.Error!Token {
        self.advance(); // opening quote
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);

        while (true) {
            if (self.pos >= self.src.len or self.src[self.pos] == '\n') {
                // Rejecting a raw newline keeps a missing close quote from
                // swallowing the rest of the file; the span points at the
                // opening quote, which is where the fix goes.
                const span: Span = .{
                    .start = start,
                    .end = self.pos,
                    .line = start_line,
                    .col = start_col,
                };
                self.diags.add(span, "unterminated string literal", .{});
                return .{ .kind = .invalid, .span = span };
            }
            const c = self.src[self.pos];
            if (c == '"') {
                self.advance();
                break;
            }
            if (c != '\\') {
                try buf.append(self.arena, c);
                self.advance();
                continue;
            }

            // Escape.
            const esc_start = self.pos;
            const esc_line = self.line;
            const esc_col = self.col(esc_start);
            self.advance(); // backslash
            const e = self.peek() orelse continue; // next loop reports the EOF
            switch (e) {
                'n' => {
                    try buf.append(self.arena, '\n');
                    self.advance();
                },
                't' => {
                    try buf.append(self.arena, '\t');
                    self.advance();
                },
                '\\' => {
                    try buf.append(self.arena, '\\');
                    self.advance();
                },
                '"' => {
                    try buf.append(self.arena, '"');
                    self.advance();
                },
                'u' => {
                    self.advance(); // 'u'
                    try self.lexUnicodeEscape(&buf, esc_start, esc_line, esc_col);
                },
                else => {
                    self.advance();
                    self.diags.add(.{
                        .start = esc_start,
                        .end = self.pos,
                        .line = esc_line,
                        .col = esc_col,
                    }, "unknown escape '\\{c}'; morphl has \\n \\t \\\\ \\\" and \\u{{…}}", .{e});
                },
            }
        }

        const span = self.spanFrom(start, start_line, start_col);
        // §3.1: Str is *always* valid UTF-8, so this is an invariant of the
        // token, not a check some later stage can choose to skip.
        if (!std.unicode.utf8ValidateSlice(buf.items)) {
            self.diags.add(span, "string literal is not valid UTF-8", .{});
            return .{ .kind = .invalid, .span = span };
        }
        const owned = try self.arena.dupe(u8, buf.items);
        return .{ .kind = .{ .str = owned }, .span = span };
    }

    fn lexUnicodeEscape(
        self: *Lexer,
        buf: *std.ArrayList(u8),
        esc_start: u32,
        esc_line: u32,
        esc_col: u32,
    ) Allocator.Error!void {
        const fail = struct {
            fn span(s: u32, e: u32, l: u32, c: u32) Span {
                return .{ .start = s, .end = e, .line = l, .col = c };
            }
        };
        if (self.peek() != @as(u8, '{')) {
            self.diags.add(
                fail.span(esc_start, self.pos, esc_line, esc_col),
                "expected '{{' after '\\u'",
                .{},
            );
            return;
        }
        self.advance(); // '{'
        const digits_start = self.pos;
        while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.advance();
        const digits = self.src[digits_start..self.pos];
        if (self.peek() != @as(u8, '}')) {
            self.diags.add(
                fail.span(esc_start, self.pos, esc_line, esc_col),
                "expected '}}' to close '\\u{{'",
                .{},
            );
            return;
        }
        self.advance(); // '}'
        const span = fail.span(esc_start, self.pos, esc_line, esc_col);
        if (digits.len == 0 or digits.len > 6) {
            self.diags.add(span, "'\\u{{…}}' takes 1 to 6 hex digits", .{});
            return;
        }
        const cp = std.fmt.parseInt(u32, digits, 16) catch {
            self.diags.add(span, "invalid code point '\\u{{{s}}}'", .{digits});
            return;
        };
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(std.math.cast(u21, cp) orelse 0x110000, &enc) catch {
            self.diags.add(span, "'\\u{{{s}}}' is not a valid code point", .{digits});
            return;
        };
        try buf.appendSlice(self.arena, enc[0..n]);
    }
};

/// §2.1: identifiers may not start with `$`, which is reserved for keywords.
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isDigit(c: u8) bool {
    return std.ascii.isDigit(c);
}

fn isDigitOpt(c: ?u8) bool {
    return if (c) |x| isDigit(x) else false;
}

fn isIdentStartOpt(c: ?u8) bool {
    return if (c) |x| isIdentStart(x) else false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    diags: Diagnostics,
    tokens: []Token,
    pool: StringPool = undefined,

    fn init(src: []const u8) !Harness {
        var h: Harness = .{
            .arena_state = .init(testing.allocator),
            .diags = .init(testing.allocator),
            .tokens = &.{},
        };
        const arena = h.arena_state.allocator();
        h.pool = .init(arena);
        h.tokens = try tokenize(testing.allocator, arena, src, &h.diags, &h.pool);
        return h;
    }

    fn deinit(self: *Harness) void {
        testing.allocator.free(self.tokens);
        self.diags.deinit();
        self.arena_state.deinit();
    }
};

fn kindsOf(src: []const u8, expected: []const std.meta.Tag(TokenKind)) !void {
    var h = try Harness.init(src);
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqual(expected.len, h.tokens.len);
    for (expected, h.tokens) |want, got| {
        try testing.expectEqual(want, std.meta.activeTag(got.kind));
    }
}

test "trivia: whitespace, both comments, and ';' carry no meaning" {
    try kindsOf(
        \\// leading comment
        \\ a ; b /* block
        \\ spanning lines */ c
    , &.{ .name, .name, .name, .eof });
}

test "keywords resolve; identifiers may not start with $" {
    var h = try Harness.init("$decl x 1");
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqual(Keyword.decl, h.tokens[0].kind.keyword);
    try testing.expectEqualStrings("x", h.tokens[1].kind.name);
    try testing.expectEqual(@as(i64, 1), h.tokens[2].kind.int);
}

test "unknown keyword is reported but lexing continues" {
    var h = try Harness.init("$nope x $decl");
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1), h.diags.items.items.len);
    try testing.expectEqualStrings("unknown keyword '$nope'", h.diags.items.items[0].msg);
    try testing.expectEqual(TokenKind.invalid, std.meta.activeTag(h.tokens[0].kind));
    try testing.expectEqual(Keyword.decl, h.tokens[2].kind.keyword);
}

test "true and false are literals, not names" {
    var h = try Harness.init("true false truest");
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqual(TokenKind.true_lit, std.meta.activeTag(h.tokens[0].kind));
    try testing.expectEqual(TokenKind.false_lit, std.meta.activeTag(h.tokens[1].kind));
    try testing.expectEqualStrings("truest", h.tokens[2].kind.name);
}

test "intrinsics are ordinary names" {
    var h = try Harness.init("add print eq panic");
    defer h.deinit();
    try testing.expect(!h.diags.any());
    for (h.tokens[0..4]) |t| try testing.expectEqual(TokenKind.name, std.meta.activeTag(t.kind));
}

test "numbers: negative ints, floats kept as text" {
    var h = try Harness.init("0 42 -7 0.0 3.14 -2.5");
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqual(@as(i64, 0), h.tokens[0].kind.int);
    try testing.expectEqual(@as(i64, 42), h.tokens[1].kind.int);
    try testing.expectEqual(@as(i64, -7), h.tokens[2].kind.int);
    try testing.expectEqualStrings("0.0", h.tokens[3].kind.float);
    try testing.expectEqualStrings("3.14", h.tokens[4].kind.float);
    try testing.expectEqualStrings("-2.5", h.tokens[5].kind.float);
}

test "a dot is a projection unless a digit continues a number" {
    var h = try Harness.init("x.a p.1 1.5 s.tail");
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqualStrings("a", h.tokens[1].kind.proj_name);
    try testing.expectEqual(@as(u32, 1), h.tokens[3].kind.proj_index);
    try testing.expectEqualStrings("1.5", h.tokens[4].kind.float);
    try testing.expectEqualStrings("tail", h.tokens[6].kind.proj_name);
}

test "group indices are 1-based" {
    var h = try Harness.init("x.0");
    defer h.deinit();
    try testing.expectEqualStrings("group indices start at .1, not .0", h.diags.items.items[0].msg);
}

test "integer overflow is a lexical error" {
    var h = try Harness.init("99999999999999999999");
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1), h.diags.items.items.len);
}

test "string escapes are decoded" {
    var h = try Harness.init(
        \\"a\nb\t\\\"c\u{1F600}\u{41}"
    );
    defer h.deinit();
    try testing.expect(!h.diags.any());
    try testing.expectEqualStrings("a\nb\t\\\"c\u{1F600}A", h.tokens[0].kind.str);
}

test "bad escapes and unterminated strings are reported" {
    {
        var h = try Harness.init(
            \\"oops \q"
        );
        defer h.deinit();
        try testing.expectEqual(@as(usize, 1), h.diags.items.items.len);
    }
    {
        var h = try Harness.init("\"no close\nnext line");
        defer h.deinit();
        try testing.expectEqualStrings("unterminated string literal", h.diags.items.items[0].msg);
        // The span points at the opening quote, not at end-of-file.
        try testing.expectEqual(@as(u32, 1), h.diags.items.items[0].span.line);
        try testing.expectEqual(@as(u32, 1), h.diags.items.items[0].span.col);
    }
}

test "spans track line and column" {
    var h = try Harness.init("a\n  bb\n");
    defer h.deinit();
    try testing.expectEqual(@as(u32, 1), h.tokens[0].span.line);
    try testing.expectEqual(@as(u32, 1), h.tokens[0].span.col);
    try testing.expectEqual(@as(u32, 2), h.tokens[1].span.line);
    try testing.expectEqual(@as(u32, 3), h.tokens[1].span.col);
    try testing.expectEqual(@as(u32, 3), h.tokens[2].span.line);
}

test "unterminated block comment is reported once" {
    var h = try Harness.init("a /* forever");
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1), h.diags.items.items.len);
    try testing.expectEqualStrings("unterminated block comment", h.diags.items.items[0].msg);
}
