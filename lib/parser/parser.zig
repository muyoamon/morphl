//! Parser — BOOTSTRAP.md §5 step 2.
//!
//! Table-driven off the fixed-arity table in SPEC.md §2.2: each `$kw` reads
//! exactly its own operands, so there is no precedence, no associativity and no
//! separator handling anywhere in this file. The only recursive structures are
//! groups, blocks and postfix projection.
//!
//! Errors do not stop the parse. A failed expression is reported once and then
//! the parser skips to the next plausible start (a `,`, a closer, a keyword, or
//! the next top-level expression), so a file with several mistakes reports
//! several diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const lexer = @import("lexer");
const ast = @import("ast");
const kw = @import("keyword");

const Span = diag.Span;
const Diagnostics = diag.Diagnostics;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Node = ast.Node;
const Keyword = kw.Keyword;

const Error = Allocator.Error;

/// Signals "this expression was already reported"; the caller recovers.
const Bad = error{Bad};
const ParseError = Error || Bad;

/// Parse a whole file. §3.3: a source file is a block, so this is a sequence of
/// expressions with no separators.
///
/// `arena` owns the returned tree. Check `diags.any()` for failure: a tree is
/// still returned on error, with the unparsable parts dropped.
pub fn parseFile(
    arena: Allocator,
    tokens: []const Token,
    diags: *Diagnostics,
) Error!ast.File {
    var p: Parser = .{ .arena = arena, .tokens = tokens, .diags = diags };
    var exprs: std.ArrayList(Node) = .empty;
    while (!p.at(.eof)) {
        const before = p.pos;
        const node = p.parseExpr() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Bad => {
                p.recover(.top_level);
                // Guarantee progress even if recovery consumed nothing.
                if (p.pos == before) p.pos += 1;
                continue;
            },
        };
        try exprs.append(arena, node);
    }
    const file: ast.File = .{ .exprs = try exprs.toOwnedSlice(arena) };
    validate(file, diags);
    return file;
}

