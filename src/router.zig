const std = @import("std");

const kv = @import("kv.zig");
const KeyValue = kv.KeyValue;

const Body = @import("request.zig").Body;
const handlerFromFn = @import("request.zig").handlerFromFn;
const OnRequest = @import("request.zig").OnRequest;

const TreeConfig = @import("tree.zig").Config;

pub const Config = struct {
    parser: kv.parse = kv.matchitParser,
};

pub fn Router(comptime App: type, comptime Request: type, decoder: anytype) type {
    const H = @import("request.zig").Handler(App, Request);
    const Tree = @import("tree.zig").Tree(H);

    return struct {
        const Self = @This();

        _app: ?App,

        // methods
        _get: Tree,
        _post: Tree,
        _other: Tree,

        // error_handler
        // not_found_handler

        allocator: std.mem.Allocator,

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
            try self.addPath(.GET, path, handlerFn);
        }

        pub fn post(self: *Self, path: []const u8, handlerFn: anytype) !void {
            try self.addPath(.POST, path, handlerFn);
        }

        pub inline fn addPath(self: *Self, method: std.http.Method, path: []const u8, handlerFn: anytype) !void {
            const handler = handlerFromFn(App, Request, handlerFn, decoder);
            return try switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.insert(path, handler);
        }

        pub fn resolve(self: *const Self, req: OnRequest(Request)) void {
            const matched = switch (req.method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.resolve(req.path);

            if (matched.value) |handler| {
                handler.handle(self._app, req, req.query, &matched.kvs) catch |err| {
                    // TODO: replace this with an error handler
                    std.debug.print("ERROR by call handler: {}\n", .{err});
                };
            }

            // TODO: else NOT FOUND handler
        }
    };
}

pub fn NoDecoder(Request: type, value: anytype) type {
    return struct {
        fn Decoded(T: type) type {
            return struct {
                comptime value: T = value,

                pub fn deinit(_: @This()) void {}
            };
        }

        pub fn decode(_: @This(), T: type, _: OnRequest(Request)) Decoded(T) {
            return Decoded(T){};
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

    var router = Router(void, *i32, null).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn user(u: ReqObject) anyerror!void {
            u.i.* += 1;
        }
    }.user);

    var i: i32 = 3;
    router.resolve(.{ .method = .GET, .path = "/foo", .request = &i });

    try std.testing.expectEqual(4, i);
}

const P = @import("request.zig").P;
const Q = @import("request.zig").Q;
const B = @import("request.zig").B;
const Params = @import("request.zig").Params;
const Query = @import("request.zig").Query;

test "router for i32" {
    const App = struct { value: i32 };
    var app = App{ .value = -1 };

    var router = Router(*App, *i32, void).initWithApp(std.testing.allocator, &app, .{});
    defer router.deinit();

    try router.addPath(.HEAD, "/foo", struct {
        fn addOne(a: *App, i: *i32, _: Params) anyerror!void {
            a.value = i.* + 2;
            i.* += 1;
        }
    }.addOne);

    var i: i32 = 3;
    router.resolve(.{ .method = .OPTIONS, .path = "/foo", .request = &i });

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

    router.resolve(.{ .method = .POST, .path = "/user/42", .request = &req });

    // the user function set keep_alive = true
    try std.testing.expectEqual(true, req.head.keep_alive);
}

test "router for struct params" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    const Ok = struct { ok: bool };

    try router.addPath(.GET, "/foo/:ok", struct {
        fn get(i: *i32, p: P(Ok)) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(true, p.ok);
        }
    }.get);

    var i: i32 = 3;
    router.resolve(.{ .method = .GET, .path = "/foo/true", .request = &i });

    try std.testing.expectEqual(4, i);
}

test "router for params" {
    var router = Router(void, *i32, void).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.addPath(.POST, "/foo/:id", struct {
        fn addOne(i: *i32, p: Params) anyerror!void {
            i.* += 1;
            try std.testing.expectEqual(42, p.valueAs(i32, "id"));
        }
    }.addOne);

    var i: i32 = 3;
    router.resolve(.{ .method = .POST, .path = "/foo/42", .request = &i });

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
    router.resolve(.{ .method = .GET, .path = "/foo/42", .request = &i });

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
    router.resolve(.{
        .method = .GET,
        .path = "/foo",
        .query = &[_]KeyValue{.{ .key = "id", .value = "42" }},
        .request = &i,
    });

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
    router.resolve(.{
        .method = .GET,
        .path = "/foo",
        .query = &[_]KeyValue{.{ .key = "id", .value = "42" }},
        .request = &i,
    });

    try std.testing.expectEqual(45, i);
}

test "with B" {
    const Id = struct { id: i32 };
    const decoder = NoDecoder(*i32, B(Id){ .id = 42 }){};

    var router = Router(void, *i32, decoder).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(b: B(Id), i: *i32) anyerror!void {
            i.* += b.id;
        }
    }.foo);

    var i: i32 = 3;
    router.resolve(.{ .method = .GET, .path = "/foo", .request = &i });

    try std.testing.expectEqual(45, i);
}
