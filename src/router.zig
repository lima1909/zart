const std = @import("std");
const Allocator = std.mem.Allocator;

const kv = @import("kv.zig");
const Response = @import("handler.zig").Response;

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

/// A Route is a 'path' and one or more 'handles'
/// A 'handles' is a 'method' and a 'hanlder function'
/// example:
///     Route('/users', .{ .GET, users })                            // one Handle
///     Route('/users', .{ .{ .GET, users }, .{ .POST, users }  })   // List of two Handles
///     Route('/users', .{ get(users), post(users) })                // List of two Handles
pub fn Route(path: []const u8, handles: anytype) struct { path: []const u8, handles: @TypeOf(handles) } {
    return .{ .path = path, .handles = handles };
}

pub fn NewRouter(Request: type) type {
    return struct {
        pub fn init(allocator: Allocator, routes: anytype, cfg: Config(Request)) !Router(void, Request) {
            return try Router(void, Request).init(allocator, null, routes, cfg);
        }

        pub fn initWithApp(allocator: Allocator, app: anytype, routes: anytype, cfg: Config(Request)) !Router(@TypeOf(app), Request) {
            return try Router(@TypeOf(app), Request).init(allocator, app, routes, cfg);
        }
    };
}

pub fn Router(App: type, Request: type) type {
    // NOT FOUND error
    const NOT_FOUND = Response([]u8){
        .status = .not_found,
        .body_content = @constCast("404 Not Found"),
    };

    // default error handler
    const defaultErrorHandler = struct {
        fn handleError(_: Request, resp: Response([]u8)) void {
            const status = @tagName(resp.status);
            std.debug.print("error: {any} ({s})\n", .{ resp.body_content, status });
        }
    }.handleError;

    return struct {
        const Self = @This();

        app: ?App,
        trees: Trees(App, Request),
        error_handler: *const fn (Request, Response([]u8)) void,

        fn init(allocator: Allocator, app: ?App, routes: anytype, cfg: Config(Request)) !Self {
            var self = Self{
                .app = app,
                .trees = Trees(App, Request).init(cfg),
                .error_handler = cfg.error_handler orelse defaultErrorHandler,
            };

            inline for (routes) |r| {
                if (@typeInfo(@TypeOf(r.handles[0])) == .enum_literal) {
                    const handler = @import("handler.zig").handlerFromFn(
                        App,
                        Request,
                        r.handles[1],
                        cfg.Extractor,
                    );
                    try self.trees.write(r.handles[0], allocator).insert(r.path, handler);
                } else {
                    inline for (r.handles) |h| {
                        const handler = @import("handler.zig").handlerFromFn(
                            App,
                            Request,
                            h[1],
                            cfg.Extractor,
                        );
                        try self.trees.write(h[0], allocator).insert(r.path, handler);
                    }
                }
            }

            return self;
        }

        pub fn deinit(self: Self) void {
            self.trees.deinit();
        }

        pub fn resolve(self: *const Self, method: anytype, path: []const u8, req: Request, query: []const kv.KeyValue) void {
            const tree = self.trees.read(method) orelse {
                self.error_handler(req, NOT_FOUND);
                return;
            };

            const matched = tree.resolve(path);
            if (matched.value) |handler| {
                // TODO: can I do it better?
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                var arena = std.heap.ArenaAllocator.init(gpa.allocator());
                defer arena.deinit();

                handler.handle(self.app, req, query, &matched.kvs, arena.allocator()) catch |err| {
                    var buffer: [50]u8 = undefined;
                    self.error_handler(req, .{
                        .status = .bad_request,
                        .body_content = std.fmt.bufPrint(&buffer, "{s}{}", .{ "400 Bad Request: ", err }) catch @constCast("400 Bad Request"),
                    });
                };
                return;
            }

            self.error_handler(req, NOT_FOUND);
        }
    };
}

pub fn Trees(App: type, Request: type) type {
    const H = @import("handler.zig").Handler(App, Request);
    const Tree = @import("tree.zig").Tree(H);
    const TreeCfg = @import("tree.zig").Config;

    return struct {
        const Self = @This();

        treeCfg: TreeCfg,
        trees: [9]?Tree = .{null} ** 9,

        fn init(cfg: Config(Request)) Self {
            return .{
                .treeCfg = .{ .parser = cfg.parser },
            };
        }

        fn deinit(self: Self) void {
            inline for (self.trees) |tree| {
                if (tree) |t| {
                    t.deinit();
                }
            }
        }

        const INVALID_INDEX: u8 = 100;

        inline fn index(method: anytype) u8 {
            return switch (method) {
                .GET => 0,
                .POST => 1,
                .PATCH => 2,
                .PUT => 3,
                .DELETE => 4,
                .HEAD => 5,
                .CONNECT => 6,
                .OPTIONS => 7,
                .TRACE => 8,
                else => INVALID_INDEX,
            };
        }

        fn write(self: *Self, method: @TypeOf(.enum_literal), allocator: Allocator) *Tree {
            const idx = index(method);
            if (idx == INVALID_INDEX) {
                @compileError("Not supported HTTP-Method: " ++ @tagName(method));
            }

            if (self.trees[idx] == null) {
                self.trees[idx] = Tree.init(allocator, self.treeCfg);
            }
            return &self.trees[idx].?;
        }

        fn read(self: *const Self, method: anytype) ?*const Tree {
            const idx = index(method);
            if (idx == INVALID_INDEX) {
                @panic("Not supported HTTP-Method");
            }

            return if (self.trees[idx]) |t| &t else null;
        }
    };
}

