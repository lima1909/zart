const std = @import("std");
const vars = @import("vars.zig");

const Allocator = std.mem.Allocator;

pub fn Node(comptime V: type) type {
    return struct {
        const Self = @This();

        key: []const u8,
        value: ?V = null,
        children: std.ArrayList(*Self),

        // handle variables
        matcher: ?vars.Parsed = null,

        allocator: Allocator,

        pub fn init(allocator: Allocator, key: []const u8, value: ?V) !*Self {
            const node = try allocator.create(Self);
            node.* = .{ .allocator = allocator, .children = std.ArrayList(*Self).init(allocator), .key = key, .value = value };
            return node;
        }

        pub fn deinit(self: *Self) void {
            for (self.children.items) |child| {
                child.deinit();
            }

            self.children.deinit();
            self.allocator.destroy(self);
        }

        /// Find and returns the edge for a given letter or null, if not found.
        pub fn edge(self: *Self, l: u8) ?*Self {
            for (self.children.items) |child| {
                if (child.key[0] == l) {
                    return child;
                }
            }

            return null;
        }

        // Create a new empty root and add the child nodes
        // previous root: 'app', new added node: 'foo'
        //     (new_root)
        //        /\
        //     app  foo
        pub inline fn newEmptyRoot(self: *Self, path: []const u8, value: V) !Self {
            var root = Self{
                .allocator = self.allocator,
                .children = std.ArrayList(*Self).init(self.allocator),
                .key = "",
            };

            var lhs = try Self.init(self.allocator, self.key, self.value);
            // clear all data of self, BUT don't remove the pointer self
            lhs.children = self.children;
            try root.children.append(lhs);

            const rhs = try Self.init(self.allocator, path, value);
            try root.children.append(rhs);

            return root;
        }

        // Split current node:
        // input: 'app' on current node: 'apple' -> 'app' ++ le
        pub inline fn splitCurrentNode(self: *Self, path: []const u8, lenPrefix: usize, value: V) !void {
            // new 'le'
            var child = try Self.init(self.allocator, self.key[lenPrefix..], self.value);
            child.children = try self.children.clone();

            // new 'app' node
            self.key = path[0..lenPrefix];
            self.value = null;
            if (path.len == lenPrefix) {
                self.value = value;
            }
            self.children.clearRetainingCapacity();
            try self.children.append(child);
        }

        pub fn print(self: *Self) void {
            self.printIndent(0);
        }

        fn printIndent(self: *Self, indent: u8) void {
            for (0..indent) |_| {
                std.debug.print("\t", .{});
            }

            std.debug.print("{s}\t\t({any})\n", .{ self.key, self.value });
            for (self.children.items, 0..) |_, i| {
                self.children.items[i].printIndent(indent + 1);
            }
        }
    };
}

// parse the given path, if the path contains variable,
// then returns the root Node from the path, otherwise null
pub inline fn parsePath(comptime V: type, allocator: Allocator, p: ?vars.parse, path: []const u8, value: V) !?*Node(V) {
    if (p == null) {
        return null;
    }

    const parse = p.?;
    var remains = path;
    var root: *Node(V) = undefined;
    var current: ?*Node(V) = null;

    if (try parse(remains)) |parsed| {
        if (parsed.start == 0) {
            // root Node is var Node
            root = try Node(V).init(allocator, remains[0..parsed.end], null);
            root.matcher = parsed;
            current = root;
        } else {
            // prefix Node
            root = try Node(V).init(allocator, remains[0..parsed.start], null);
            // var Node
            var child = try Node(V).init(allocator, remains[parsed.start..parsed.end], null);
            child.matcher = parsed;
            try root.children.append(child);
            current = child;
        }

        remains = remains[parsed.end..];
        if (remains.len == 0) {
            // the last node get the value
            current.?.value = value;
            return root;
        }
    } else {
        return null;
    }

    while (try parse(remains)) |parsed| {
        if (current.?.children.items.len > 0) {
            // TODO: replace painc with error
            @panic("params can not be used, if the node has children");
        }

        if (parsed.start > 0) {
            // prefix Node
            const child = try Node(V).init(allocator, remains[0..parsed.start], null);
            try current.?.children.append(child);
            current = child;
        }

        // var Node
        var child = try Node(V).init(allocator, remains[parsed.start..parsed.end], null);
        child.matcher = parsed;
        try current.?.children.append(child);
        current = child;

        remains = remains[parsed.end..];
        if (remains.len == 0) {
            // the last node get the value
            current.?.value = value;
            return root;
        }
    }

    return root;
}

test "new empty root node" {
    const alloc = std.testing.allocator;
    const root = try Node(i32).init(alloc, "app", 42);
    defer root.deinit();

    root.* = (try root.newEmptyRoot("foo", 11));

    try std.testing.expectEqualStrings("", root.key);
    try std.testing.expectEqual(null, root.value);
    try std.testing.expectEqual(2, root.children.items.len);

    const lhs = root.children.items[0];
    try std.testing.expectEqualStrings("app", lhs.key);
    try std.testing.expectEqual(42, lhs.value);
    try std.testing.expectEqual(0, lhs.children.items.len);

    const rhs = root.children.items[1];
    try std.testing.expectEqualStrings("foo", rhs.key);
    try std.testing.expectEqual(11, rhs.value);
    try std.testing.expectEqual(0, rhs.children.items.len);
}

