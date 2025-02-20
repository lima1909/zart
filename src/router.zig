const std = @import("std");

const vars = @import("vars.zig");
const Tree = @import("tree.zig").Tree;

const Allocator = std.mem.Allocator;

pub fn Context(comptime Request: type) type {
    return struct {
        request: Request,
        params: [3]vars.Variable = undefined,
    };
}

pub fn Router(comptime Request: type) type {
    //
    const Handler = *const fn (Context(Request)) anyerror!void;

    return struct {
        const Self = @This();

        _get: Tree(Handler),
        // error_handler
        // not_found_handler

        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            const cfg = .{ .parser = vars.matchitParser };
            return .{
                .allocator = allocator,
                ._get = Tree(Handler).init(allocator, cfg),
            };
        }

        pub fn deinit(self: *Self) void {
            self._get.deinit();
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) !void {
            try self._get.insert(path, handler);
        }

        pub fn resolve(self: *const Self, path: []const u8, req: Request) void {
            const matched = self._get.resolve(path);
            if (matched.value) |handler| {
                handler(Context(Request){ .request = req, .params = matched.vars }) catch |err| {
                    // TODO: replace this with an error handler
                    std.debug.print("ERROR by call handler: {}\n", .{err});
                };
            }

            // TODO: else NOT FOUND handler
        }
    };
}

test "router for i32" {
    var router = Router(*i32).init(std.testing.allocator);
    defer router.deinit();

    const Example = struct {
        fn foo(ctx: Context(*i32)) anyerror!void {
            ctx.request.* += 1;
        }
    };

    try router.get("/foo", Example.foo);

    var i: i32 = 3;
    router.resolve("/foo", &i);

    try std.testing.expectEqual(4, i);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    var router = Router(*HttpRequest).init(std.testing.allocator);
    defer router.deinit();

    const Example = struct {
        fn user(ctx: Context(*HttpRequest)) anyerror!void {
            ctx.request.head.keep_alive = true;

            const id = ctx.params[0];
            try std.testing.expectEqualStrings("id", id.key);
            try std.testing.expectEqualStrings("42", id.value);

            try std.testing.expectEqualStrings("/user/42", ctx.request.head.target);
            try std.testing.expectEqual(std.http.Method.GET, ctx.request.head.method);
        }
    };

    try router.get("/user/:id", Example.user);

    var req = HttpRequest{
        .server = undefined,
        .head_end = 0,
        .reader_state = undefined,
        .head = std.http.Server.Request.Head{
            .target = "/user/42",
            .method = std.http.Method.GET,
            .version = std.http.Version.@"HTTP/1.0",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = std.http.TransferEncoding.none,
            .transfer_compression = std.http.ContentEncoding.@"x-gzip",
            .keep_alive = false,
            .compression = undefined,
        },
    };
    router.resolve("/user/42", &req);

    // the user function set keep_alive = true
    try std.testing.expectEqual(true, req.head.keep_alive);
}
