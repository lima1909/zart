const std = @import("std");

pub const Variable = struct {
    key: []const u8,
    value: []const u8,
};

// Parse is the interface for using different implementation of parsing an given 'path'
// and return the result 'Parsed' and a match function, for resolving the parsed variable.
pub const parse = *const fn (path: []const u8) ParseError!?Parsed;

pub const ParseError = error{
    EmptyVariable,
    WildcardContainsSlash,
    RedundantVariableChar,
};

pub const Parsed = struct {
    variable: []const u8,
    isWildcard: bool = false,
    start: usize,
    end: usize,

    _matchFn: *const fn (path: []const u8, variable: []const u8, isWildcard: bool) Variable,

    pub fn match(self: *const @This(), path: []const u8) Variable {
        return self._matchFn(path, self.variable, self.isWildcard);
    }
};

// MatchItParser is one implementation of an Parser
pub fn matchitParser(current_path: []const u8) ParseError!?Parsed {
    const parser = struct {
        fn parse(path: []const u8) ParseError!?Parsed {
            for (path, 0..) |s, start| {
                // ignore prefix
                if (s != ':' and s != '*') {
                    continue;
                }

                if (start == path.len - 1) {
                    return ParseError.EmptyVariable;
                }

                const isWildcard = path[start] == '*';
                const afterStart = start + 1;
                var until: usize = 0;
                const rest = path[afterStart..];

                for (rest, afterStart..) |e, end| {
                    switch (e) {
                        '/' => {
                            if (end - afterStart == 0) {
                                return ParseError.EmptyVariable;
                            }
                            // with wildcard == true, then must read until the end
                            if (isWildcard) {
                                return ParseError.WildcardContainsSlash;
                            }

                            until = end;
                            break;
                        },
                        ':', '*' => {
                            return ParseError.RedundantVariableChar;
                        },
                        else => {},
                    }
                }

                until = if (until == 0) path.len else until;

                return .{
                    .variable = path[afterStart..until],
                    .start = start,
                    .end = until,
                    .isWildcard = isWildcard,
                    ._matchFn = match,
                };
            }

            // contains no variable
            return null;
        }

        pub fn match(path: []const u8, variable: []const u8, isWildcard: bool) Variable {
            if (isWildcard) {
                return .{ .key = variable, .value = path };
            }

            var end: usize = 0;
            while (end < path.len and path[end] != '/') {
                end += 1;
            }
            return .{ .key = variable, .value = path[0..end] };
        }
    };

    return parser.parse(current_path);
}

const t = std.testing;

test "matchit no prefix" {
    const m = (try matchitParser(":id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "matchit no prefix with wildcard" {
    const m = (try matchitParser("*id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42/foo" }, m.match("42/foo"));
}

test "mathit with prefix" {
    const m = (try matchitParser("mi:id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "mathit with prefix with wildcard" {
    const m = (try matchitParser("mi*id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42/foo" }, m.match("42/foo"));
}

test "matchit empty variable" {
    try t.expectError(ParseError.EmptyVariable, matchitParser(":"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("xy:"));
    try t.expectError(ParseError.EmptyVariable, matchitParser(":/xy"));

    try t.expectError(ParseError.EmptyVariable, matchitParser("*"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("xy*"));
}

test "error with RedundantVariableChar" {
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("::"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser(":a:"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("a::"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("::a"));

    try t.expectError(ParseError.RedundantVariableChar, matchitParser("**"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("*a*"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("a**"));
    try t.expectError(ParseError.RedundantVariableChar, matchitParser("**a"));
}

test "error with WildcardContainsSlash" {
    try t.expectError(ParseError.WildcardContainsSlash, matchitParser("*a/"));
    try t.expectError(ParseError.WildcardContainsSlash, matchitParser("a*a/"));
}

test "matchit only variable" {
    const m = (try matchitParser(":abc")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(4, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit only variable with wildcard" {
    const m = (try matchitParser("*abc")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(4, m.end);
    try t.expectEqual(true, m.isWildcard);
}

test "matchit variable with prefix" {
    const m = (try matchitParser("xy:abc")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(2, m.start);
    try t.expectEqual(6, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit variable with suffix" {
    const m = (try matchitParser(":abc/xy")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(4, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit variable with prefix and suffix" {
    const m = (try matchitParser("ml*abcxy")).?;

    try t.expectEqualStrings("abcxy", m.variable);
    try t.expectEqual(2, m.start);
    try t.expectEqual(8, m.end);
    try t.expectEqual(true, m.isWildcard);
}

test "resolve variable" {
    const m = (try matchitParser("ml:id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "resolve variable with wildcard" {
    const m = (try matchitParser("ml*id")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42/foo" }, m.match("42/foo"));
}
