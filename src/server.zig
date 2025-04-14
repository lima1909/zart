const std = @import("std");
const http = std.http;

const KeyValue = @import("kv.zig").KeyValue;
const Response = @import("handler.zig").Response;

pub fn Server(comptime App: type) type {
    const Router = @import("router.zig").Router(App, http.Server.Request, JsonExtractor);

    return struct {
        const Self = @This();

        _router: Router,
        _server: ?std.net.Server = undefined,

        pub fn init(allocator: std.mem.Allocator) Self {
            var r = Router.init(allocator, .{});
            r.error_handler = ErrorHandler.handleError;

            return .{ ._router = r };
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

            var buffer: [4096]u8 = undefined;
            var http_server = http.Server.init(conn, &buffer);
            var req = try http_server.receiveHead();

            const target = req.head.target;
            const indexQuery = std.mem.indexOfPos(u8, target, 0, "?");
            const path = if (indexQuery) |i| target[0..i] else target;

            var vars: [7]KeyValue = undefined;
            const queryStr = if (indexQuery) |i| target[i + 1 ..] else null;
            const size: usize = if (queryStr) |s| parseQueryString(s, &vars) else 0;

            r.resolve(req.head.method, path, req, vars[0..size]);
            // if no response defined, than is simple status .ok returned
            try req.respond("", http.Server.Request.RespondOptions{ .status = .ok });
        }
    };
}

pub const JsonExtractor = struct {
    pub fn body(T: type, allocator: std.mem.Allocator, req: http.Server.Request) !T {
        var r = req;
        const reader = try r.reader();

        return try std.json.parseFromSliceLeaky(T, allocator, try reader.readAllAlloc(allocator, 10 * 1024), .{});
    }

    pub fn response(T: type, allocator: std.mem.Allocator, req: http.Server.Request, resp: Response(T)) !void {
        const content = switch (resp.content) {
            .strukt => |s| try std.json.stringifyAlloc(allocator, s, .{}),
            .string => |s| s,
        };

        var r = req;
        try r.respond(content, .{ .status = resp.status });
    }
};

const ErrorHandler = struct {
    fn handleError(r: http.Server.Request, resp: Response([]u8)) void {
        const content = switch (resp.content) {
            .string => |s| s,
            .strukt => "could not send struct content",
        };

        var req = r;
        req.respond(content, .{ .status = resp.status }) catch |err| {
            std.debug.print("error by sending the response: {} ({s})\n", .{ err, @tagName(resp.status) });
        };
    }
};

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
