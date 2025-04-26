const std = @import("std");
const http = std.http;

const request = @import("handler.zig");
const Params = request.Params;
const Query = request.Query;
const B = request.B;
const Body = request.Body;

const zart = @import("zart.zig");
const server = @import("server.zig");
const get = @import("router.zig").get;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const router = try zart.NewRouter(http.Server.Request).init(allocator, .{
        zart.Route("/user/:id", get(user)),
        zart.Route("/value", get(value)),
    }, .{
        .Extractor = server.JsonExtractor,
        .error_handler = server.ErrorHandler.handleError,
    });
    defer router.deinit();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
    var listener = try addr.listen(.{ .reuse_address = true });
    std.debug.print("Listening on {}\n", .{addr});

    while (true) {
        try server.handleConnection(void, &router, try listener.accept());
    }
}

const ID = struct { id: i32 };

//
// curl -X GET http://localhost:8080/user/42?foo=bar -d '{"id": 41}'
//
fn user(r: http.Server.Request, p: Params, q: Query, b: B(ID)) ID {
    std.debug.print("Method: {}\n", .{r.head.method});
    if (p.value("id")) |v| {
        std.debug.print("- Param ID: {s}\n", .{v});
    }

    if (q.value("foo")) |v| {
        std.debug.print("- Query Foo: {s} ({d})\n", .{ v, q.vars.len });
    }

    // std.debug.print("- Body ID: {d}\n", .{b.id});
    return .{ .id = b.id };
}

//
// curl -X GET http://localhost:8080/value -d '{"id": 41}'
//
fn value(b: Body) !void {
    const obj = b.object;
    const id = obj.get("id") orelse .null;
    std.debug.print("- Body ID: {}\n", .{id.integer});
}
