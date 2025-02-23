const std = @import("std");

const vars = @import("vars.zig");
const Tree = @import("tree.zig").Tree;

const Allocator = std.mem.Allocator;

// fn user(req: *HttpRequest) anyerror!void {
// fn user(req: *HttpRequest, params: Params) anyerror!void {
// fn user(user: JsonBody(User), params: Params) anyerror!void {

pub fn Handler(comptime Request: type) type {
    const HandlerFn = union(enum) {
        request: *const fn (Request) anyerror!void,
        requestWithParams: *const fn (Request, [3]vars.Variable) anyerror!void,
    };

    return struct {
        const Self = @This();

        handler: HandlerFn,

        pub fn fromFunc(func: anytype) Self {
            const meta = @typeInfo(@TypeOf(func));
            if (meta != .Fn) @compileError("Handler only accepts functions");
            if (meta.Fn.params[0].type != Request) @compileError("Handler only accepts functions");

            switch (meta.Fn.params.len) {
                1 => return .{ .handler = HandlerFn{ .request = func } },
                2 => return .{ .handler = HandlerFn{ .requestWithParams = func } },
                else => @compileError("Handler function must have 1 or 2 parameters, not more: " ++ meta.Fn.params.len),
            }
        }

        pub fn exec(self: *const Self, req: Request, params: [3]vars.Variable) anyerror!void {
            switch (self.handler) {
                HandlerFn.request => |hanlde| try hanlde(req),
                HandlerFn.requestWithParams => |hanlde| try hanlde(req, params),
            }
        }
    };
}

pub fn Router(comptime Request: type) type {
    return struct {
        const Self = @This();

        _get: Tree(Handler(Request)),
        // error_handler
        // not_found_handler

        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            const cfg = .{ .parser = vars.matchitParser };
            return .{
                .allocator = allocator,
                ._get = Tree(Handler(Request)).init(allocator, cfg),
            };
        }

        pub fn deinit(self: *Self) void {
            self._get.deinit();
        }

        pub fn get(self: *Self, path: []const u8, comptime func: anytype) !void {
            const handler = Handler(Request).fromFunc(func);
            try self._get.insert(path, handler);
        }

        pub fn resolve(self: *const Self, path: []const u8, req: Request) void {
            const matched = self._get.resolve(path);
            if (matched.value) |handler| {
                handler.exec(req, matched.vars) catch |err| {
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
        fn addOne(i: *i32) anyerror!void {
            i.* += 1;
        }
    };

    try router.get("/foo", Example.addOne);

    var i: i32 = 3;
    router.resolve("/foo", &i);

    try std.testing.expectEqual(4, i);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    var router = Router(*HttpRequest).init(std.testing.allocator);
    defer router.deinit();

    const Example = struct {
        fn user(req: *HttpRequest, params: [3]vars.Variable) anyerror!void {
            req.head.keep_alive = true;

            const id = params[0];
            try std.testing.expectEqualStrings("id", id.key);
            try std.testing.expectEqualStrings("42", id.value);

            try std.testing.expectEqualStrings("/user/42", req.head.target);
            try std.testing.expectEqual(std.http.Method.GET, req.head.method);
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
