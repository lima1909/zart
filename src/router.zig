const std = @import("std");
const http = std.http;

const Response = @import("handler.zig").Response;
const Func = @import("handler.zig").Func;
const TreeConfig = @import("tree.zig").Config;

const kv = @import("kv.zig");

const Handle = struct {
    method: http.Method,
    func: Func,
};

pub fn get(f: anytype) Handle {
    return .{ .method = .GET, .func = Func.from(f) };
}

pub fn post(f: anytype) Handle {
    return .{ .method = .POST, .func = Func.from(f) };
}

pub fn patch(f: anytype) Handle {
    return .{ .method = .PATCH, .func = Func.from(f) };
}

pub fn delete(f: anytype) Handle {
    return .{ .method = .DELETE, .func = Func.from(f) };
}

/// A general Handle with http.Method and handle function.
pub fn handle(m: http.Method, f: anytype) Handle {
    return .{ .method = m, .func = Func.from(f) };
}

///
/// Route has an given path and one or a list of Handle:
/// A Handle consist of a http.Method and a (handle function).
///
/// Examples:
/// Route("/users/:id", get(user));
/// Route("/users", .{ patch(updateUser) , post(createUser) });
///
pub fn Route(path: []const u8, handles: anytype) type {
    const hlen = if (@TypeOf(handles) == Handle) 1 else handles.len;
    comptime var hs: [hlen]Handle = undefined;

    if (@TypeOf(handles) == Handle) {
        hs = [1]Handle{handles};
    } else {
        inline for (handles, 0..) |h, i| {
            hs[i] = h;
        }
    }

    return struct {
        path: []const u8 = path,
        handles: [hlen]Handle = hs,
    };
}

pub fn Config(Request: type) type {
    return struct {
        parser: kv.parse = kv.matchitParser,
        ///
        /// Signature for Extractor:
        ///   pub fn body(T: type, allocator: std.mem.Allocator, r: Request) !T
        ///   pub fn response(T: type, allocator: std.mem.Allocator, r: Request, resp: Response(T)) !void
        Extractor: type = void,
        error_handler: ?*const fn (Request, Response([]u8)) void = null,
    };
}

pub fn NewRouter(Request: type) type {
    return struct {
        pub fn init(allocator: std.mem.Allocator, routes: anytype, cfg: Config(Request)) !Router(void, Request) {
            return try Router(void, Request).init(allocator, null, routes, cfg);
        }

        pub fn initWithApp(allocator: std.mem.Allocator, app: anytype, routes: anytype, cfg: Config(Request)) !Router(@TypeOf(app), Request) {
            return try Router(@TypeOf(app), Request).init(allocator, app, routes, cfg);
        }
    };
}

pub fn Router(App: type, Request: type) type {
    const H = @import("handler.zig").Handler(App, Request);
    const Tree = @import("tree.zig").Tree(H);

    const defaultErrorHandler = struct {
        fn handleError(_: Request, resp: Response([]u8)) void {
            const status = @tagName(resp.status);
            switch (resp.content) {
                .string => |s| std.debug.print("error: {s} ({s})\n", .{ s, status }),
                .object => |s| std.debug.print("error: {any} ({s})\n", .{ s, status }),
            }
        }
    }.handleError;

    return struct {
        allocator: std.mem.Allocator,

        _app: ?App,
        _error_handler: *const fn (Request, Response([]u8)) void,

        // methods
        _get: Tree = undefined,
        _post: Tree = undefined,
        _patch: Tree = undefined,
        _delete: Tree = undefined,
        _other: Tree = undefined,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, app: ?App, routes: anytype, cfg: Config(Request)) !Self {
            const tcfg = @import("tree.zig").Config{ .parser = cfg.parser };

            var self = Self{
                .allocator = allocator,
                ._app = app,
                ._error_handler = cfg.error_handler orelse defaultErrorHandler,

                ._get = Tree.init(allocator, tcfg),
                ._post = Tree.init(allocator, tcfg),
                ._patch = Tree.init(allocator, tcfg),
                ._delete = Tree.init(allocator, tcfg),
                ._other = Tree.init(allocator, tcfg),
            };

            inline for (routes) |r| {
                const route = r{};

                inline for (route.handles) |h| {
                    const handler = @import("handler.zig").handlerFromFn(
                        App,
                        Request,
                        h.func,
                        cfg.Extractor,
                    );

                    const tree = switch (h.method) {
                        .GET => &self._get,
                        .POST => &self._post,
                        .PATCH => &self._patch,
                        .DELETE => &self._delete,
                        else => &self._other,
                    };
                    try tree.insert(route.path, handler);
                }
            }

            return self;
        }

        pub fn deinit(self: Self) void {
            self._get.deinit();
            self._post.deinit();
            self._patch.deinit();
            self._delete.deinit();
            self._other.deinit();
        }

        pub fn resolve(self: *const Self, method: http.Method, path: []const u8, req: Request, query: []const kv.KeyValue) void {
            const matched = switch (method) {
                .GET => &self._get,
                .POST => &self._post,
                .PATCH => &self._patch,
                .DELETE => &self._delete,
                else => &self._other,
            }.resolve(path);

            if (matched.value) |handler| {

                // TODO: replace self.allocator
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                handler.handle(self._app, req, query, &matched.kvs, arena.allocator()) catch |err| {
                    // BAD REQUEST handler
                    var buffer: [50]u8 = undefined;
                    const error_msg = std.fmt.bufPrint(&buffer, "{s}{}", .{ "400 Bad Request: ", err }) catch "400 Bad Request";

                    self._error_handler(req, Response([]u8){
                        .status = .bad_request,
                        .content = .{ .string = error_msg },
                    });
                };
                return;
            }

            // NOT FOUND handler
            self._error_handler(req, Response([]u8){
                .status = .not_found,
                .content = .{ .string = "404 Not Found" },
            });
        }
    };
}

