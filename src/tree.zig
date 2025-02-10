// ZART (Zig Adaptive Radix Tree)
// Great if your implementation is adaptive (like ART).
//
// Module: zart.zig
//
// => aa, aappzz, aappxx
//
// => aappzz, aa, aappxx
//
// 1) aappzz, aa
//
//     aa
//     |
//    ppzz
//
// 2) aappxx
//
//     aa
//     |
//    pp (no value)
//   /\
// xx  zz
//
const std = @import("std");

const vars = @import("vars.zig");
const Node = @import("node.zig").Node;

const Allocator = std.mem.Allocator;

pub fn Tree(comptime T: type) type {
    return struct {
        const Self = @This();

        root: *Node(T),
        parser: ?vars.parse = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .root = try Node(T).init(allocator, "", null),
                // TODO: make it possible to set a parser for variables
                // .parser = vars.matchitParser,
            };
        }

        fn deinit(self: *Self) void {
            self.root.deinit();
        }

        pub fn insert(self: *Self, key: []const u8, value: T) !void {
            // first step, root doesn't exist -> create root node
            if (self.root.key.len == 0 and self.root.children.items.len == 0) {
                self.root.key = key;
                self.root.value = value;
                // overwrite the key and value, if the root path contains variables and the tree has an parser
                if (self.parser) |parser| {
                    try self.root.splitIntoVariableNodes(parser, key, value);
                }
                return;
            }

            var current: *Node(T) = self.root;
            var remains = key;

            traverse: while (true) {
                const len_prefix = commonPrefixLen(current.key, remains);

                // NOT FOUND, create a new root and add the child nodes
                // e.g. root: app, new node: foo ->
                // (new_root)
                //    /\
                // app  foo
                if (len_prefix == 0) {
                    current.* = try current.newEmptyRoot(remains, value);
                    return;
                }

                // split current node:
                // input: app on current node: apple -> app ++ le (new path = app)
                if (len_prefix < current.key.len) {
                    try current.splitCurrentNode(remains, len_prefix, value);
                }

                // traverse the tree down
                if (len_prefix < remains.len) {
                    remains = remains[len_prefix..];

                    if (current.edge(remains[0])) |child| {
                        current = child;
                        continue :traverse;
                    }

                    // check is the path is not a param
                    // if (!param.isParam(remains)) {
                    const new_child = try Node(T).init(self.allocator, remains, value);
                    try current.children.append(new_child);
                    // }

                    if (self.parser) |parser| {
                        try current.splitIntoVariableNodes(parser, remains, value);
                    }
                    return;
                }

                return;
            }
        }

        pub fn resolve(self: *Self, path: []const u8) ?T {
            // resolveing for the root key
            if (std.mem.eql(u8, self.root.key, path)) {
                return self.root.value;
            }

            var current: *Node(T) = self.root;
            var remains = path;

            traverse: while (true) {
                if (remains.len == 0 or remains.len <= current.key.len) {
                    // no remains left -> not found
                    return null;
                }
                remains = remains[current.key.len..];

                // no params
                // if (!current.hasParamChild) {
                if (current.edge(remains[0])) |child| {
                    current = child;
                    if (std.mem.eql(u8, current.key, remains)) {
                        return current.value;
                    }
                    continue :traverse;
                }

                // not found
                return null;
                // }

                // with params
                // if (current.children.items[0].paramResolver) |r| {
                //     const p = r.match(remains);
                //     std.debug.print("-- Param: {s} = {s}\n", .{ p.key, p.value });
                // }
            }
        }
    };
}

pub inline fn commonPrefixLen(lhs: []const u8, rhs: []const u8) usize {
    const max = if (lhs.len < rhs.len) lhs.len else rhs.len;
    var i: usize = 0;
    return while (i < max) : (i += 1) {
        if (lhs[i] != rhs[i]) break i;
    } else i;
}

test "commonPrefixLen" {
    try std.testing.expectEqual(3, commonPrefixLen("app", "apple"));
    try std.testing.expectEqual(3, commonPrefixLen("apple", "app"));
    try std.testing.expectEqual(3, commonPrefixLen("apple", "appxx"));

    try std.testing.expectEqual(0, commonPrefixLen("apple", "foo"));
    try std.testing.expectEqual(0, commonPrefixLen("", "foo"));
    try std.testing.expectEqual(0, commonPrefixLen("apple", ""));
    try std.testing.expectEqual(0, commonPrefixLen("", ""));

    const l = "app";
    const r = "apple";
    try std.testing.expectEqual(2, commonPrefixLen(l[1..3], r[1..4]));
}

