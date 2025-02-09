const std = @import("std");

pub const Variable = struct {
    key: []const u8,
    value: []const u8,
};

// Parse is the interface for using different implementation of parsing an given 'path'
// and return the result 'Parsed' and a match function, for resolving the parsed variable.
pub const parse = fn (path: []const u8) ParseError!?Parsed;

pub const ParseError = error{
    EmptyVariable,
    MissingClosingBracket,
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

// noParser is an Parser, which ALWAYS returns null.
pub fn noParser(_: []const u8) ParseError!?Parsed {
    return null;
}

// MatchItParser is one implementation of an Parser
pub fn matchitParser(current_path: []const u8) ParseError!?Parsed {
    const parser = struct {
        fn parse(path: []const u8) ParseError!?Parsed {
            for (path, 0..) |s, start| {
                if (s != '{') {
                    continue;
                }

                const afterStart = start + 1;
                for (path[afterStart..], afterStart..) |e, end| {
                    if (e == '}') {
                        if (end - afterStart == 0) {
                            return ParseError.EmptyVariable;
                        }

                        const isWildcard = path[afterStart] == '*';
                        if (isWildcard and end - (afterStart + 1) == 0) {
                            return ParseError.EmptyVariable;
                        }

                        return .{
                            .variable = if (isWildcard) path[afterStart + 1 .. end] else path[afterStart..end],
                            .start = start,
                            .end = end + 1,
                            .isWildcard = isWildcard,
                            ._matchFn = match,
                        };
                    }
                }

                return ParseError.MissingClosingBracket;
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

test "mathit with prefix" {
    const m = (try matchitParser("mi{id}")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "matchit without prefix" {
    const m = (try matchitParser("{id}")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "matchit empty variable" {
    try t.expectError(ParseError.EmptyVariable, matchitParser("{}"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("xy{}"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("{}xy"));

    try t.expectError(ParseError.EmptyVariable, matchitParser("{*}"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("xy{*}"));
    try t.expectError(ParseError.EmptyVariable, matchitParser("{*}xy"));
}

test "matchit missing closing brackest" {
    try t.expectError(ParseError.MissingClosingBracket, matchitParser("{"));
    try t.expectError(ParseError.MissingClosingBracket, matchitParser("xy{"));
    try t.expectError(ParseError.MissingClosingBracket, matchitParser("{xy"));

    try t.expectError(ParseError.MissingClosingBracket, matchitParser("{*"));
    try t.expectError(ParseError.MissingClosingBracket, matchitParser("xy{*"));
    try t.expectError(ParseError.MissingClosingBracket, matchitParser("{*xy"));
}

test "matchit only variable" {
    const m = (try matchitParser("{abc}")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(5, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit only variable catch-all" {
    const m = (try matchitParser("{*abc}")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(6, m.end);
    try t.expectEqual(true, m.isWildcard);
}

test "matchit variable with prefix" {
    const m = (try matchitParser("xy{abc}")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(2, m.start);
    try t.expectEqual(7, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit variable with suffix" {
    const m = (try matchitParser("{abc}xy")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(0, m.start);
    try t.expectEqual(5, m.end);
    try t.expectEqual(false, m.isWildcard);
}

test "matchit variable with prefix and suffix" {
    const m = (try matchitParser("ml{*abc}xy")).?;

    try t.expectEqualStrings("abc", m.variable);
    try t.expectEqual(2, m.start);
    try t.expectEqual(8, m.end);
    try t.expectEqual(true, m.isWildcard);
}

test "resolve variable" {
    const m = (try matchitParser("ml{id}")).?;

    try t.expectEqualDeep(Variable{ .key = "id", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "foo" }, m.match("foo"));
    try t.expectEqualDeep(Variable{ .key = "id", .value = "42" }, m.match("42/foo"));
}

test "resolve variable catch-all" {
    const m = (try matchitParser("ml{*all}")).?;

    try t.expectEqualDeep(Variable{ .key = "all", .value = "" }, m.match(""));
    try t.expectEqualDeep(Variable{ .key = "all", .value = "42" }, m.match("42"));
    try t.expectEqualDeep(Variable{ .key = "all", .value = "42/foo" }, m.match("42/foo"));
}

test "noParser parser" {
    try t.expectEqual(null, try noParser("ml{id}"));
}
