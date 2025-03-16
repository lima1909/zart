const std = @import("std");

const Variable = @import("vars.zig").Variable;
const Variables = @import("vars.zig").Variables;
const matchitParser = @import("vars.zig").matchitParser;

const Params = @import("request.zig").Params;
const FromVars = @import("request.zig").FromVars;

const Tree = @import("tree.zig").Tree;

// Supported Handler function signatures:
//   - fn (req: Request)
//   - fn (req: Request, params: Params) || fn (req: Request, params: MyParam)
//   - fn (app: App, req: Request, params: Params(T))
//   - fn (app: App, req: Request)
//
pub fn Handler(comptime App: type, comptime Request: type) type {
    return struct {
        handle: *const fn (app: ?App, req: Request, params: []const Variable) anyerror!void,
    };
}

pub fn handlerFromFn(comptime App: type, comptime Request: type, func: anytype) Handler(App, Request) {
    const meta = @typeInfo(@TypeOf(func));
    const argsLen = meta.Fn.params.len;

    // validate the args
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

    // find the arg index from Request
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

    // find the arg index from Request
    const indexParams: ?usize = switch (argsLen) {
        // only Request
        1 => null,
        // App + Request | Request + params
        2 => if (meta.Fn.params[0].type == App) null else 1,
        // App, Request, params (3 Args)
        3 => 2,
        else => null,
    };

    const FromParamsType: ?type = if (indexParams) |i|
        if (meta.Fn.params[i].type == Params) null else meta.Fn.params[i].type
    else
        null;

    const h = struct {
        fn handle(app: ?App, req: Request, vs: []const Variable) !void {
            const request = if (fromRequest) |fr| fr(req) else req;
            const params = if (FromParamsType) |T| try FromVars(T, vs) else Params{ .vars = vs };

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
    OTHER,

    pub fn fromStdMethod(m: std.http.Method) Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            else => .OTHER, // TODO: maybe throw an error or optional?
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
        _other: Tree(H),

        // error_handler
        // not_found_handler

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithApp(allocator, undefined);
        }

        pub fn initWithApp(allocator: std.mem.Allocator, app: ?App) Self {
            const cfg = .{ .parser = matchitParser };

            return .{
                .allocator = allocator,
                ._app = app,
                ._get = Tree(H).init(allocator, cfg),
                ._post = Tree(H).init(allocator, cfg),
                ._other = Tree(H).init(allocator, cfg),
            };
        }

        pub fn deinit(self: *Self) void {
            self._get.deinit();
            self._post.deinit();
            self._other.deinit();
        }

        pub fn get(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.addPath(.GET, path, handlerFn);
        }

        pub fn post(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.addPath(.POST, path, handlerFn);
        }

        pub inline fn addPath(self: *Self, method: Method, path: []const u8, handlerFn: anytype) !void {
            const handler = handlerFromFn(App, Request, handlerFn);
            return try switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.insert(path, handler);
        }

        pub fn resolve(self: *const Self, method: Method, path: []const u8, req: Request) void {
            const matched = switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.resolve(path);

            if (matched.value) |handler| {
                handler.handle(self._app, req, &matched.vars) catch |err| {
                    // TODO: replace this with an error handler
                    std.debug.print("ERROR by call handler: {}\n", .{err});
                };
            }

            // TODO: else NOT FOUND handler
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

    var router = Router(void, *i32).init(std.testing.allocator);
    defer router.deinit();

    try router.get("/foo", struct {
        fn user(u: Body) anyerror!void {
            u.i.* += 1;
        }
    }.user);

    var i: i32 = 3;
    router.resolve(Method.fromStdMethod(std.http.Method.GET), "/foo", &i);

    try std.testing.expectEqual(4, i);
}

test "router for i32" {
    const App = struct { value: i32 };
    var app = App{ .value = -1 };

    var router = Router(*App, *i32).initWithApp(std.testing.allocator, &app);
    defer router.deinit();

    try router.addPath(.OTHER, "/foo", struct {
        fn addOne(a: *App, i: *i32, _: Params) anyerror!void {
            a.value = i.* + 2;
            i.* += 1;
        }
    }.addOne);

    var i: i32 = 3;
    router.resolve(.OTHER, "/foo", &i);

    try std.testing.expectEqual(4, i);
    try std.testing.expectEqual(5, app.value);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    var router = Router(void, *HttpRequest).init(std.testing.allocator);
    defer router.deinit();

    try router.post("/user/:id", struct {
        fn user(req: *HttpRequest, params: Params) anyerror!void {
            req.head.keep_alive = true;

            try std.testing.expectEqualStrings("42", params.value("id").?);
            try std.testing.expectEqual(42, (try params.valueAs(i32, "id")).?);

            try std.testing.expectEqualStrings("/user/42", req.head.target);
            try std.testing.expectEqual(std.http.Method.GET, req.head.method);
        }
    }.user);

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

test "router for struct params" {
    var router = Router(void, *i32).init(std.testing.allocator);
    defer router.deinit();

    const POk = struct { ok: bool };

    try router.addPath(.GET, "/foo/:ok", struct {
        fn get(i: *i32, p: POk) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(true, p.ok);
        }
    }.get);

    var i: i32 = 3;
    router.resolve(.GET, "/foo/true", &i);

    try std.testing.expectEqual(4, i);
}

test "router for params" {
    var router = Router(void, *i32).init(std.testing.allocator);
    defer router.deinit();

    try router.addPath(.POST, "/foo/:id", struct {
        fn addOne(i: *i32, p: Params) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(42, p.valueAs(i32, "id"));
        }
    }.addOne);

    var i: i32 = 3;
    router.resolve(.POST, "/foo/42", &i);

    try std.testing.expectEqual(4, i);
}
