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
const parsePath = @import("node.zig").parsePath;

const Allocator = std.mem.Allocator;

pub const Config = struct {
    parser: ?vars.parse = null,
};

pub fn Tree(comptime V: type) type {
    return struct {
        const Self = @This();

        root: ?*Node(V) = null,
        parser: ?vars.parse = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator, cfg: Config) Self {
            return .{ .allocator = allocator, .parser = cfg.parser };
        }

        fn deinit(self: *Self) void {
            if (self.root) |root| {
                root.deinit();
            }
        }

        pub fn insert(self: *Self, key: []const u8, value: V) !void {

            // first step, root doesn't exist -> create root node
            if (self.root == null) {
                // if an parser is set, then parse the given key, if he contains variables
                if (try parsePath(V, self.allocator, self.parser, key, value)) |node| {
                    self.root = node;
                } else {
                    self.root = try Node(V).init(self.allocator, key, value);
                    return;
                }
            }

            var current: *Node(V) = self.root.?;
            var remains = key;

            traverse: while (true) {
                const len_prefix = commonPrefixLen(current.key, remains);

                // e.g. root: app, new node: foo ->
                // (new_root)
                //    /\
                // app  foo
                if (len_prefix == 0) {
                    current.* = try current.newEmptyRoot(remains, value);
                    return;
                }

                // split current node:
                // input: app on current node: apple ->
                //   app
                //   /
                //  le
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

                    if (try parsePath(V, self.allocator, self.parser, remains, value)) |node| {
                        try current.children.append(node);
                        return;
                    }

                    const new_child = try Node(V).init(self.allocator, remains, value);
                    try current.children.append(new_child);
                    return;
                }

                return;
            }
        }

        /// Resolve the given path for finding the value and collect potential variables.
        /// Hint: the are only 3 variables per path possible!
        pub fn resolve(self: *Self, path: []const u8) Matched(V) {
            var matched = Matched(V){};

            // no root and no input path -> not found
            if (self.root == null or path.len == 0) {
                return matched;
            }

            var current: *Node(V) = self.root.?;
            var remains = path;

            if (self.parser != null) {
                // the match is on the current node, e.g. root-node
                if (current.matcher) |matcher| {
                    const vr = matcher.match(remains);
                    matched.addVariable(vr);
                    remains = remains[vr.value.len..];
                    if (remains.len == 0) {
                        matched.value = current.value;
                        return matched;
                    }

                    if (current.children.items.len > 0) {
                        current = current.children.items[0];
                    }
                }
            }

            traverse: while (true) {

                // found the wanted node and return the value
                if (std.mem.eql(u8, current.key, remains)) {
                    matched.value = current.value;
                    return matched;
                }
                //
                // traverse the tree down for the next try
                else if (remains.len > current.key.len) {
                    remains = remains[current.key.len..];

                    // check, there are possible variables
                    if (self.parser != null) {
                        // has the child-node a variable?
                        if (current.children.items.len > 0) {
                            const child = current.children.items[0];
                            if (child.matcher != null) {
                                const vr = child.matcher.?.match(remains);
                                matched.addVariable(vr);
                                remains = remains[vr.value.len..];
                                if (remains.len == 0) {
                                    matched.value = child.value;
                                    return matched;
                                }

                                if (child.children.items.len > 0) {
                                    current = child.children.items[0];
                                }
                                continue :traverse;
                            }
                        }
                    }

                    // there are no variables
                    if (current.edge(remains[0])) |child| {
                        current = child;
                        continue :traverse;
                    }

                    // not found
                    return matched;
                }
                //
                // no remains left -> not found
                else {
                    return matched;
                }
            }
        }

        pub fn print(self: *Self) void {
            if (self.root) |root| {
                root.print();
            } else {
                std.debug.print("NO root node available!\n", .{});
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

pub fn Matched(comptime V: type) type {
    return struct {
        const Self = @This();

        value: ?V = null,
        // only support for 3 variables!!!
        vars: [3]vars.Variable = undefined,
        idx: u8 = 0,

        pub inline fn addVariable(self: *Self, v: vars.Variable) void {
            self.vars[self.idx] = v;
            self.idx += 1;
        }

        pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
            if (key.len == 0) {
                return null;
            }

            for (self.vars) |v| {
                if (std.mem.eql(u8, v.key, key)) {
                    return v.value;
                }
            }

            return null;
        }
    };
}

test "only root param" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("{name}", 96);

    try std.testing.expectEqualStrings("{name}", tree.root.?.key);
    try std.testing.expectEqual(96, tree.root.?.value);
    try std.testing.expectEqual(0, tree.root.?.children.items.len);

    // resolving
    const r = tree.resolve("jasmin");
    try std.testing.expectEqual(96, r.value);
    try std.testing.expectEqualDeep("jasmin", r.get("name"));
    try std.testing.expectEqual(null, r.get(""));
    try std.testing.expectEqual(null, r.get("invalid"));
}