test "split current node" {
    const alloc = std.testing.allocator;
    const node = try Node(i32).init(alloc, "apple", 42);
    defer node.deinit();

    try node.splitCurrentNode("app", 3, 11);

    try std.testing.expectEqualStrings("app", node.key);
    try std.testing.expectEqual(11, node.value);
    try std.testing.expectEqual(1, node.children.items.len);

    const child = node.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(42, child.value);
    try std.testing.expectEqual(0, child.children.items.len);
}

test "split current node, overlapping" {
    const alloc = std.testing.allocator;
    const node = try Node(i32).init(alloc, "apple", 42);
    defer node.deinit();

    try node.splitCurrentNode("appX", 3, 11);

    try std.testing.expectEqualStrings("app", node.key);
    // the current value (11) is in new Node: 'X'
    try std.testing.expectEqual(null, node.value);
    try std.testing.expectEqual(1, node.children.items.len);

    const child = node.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(42, child.value);
    try std.testing.expectEqual(0, child.children.items.len);
}

test "parsePath: variable is in the beginning and only" {
    const alloc = std.testing.allocator;
    const node = (try parsePath(i32, alloc, vars.matchitParser, "{id}", 1)).?;
    defer node.deinit();

    try std.testing.expectEqualStrings("{id}", node.key);
    try std.testing.expectEqual(1, node.value);
    try std.testing.expectEqual(0, node.children.items.len);
    try std.testing.expect(null != node.matcher);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "id", .value = "42" }, node.matcher.?.match("42"));
}

test "parsePath: variable with prefix" {
    const alloc = std.testing.allocator;
    const node = (try parsePath(i32, alloc, vars.matchitParser, "/user/{id}", 1)).?;
    defer node.deinit();

    try std.testing.expectEqualStrings("/user/", node.key);
    try std.testing.expectEqual(null, node.value);
    try std.testing.expectEqual(1, node.children.items.len);
    try std.testing.expectEqual(null, node.matcher);

    const child = node.children.items[0];
    try std.testing.expectEqualStrings("{id}", child.key);
    try std.testing.expectEqual(1, child.value);
    try std.testing.expect(null != child.matcher);
    try std.testing.expectEqual(false, child.matcher.?.isWildcard);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "id", .value = "42" }, child.matcher.?.match("42/name"));
}

test "parsePath: variable with suffix" {
    const alloc = std.testing.allocator;
    const node = (try parsePath(i32, alloc, vars.matchitParser, "{id}/user/", 1)).?;
    defer node.deinit();

    try std.testing.expectEqualStrings("{id}", node.key);
    try std.testing.expectEqual(null, node.value);
    try std.testing.expect(null != node.matcher);
    try std.testing.expectEqual(false, node.matcher.?.isWildcard);
    try std.testing.expectEqual(0, node.children.items.len);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "id", .value = "42" }, node.matcher.?.match("42/name"));
}

test "parsePath: variable in between" {
    const alloc = std.testing.allocator;
    const node = (try parsePath(i32, alloc, vars.matchitParser, "/user/{id}/name", 1)).?;
    defer node.deinit();

    try std.testing.expectEqualStrings("/user/", node.key);
    try std.testing.expectEqual(null, node.value);
    try std.testing.expectEqual(1, node.children.items.len);
    try std.testing.expectEqual(null, node.matcher);

    const id = node.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(null, id.value);
    try std.testing.expect(null != id.matcher);
    try std.testing.expectEqual(false, id.matcher.?.isWildcard);
    try std.testing.expectEqual(0, id.children.items.len);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "id", .value = "42" }, id.matcher.?.match("42/name"));
}

test "parsePath: split into variable Nodes with two variables" {
    const alloc = std.testing.allocator;
    const node = (try parsePath(i32, alloc, vars.matchitParser, "/user/{id}/name/{name}", 1)).?;
    defer node.deinit();

    try std.testing.expectEqualStrings("/user/", node.key);
    try std.testing.expectEqual(null, node.value);
    try std.testing.expectEqual(1, node.children.items.len);
    try std.testing.expectEqual(null, node.matcher);

    const id = node.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(null, id.value);
    try std.testing.expect(null != id.matcher);
    try std.testing.expectEqual(false, id.matcher.?.isWildcard);
    try std.testing.expectEqual(1, id.children.items.len);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "id", .value = "42" }, id.matcher.?.match("42/name"));

    const child = id.children.items[0];
    try std.testing.expectEqualStrings("/name/", child.key);
    try std.testing.expectEqual(null, child.value);
    try std.testing.expect(null == child.matcher);
    try std.testing.expectEqual(1, child.children.items.len);

    const name = child.children.items[0];
    try std.testing.expectEqualStrings("{name}", name.key);
    try std.testing.expectEqual(1, name.value);
    try std.testing.expectEqual(0, name.children.items.len);
    try std.testing.expect(null != name.matcher);
    try std.testing.expectEqual(false, name.matcher.?.isWildcard);

    try std.testing.expectEqualDeep(vars.Variable{ .key = "name", .value = "me" }, name.matcher.?.match("me"));
}
