//! Lexer module

const std = @import("std");

pub const TokenKind = union(enum) {
    /// identifier token
    ident:  []const u8,
    /// string token 
    str:    []const u8,
    /// number token i.e., integer
    num:    i64,
    /// float token 
    float:  f64,
    /// symbol token i.e., non-alphanumeric and not $ or _
    symbol: u8,
    /// whitespace token
    wspace: u8,
    /// end-of-file token
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    line: usize,
    col: usize,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    
    pub fn init(source: []const u8) Lexer {
        return .{ .source = source};
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens = std.ArrayList(Token).empty;
        errdefer tokens.deinit(allocator);
        

        while (true) {
            const tok = try self.nextToken();
            try tokens.append(allocator, tok);

            if (tok.kind == .eof) break;
        }

        return tokens.toOwnedSlice(allocator);
    }

    fn nextToken(self: *Lexer) !Token {
        if (self.pos >= self.source.len) {
            return .{.kind = .eof, .line = self.line, .col = self.col};
        }

        const start = self.pos;
        const ch = self.source[self.pos];
        const start_line = self.line;
        const start_col = self.col;

        // identifier
        if (isLetter(ch)) {
            while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
                self.incPos();
            }

            const text = self.source[start..self.pos];

            return .{
                .kind = .{ .ident = text },
                .line = start_line,
                .col = start_col,
            };
        }

        // number
        if (std.ascii.isDigit(ch)) {
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.incPos();
            }

            var text = self.source[start..self.pos];
            var kind: TokenKind = .{ .num = try std.fmt.parseInt(i64, text, 10) };
            
            // float
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                if (self.peekNextCh()) |next_ch| {
                    if (std.ascii.isDigit(next_ch)) {
                        self.incPos();
                        
                        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                            self.incPos();
                        }

                        text = self.source[start..self.pos];
                        kind = .{ .float = try std.fmt.parseFloat(f64, text)};
                    }
                }
            }

            return .{
                .kind = kind,
                .line = start_line,
                .col = start_col,
            };

        }

        // integer-less float 
        if (ch == '.') {
            if (self.peekNextCh()) |next_ch| {
                if (std.ascii.isDigit(next_ch)) {
                    self.incPos();

                    while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                        self.incPos();
                    }

                    const text = self.source[start..self.pos];
                    
                    return .{
                        .kind =  .{ .float = try std.fmt.parseFloat(f64, text)},
                        .line = start_line,
                        .col = start_col,
                    };
                }
            }
        }

        // string 
        if (ch == '"') {
            self.incPos();
            const str_start = self.pos;
            while (self.pos < self.source.len) {
                
                if (self.source[self.pos] == '"') {
                    if (self.source[self.pos - 1] != '\\') {
                        const text = self.source[str_start..self.pos];
                        self.incPos();

                        return . {
                            .kind = .{ .str = text },
                            .col = start_col,
                            .line = start_line,
                        };
                    }
                }   

                self.incPos();
            }
        }

        // whitespace
        if (std.ascii.isWhitespace(ch)) {
            self.incPos();
            return .{
                .kind = .{ .wspace = ch },
                .line = start_line,
                .col = start_col,
            };
        }

        // everything else is a symbol 
        self.incPos();
        return .{
            .kind = .{ .symbol = ch },
            .line = start_line,
            .col = start_col,
        };
    }

    /// increment pos
    fn incPos(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.col = 0;
            }
        }
        self.pos += 1;
        self.col += 1;
    }

    fn peekNextCh(self: *Lexer) ?u8 {
        if (self.pos + 1 >= self.source.len) {
            return null;
        }
        return self.source[self.pos + 1];
    }

};