test "root param starts with slash" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/{name}", 99);

    try std.testing.expectEqualStrings("/", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const name = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("{name}", name.key);
    try std.testing.expectEqual(99, name.value);
    try std.testing.expectEqual(0, name.children.items.len);

    // resolving
    const r = tree.resolve("/petra");
    try std.testing.expectEqual(99, r.value);
    try std.testing.expectEqualDeep("petra", r.get("name"));
}

test "root param with prefix" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/user/{id}", 1);

    try std.testing.expectEqualStrings("/user/", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const id = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(1, id.value);
    try std.testing.expectEqual(0, id.children.items.len);

    // resolving
    const r = tree.resolve("/user/42");
    try std.testing.expectEqual(1, r.value);
    try std.testing.expectEqualDeep("42", r.get("id"));
}

test "root paramn with suffix" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("{id}/user/", 1);

    try std.testing.expectEqualStrings("{id}", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expect(tree.root.?.matcher != null);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const user = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("/user/", user.key);
    try std.testing.expectEqual(1, user.value);
    try std.testing.expect(user.matcher == null);
    try std.testing.expectEqual(0, user.children.items.len);

    // resolving
    const r = tree.resolve("42/user/");
    try std.testing.expectEqual(1, r.value);
    try std.testing.expectEqualDeep("42", r.get("id"));
}

test "root paramn in between" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/prefix/{id}/user/", 1);

    try std.testing.expectEqualStrings("/prefix/", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expect(tree.root.?.matcher == null);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const id = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(null, id.value);
    try std.testing.expect(id.matcher != null);
    try std.testing.expectEqual(1, id.children.items.len);

    const user = id.children.items[0];
    try std.testing.expectEqualStrings("/user/", user.key);
    try std.testing.expectEqual(1, user.value);
    try std.testing.expect(user.matcher == null);
    try std.testing.expectEqual(0, user.children.items.len);

    // resolving
    const r = tree.resolve("/prefix/42/user/");
    try std.testing.expectEqual(1, r.value);
    try std.testing.expectEqualDeep("42", r.get("id"));
}

test "root with two params" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/user/{id}/{name}", 1);

    try std.testing.expectEqualStrings("/user/", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const id = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(null, id.value);
    try std.testing.expect(id.matcher != null);
    try std.testing.expectEqual(1, id.children.items.len);

    const slash = id.children.items[0];
    try std.testing.expectEqualStrings("/", slash.key);
    try std.testing.expectEqual(null, slash.value);
    try std.testing.expect(slash.matcher == null);

    const name = slash.children.items[0];
    try std.testing.expectEqualStrings("{name}", name.key);
    try std.testing.expectEqual(1, name.value);
    try std.testing.expect(name.matcher != null);
    try std.testing.expectEqual(0, name.children.items.len);

    // resolving
    const r = tree.resolve("/user/42/paul");
    try std.testing.expectEqual(1, r.value);
    try std.testing.expectEqualDeep("42", r.get("id"));
    try std.testing.expectEqualDeep("paul", r.get("name"));
}

test "params: only root with two params and one node between" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/user/{id}/with/{name}", 77);

    const r = tree.resolve("/user/42/with/paul");
    try std.testing.expectEqual(77, r.value);
    try std.testing.expectEqualDeep("42", r.get("id"));
    try std.testing.expectEqualDeep("paul", r.get("name"));
}