pub fn Handle(func: anytype) type {
    return struct {
        @TypeOf(.enum_literal),
        @TypeOf(func),
    };
}

pub fn get(func: anytype) Handle(func) {
    return .{ .GET, func };
}

pub fn post(func: anytype) Handle(func) {
    return .{ .POST, func };
}

pub fn patch(func: anytype) Handle(func) {
    return .{ .PATCH, func };
}

pub fn put(func: anytype) Handle(func) {
    return .{ .PUT, func };
}

pub fn delete(func: anytype) Handle(func) {
    return .{ .DELETE, func };
}

pub fn head(func: anytype) Handle(func) {
    return .{ .HEAD, func };
}

pub fn connect(func: anytype) Handle(func) {
    return .{ .CONNECT, func };
}

pub fn options(func: anytype) Handle(func) {
    return .{ .OPTIONS, func };
}

pub fn trace(func: anytype) Handle(func) {
    return .{ .TRACE, func };
}

// ========================== TESTS =============================
const arg = @import("handler.zig").arg;
const P = arg.P;
const Q = arg.Q;
const B = arg.B;
const Params = arg.Params;
const Query = arg.Query;
const Body = arg.Body;

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
        Route("/foo", .{ get(user), post(user) }),
        .{ .path = "/bar", .handles = .{ .GET, user } },
    }, .{});
    defer router.deinit();

    var i: i32 = 3;

    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);

    router.resolve(.GET, "/bar", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(5, i);
}

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
        Route("/foo", .{ .HEAD, addOne }),
    }, .{});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.HEAD, "/foo", &i, &[_]kv.KeyValue{});

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
            try std.testing.expectEqual(.GET, req.head.method);
        }
    }.user;

    const router = try NewRouter(*HttpRequest).init(std.testing.allocator, .{
        Route("/user/:id", .{ .PATCH, user }),
    }, .{});
    defer router.deinit();

    var req = HttpRequest{
        .server = undefined,
        .head_end = 0,
        .reader_state = undefined,
        .head = std.http.Server.Request.Head{
            .target = "/user/42",
            .method = .GET,
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
        Route("/foo/:ok", .{ .DELETE, addOne }),
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
        Route("/foo/:id", .{post(addOne)}),
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
        Route("/foo/:id", &.{get(foo)}),
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
        Route("/foo", .{ .GET, foo }),
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
        Route("/foo", .{ .GET, foo }),
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
        Route("/foo", .{ .GET, foo }),
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
        Route("/foo", &.{ .GET, foo }),
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
        Route("/foo", .{ .GET, foo }),
    }, .{ .Extractor = extract });
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", .{ &i, true }, &[_]kv.KeyValue{});
    try std.testing.expectEqual(48, i);
}

test "not found" {
    const NotFound = struct { resp: ?Response([]u8) = null };

    const foo = struct {
        fn foo() void {
            return;
        }
    }.foo;

    const router = try NewRouter(*NotFound).init(std.testing.allocator, .{
        Route("/foo", .{ .GET, foo }),
    }, .{
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
    try std.testing.expectEqualStrings("404 Not Found", notFound.resp.?.body_content);

    // for POST is no tree
    router.resolve(.POST, "/not_found", &notFound, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.not_found, notFound.resp.?.status);
    try std.testing.expectEqualStrings("404 Not Found", notFound.resp.?.body_content);
}

test "bad request" {
    const BadRequest = struct {
        status: std.http.Status = .ok,
        was_called: bool = false,
    };

    const foo = struct {
        fn foo() !void {
            return error.BAD;
        }
    }.foo;

    const router = try NewRouter(*BadRequest).init(std.testing.allocator, .{
        Route("/foo", .{ .GET, foo }),
    }, .{
        .error_handler = struct {
            fn handleError(req: *BadRequest, resp: Response([]u8)) void {
                // std.debug.print("-- {s}\n", .{resp.body_content});
                std.testing.expectEqualStrings("400 Bad Request: error.BAD", resp.body_content) catch @panic("test failed");
                req.status = resp.status;
                req.was_called = true;
            }
        }.handleError,
    });
    defer router.deinit();

    var badRequest = BadRequest{};
    router.resolve(.GET, "/foo", &badRequest, &[_]kv.KeyValue{});

    try std.testing.expectEqual(true, badRequest.was_called);
    try std.testing.expectEqual(.bad_request, badRequest.status);
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
