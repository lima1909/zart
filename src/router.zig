const std = @import("std");

const TreeConfig = @import("tree.zig").Config;

const Response = @import("handler.zig").Response;
const Content = @import("handler.zig").Content;

const kv = @import("kv.zig");

pub const Config = struct {
    parser: kv.parse = kv.matchitParser,
};

///
/// Signature for Extractor:
///   pub fn body(T: type, allocator: std.mem.Allocator, r: Request) !T
///   pub fn response(T: type, allocator: std.mem.Allocator, resp: Response(T), r: Request) !void
/// where T means a struct (the Body)
///
pub fn Router(App: type, Request: type, Extractor: type) type {
    const H = @import("handler.zig").Handler(App, Request);
    const Tree = @import("tree.zig").Tree(H);

    const defaultErrorHandler = struct {
        fn handleError(_: Request, resp: Response([]u8)) void {
            const status = @tagName(resp.status);
            switch (resp.content) {
                .string => |s| std.debug.print("error: {s} ({s})\n", .{ s, status }),
                .strukt => |s| std.debug.print("error: {any} ({s})\n", .{ s, status }),
            }
        }
    }.handleError;

    return struct {
        const Self = @This();

        _app: ?App,
        allocator: std.mem.Allocator,

        // methods
        _get: Tree,
        _post: Tree,
        _other: Tree,

        error_handler: *const fn (Request, Response([]u8)) void = defaultErrorHandler,

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Self {
            return initWithApp(allocator, undefined, cfg);
        }

        pub fn initWithApp(allocator: std.mem.Allocator, app: ?App, cfg: Config) Self {
            const tcfg = TreeConfig{ .parser = cfg.parser };

            return .{
                .allocator = allocator,
                ._app = app,
                ._get = Tree.init(allocator, tcfg),
                ._post = Tree.init(allocator, tcfg),
                ._other = Tree.init(allocator, tcfg),
            };
        }

        pub fn deinit(self: *Self) void {
            self._get.deinit();
            self._post.deinit();
            self._other.deinit();
        }

        pub fn get(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.route(.GET, path, handlerFn);
        }

        pub fn post(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.route(.POST, path, handlerFn);
        }

        pub inline fn route(self: *Self, method: std.http.Method, path: []const u8, handlerFn: anytype) !void {
            const handler = @import("handler.zig").handlerFromFn(
                App,
                Request,
                handlerFn,
                Extractor,
            );
            return try switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.insert(path, handler);
        }

        pub fn resolve(self: *const Self, method: std.http.Method, path: []const u8, req: Request, query: []const kv.KeyValue) void {
            const matched = switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.resolve(path);

            if (matched.value) |handler| {

                // TODO: replace self.allocator
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                handler.handle(self._app, req, query, &matched.kvs, arena.allocator()) catch |err| {
                    // BAD REQUEST handler
                    var buffer: [50]u8 = undefined;
                    const error_msg = std.fmt.bufPrint(&buffer, "{s}{}", .{ "400 Bad Request: ", err }) catch "400 Bad Request";

                    self.error_handler(req, Response([]u8){
                        .status = .bad_request,
                        .content = .{ .string = error_msg },
                    });
                };
                return;
            }

            // NOT FOUND handler
            self.error_handler(req, Response([]u8){
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

    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn user(u: ReqObject) void {
            u.i.* += 1;
        }
    }.user);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});

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

    var router = Router(*App, *i32, void).initWithApp(std.testing.allocator, &app, .{});
    defer router.deinit();

    try router.route(.HEAD, "/foo", struct {
        fn addOne(a: *App, i: *i32, _: Params) anyerror!void {
            a.value = i.* + 2;
            i.* += 1;
        }
    }.addOne);

    var i: i32 = 3;
    _ = router.resolve(.OPTIONS, "/foo", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(4, i);
    try std.testing.expectEqual(5, app.value);
}

const HttpRequest = std.http.Server.Request;

test "router std.http.Server.Request" {
    var router = Router(void, *HttpRequest, void).init(std.testing.allocator, .{});
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

    _ = router.resolve(.POST, "/user/42", &req, &[_]kv.KeyValue{});

    // the user function set keep_alive = true
    try std.testing.expectEqual(true, req.head.keep_alive);
}

test "router for struct params" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    const Ok = struct { ok: bool };

    try router.route(.GET, "/foo/:ok", struct {
        fn get(i: *i32, p: P(Ok)) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(true, p.ok);
        }
    }.get);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo/true", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(4, i);
}