const Parser = struct {
    arena: Allocator,
    tokens: []const Token,
    diags: *Diagnostics,
    pos: usize = 0,

    fn cur(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn at(self: *const Parser, tag: std.meta.Tag(TokenKind)) bool {
        return std.meta.activeTag(self.cur().kind) == tag;
    }

    fn eat(self: *Parser, tag: std.meta.Tag(TokenKind)) ?Token {
        if (!self.at(tag)) return null;
        const t = self.cur();
        self.pos += 1;
        return t;
    }

    fn bump(self: *Parser) Token {
        const t = self.cur();
        if (!self.at(.eof)) self.pos += 1;
        return t;
    }

    fn node(self: *Parser, span: Span, data: Node.Data) Error!Node {
        _ = self;
        return .{ .span = span, .data = data };
    }

    fn boxed(self: *Parser, n: Node) Error!*Node {
        const p = try self.arena.create(Node);
        p.* = n;
        return p;
    }

    // ------------------------------------------------------------ expressions

    fn parseExpr(self: *Parser) ParseError!Node {
        var n = try self.parsePrimary();
        // Postfix projection binds tighter than everything else; since there
        // are no infix operators, a `.x` token can only be a projection.
        while (true) {
            if (self.eat(.proj_name)) |t| {
                n = try self.node(n.span.to(t.span), .{ .proj_name = .{
                    .target = try self.boxed(n),
                    .field = t.kind.proj_name,
                } });
            } else if (self.eat(.proj_index)) |t| {
                n = try self.node(n.span.to(t.span), .{ .proj_index = .{
                    .target = try self.boxed(n),
                    .field = t.kind.proj_index,
                } });
            } else return n;
        }
    }

    fn parsePrimary(self: *Parser) ParseError!Node {
        const t = self.cur();
        switch (t.kind) {
            .int => |v| {
                self.pos += 1;
                return self.node(t.span, .{ .int = v });
            },
            .float => |text| {
                self.pos += 1;
                return self.node(t.span, .{ .float = text });
            },
            .str => |s| {
                self.pos += 1;
                return self.node(t.span, .{ .str = s });
            },
            .true_lit => {
                self.pos += 1;
                return self.node(t.span, .{ .bool_lit = true });
            },
            .false_lit => {
                self.pos += 1;
                return self.node(t.span, .{ .bool_lit = false });
            },
            .name => |n| {
                self.pos += 1;
                return self.node(t.span, .{ .name = n });
            },
            .lparen => return self.parseGroup(),
            .lbrace => return self.parseBlock(),
            .keyword => |k| return self.parseForm(k),
            .invalid => {
                // Already reported by the lexer; don't pile on.
                self.pos += 1;
                return error.Bad;
            },
            .rparen, .rbrace, .comma => {
                self.diags.add(t.span, "expected an expression, found '{s}'", .{describe(t.kind)});
                return error.Bad;
            },
            .proj_name, .proj_index => {
                self.diags.add(t.span, "projection has nothing to its left", .{});
                self.pos += 1;
                return error.Bad;
            },
            .eof => {
                self.diags.add(t.span, "unexpected end of file, expected an expression", .{});
                return error.Bad;
            },
        }
    }

    /// `( e, e, … )` — §2.3. Comma separated, so unlike a block it *does* need
    /// separators; `()` is unit and `(e)` folds away.
    fn parseGroup(self: *Parser) ParseError!Node {
        const open = self.bump(); // '('
        if (self.eat(.rparen)) |close| {
            return self.node(open.span.to(close.span), .unit);
        }

        var elems: std.ArrayList(Node) = .empty;
        while (true) {
            const before = self.pos;
            if (self.parseExpr()) |e| {
                try elems.append(self.arena, e);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Bad => {
                    self.recover(.group);
                    if (self.pos == before and !self.at(.rparen) and !self.at(.comma)) self.pos += 1;
                },
            }

            if (self.eat(.comma) != null) {
                if (self.at(.rparen)) {
                    self.diags.add(self.cur().span, "trailing ',' in group", .{});
                }
                continue;
            }
            if (self.eat(.rparen)) |close| {
                const span = open.span.to(close.span);
                // §2.3: "A one-element group is the element."
                if (elems.items.len == 1) return elems.items[0];
                if (elems.items.len == 0) return self.node(span, .unit);
                return self.node(span, .{ .group = try elems.toOwnedSlice(self.arena) });
            }
            if (self.at(.eof)) {
                self.diags.add(open.span, "unclosed '(' — group is missing its ')'", .{});
                return error.Bad;
            }
            self.diags.add(self.cur().span, "expected ',' or ')' in group, found '{s}'", .{describe(self.cur().kind)});
            self.recover(.group);
            if (!self.at(.comma) and !self.at(.rparen)) return error.Bad;
        }
    }

    /// `{ e e … }` — §2.3, no separator required.
    fn parseBlock(self: *Parser) ParseError!Node {
        const open = self.bump(); // '{'
        if (self.eat(.rbrace)) |close| {
            // §2.3: the empty block and the empty group are the same value.
            return self.node(open.span.to(close.span), .unit);
        }

        var exprs: std.ArrayList(Node) = .empty;
        while (true) {
            if (self.eat(.rbrace)) |close| {
                return self.node(open.span.to(close.span), .{
                    .block = try exprs.toOwnedSlice(self.arena),
                });
            }
            if (self.at(.eof)) {
                self.diags.add(open.span, "unclosed '{{' — block is missing its '}}'", .{});
                return error.Bad;
            }
            const before = self.pos;
            if (self.parseExpr()) |e| {
                try exprs.append(self.arena, e);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Bad => {
                    self.recover(.block);
                    if (self.pos == before and !self.at(.rbrace)) self.pos += 1;
                },
            }
        }
    }

    /// A keyword form: read exactly `arity` operands, each of the kind the
    /// §2.2 table names for that slot.
    fn parseForm(self: *Parser, keyword: Keyword) ParseError!Node {
        const start = self.bump(); // '$kw'
        const sig = keyword.signature();
        const operands = try self.arena.alloc(Node, sig.len);
        var span = start.span;

        for (sig, 0..) |kind, i| {
            const op = try self.parseOperand(keyword, kind, i, start.span);
            operands[i] = op;
            span = span.to(op.span);
        }
        return self.node(span, .{ .form = .{ .keyword = keyword, .operands = operands } });
    }

    fn parseOperand(
        self: *Parser,
        keyword: Keyword,
        kind: kw.OperandKind,
        index: usize,
        kw_span: Span,
    ) ParseError!Node {
        if (self.at(.eof)) {
            self.diags.add(kw_span, "{s} takes {d} operand{s}, found {d}", .{
                keyword.text(),
                keyword.arity(),
                if (keyword.arity() == 1) "" else "s",
                index,
            });
            return error.Bad;
        }
        switch (kind) {
            .expr => return self.parseExpr(),
            .name => return self.parseNameOperand(keyword, index),
            .str_lit => {
                const t = self.cur();
                if (self.eat(.str)) |s| return self.node(s.span, .{ .str = s.kind.str });
                self.diags.add(t.span, "{s} operand {d} must be a string literal, found '{s}'", .{
                    keyword.text(), index + 1, describe(t.kind),
                });
                return error.Bad;
            },
            .names => {
                // `$template T body` or `$template (A, B) body` (§4.9).
                if (self.at(.lparen)) {
                    const g = try self.parseGroup();
                    switch (g.data) {
                        .name => return g, // `(T)` folded to `T`
                        .group => |elems| {
                            for (elems) |el| {
                                if (std.meta.activeTag(el.data) != .name) {
                                    self.diags.add(el.span, "{s} generic parameters must be plain names", .{keyword.text()});
                                    return error.Bad;
                                }
                            }
                            return g;
                        },
                        else => {
                            self.diags.add(g.span, "{s} expects a name or a group of names", .{keyword.text()});
                            return error.Bad;
                        },
                    }
                }
                return self.parseNameOperand(keyword, index);
            },
        }
    }

    fn parseNameOperand(self: *Parser, keyword: Keyword, index: usize) ParseError!Node {
        const t = self.cur();
        if (self.eat(.name)) |n| return self.node(n.span, .{ .name = n.kind.name });
        // A keyword here is almost always a real mistake worth naming, e.g.
        // `$decl $new 0` or a shadowing attempt on `true`.
        self.diags.add(t.span, "{s} operand {d} must be a name, found '{s}'", .{
            keyword.text(), index + 1, describe(t.kind),
        });
        return error.Bad;
    }

    // -------------------------------------------------------------- recovery

    const Context = enum { top_level, group, block };

    /// Skip to somewhere a new expression can plausibly start, without eating
    /// the delimiter the caller is waiting for.
    fn recover(self: *Parser, ctx: Context) void {
        while (!self.at(.eof)) {
            switch (self.cur().kind) {
                .comma, .rparen => {
                    if (ctx == .group) return;
                    self.pos += 1;
                },
                .rbrace => {
                    if (ctx == .block) return;
                    self.pos += 1;
                },
                .keyword => return,
                else => self.pos += 1,
            }
        }
    }
};

fn describe(kind: TokenKind) []const u8 {
    return switch (kind) {
        .int => "integer literal",
        .float => "float literal",
        .str => "string literal",
        .name => "identifier",
        .keyword => |k| k.text(),
        .true_lit => "true",
        .false_lit => "false",
        .lparen => "(",
        .rparen => ")",
        .lbrace => "{",
        .rbrace => "}",
        .comma => ",",
        .proj_name, .proj_index => "projection",
        .invalid => "invalid token",
        .eof => "end of file",
    };
}

// ------------------------------------------------------------- validation

/// Post-parse structural checks that the arity table cannot express.
///
/// Right now that is exactly one rule: §2.2 says `$case` is "only inside
/// `$match`". It is checked here rather than in `parseForm` because the arms
/// sit inside a group, and threading a "we are in arms" flag through group
/// parsing would be both fiddly and easy to get subtly wrong.
pub fn validate(file: ast.File, diags: *Diagnostics) void {
    for (file.exprs) |*e| walk(e, diags);
}

fn walk(n: *const Node, diags: *Diagnostics) void {
    switch (n.data) {
        .form => |f| switch (f.keyword) {
            .match => {
                walk(&f.operands[0], diags);
                checkArms(&f.operands[1], diags);
                return;
            },
            .case => {
                diags.add(n.span, "$case is only valid as an arm of $match", .{});
            },
            else => {},
        },
        else => {},
    }
    for (n.children()) |*c| walk(c, diags);
}

/// The arms operand of a `$match`. Because `(e)` folds to `e` (§2.3), a
/// single-arm match has the `$case` form here directly rather than a group.
fn checkArms(arms: *const Node, diags: *Diagnostics) void {
    switch (arms.data) {
        .form => |f| {
            if (f.keyword == .case) return walkCaseBody(arms, diags);
            diags.add(arms.span, "$match arms must be $case forms, found {s}", .{f.keyword.text()});
        },
        .group => |elems| {
            for (elems) |*el| {
                if (el.isForm(.case)) {
                    walkCaseBody(el, diags);
                } else {
                    diags.add(el.span, "$match arms must be $case forms", .{});
                    walk(el, diags);
                }
            }
        },
        else => diags.add(arms.span, "$match arms must be a group of $case forms", .{}),
    }
}

fn walkCaseBody(case_node: *const Node, diags: *Diagnostics) void {
    // The pattern is a type-only position (§5.7) and is never evaluated, but it
    // is still an expression and can still contain a stray `$case`.
    for (case_node.data.form.operands) |*op| walk(op, diags);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    diags: Diagnostics,
    file: ast.File,

    fn init(src: []const u8) !Harness {
        var h: Harness = .{
            .arena_state = .init(testing.allocator),
            .diags = .init(testing.allocator),
            .file = .{ .exprs = &.{} },
        };
        const arena = h.arena_state.allocator();
        const tokens = try lexer.tokenize(testing.allocator, arena, src, &h.diags);
        defer testing.allocator.free(tokens);
        h.file = try parseFile(arena, tokens, &h.diags);
        return h;
    }

    fn deinit(self: *Harness) void {
        self.diags.deinit();
        self.arena_state.deinit();
    }
};

fn expectDump(src: []const u8, expected: []const u8) !void {
    var h = try Harness.init(src);
    defer h.deinit();
    if (h.diags.any()) {
        std.debug.print("unexpected diagnostics for `{s}`:\n", .{src});
        for (h.diags.items.items) |d| std.debug.print("  {d}:{d}: {s}\n", .{ d.span.line, d.span.col, d.msg });
        return error.UnexpectedDiagnostics;
    }
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try h.file.dump(&out.writer);
    try testing.expectEqualStrings(expected, std.mem.trimEnd(u8, out.written(), "\n"));
}

fn expectError(src: []const u8, expected_substring: []const u8) !void {
    var h = try Harness.init(src);
    defer h.deinit();
    try testing.expect(h.diags.any());
    for (h.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, expected_substring) != null) return;
    }
    std.debug.print("no diagnostic containing \"{s}\"; got:\n", .{expected_substring});
    for (h.diags.items.items) |d| std.debug.print("  {s}\n", .{d.msg});
    return error.WrongDiagnostic;
}

