const std = @import("std");
const http = std.http;

const zart = @import("zart.zig");
const arg = zart.handler.arg;
const Route = zart.Route;
const get = zart.router.get;
const post = zart.router.post;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const router = try zart.NewRouter(http.Server.Request).init(allocator, .{
        Route("/user/:id", .{ .GET, user }),
        Route("/value", .{ get(value), post(value) }),
        Route("/", .{get(staticStr)}),
        Route("/number", .{get(staticNumber)}),
    }, .{
        .Extractor = zart.server.JsonExtractor,
        .error_handler = zart.server.ErrorHandler.handleError,
    });
    defer router.deinit();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
    var listener = try addr.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });
    defer listener.deinit();
    std.debug.print("Listening on {}\n", .{addr});

    while (true) {
        try zart.server.handleConnection(void, &router, try listener.accept());
    }
}

const ID = struct { id: i32 };

//
// curl -X GET http://localhost:8080/user/42?foo=bar -d '{"id": 41}'
//
fn user(r: http.Server.Request, p: arg.Params, q: arg.Query, b: arg.B(ID)) ID {
    std.debug.print("Method: {}\n", .{r.head.method});
    if (p.value("id")) |v| {
        std.debug.print("- Param ID: {s}\n", .{v});
    }

    if (q.value("foo")) |v| {
        std.debug.print("- Query Foo: {s} ({d})\n", .{ v, q.kvs.len });
    }

    // std.debug.print("- Body ID: {d}\n", .{b.id});
    return .{ .id = b.id };
}

//
// curl -X GET http://localhost:8080/value -d '{"id": 41}'
//
fn value(b: arg.Body) !void {
    const obj = b.object;
    const id = obj.get("id") orelse .null;
    std.debug.print("- Body ID: {}\n", .{id.integer});
}

//
// curl -X GET http://localhost:8080/
//
fn staticStr() []const u8 {
    return "hello world";
}

//
// curl -X GET http://localhost:8080/number
//
fn staticNumber() zart.Response(i32) {
    return .{ .body_content = 42 };
}
