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
const Allocator = std.mem.Allocator;

pub fn Tree(comptime T: type) type {
    return struct {
        const Self = @This();

        root: Node(T),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .root = Node(T).init(allocator) };
        }

        fn deinit(self: *Self) void {
            self.root.deinit(self.allocator);
        }

        pub fn insert(self: *Self, key: []const u8, value: T) !void {
            // first step, root doesn't exist -> create root node
            if (self.root.key.len == 0 and self.root.children.items.len == 0) {
                self.root.key = key;
                self.root.value = value;
                return;
            }

            var current: *Node(T) = &self.root;
            var remains = key;

            traverse: while (true) {
                // longestPrefix(current.key, remains);
                const max = if (current.key.len < remains.len) current.key.len else remains.len;
                var i: usize = 0;
                const len_prefix = while (i < max) : (i += 1) {
                    if (current.key[i] != remains[i]) break i;
                } else i;

                // NOT FOUND, create a new root and add the child nodes
                // e.g. root: app, new node: foo ->
                // (new_root)
                //    /\
                // app  foo
                if (len_prefix == 0) {
                    const child_one = try Node(T).new(self.allocator, current.key, current.value);
                    child_one.children = current.children;

                    const child_two = try Node(T).new(self.allocator, remains, value);

                    current.* = Node(T).init(self.allocator);
                    try current.children.append(child_one);
                    try current.children.append(child_two);

                    return;
                }

                //
                if (len_prefix < current.key.len) {
                    // apple + app ==> app -> le
                    // app + ap ==> ap -> p
                    var child = try Node(T).new(self.allocator, current.key[len_prefix..], current.value);
                    child.children = try current.children.clone();

                    current.key = remains[0..len_prefix];
                    current.value = null;
                    if (remains.len == len_prefix) {
                        current.value = value;
                    }
                    current.children.clearRetainingCapacity();
                    try current.children.append(child);
                }

                // traverse the tree down
                // app -> apple (le) ==> app--le
                if (len_prefix < remains.len) {
                    remains = remains[len_prefix..];

                    if (current.edge(remains[0])) |child| {
                        current = child;
                        continue :traverse;
                    }

                    // std.debug.print("-- not found \n", .{});
                    const new_child = try Node(T).new(self.allocator, remains, value);
                    try current.children.append(new_child);
                    return;
                }

                return;
            }
        }

        pub fn search(self: *Self, key: []const u8) ?T {
            // searching for the root key
            if (std.mem.eql(u8, self.root.key, key)) {
                return self.root.value;
            }

            var current: *Node(T) = &self.root;
            var remains = key;

            traverse: while (true) {
                if (remains.len == 0 or remains.len <= current.key.len) {
                    // no remains left -> not found
                    return null;
                }
                remains = remains[current.key.len..];

                if (current.edge(remains[0])) |child| {
                    current = child;
                    if (std.mem.eql(u8, current.key, remains)) {
                        return current.value;
                    }
                    continue :traverse;
                }

                // not found
                return null;
            }
        }
    };
}

fn Node(comptime T: type) type {
    return struct {
        const Self = @This();

        key: []const u8,
        value: ?T = null,
        children: std.ArrayList(*Self),

        fn new(allocator: Allocator, key: []const u8, value: ?T) !*Self {
            const node = try allocator.create(Self);
            node.* = .{ .children = std.ArrayList(*Self).init(allocator), .key = key, .value = value };
            return node;
        }

        fn init(allocator: Allocator) Self {
            return .{ .children = std.ArrayList(*Self).init(allocator), .key = "" };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            for (self.children.items) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            }
            self.children.deinit();
        }

        /// Find and returns the edge for a given letter or null, if not found.
        fn edge(self: *Self, l: u8) ?*Self {
            for (self.children.items, 0..) |child, i| {
                if (child.key.len > 0 and child.key[0] == l) {
                    return self.children.items[i];
                }
            }
            return null;
        }

        fn print(self: *Self) void {
            self.printIndent(0);
        }

        fn printIndent(self: *Self, indent: u8) void {
            for (0..indent) |_| {
                std.debug.print("  ", .{});
            }

            std.debug.print("name: {s}: {any}\n", .{ self.key, self.value });
            for (self.children.items, 0..) |_, i| {
                self.children.items[i].printIndent(indent + 1);
            }
        }
    };
}

test "search: empty tree" {
    var tree = Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(null, tree.search("not-found"));
    try std.testing.expectEqual(null, tree.search("root"));
    try std.testing.expectEqual(null, tree.search(""));
}

test "search: find root" {
    var tree = Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("root", 1);

    try std.testing.expectEqual(1, tree.search("root"));
    try std.testing.expectEqual(null, tree.search("foo"));
}

test "init: empty root" {
    var tree = Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual("", tree.root.key);
    try std.testing.expectEqual(null, tree.root.value);
    try std.testing.expectEqual(0, tree.root.children.items.len);

    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(null, tree.search("foo"));
}

test "only root: app" {
    var tree = Tree(i32).init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert("app", 1);
    try std.testing.expectEqual("app", tree.root.key);
    try std.testing.expectEqual(1, tree.root.value);
    try std.testing.expectEqual(0, tree.root.children.items.len);

    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(1, tree.search("app"));
}

test "app + apple ==> app -> le" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(1, tree.search("app"));
    try std.testing.expectEqual(5, tree.search("apple"));
    try std.testing.expectEqual(null, tree.search("le"));
}

test "apple + app ==> app -> le" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(1, tree.search("app"));
    try std.testing.expectEqual(5, tree.search("apple"));
}

test "apple + appx ==> app -> le & x" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(1, tree.search("appx"));
    try std.testing.expectEqual(5, tree.search("apple"));
    try std.testing.expectEqual(null, tree.search("app"));
    try std.testing.expectEqual(null, tree.search("le"));
    try std.testing.expectEqual(null, tree.search("x"));
    try std.testing.expectEqual(null, tree.search("foo"));
}

test "app + foo ==> app & foo" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(1, tree.search("app"));
    try std.testing.expectEqual(5, tree.search("foo"));
}

test "app + apple + foo ==> app -> le  & foo" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(1, tree.search("app"));
    try std.testing.expectEqual(2, tree.search("apple"));
    try std.testing.expectEqual(5, tree.search("foo"));
    try std.testing.expectEqual(null, tree.search("le"));
    try std.testing.expectEqual(null, tree.search("applex"));
}

test "apple + app + ap ==> ap -> p -> le" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(2, tree.search("app"));
    try std.testing.expectEqual(1, tree.search("apple"));
    try std.testing.expectEqual(3, tree.search("ap"));
}

test "aappzz + aa + aappxx ==> aa -> pp -> xx & zz" {
    var tree = Tree(i32).init(std.testing.allocator);
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

    // searching
    try std.testing.expectEqual(null, tree.search(""));
    try std.testing.expectEqual(1, tree.search("aappzz"));
    try std.testing.expectEqual(2, tree.search("aa"));
    try std.testing.expectEqual(3, tree.search("aappxx"));
    try std.testing.expectEqual(null, tree.search("xx"));
    try std.testing.expectEqual(null, tree.search("zz"));
}
