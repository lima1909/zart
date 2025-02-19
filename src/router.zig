const std = @import("std");

const Tree = @import("tree.zig").Tree;
const vars = @import("vars.zig");

const Allocator = std.mem.Allocator;

pub const RouterError = error{};

pub fn Router(comptime R: type) type {
    const Handler = *const fn (R) RouterError!void;

    return struct {
        const Self = @This();

        tree: Tree(Handler),
        // error_handler
        // not_found_handler

        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .tree = Tree(Handler).init(allocator, .{ .parser = vars.matchitParser }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
            try self.tree.insert(path, handler);
        }

        pub fn resolve(self: *Self, path: []const u8, req: R) void {
            if (self.tree.resolve(path).value) |handler| {
                try handler(req);
            }
            // else NOT FOUND
        }
    };
}

test "router" {
    var router = Router(*i32).init(std.testing.allocator);
    defer router.deinit();

    const H = struct {
        fn foo(i: *i32) RouterError!void {
            i.* += 1;
        }
    };

    try router.get("/foo", H.foo);

    var i: i32 = 3;
    router.resolve("/foo", &i);

    try std.testing.expectEqual(4, i);
}