// test "params: only root" {
//     var tree = try Tree(i32).init(std.testing.allocator);
//     defer tree.deinit();
//
//     try tree.insert("/user/{id}", 1);
//
//     try std.testing.expectEqualStrings("/user/", tree.root.key);
//     try std.testing.expectEqual(null, tree.root.value);
//     // try std.testing.expectEqual(true, tree.root.hasParamChild);
//     try std.testing.expectEqual(1, tree.root.children.items.len);
//
//     const id = tree.root.children.items[0];
//     try std.testing.expectEqualStrings("id", id.key);
//     try std.testing.expectEqual(1, id.value);
//     // try std.testing.expectEqual(false, id.hasParamChild);
//     try std.testing.expectEqual(0, id.children.items.len);
//
//     // resolveing
//     _ = tree.resolve("/user/42");
// }
//
// test "params: root with child" {
//     var tree = Tree(i32).init(std.testing.allocator);
//     defer tree.deinit();
//
//     try tree.insert("/user/", 1);
//     try tree.insert("/user/{id}", 2);
//
//     try std.testing.expectEqualStrings("/user/", tree.root.key);
//     try std.testing.expectEqual(1, tree.root.value);
//     try std.testing.expectEqual(true, tree.root.hasParamChild);
//     try std.testing.expectEqual(1, tree.root.children.items.len);
//
//     const id = tree.root.children.items[0];
//     try std.testing.expectEqualStrings("id", id.key);
//     try std.testing.expectEqual(2, id.value);
//     try std.testing.expectEqual(false, id.hasParamChild);
//     try std.testing.expectEqual(0, id.children.items.len);
// }
//
// test "params: root with two child" {
//     var tree = Tree(i32).init(std.testing.allocator);
//     defer tree.deinit();
//
//     try tree.insert("/user/", 1);
//     try tree.insert("/group/", 2);
//     try tree.insert("/user/{id}", 3);
//
//     try std.testing.expectEqualStrings("/", tree.root.key);
//     try std.testing.expectEqual(null, tree.root.value);
//     try std.testing.expectEqual(false, tree.root.hasParamChild);
//     try std.testing.expectEqual(2, tree.root.children.items.len);
//
//     const user = tree.root.children.items[0];
//     try std.testing.expectEqualStrings("user/", user.key);
//     try std.testing.expectEqual(1, user.value);
//     // try std.testing.expectEqual(true, user.hasParamChild);
//     try std.testing.expectEqual(1, user.children.items.len);
//
//     const id = user.children.items[0];
//     try std.testing.expectEqualStrings("id", id.key);
//     try std.testing.expectEqual(3, id.value);
//     // try std.testing.expectEqual(false, id.hasParamChild);
//     try std.testing.expectEqual(0, id.children.items.len);
//
//     const group = tree.root.children.items[1];
//     try std.testing.expectEqualStrings("group/", group.key);
//     try std.testing.expectEqual(2, group.value);
//     // try std.testing.expectEqual(false, group.hasParamChild);
//     try std.testing.expectEqual(0, group.children.items.len);
// }
//

test "resolve: empty tree" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(null, tree.resolve("not-found"));
    try std.testing.expectEqual(null, tree.resolve("root"));
    try std.testing.expectEqual(null, tree.resolve(""));
}

test "resolve: only root" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("root", 1);

    try std.testing.expectEqual(1, tree.resolve("root"));
    try std.testing.expectEqual(null, tree.resolve("foo"));
}

test "init: empty root" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual("", tree.root.key);
    try std.testing.expectEqual(null, tree.root.value);
    try std.testing.expectEqual(0, tree.root.children.items.len);

    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(null, tree.resolve("foo"));
}

test "only root: app" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("app", 1);
    try std.testing.expectEqual("app", tree.root.key);
    try std.testing.expectEqual(1, tree.root.value);
    try std.testing.expectEqual(0, tree.root.children.items.len);

    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(1, tree.resolve("app"));
}

test "app + apple ==> app -> le" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("apple", 5);

    try std.testing.expectEqualStrings("app", tree.root.key);
    try std.testing.expectEqual(1, tree.root.value);
    try std.testing.expectEqual(1, tree.root.children.items.len);

    const child = tree.root.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(5, child.value);
    try std.testing.expectEqual(0, child.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("app"));
    try std.testing.expectEqual(5, tree.resolve("apple"));
    try std.testing.expectEqual(null, tree.resolve("le"));
}

test "apple + app ==> app -> le" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("apple", 5);
    try tree.insert("app", 1);

    try std.testing.expectEqualStrings("app", tree.root.key);
    try std.testing.expectEqual(1, tree.root.value);
    try std.testing.expectEqual(1, tree.root.children.items.len);

    const child = tree.root.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(5, child.value);
    try std.testing.expectEqual(0, child.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("app"));
    try std.testing.expectEqual(5, tree.resolve("apple"));
}