test "arity drives the parse: no separators needed" {
    try expectDump("$decl x 1", "($decl x 1)");
    try expectDump("$decl x 1 $decl y 2", "($decl x 1)\n($decl y 2)");
    try expectDump("$if true 1 2", "($if true 1 2)");
    try expectDump("$do a b", "($do a b)");
}

test "groups: unit, folding, and tuples" {
    try expectDump("()", "()");
    try expectDump("{}", "()"); // §2.3: same value
    try expectDump("(a)", "a"); // no one-tuple
    try expectDump("(a, b)", "(group a b)");
    try expectDump("(a, b, c)", "(group a b c)");
}

test "blocks keep one element; only groups fold" {
    try expectDump("{a}", "(block a)");
    try expectDump("{a b}", "(block a b)");
}

test "';' is not a separator, it is nothing" {
    try expectDump("$decl x 1; $decl y 2", "($decl x 1)\n($decl y 2)");
    try expectDump("{a; b;}", "(block a b)");
}

test "projection is postfix and binds tightest" {
    try expectDump("x.a", "(. x a)");
    try expectDump("x.a.b", "(. (. x a) b)");
    try expectDump("p.1", "(. p 1)");
    try expectDump("{ $decl r 1 }.r", "(. (block ($decl r 1)) r)");
    try expectDump("$call f x.a", "($call f (. x a))");
}

