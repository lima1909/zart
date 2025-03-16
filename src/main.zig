const std = @import("std");

const Server = @import("server.zig").Server;
const Params = @import("request.zig").Params;

// curl -X POST http://localhost:8080/user/42 -d "Hello, Zig!"

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = Server(void).init(allocator);
    defer server.deinit();

    var r = server.router();
    try r.get("/user/:id", user);

    try server.run();
}

fn user(r: *std.http.Server.Request, p: Params) !void {
    std.debug.print("Method: {}\n", .{r.head.method});
    if (p.value("id")) |v| {
        std.debug.print("Param ID: {s}\n", .{v});
    }
}