pub fn isLetter(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

pub fn isIdentChar(ch: u8) bool {
    return isLetter(ch) or std.ascii.isDigit(ch) or ch == '$';
}


test "isLetter function" {
    try std.testing.expect(isLetter('a'));
    try std.testing.expect(isLetter('b'));
    try std.testing.expect(isLetter('c'));
    try std.testing.expect(isLetter('_'));
    try std.testing.expect(!isLetter('1'));
    try std.testing.expect(!isLetter('$'));
}

test "isIdentChar function" {
    try std.testing.expect(isIdentChar('a'));
    try std.testing.expect(isIdentChar('b'));
    try std.testing.expect(isIdentChar('c'));
    try std.testing.expect(isIdentChar('_'));
    try std.testing.expect(isIdentChar('$'));
    try std.testing.expect(!isIdentChar('%'));
    try std.testing.expect(isIdentChar('1'));
    try std.testing.expect(!isIdentChar(' '));
}

fn expectPosition(token: Token, line: usize, col: usize) !void {
    try std.testing.expectEqual(line, token.line);
    try std.testing.expectEqual(col, token.col);
}

fn expectIdent(token: Token, expected: []const u8, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqualStrings(expected, switch (token.kind) {
        .ident => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectStr(token: Token, expected: []const u8, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqualStrings(expected, switch (token.kind) {
        .str => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectNum(token: Token, expected: i64, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqual(expected, switch (token.kind) {
        .num => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectFloat(token: Token, expected: f64, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqual(expected, switch (token.kind) {
        .float => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectSymbol(token: Token, expected: u8, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqual(expected, switch (token.kind) {
        .symbol => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectWhitespace(token: Token, expected: u8, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expectEqual(expected, switch (token.kind) {
        .wspace => |value| value,
        else => return error.UnexpectedTokenKind,
    });
}

fn expectEof(token: Token, line: usize, col: usize) !void {
    try expectPosition(token, line, col);
    try std.testing.expect(token.kind == .eof);
}

test "tokenize empty input returns eof" {
    var lexer = Lexer.init("");
    const tokens = try lexer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectEof(tokens[0], 1, 1);
}

test "tokenize identifiers, whitespace, and symbols" {
    var lexer = Lexer.init("abc _name name$1 +=");
    const tokens = try lexer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 9), tokens.len);
    try expectIdent(tokens[0], "abc", 1, 1);
    try expectWhitespace(tokens[1], ' ', 1, 4);
    try expectIdent(tokens[2], "_name", 1, 5);
    try expectWhitespace(tokens[3], ' ', 1, 10);
    try expectIdent(tokens[4], "name$1", 1, 11);
    try expectWhitespace(tokens[5], ' ', 1, 17);
    try expectSymbol(tokens[6], '+', 1, 18);
    try expectSymbol(tokens[7], '=', 1, 19);
    try expectEof(tokens[8], 1, 20);
}

test "tokenize integer and float literals" {
    var lexer = Lexer.init("0 42 1.5 0.25 .75 1.");
    const tokens = try lexer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 13), tokens.len);
    try expectNum(tokens[0], 0, 1, 1);
    try expectWhitespace(tokens[1], ' ', 1, 2);
    try expectNum(tokens[2], 42, 1, 3);
    try expectWhitespace(tokens[3], ' ', 1, 5);
    try expectFloat(tokens[4], 1.5, 1, 6);
    try expectWhitespace(tokens[5], ' ', 1, 9);
    try expectFloat(tokens[6], 0.25, 1, 10);
    try expectWhitespace(tokens[7], ' ', 1, 14);
    try expectFloat(tokens[8], 0.75, 1, 15);
    try expectWhitespace(tokens[9], ' ', 1, 18);
    try expectNum(tokens[10], 1, 1, 19);
    try expectSymbol(tokens[11], '.', 1, 20);
    try expectEof(tokens[12], 1, 21);
}

test "tokenize strings consumes closing quote" {
    var lexer = Lexer.init("\"hello\" \"a\\\"b\"");
    const tokens = try lexer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try expectStr(tokens[0], "hello", 1, 1);
    try expectWhitespace(tokens[1], ' ', 1, 8);
    try expectStr(tokens[2], "a\\\"b", 1, 9);
    try expectEof(tokens[3], 1, 15);
}

test "tokenize tracks line and column positions" {
    var lexer = Lexer.init("a\n\tb");
    const tokens = try lexer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try expectIdent(tokens[0], "a", 1, 1);
    try expectWhitespace(tokens[1], '\n', 1, 2);
    try expectWhitespace(tokens[2], '\t', 2, 1);
    try expectIdent(tokens[3], "b", 2, 2);
    try expectEof(tokens[4], 2, 3);
}
