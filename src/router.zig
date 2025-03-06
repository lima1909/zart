const std = @import("std");

const vars = @import("vars.zig");
const Tree = @import("tree.zig").Tree;

// Supported Handler function signatures:
//   - fn (req: Request)
//   - fn (req: Request, params: [3]vars.Variable)
//   - fn (app: App, req: Request, params: [3]vars.Variable)
//   - fn (app: App, req: Request)
//
pub fn Handler(comptime App: type, comptime Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, params: [3]vars.Variable) anyerror!void,
    };
}

pub fn handlerFromFn(comptime App: type, comptime Request: type, func: anytype) Handler(App, Request) {
    const meta = @typeInfo(@TypeOf(func));
    const argsLen = meta.Fn.params.len;

    switch (argsLen) {
        0 => @compileError("Function must have at least one parameter: " ++ @typeName(func)),
        1, 2 => {},
        3 => {
            if (meta.Fn.params[0].type != App) {
                @compileError("The first argument in the given function must be the App: " ++ @typeName(func));
            }
        },
        else => @compileError("Function with more then 3 parameter are not supported " ++ @typeName(func)),
    }

    // const indexRequest: usize = if (argsLen == 3) 1 else 0;
    const indexRequest: usize = switch (argsLen) {
        // only Request
        1 => 0,
        // App + Request | Request + params
        2 => if (meta.Fn.params[0].type == App) return 1 else 0,
        // App, Request, params (3 Args)
        else => 1,
    };

    const argType = meta.Fn.params[indexRequest].type.?;

    const isRequest = Request == argType;
    if (!isRequest) {
        if (std.meta.hasFn(argType, "fromRequest") == false) {
            @compileError("Missing method .fromRequest for: " ++ @typeName(argType));
        }
    }

    const fromRequest: ?*const fn (Request) argType = if (isRequest) null else argType.fromRequest;

    const h = struct {
        fn handle(app: ?App, req: Request, params: [3]vars.Variable) !void {
            const request = if (fromRequest) |fr| fr(req) else req;
            switch (argsLen) {
                1 => return @call(.auto, func, .{request}),
                2 => return @call(.auto, func, .{ request, params }),
                else => return @call(.auto, func, .{ app.?, request, params }),
            }
        }
    };

    return Handler(App, Request){ .handle = h.handle };
}

pub const Method = enum {
    GET,
    POST,

    pub fn fromStdMethod(comptime m: std.http.Method) Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            else => |t| @panic("not implemented yet" ++ @tagName(t)),
        };
    }
};

pub fn Router(comptime App: type, comptime Request: type) type {
    const H = Handler(App, Request);

    return struct {
        const Self = @This();

        _app: ?App,

        // methods
        _get: Tree(H),
        _post: Tree(H),

        // error_handler
        // not_found_handler

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithApp(allocator, undefined);
        }

        pub fn initWithApp(allocator: std.mem.Allocator, app: ?App) Self {
            const cfg = .{ .parser = vars.matchitParser };

            return .{
                .allocator = allocator,
                ._app = app,
                ._get = Tree(H).init(allocator, cfg),
                ._post = Tree(H).init(allocator, cfg),
            };
        }

        pub fn deinit(self: *Self) void {
            self._get.deinit();
            self._post.deinit();
        }

        pub fn get(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.addPath(.GET, path, handlerFn);
        }

        pub fn post(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.addPath(.POST, path, handlerFn);
        }

        pub fn resolve(self: *const Self, method: Method, path: []const u8, req: Request) void {
            const matched = switch (method) {
                .GET => self._get,
                .POST => self._post,
            }.resolve(path);

            if (matched.value) |handler| {
                handler.handle(self._app, req, matched.vars) catch |err| {
                    // TODO: replace this with an error handler
                    std.debug.print("ERROR by call handler: {}\n", .{err});
                };
            }

            // TODO: else NOT FOUND handler
        }

        inline fn addPath(self: *Self, method: Method, path: []const u8, handlerFn: anytype) !void {
            const handler = handlerFromFn(App, Request, handlerFn);
            return try switch (method) {
                .GET => &self._get,
                .POST => &self._post,
            }.insert(path, handler);
        }
    };
}

test "router for handler object Body" {
    const Body = struct {
        const Self = @This();

        i: *i32,

        pub fn fromRequest(req: *i32) Self {
            return .{ .i = req };
        }
    };

    const Example = struct {
        fn user(u: Body) anyerror!void {
            u.i.* += 1;
        }
    };

    var router = Router(void, *i32).init(std.testing.allocator);
    defer router.deinit();

    try router.get("/foo", Example.user);

    var i: i32 = 3;
    router.resolve(Method.fromStdMethod(std.http.Method.GET), "/foo", &i);

    try std.testing.expectEqual(4, i);
}

test "router for i32" {
    const App = struct { value: i32 };
    var app = App{ .value = -1 };

    var router = Router(*App, *i32).initWithApp(std.testing.allocator, &app);
    defer router.deinit();

    const Example = struct {
        fn addOne(a: *App, i: *i32, _: [3]vars.Variable) anyerror!void {
            a.value = i.* + 2;
            i.* += 1;
        }
    };

    try router.get("/foo", Example.addOne);

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i);

    try std.testing.expectEqual(4, i);
    try std.testing.expectEqual(5, app.value);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    var router = Router(void, *HttpRequest).init(std.testing.allocator);
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

    try router.post("/user/:id", Example.user);

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
    router.resolve(.POST, "/user/42", &req);

    // the user function set keep_alive = true
    try std.testing.expectEqual(true, req.head.keep_alive);
}