test "params: root with child" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/user/", 1);
    try tree.insert("/user/{id}", 2);

    try std.testing.expectEqualStrings("/user/", tree.root.?.key);
    try std.testing.expectEqual(1, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);
    try std.testing.expect(tree.root.?.matcher == null);

    const id = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(2, id.value);
    try std.testing.expectEqual(0, id.children.items.len);
    try std.testing.expect(id.matcher != null);

    // resolving
    try std.testing.expectEqual(null, tree.resolve("/foo/").value);
    try std.testing.expectEqual(1, tree.resolve("/user/").value);

    const r = tree.resolve("/user/007");
    try std.testing.expectEqual(2, r.value);
    try std.testing.expectEqualDeep("007", r.get("id"));
}

test "params: root with two child" {
    var tree = Tree(i32).init(std.testing.allocator, .{ .parser = vars.matchitParser });
    defer tree.deinit();

    try tree.insert("/user/", 1);
    try tree.insert("/group/", 2);
    try tree.insert("/user/{id}", 3);

    try std.testing.expectEqualStrings("/", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(2, tree.root.?.children.items.len);

    const user = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("user/", user.key);
    try std.testing.expectEqual(1, user.value);
    try std.testing.expectEqual(1, user.children.items.len);

    const id = user.children.items[0];
    try std.testing.expectEqualStrings("{id}", id.key);
    try std.testing.expectEqual(3, id.value);
    try std.testing.expectEqual(0, id.children.items.len);

    const group = tree.root.?.children.items[1];
    try std.testing.expectEqualStrings("group/", group.key);
    try std.testing.expectEqual(2, group.value);
    try std.testing.expectEqual(0, group.children.items.len);

    // resolving
    try std.testing.expectEqual(1, tree.resolve("/user/").value);
    try std.testing.expectEqual(2, tree.resolve("/group/").value);

    const r = tree.resolve("/user/33");
    try std.testing.expectEqual(3, r.value);
    try std.testing.expectEqualDeep("33", r.get("id"));
}

test "resolve: empty tree" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try std.testing.expectEqual(null, tree.resolve("not-found").value);
    try std.testing.expectEqual(null, tree.resolve("root").value);
    try std.testing.expectEqual(null, tree.resolve("").value);
}

test "resolve: only root" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("root", 1);

    try std.testing.expectEqual(1, tree.resolve("root").value);
    try std.testing.expectEqual(null, tree.resolve("foo").value);

    // resolving
    try std.testing.expectEqual(1, tree.resolve("root").value);
}

test "init: empty root" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try std.testing.expectEqual(null, tree.root);

    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(null, tree.resolve("foo").value);
}

test "only root: app" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("app", 1);
    try std.testing.expectEqual("app", tree.root.?.key);
    try std.testing.expectEqual(1, tree.root.?.value);
    try std.testing.expectEqual(0, tree.root.?.children.items.len);

    // resolving
    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(1, tree.resolve("app").value);
}

test "app + apple ==> app -> le" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("apple", 5);

    try std.testing.expectEqualStrings("app", tree.root.?.key);
    try std.testing.expectEqual(1, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const child = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(5, child.value);
    try std.testing.expectEqual(0, child.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("app").value);
    try std.testing.expectEqual(5, tree.resolve("apple").value);
    try std.testing.expectEqual(null, tree.resolve("le").value);

    // resolving
    try std.testing.expectEqual(1, tree.resolve("app").value);
    try std.testing.expectEqual(5, tree.resolve("apple").value);
}

test "apple + app ==> app -> le" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("apple", 5);
    try tree.insert("app", 1);

    try std.testing.expectEqualStrings("app", tree.root.?.key);
    try std.testing.expectEqual(1, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const child = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("le", child.key);
    try std.testing.expectEqual(5, child.value);
    try std.testing.expectEqual(0, child.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("app").value);
    try std.testing.expectEqual(5, tree.resolve("apple").value);
}

test "apple + appx ==> app -> le & x" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("apple", 5);
    try tree.insert("appx", 1);

    try std.testing.expectEqualStrings("app", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(2, tree.root.?.children.items.len);

    const le = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("le", le.key);
    try std.testing.expectEqual(5, le.value);
    try std.testing.expectEqual(0, le.children.items.len);
    const x = tree.root.?.children.items[1];
    try std.testing.expectEqualStrings("x", x.key);
    try std.testing.expectEqual(1, x.value);
    try std.testing.expectEqual(0, x.children.items.len);

    // resolve
    try std.testing.expectEqual(1, tree.resolve("appx").value);
    try std.testing.expectEqual(5, tree.resolve("apple").value);
    try std.testing.expectEqual(null, tree.resolve("app").value);
    try std.testing.expectEqual(null, tree.resolve("le").value);
    try std.testing.expectEqual(null, tree.resolve("x").value);
    try std.testing.expectEqual(null, tree.resolve("foo").value);
}