test "$call with a folded single argument (2.3/2.4)" {
    try expectDump("$call f x", "($call f x)");
    try expectDump("$call f (x)", "($call f x)");
    try expectDump("$call f (x, y)", "($call f (group x y))");
    try expectDump("$call f ()", "($call f ())");
}

test "worked example: counter and aliasing (SPEC 12)" {
    try expectDump(
        \\$decl n $mut $new 0
        \\$set n ($call add (n, 1))
        \\$decl y n
        \\$decl z $new n
    ,
        \\($decl n ($mut ($new 0)))
        \\($set n ($call add (group n 1)))
        \\($decl y n)
        \\($decl z ($new n))
    );
}

test "worked example: mutual recursion with \\$fwd (SPEC 12)" {
    try expectDump(
        \\{
        \\  $fwd odd
        \\  $decl even $func ($decl n 0) $if ($call eq (n, 0)) true  ($call odd  ($call sub (n, 1)))
        \\}
    ,
        "(block ($fwd odd) ($decl even ($func ($decl n 0) " ++
            "($if ($call eq (group n 0)) true ($call odd ($call sub (group n 1)))))))",
    );
}

test "worked example: tagged blocks and match (SPEC 12)" {
    try expectDump(
        \\$decl area $func ($decl s $union (circle, square)) $match s (
        \\  $case {$prop kind "circle"} $call mul (3.14, s.r),
        \\  $case {$prop kind "square"} $call mul (s.w, s.w)
        \\)
    ,
        "($decl area ($func ($decl s ($union (group circle square))) " ++
            "($match s (group ($case (block ($prop kind \"circle\")) ($call mul (group 3.14 (. s r)))) " ++
            "($case (block ($prop kind \"square\")) ($call mul (group (. s w) (. s w))))))))",
    );
}

