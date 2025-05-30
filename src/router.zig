const std = @import("std");
const Allocator = std.mem.Allocator;

const kv = @import("kv.zig");

pub fn Config(Request: type) type {
    return struct {
        const ErrorHandler = *const fn (Request, HttpError) void;

        error_handler: ?ErrorHandler = null,

        ///
        /// Signature for Extractor:
        ///   pub fn body(T: type, allocator: std.mem.Allocator, r: Request) !T
        ///   pub fn response(T: type, allocator: std.mem.Allocator, r: Request, resp: Response(T)) !void
        Extractor: type = void,
        ///
        /// set the Method enum if it is not from the std lib
        Method: type = std.http.Method,
        ///
        /// set the type of the Middleware-Context
        MiddlewareContext: type = void,

        parser: kv.parse = kv.matchitParser,
    };
}

pub const HttpError = struct {
    status: std.http.Status,
    message: []u8,

    pub fn withStringMessage(buffer: []u8, status: std.http.Status, msg: []const u8, err: anyerror) HttpError {
        return .{
            .status = status,
            .message = std.fmt.bufPrint(buffer, "{d} {s}: {}", .{ @intFromEnum(status), msg, err }) catch @constCast(msg),
        };
    }
};

/// A Route is a 'path' and one or more 'handles'
/// A 'handles' is a 'method' and a 'hanlder function'
/// example:
///     Route('/users', .{ .GET, users })                            // one Handle
///     Route('/users', .{ .{ .GET, users }, .{ .POST, users }  })   // List of two Handles
///     Route('/users', .{ get(users), post(users) })                // List of two Handles
pub fn Route(path: []const u8, handlers: anytype) struct { path: []const u8, handles: @TypeOf(handlers) } {
    return .{ .path = path, .handles = handlers };
}

fn Builder(Request: type) type {
    return struct {
        const Self = @This();
        config: Config(Request) = .{},

        pub fn withConfig(_: Self, config: Config(Request)) Self {
            return .{
                .config = config,
            };
        }

        pub fn init(self: Self, allocator: Allocator, routes: anytype) !Router(
            void,
            Request,
            self.config.Method,
            self.config.MiddlewareContext,
        ) {
            return try Router(
                void,
                Request,
                self.config.Method,
                self.config.MiddlewareContext,
            ).init(allocator, null, routes, self.config);
        }

        pub fn initWithApp(self: Self, allocator: Allocator, app: anytype, routes: anytype) !Router(
            @TypeOf(app),
            Request,
            self.config.Method,
            self.config.MiddlewareContext,
        ) {
            return try Router(
                @TypeOf(app),
                Request,
                self.config.Method,
                self.config.MiddlewareContext,
            ).init(allocator, app, routes, self.config);
        }
    };
}

/// A Builder to create an configure a desired Router.
pub fn NewRouter(Request: type) Builder(Request) {
    return Builder(Request){};
}

pub fn Router(App: type, Request: type, Method: type, MiddlewareContext: type) type {

    // default error handler
    const DefaultErrorHandler = struct {
        fn handleError(_: Request, err: HttpError) void {
            std.debug.print("error: {s} ({s})\n", .{ err.message, @tagName(err.status) });
        }
    };

    return struct {
        const ResponseWriter = @import("handler.zig").ResponseWriter;
        const Middleware = @import("middleware.zig").Middleware(MiddlewareContext, Request);
        const Executor = @import("middleware.zig").Executor(MiddlewareContext, Request);

        const Self = @This();

        app: ?App,
        trees: Trees(App, Request, Method),
        error_handler: Config(Request).ErrorHandler,
        middlewars: []const Middleware = &.{},

        fn init(allocator: Allocator, app: ?App, routes: anytype, cfg: Config(Request)) !Self {
            var self = Self{
                .app = app,
                .trees = Trees(App, Request, Method){},
                .error_handler = cfg.error_handler orelse DefaultErrorHandler.handleError,
            };

            inline for (routes) |r| {
                if (@typeInfo(@TypeOf(r.handles[0])) == .enum_literal) {
                    const handler = @import("handler.zig").handlerFromFn(
                        App,
                        Request,
                        r.handles[1],
                        cfg.Extractor,
                    );
                    try self.trees.write(allocator, r.handles[0], cfg.parser).insert(r.path, handler);
                } else {
                    inline for (r.handles) |h| {
                        const handler = @import("handler.zig").handlerFromFn(
                            App,
                            Request,
                            h[1],
                            cfg.Extractor,
                        );
                        try self.trees.write(allocator, h[0], cfg.parser).insert(r.path, handler);
                    }
                }
            }

            return self;
        }

        pub fn deinit(self: Self) void {
            self.trees.deinit();
        }

        pub fn withMiddlewares(self: *Self, middlewares: []const Middleware) void {
            self.middlewars = middlewares;
        }

        pub fn resolve(self: *const Self, method: Method, path: []const u8, req: Request, query: []const kv.KeyValue) void {
            const tree = self.trees.read(method) orelse {
                return self.error_handler(req, .{ .status = .method_not_allowed, .message = @constCast("405 Method Not Allowed") });
            };

            const matched = tree.resolve(path);
            if (matched.value) |handler| {
                // TODO: can I do it better?
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                var arena = std.heap.ArenaAllocator.init(gpa.allocator());
                defer arena.deinit();

                const exec = Executor{
                    .context = {},
                    .request = &req,
                    .middlewares = self.middlewars,
                };
                _ = exec;

                var w = ResponseWriter{};
                return handler.handle(arena.allocator(), self.app, req, &w, query, &matched.kvs) catch |err| {
                    var buffer: [50]u8 = undefined;
                    self.error_handler(req, HttpError.withStringMessage(&buffer, .bad_request, "Bad Request", err));
                };
            }

            self.error_handler(req, .{ .status = .not_found, .message = @constCast("404 Not Found") });
        }
    };
}

