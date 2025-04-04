const std = @import("std");

const handlerFromFn = @import("request.zig").handlerFromFn;
const OnRequest = @import("request.zig").OnRequest;
const Response = @import("request.zig").Response;

const TreeConfig = @import("tree.zig").Config;
const kv = @import("kv.zig");

pub const Config = struct {
    parser: kv.parse = kv.matchitParser,
};

///
/// signature for decodeFn: fn decode(T: type, req: Request, allocator: std.mem.Allocator) !T {
/// where T)means a struct with a value field
///
pub fn Router(App: type, Request: type, decodeFn: anytype) type {
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
        error_handler: ?*const fn (Request) Response = null,
        // not_found_handler
        not_found: ?*const fn (Request) Response = null,

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
            const handler = handlerFromFn(
                App,
                Request,
                handlerFn,
                decodeFn,
            );
            return try switch (method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.insert(path, handler);
        }

        pub fn resolve(self: *const Self, req: OnRequest(Request)) ?Response {
            const matched = switch (req.method) {
                .GET => self._get,
                .POST => self._post,
                else => self._other,
            }.resolve(req.path);

            if (matched.value) |handler| {

                // TODO: replace self.allocator
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                return handler.handle(self._app, req.request, req.query, &matched.kvs, arena.allocator()) catch |err| {
                    // handle error
                    if (self.error_handler) |eh| {
                        return eh(req.request);
                    }

                    var buffer: [50]u8 = undefined;
                    _ = std.fmt.bufPrint(&buffer, "{s}{any}", .{ "ERROR in handler: ", err }) catch "ERROR in handler";
                    return .{ .status = .bad_request, .content = "ERROR in handler" };
                };
            }

            // NOT FOUND handler
            return if (self.not_found) |nf|
                nf(req.request)
            else
                .{ .status = .not_found };
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
    _ = router.resolve(.{ .method = .GET, .path = "/foo", .request = &i });

    try std.testing.expectEqual(4, i);
}

const P = @import("request.zig").P;
const Q = @import("request.zig").Q;
const B = @import("request.zig").B;
const Params = @import("request.zig").Params;
const Query = @import("request.zig").Query;
const Body = @import("request.zig").Body;

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
    _ = router.resolve(.{ .method = .OPTIONS, .path = "/foo", .request = &i });

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

    _ = router.resolve(.{ .method = .POST, .path = "/user/42", .request = &req });

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
    _ = router.resolve(.{ .method = .GET, .path = "/foo/true", .request = &i });

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
    _ = router.resolve(.{ .method = .POST, .path = "/foo/42", .request = &i });

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
    _ = router.resolve(.{ .method = .GET, .path = "/foo/42", .request = &i });

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
    _ = router.resolve(.{
        .method = .GET,
        .path = "/foo",
        .query = &[_]kv.KeyValue{.{ .key = "id", .value = "42" }},
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
    _ = router.resolve(.{
        .method = .GET,
        .path = "/foo",
        .query = &[_]kv.KeyValue{.{ .key = "id", .value = "42" }},
        .request = &i,
    });

    try std.testing.expectEqual(45, i);
}

test "with B" {
    const Id = struct { id: i32 };
    const decoder = struct {
        pub fn decode(T: type, _: *i32, _: std.mem.Allocator) !T {
            return B(Id){ .id = 42 };
        }
    }.decode;

    var router = Router(void, *i32, decoder).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(b: B(Id), i: *i32) anyerror!void {
            i.* += b.id;
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.{ .method = .GET, .path = "/foo", .request = &i });

    try std.testing.expectEqual(45, i);
}

test "with Body" {
    const decoder = struct {
        pub fn decode(T: type, _: *i32, allocator: std.mem.Allocator) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 42}", .{});
        }
    }.decode;

    var router = Router(void, *i32, decoder).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo(b: Body, i: *i32) anyerror!void {
            const obj = b.object;
            const id = obj.get("id") orelse .null;
            i.* += @intCast(id.integer);
        }
    }.foo);

    var i: i32 = 3;
    _ = router.resolve(.{ .method = .GET, .path = "/foo", .request = &i });

    try std.testing.expectEqual(45, i);
}

test "request with two args" {
    const Req = struct { *i32, bool };

    const decoder = struct {
        pub fn decode(T: type, _: Req, allocator: std.mem.Allocator) !T {
            return try std.json.parseFromSliceLeaky(T, allocator, "{\"id\": 45}", .{});
        }
    }.decode;

    var router = Router(void, Req, decoder).init(std.testing.allocator, .{});
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
    _ = router.resolve(.{ .method = .GET, .path = "/foo", .request = .{ &i, true } });

    try std.testing.expectEqual(48, i);
}

test "not found" {
    var router = Router(void, struct {}, null).init(std.testing.allocator, .{});
    defer router.deinit();

    const response = router.resolve(.{ .method = .GET, .path = "/not_found", .request = .{} });

    try std.testing.expectEqual(.not_found, response.?.status);
}

test "bad request" {
    var router = Router(void, struct {}, null).init(std.testing.allocator, .{});
    defer router.deinit();

    try router.get("/foo", struct {
        fn foo() !void {
            return error.BAD;
        }
    }.foo);

    const response = router.resolve(.{ .method = .GET, .path = "/foo", .request = .{} });

    const r = response.?;
    try std.testing.expectEqual(.bad_request, r.status);
    try std.testing.expectEqualStrings("ERROR in handler", r.content.?);
    // std.debug.print("-- {s}\n", .{r.content.?});
}
