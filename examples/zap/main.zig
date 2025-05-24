//!
//! Run:  zig build zap
//!
const std = @import("std");
const zap = @import("zap");
const zart = @import("zart");
const KeyValue = @import("zart").kv.KeyValue;

pub const JsonExtractor = struct {
    pub fn body(T: type, allocator: std.mem.Allocator, r: zap.Request) !T {
        return try std.json.parseFromSliceLeaky(T, allocator, r.body, .{});
    }

    pub fn response(T: type, allocator: std.mem.Allocator, r: zap.Request, resp: zart.Response(T)) !void {
        const content = try std.json.stringifyAlloc(allocator, resp.body_content, .{});
        try r.sendJson(content);
    }
};

pub const ErrorHandler = struct {
    pub fn handleError(r: zap.Request, resp: zart.Response([]u8)) void {
        r.sendBody(resp.body_content) catch |err| {
            std.debug.print("error by sending the response: {} ({s})\n", .{ err, @tagName(resp.status) });
        };
    }
};

var router: zart.Router(void, zap.Request, zap.http.Method) = undefined;

fn on_request(r: zap.Request) !void {
    router.resolve(r.methodAsEnum(), r.path.?, r, &.{});
}

fn staticStr() []const u8 {
    return "hello world";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    router = try zart.NewRouter(zap.Request)
        .withConfig(.{
            .Extractor = JsonExtractor,
            .error_handler = ErrorHandler.handleError,
            .Method = zap.http.Method,
        })
        .init(
        allocator,
        .{
            zart.Route("/", .{ .GET, staticStr }),
            zart.Route("/", .{ .POST, staticStr }),
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