pub fn Trees(App: type, Request: type, Method: type) type {
    const H = @import("handler.zig").Handler(App, Request);
    const Tree = @import("tree.zig").Tree(H);

    const ms = struct {
        const methods = std.enums.values(Method);
        const len = methods.len;

        inline fn index(method: Method) u4 {
            inline for (methods, 0..) |m, i| {
                if (m == method) {
                    return @intCast(i);
                }
            }

            // should never happen
            std.debug.panic("Not supported HTTP-Method: {}", .{method});
        }
    };

    return struct {
        const Self = @This();
        trees: [ms.len]?Tree = .{null} ** ms.len,

        fn deinit(self: Self) void {
            inline for (self.trees) |tree| {
                if (tree) |t| {
                    t.deinit();
                }
            }
        }

        fn write(self: *Self, allocator: Allocator, comptime method: Method, parser: kv.parse) *Tree {
            const idx = ms.index(method);

            if (self.trees[idx] == null) {
                self.trees[idx] = Tree.init(allocator, .{ .parser = parser });
            }

            return &self.trees[idx].?;
        }

        fn read(self: *const Self, method: Method) ?*const Tree {
            const idx = ms.index(method);
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
    });
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
    });
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
    });
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
    });
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
    });
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
    });
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
    });
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
    });
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

    const router = try NewRouter(*i32).withConfig(.{ .Extractor = extract }).init(std.testing.allocator, .{
        Route("/foo", .{ .GET, foo }),
    });
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

    const router = try NewRouter(*i32).withConfig(.{ .Extractor = extract }).init(std.testing.allocator, .{
        Route("/foo", &.{ .GET, foo }),
    });
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

    const router = try NewRouter(Req).withConfig(.{ .Extractor = extract }).init(std.testing.allocator, .{
        Route("/foo", .{ .GET, foo }),
    });
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", .{ &i, true }, &[_]kv.KeyValue{});
    try std.testing.expectEqual(48, i);
}

test "not found" {
    const NotFound = struct { err: ?HttpError = null };

    const foo = struct {
        fn foo() void {
            return;
        }
    }.foo;

    const router = try NewRouter(*NotFound)
        .withConfig(.{
            .error_handler = struct {
                fn handleError(req: *NotFound, err: HttpError) void {
                    req.err = err;
                }
            }.handleError,
        })
        .init(
        std.testing.allocator,
        .{
            Route("/foo", .{ .GET, foo }),
        },
    );
    defer router.deinit();

    var notFound = NotFound{};
    router.resolve(.GET, "/not_found", &notFound, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.not_found, notFound.err.?.status);
    try std.testing.expectEqualStrings("404 Not Found", notFound.err.?.message);

    // for POST is no tree
    router.resolve(.POST, "/not_found", &notFound, &[_]kv.KeyValue{});

    try std.testing.expectEqual(.method_not_allowed, notFound.err.?.status);
    try std.testing.expectEqualStrings("405 Method Not Allowed", notFound.err.?.message);
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

    const router = try NewRouter(*BadRequest)
        .withConfig(.{
            .error_handler = struct {
                fn handleError(req: *BadRequest, err: HttpError) void {
                    std.testing.expectEqualStrings("400 Bad Request: error.BAD", err.message) catch @panic("test failed");
                    req.status = err.status;
                    req.was_called = true;
                }
            }.handleError,
        })
        .init(
        std.testing.allocator,
        .{
            Route("/foo", .{ .GET, foo }),
        },
    );
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
    );
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);
    router.resolve(.POST, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(5, i);
}

test "with Middleware" {
    const foo = struct {
        fn foo(i: *i32) void {
            i.* += 1;
        }
    }.foo;

    const R = Router(void, *i32, std.http.Method, void);
    const M = struct {
        const Self = @This();

        pub fn execute(ptr: *anyopaque, c: *void, r: *const *i32, w: *R.ResponseWriter, exec: *R.Executor) anyerror!void {
            _ = ptr;
            _ = c;
            _ = r;
            _ = w;

            try exec.next();
        }

        fn middleware(self: *Self) R.Middleware {
            return .{
                .ptr = self,
                .executeFn = execute,
            };
        }
    };

    var m = M{};
    var router = try NewRouter(*i32).init(
        std.testing.allocator,
        .{
            Route("/foo", .{get(foo)}),
        },
    );
    router.withMiddlewares(&[_]R.Middleware{m.middleware()});
    defer router.deinit();

    var i: i32 = 3;
    router.resolve(.GET, "/foo", &i, &[_]kv.KeyValue{});
    try std.testing.expectEqual(4, i);
}