test "router for handler object" {
    const ReqObject = struct {
        const Self = @This();

        i: *i32,

        pub fn fromRequest(req: *i32) Self {
            return .{ .i = req };
        }
    };

    const user = struct {
        fn user(u: ReqObject) void {
            u.i.* += 1;
        }
    }.user;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo", get(user)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(4, i);
}

const request = @import("handler.zig");
const P = request.P;
const Q = request.Q;
const B = request.B;
const Params = request.Params;
const Query = request.Query;
const Body = request.Body;

test "router for i32" {
    const App = struct { value: i32 };
    var app = App{ .value = -1 };

    const addOne = struct {
        fn addOne(a: *App, i: *i32, _: Params) anyerror!void {
            a.value = i.* + 2;
            i.* += 1;
        }
    }.addOne;

    const router = try NewRouter(*i32).initWithApp(std.testing.allocator, &app, .{
        Route("/foo", handle(.HEAD, addOne)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.OPTIONS, "/foo", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(4, i);
    try std.testing.expectEqual(5, app.value);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    const user = struct {
        fn user(req: *HttpRequest, params: Params) anyerror!void {
            req.head.keep_alive = true;

            try std.testing.expectEqualStrings("42", params.value("id").?);
            try std.testing.expectEqual(42, (try params.valueAs(i32, "id")).?);

            try std.testing.expectEqualStrings("/user/42", req.head.target);
            try std.testing.expectEqual(std.http.Method.GET, req.head.method);
        }
    }.user;

    const router = try NewRouter(*HttpRequest).init(std.testing.allocator, .{
        Route("/user/:id", patch(user)),
    }, .{});
    defer router.deinit();

    var req = HttpRequest{
        .server = undefined,
        .head_end = 0,
        .reader_state = undefined,
        .head = std.http.Server.Request.Head{
            .target = "/user/42",
            .method = http.Method.GET,
            .version = http.Version.@"HTTP/1.0",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = std.http.TransferEncoding.none,
            .transfer_compression = std.http.ContentEncoding.@"x-gzip",
            .keep_alive = false,
            .compression = undefined,
        },
    };

    router.resolve(.PATCH, "/user/42", &req, &[_]kv.KeyValue{});
    // the user function set keep_alive = true
    try std.testing.expectEqual(true, req.head.keep_alive);
}

test "router for struct params" {
    const Ok = struct { ok: bool };
    const addOne = struct {
        fn addOne(i: *i32, p: P(Ok)) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(true, p.ok);
        }
    }.addOne;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo/:ok", delete(addOne)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.DELETE, "/foo/true", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);
}

test "router for params" {
    const addOne = struct {
        fn addOne(i: *i32, p: Params) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(42, p.valueAs(i32, "id"));
        }
    }.addOne;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo/:id", post(addOne)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    _ = router.resolve(.POST, "/foo/42", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);
}

test "first Params, than request" {
    const foo = struct {
        fn foo(p: Params, i: *i32) anyerror!void {
            i.* += (try p.valueAs(i32, "id")).?;
        }
    }.foo;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo/:id", get(foo)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo/42", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(45, i);
}

test "with query" {
    const foo = struct {
        fn foo(q: Query, i: *i32) anyerror!void {
            i.* += (try q.valueAs(i32, "id")).?;
        }
    }.foo;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{.{ .key = "id", .value = "42" }});
    try std.testing.expectEqual(45, i);
}

