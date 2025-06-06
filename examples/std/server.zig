const std = @import("std");

const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const Method = std.http.Method;
const Connection = std.net.Server.Connection;

const zart = @import("zart");

pub const Router = zart.Router(void, std.http.Server.Request, std.http.Method, JsonExtractor);

pub fn handleConnection(router: *const Router, conn: Connection) !void {
    defer conn.stream.close();

    var buffer: [4096]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buffer);
    var req = try http_server.receiveHead();

    const target = req.head.target;
    const indexQuery = std.mem.indexOfPos(u8, target, 0, "?");
    const path = if (indexQuery) |i| target[0..i] else target;

    var vars: [7]zart.KeyValue = undefined;
    const queryStr = if (indexQuery) |i| target[i + 1 ..] else null;
    const size: usize = if (queryStr) |s| parseQueryString(s, &vars) else 0;

    router.resolve(req.head.method, path, req, vars[0..size]);
    // if no response defined, than is simple status .ok returned
    try req.respond("", Request.RespondOptions{ .status = .ok });
}

pub const JsonExtractor = struct {
    pub fn body(T: type, allocator: Allocator, req: Request) !T {
        var r = req;
        const reader = try r.reader();

        return try std.json.parseFromSliceLeaky(T, allocator, try reader.readAllAlloc(allocator, 10 * 1024), .{});
    }

    pub fn response(T: type, allocator: Allocator, req: Request, w: *zart.ResponseWriter, resp: T) !void {
        const content = try std.json.stringifyAlloc(allocator, resp, .{});
        var r = req;
        try r.respond(content, .{ .status = w.status });
    }
};

pub const ErrorHandler = struct {
    pub fn handleError(r: Request, err: zart.HttpError) void {
        var req = r;
        req.respond(err.message, .{ .status = err.status }) catch |e| {
            std.debug.print("error by sending the response: {} ({s})\n", .{ e, @tagName(err.status) });
        };
    }
}.handleError;

// URL encode
// const queryString = try allocator.dupe(u8, input);
// defer allocator.free(queryString);
// const q = std.Uri.percentDecodeInPlace(queryString);
pub fn parseQueryString(input: []const u8, query: []zart.KeyValue) usize {
    if (input.len == 0) {
        return 0;
    }

    var size: usize = 0;

    var iter = std.mem.splitScalar(u8, input, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
            const v = zart.KeyValue{ .key = pair[0..sep], .value = pair[sep + 1 ..] };
            query[size] = v;
            size += 1;
        }
    }

    return size;
}

test "parse query string" {
    var query: [7]zart.KeyValue = undefined;

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