test "apple + appx ==> app -> le & x" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("apple", 5);
    try tree.insert("appx", 1);

    try std.testing.expectEqualStrings("app", tree.root.key);
    try std.testing.expectEqual(null, tree.root.value);
    try std.testing.expectEqual(2, tree.root.children.items.len);

    const le = tree.root.children.items[0];
    try std.testing.expectEqualStrings("le", le.key);
    try std.testing.expectEqual(5, le.value);
    try std.testing.expectEqual(0, le.children.items.len);
    const x = tree.root.children.items[1];
    try std.testing.expectEqualStrings("x", x.key);
    try std.testing.expectEqual(1, x.value);
    try std.testing.expectEqual(0, x.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("appx"));
    try std.testing.expectEqual(5, tree.resolve("apple"));
    try std.testing.expectEqual(null, tree.resolve("app"));
    try std.testing.expectEqual(null, tree.resolve("le"));
    try std.testing.expectEqual(null, tree.resolve("x"));
    try std.testing.expectEqual(null, tree.resolve("foo"));
}

test "app + foo ==> app & foo" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("foo", 5);

    try std.testing.expectEqualStrings("", tree.root.key);
    try std.testing.expectEqual(null, tree.root.value);
    try std.testing.expectEqual(2, tree.root.children.items.len);

    const app = tree.root.children.items[0];
    try std.testing.expectEqualStrings("app", app.key);
    try std.testing.expectEqual(1, app.value);
    try std.testing.expectEqual(0, app.children.items.len);

    const foo = tree.root.children.items[1];
    try std.testing.expectEqualStrings("foo", foo.key);
    try std.testing.expectEqual(5, foo.value);
    try std.testing.expectEqual(0, foo.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(1, tree.resolve("app"));
    try std.testing.expectEqual(5, tree.resolve("foo"));
}

test "app + apple + foo ==> app -> le  & foo" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("apple", 2);
    try tree.insert("foo", 5);

    try std.testing.expectEqualStrings("", tree.root.key);
    try std.testing.expectEqual(null, tree.root.value);
    try std.testing.expectEqual(2, tree.root.children.items.len);

    const app = tree.root.children.items[0];
    try std.testing.expectEqualStrings("app", app.key);
    try std.testing.expectEqual(1, app.value);
    try std.testing.expectEqual(1, app.children.items.len);

    const le = app.children.items[0];
    try std.testing.expectEqualStrings("le", le.key);
    try std.testing.expectEqual(2, le.value);
    try std.testing.expectEqual(0, le.children.items.len);

    const foo = tree.root.children.items[1];
    try std.testing.expectEqualStrings("foo", foo.key);
    try std.testing.expectEqual(5, foo.value);
    try std.testing.expectEqual(0, foo.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(1, tree.resolve("app"));
    try std.testing.expectEqual(2, tree.resolve("apple"));
    try std.testing.expectEqual(5, tree.resolve("foo"));
    try std.testing.expectEqual(null, tree.resolve("le"));
    try std.testing.expectEqual(null, tree.resolve("applex"));
}

test "apple + app + ap ==> ap -> p -> le" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("apple", 1);
    try tree.insert("app", 2);
    try tree.insert("ap", 3);

    try std.testing.expectEqualStrings("ap", tree.root.key);
    try std.testing.expectEqual(3, tree.root.value);
    try std.testing.expectEqual(1, tree.root.children.items.len);

    const child_p = tree.root.children.items[0];
    try std.testing.expectEqualStrings("p", child_p.key);
    try std.testing.expectEqual(2, child_p.value);
    try std.testing.expectEqual(1, child_p.children.items.len);

    const child_le = child_p.children.items[0];
    try std.testing.expectEqualStrings("le", child_le.key);
    try std.testing.expectEqual(1, child_le.value);
    try std.testing.expectEqual(0, child_le.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(2, tree.resolve("app"));
    try std.testing.expectEqual(1, tree.resolve("apple"));
    try std.testing.expectEqual(3, tree.resolve("ap"));
}

test "aappzz + aa + aappxx ==> aa -> pp -> xx & zz" {
    var tree = try Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("aappzz", 1);
    try tree.insert("aa", 2);
    try tree.insert("aappxx", 3);

    try std.testing.expectEqualStrings("aa", tree.root.key);
    try std.testing.expectEqual(2, tree.root.value);
    try std.testing.expectEqual(1, tree.root.children.items.len);

    const pp = tree.root.children.items[0];
    try std.testing.expectEqualStrings("pp", pp.key);
    try std.testing.expectEqual(null, pp.value);
    try std.testing.expectEqual(2, pp.children.items.len);

    const zz = pp.children.items[0];
    try std.testing.expectEqualStrings("zz", zz.key);
    try std.testing.expectEqual(1, zz.value);
    try std.testing.expectEqual(0, zz.children.items.len);
    const xx = pp.children.items[1];
    try std.testing.expectEqualStrings("xx", xx.key);
    try std.testing.expectEqual(3, xx.value);
    try std.testing.expectEqual(0, xx.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve(""));
    try std.testing.expectEqual(1, tree.resolve("aappzz"));
    try std.testing.expectEqual(2, tree.resolve("aa"));
    try std.testing.expectEqual(3, tree.resolve("aappxx"));
    try std.testing.expectEqual(null, tree.resolve("xx"));
    try std.testing.expectEqual(null, tree.resolve("zz"));
}