test "with Q" {
    const Id = struct { id: i32 };
    const foo = struct {
        fn foo(q: Q(Id), i: *i32) anyerror!void {
            i.* += q.id;
        }
    }.foo;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{.{ .key = "id", .value = "42" }});
    try std.testing.expectEqual(45, i);
}

test "with B" {
    const Id = struct { id: i32 };
    const extract = struct {
        pub fn body(T: type, _: std.mem.Allocator, _: *i32) !T {
            return B(Id){ .id = 42 };
        }
    };
    const foo = struct {
        fn foo(b: B(Id), i: *i32) anyerror!void {
            i.* += b.id;
        }
    }.foo;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{ .Extractor = extract });
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(45, i);
}

test "with Body" {
    const extract = struct {
        pub fn body(T: type, allocator: std.mem.Allocator, _: *i32) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 42}", .{});
        }
    };
    const foo = struct {
        fn foo(b: Body, i: *i32) anyerror!void {
            const obj = b.object;
            const id = obj.get("id") orelse .null;
            i.* += @intCast(id.integer);
        }
    }.foo;

    const router = try NewRouter(*i32).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{ .Extractor = extract });
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(45, i);
}

test "request with two args" {
    const Req = struct { *i32, bool };

    const extract = struct {
        pub fn body(T: type, allocator: std.mem.Allocator, _: Req) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 45}", .{});
        }
    };
    const foo = struct {
        fn foo(r: Req, b: Body) anyerror!void {
            const obj = b.object;
            const id = obj.get("id") orelse .null;

            const i = r[0];
            i.* += @intCast(id.integer);
            try std.testing.expect(r[1]);
        }
    }.foo;

    const router = try NewRouter(Req).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{ .Extractor = extract });
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", .{ &i, true }, &[_]kv.KeyValue{});
    try std.testing.expectEqual(48, i);
}

test "not found" {
    const NotFound = struct { resp: ?Response([]u8) = null };

    const router = try NewRouter(*NotFound).init(std.testing.allocator, .{}, .{
        .error_handler = struct {
            fn handleError(req: *NotFound, resp: Response([]u8)) void {
                req.resp = resp;
            }
        }.handleError,
    });
    defer router.deinit();

    var notFound = NotFound{};
    router.resolve(.GET, "/not_found", &notFound, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.not_found, notFound.resp.?.status);
    try std.testing.expectEqualStrings("404 Not Found", notFound.resp.?.content.string);
}

test "bad request" {
    const BadRequest = struct {
        resp: ?Response([]u8) = null,
        was_called: bool = false,
    };

    const foo = struct {
        fn foo() !void {
            return error.BAD;
        }
    }.foo;

    const router = try NewRouter(*BadRequest).init(std.testing.allocator, .{
        Route("/foo", get(foo)),
    }, .{
        .error_handler = struct {
            fn handleError(req: *BadRequest, resp: Response([]u8)) void {
                std.testing.expectEqualStrings("400 Bad Request: error.BAD", resp.content.string) catch @panic("test failed");
                req.resp = resp;
                req.was_called = true;
            }
        }.handleError,
    });
    defer router.deinit();

    var badRequest = BadRequest{};
    router.resolve(.GET, "/foo", &badRequest, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.bad_request, badRequest.resp.?.status);
    try std.testing.expectEqual(true, badRequest.was_called);
}

test "two routes for one path" {
    const foo = struct {
        fn foo(i: *i32) void {
            i.* += 1;
        }
    }.foo;

    const router = try NewRouter(*i32).init(
        std.testing.allocator,
        .{
            Route("/foo", .{ get(foo), post(foo) }),
        },
        .{},
    );
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);
    router.resolve(.POST, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(5, i);
}