test "router for params" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.route(.POST, "/foo/:id", struct {
        fn addOne(i: *i32, p: Params) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(42, p.valueAs(i32, "id"));
        }
    }.addOne);

    var i: i32 = 3;
    _ = router.resolve(.POST, "/foo/42", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(4, i);
}

test "first Params, than request" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo/:id", struct {
        fn foo(p: Params, i: *i32) anyerror!void {
            i.* += (try p.valueAs(i32, "id")).?;
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo/42", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(45, i);
}

test "with query" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(q: Query, i: *i32) anyerror!void {
            i.* += (try q.valueAs(i32, "id")).?;
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{.{ .key = "id", .value = "42" }});

    try std.testing.expectEqual(45, i);
}

test "with Q" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    const Id = struct { id: i32 };

    try router.get("/foo", struct {
        fn foo(q: Q(Id), i: *i32) anyerror!void {
            i.* += q.id;
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{.{ .key = "id", .value = "42" }});

    try std.testing.expectEqual(45, i);
}

test "with B" {
    const Id = struct { id: i32 };
    const extract = struct {
        pub fn body(T: type, _: std.mem.Allocator, _: *i32) !T {
            return B(Id){ .id = 42 };
        }
    };

    var router = Router(void, *i32, extract).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(b: B(Id), i: *i32) anyerror!void {
            i.* += b.id;
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(45, i);
}

test "with Body" {
    const extract = struct {
        pub fn body(T: type, allocator: std.mem.Allocator, _: *i32) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 42}", .{});
        }
    };

    var router = Router(void, *i32, extract).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(b: Body, i: *i32) anyerror!void {
            const obj = b.object;
            const id = obj.get("id") orelse .null;
            i.* += @intCast(id.integer);
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});

    try std.testing.expectEqual(45, i);
}

test "request with two args" {
    const Req = struct { *i32, bool };

    const extract = struct {
        pub fn body(T: type, allocator: std.mem.Allocator, _: Req) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 45}", .{});
        }
    };

    var router = Router(void, Req, extract).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(r: Req, b: Body) anyerror!void {
            const obj = b.object;
            const id = obj.get("id") orelse .null;

            const i = r[0];
            i.* += @intCast(id.integer);
            try std.testing.expect(r[1]);
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.GET, "/foo", .{ &i, true }, &[_]kv.KeyValue{});

    try std.testing.expectEqual(48, i);
}

test "not found" {
    const NotFound = struct { resp: ?Response([]u8) = null };

    var router = Router(void, *NotFound, void).init(std.testing.allocator, .{});
    defer router.deinit();

    router.error_handler = struct {
        fn handleError(req: *NotFound, resp: Response([]u8)) void {
            req.resp = resp;
        }
    }.handleError;

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

    var router = Router(void, *BadRequest, void).init(std.testing.allocator, .{});
    defer router.deinit();

    router.error_handler = struct {
        fn handleError(req: *BadRequest, resp: Response([]u8)) void {
            std.testing.expectEqualStrings("400 Bad Request: error.BAD", resp.content.string) catch @panic("test failed");
            req.resp = resp;
            req.was_called = true;
        }
    }.handleError;

    try router.get("/foo", struct {
        fn foo() !void {
            return error.BAD;
        }
    }.foo);

    var badRequest = BadRequest{};
    router.resolve(.GET, "/foo", &badRequest, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.bad_request, badRequest.resp.?.status);
    try std.testing.expectEqual(true, badRequest.was_called);
}