test "app + foo ==> app & foo" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("foo", 5);

    try std.testing.expectEqualStrings("", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(2, tree.root.?.children.items.len);

    const app = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("app", app.key);
    try std.testing.expectEqual(1, app.value);
    try std.testing.expectEqual(0, app.children.items.len);

    const foo = tree.root.?.children.items[1];
    try std.testing.expectEqualStrings("foo", foo.key);
    try std.testing.expectEqual(5, foo.value);
    try std.testing.expectEqual(0, foo.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(1, tree.resolve("app").value);
    try std.testing.expectEqual(5, tree.resolve("foo").value);
}

test "app + apple + foo ==> app -> le  & foo" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("app", 1);
    try tree.insert("apple", 2);
    try tree.insert("foo", 5);

    try std.testing.expectEqualStrings("", tree.root.?.key);
    try std.testing.expectEqual(null, tree.root.?.value);
    try std.testing.expectEqual(2, tree.root.?.children.items.len);

    const app = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("app", app.key);
    try std.testing.expectEqual(1, app.value);
    try std.testing.expectEqual(1, app.children.items.len);

    const le = app.children.items[0];
    try std.testing.expectEqualStrings("le", le.key);
    try std.testing.expectEqual(2, le.value);
    try std.testing.expectEqual(0, le.children.items.len);

    const foo = tree.root.?.children.items[1];
    try std.testing.expectEqualStrings("foo", foo.key);
    try std.testing.expectEqual(5, foo.value);
    try std.testing.expectEqual(0, foo.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(1, tree.resolve("app").value);
    try std.testing.expectEqual(2, tree.resolve("apple").value);
    try std.testing.expectEqual(5, tree.resolve("foo").value);
    try std.testing.expectEqual(null, tree.resolve("le").value);
    try std.testing.expectEqual(null, tree.resolve("applex").value);
}

test "apple + app + ap ==> ap -> p -> le" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("apple", 1);
    try tree.insert("app", 2);
    try tree.insert("ap", 3);

    try std.testing.expectEqualStrings("ap", tree.root.?.key);
    try std.testing.expectEqual(3, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const child_p = tree.root.?.children.items[0];
    try std.testing.expectEqualStrings("p", child_p.key);
    try std.testing.expectEqual(2, child_p.value);
    try std.testing.expectEqual(1, child_p.children.items.len);

    const child_le = child_p.children.items[0];
    try std.testing.expectEqualStrings("le", child_le.key);
    try std.testing.expectEqual(1, child_le.value);
    try std.testing.expectEqual(0, child_le.children.items.len);

    // resolve
    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(2, tree.resolve("app").value);
    try std.testing.expectEqual(1, tree.resolve("apple").value);
    try std.testing.expectEqual(3, tree.resolve("ap").value);
}

test "aappzz + aa + aappxx ==> aa -> pp -> xx & zz" {
    var tree = Tree(i32).init(std.testing.allocator, .{});
    defer tree.deinit();

    try tree.insert("aappzz", 1);
    try tree.insert("aa", 2);
    try tree.insert("aappxx", 3);

    try std.testing.expectEqualStrings("aa", tree.root.?.key);
    try std.testing.expectEqual(2, tree.root.?.value);
    try std.testing.expectEqual(1, tree.root.?.children.items.len);

    const pp = tree.root.?.children.items[0];
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
    try std.testing.expectEqual(null, tree.resolve("").value);
    try std.testing.expectEqual(1, tree.resolve("aappzz").value);
    try std.testing.expectEqual(2, tree.resolve("aa").value);
    try std.testing.expectEqual(3, tree.resolve("aappxx").value);
    try std.testing.expectEqual(null, tree.resolve("xx").value);
    try std.testing.expectEqual(null, tree.resolve("zz").value);
}