test "worked example: a loop (SPEC 12)" {
    try expectDump(
        \\$decl while $func ($decl cond $func () true, $decl body $func () {})
        \\  $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}
    ,
        "($decl while ($func (group ($decl cond ($func () true)) ($decl body ($func () ()))) " ++
            "($if ($call cond ()) ($do ($call body ()) ($call while (group cond body))) ())))",
    );
}

test "worked example: error propagation with \\$try (SPEC 12)" {
    try expectDump(
        \\$decl parse_pair $func ($decl s "") {
        \\  $decl a $try ($call to_int ($call slice (s, 0, 1))) none
        \\  $decl r a
        \\}.r
    ,
        // Note where `.r` lands: on the block, *inside* the `$func` body. That
        // is what makes the function return `r` — §4.15 describes this exact
        // shape as "skipping the block and the projection".
        "($decl parse_pair ($func ($decl s \"\") " ++
            "(. (block ($decl a ($try ($call to_int ($call slice (group s 0 1))) none)) ($decl r a)) r)))",
    );
}

test "template generic parameters: name, folded group, real group" {
    try expectDump("$template T $func ($decl x T) x", "($template T ($func ($decl x T) x))");
    try expectDump("$template (T) x", "($template T x)");
    try expectDump("$template (A, B) x", "($template (group A B) x)");
    try expectError("$template (A, 1) x", "generic parameters must be plain names");
}

test "single-arm match: arms operand is the \\$case itself, not a group" {
    try expectDump("$match x ($case x 1)", "($match x ($case x 1))");
}

test "\\$case outside \\$match is rejected" {
    try expectError("$case 1 2", "$case is only valid as an arm of $match");
    try expectError("$decl f $func () ($case 1 2)", "$case is only valid as an arm of $match");
    try expectError("$match x (1, $case 2 3)", "$match arms must be $case forms");
    try expectError("$match x $decl y 1", "$match arms must be $case forms");
}

test "nested match inside an arm body is fine" {
    var h = try Harness.init("$match x ($case x $match y ($case y 1)))");
    defer h.deinit();
    // The trailing ')' is a deliberate typo; the match itself must not be the
    // thing that complains.
    for (h.diags.items.items) |d| {
        try testing.expect(std.mem.indexOf(u8, d.msg, "$case") == null);
    }
}

test "operand kinds are enforced with a pointed message" {
    try expectError("$decl 1 2", "$decl operand 1 must be a name");
    try expectError("$decl $new 0", "$decl operand 1 must be a name");
    try expectError("$import foo", "$import operand 1 must be a string literal");
    try expectError("$extern add", "$extern operand 1 must be a string literal");
    try expectError("$fwd", "$fwd takes 1 operand");
}

test "unclosed delimiters name the opener" {
    try expectError("(a, b", "unclosed '('");
    try expectError("{a b", "unclosed '{'");
    try expectError("(a b)", "expected ',' or ')' in group");
    try expectError("(a, b,)", "trailing ','");
}

test "recovery reports more than one error per run" {
    var h = try Harness.init("$decl 1 2 $decl 3 4");
    defer h.deinit();
    try testing.expect(h.diags.items.items.len >= 2);
}

test "a stray projection is reported, not crashed on" {
    try expectError(".a", "projection has nothing to its left");
}
