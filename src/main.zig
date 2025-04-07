const std = @import("std");

const Server = @import("server.zig").Server;
const Params = @import("request.zig").Params;
const Query = @import("request.zig").Query;
const B = @import("request.zig").B;
const Body = @import("request.zig").Body;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = Server(void).init(allocator);
    defer server.deinit();

    var r = server.router();
    try r.get("/user/:id", user);
    try r.get("/value", value);

    try server.run();
}

const ID = struct { id: i32 };

//
// curl -X GET http://localhost:8080/user/42?foo=bar -d '{"id": 41}'
//
fn user(r: std.http.Server.Request, p: Params, q: Query, b: B(ID)) ID {
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
