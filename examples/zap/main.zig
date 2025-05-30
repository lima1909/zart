//!
//! Run:  zig build zap
//!
const std = @import("std");
const zap = @import("zap");
const zart = @import("zart");
const KeyValue = @import("zart").kv.KeyValue;

pub const JsonExtractor = struct {
    // create parameter objects
    pub fn body(T: type, allocator: std.mem.Allocator, r: zap.Request) !T {
        return try std.json.parseFromSliceLeaky(T, allocator, r.body, .{});
    }

    // create response strings
    pub fn response(T: type, allocator: std.mem.Allocator, r: zap.Request, resp: zart.Response(T)) !void {
        const content = try std.json.stringifyAlloc(allocator, resp.body_content, .{});
        try r.sendJson(content);
    }
};

// create your own error-handler
pub const ErrorHandler = struct {
    pub fn handleError(r: zap.Request, resp: zart.Response([]u8)) void {
        r.setStatus(@enumFromInt(@intFromEnum(resp.status)));
        r.sendBody(resp.body_content) catch |err| {
            std.debug.print("error by sending the response: {} ({s})\n", .{ err, @tagName(resp.status) });
        };
    }
}.handleError;

var router: zart.Router(void, zap.Request, zap.http.Method) = undefined;

fn on_request(r: zap.Request) !void {
    router.resolve(r.methodAsEnum(), r.path.?, r, &.{});
}

// a simple handler which return a static string
fn index() []const u8 {
    return "index";
}

// a second handler which return a static string
fn staticStr(r: zap.Request) !void {
    try r.sendBody("hello world");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    router = try zart.NewRouter(zap.Request)
        .withConfig(.{
            .Extractor = JsonExtractor,
            .error_handler = ErrorHandler,
            .Method = zap.http.Method,
        })
        .init(
        allocator,
        .{
            zart.Route("/", .{ .GET, index }),
            zart.Route("/", .{ .POST, index }),
            zart.Route("/str", .{ .GET, staticStr }),
        },
    );
    defer router.deinit();

    var listener = zap.HttpListener.init(.{
        .on_request = on_request,
        .port = 3000,
        .log = false,
        .max_clients = 100,
    });
    try listener.listen();
    std.debug.print("Listening on 127.0.0.1:3000\n", .{});

    zap.start(.{ .threads = 4, .workers = 4 });
}
