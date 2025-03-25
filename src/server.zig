const std = @import("std");
const http = @import("std").http;

const OnRequest = @import("router.zig").OnRequest;
const KeyValue = @import("kv.zig").KeyValue;
const Body = @import("request.zig").Body;

pub fn Server(comptime App: type) type {
    const Router = @import("router.zig").Router(App, http.Server.Request);

    return struct {
        const Self = @This();

        _router: Router,
        _server: ?std.net.Server = undefined,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                ._router = Router.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self._router.deinit();
        }

        pub fn router(self: *Self) *Router {
            return &self._router;
        }

        pub fn run(self: *Self) !void {
            const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
            self._server = try addr.listen(.{ .reuse_address = true });
            std.debug.print("Listening on {}\n", .{addr});
            while (true) {
                try handleConnection(&self._router, try self._server.?.accept());
            }
        }

        fn handleConnection(r: *const Router, conn: std.net.Server.Connection) !void {
            defer conn.stream.close();

            var buffer: [1024]u8 = undefined;
            var http_server = std.http.Server.init(conn, &buffer);
            var req = try http_server.receiveHead();

            // var body_buffer: [4]u8 = undefined;
            // const body_len = try (try req.reader()).readAll(&body_buffer);
            // const body = body_buffer[0..body_len];
            //
            // std.debug.print("Received body: {s} | {d}\n", .{ body, body_len });

            var vars: [7]KeyValue = undefined;
            r.resolve(onRequest(req, try req.reader(), &vars));

            // try req.respond("hello world\n", std.http.Server.Request.RespondOptions{});
            try req.respond("", std.http.Server.Request.RespondOptions{ .status = .ok });
        }

        fn onRequest(req: http.Server.Request, reader: std.io.AnyReader, vars: []KeyValue) OnRequest(http.Server.Request) {
            const target = req.head.target;
            const index = std.mem.indexOfPos(u8, target, 0, "?");

            const path = if (index) |i| target[0..i] else target;
            const queryStr = if (index) |i| target[i + 1 ..] else null;
            const size: usize = if (queryStr) |s| parseQueryString(s, vars) else 0;

            return .{
                .method = req.head.method,
                .path = path,
                .query = vars[0..size],
                .body = Body{ .reader = reader },
                .request = req,
            };
        }
    };
}

// URL encode
// const queryString = try allocator.dupe(u8, input);
// defer allocator.free(queryString);
// const q = std.Uri.percentDecodeInPlace(queryString);
pub fn parseQueryString(input: []const u8, query: []KeyValue) usize {
    if (input.len == 0) {
        return 0;
    }

    var size: usize = 0;

    var iter = std.mem.splitScalar(u8, input, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
            const v = KeyValue{ .key = pair[0..sep], .value = pair[sep + 1 ..] };
            query[size] = v;
            size += 1;
        }
    }

    return size;
}

test "parse query string" {
    var query: [7]KeyValue = undefined;

    try std.testing.expectEqual(0, parseQueryString("", &query));

    var size = parseQueryString("foo=true", &query);
    try std.testing.expectEqual(1, size);
    try std.testing.expectEqualStrings("foo", query[0].key);
    try std.testing.expectEqualStrings("true", query[0].value);

    size = parseQueryString("foo=a b&bar=1", &query);
    try std.testing.expectEqual(2, size);
    try std.testing.expectEqualStrings("foo", query[0].key);
    try std.testing.expectEqualStrings("a b", query[0].value);
    try std.testing.expectEqualStrings("bar", query[1].key);
    try std.testing.expectEqualStrings("1", query[1].value);

    size = parseQueryString("foo=", &query);
    try std.testing.expectEqual(1, size);
    try std.testing.expectEqualStrings("foo", query[0].key);
    try std.testing.expectEqualStrings("", query[0].value);

    size = parseQueryString("foo", &query);
    try std.testing.expectEqual(0, size);
}
