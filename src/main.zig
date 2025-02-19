const std = @import("std");

// curl -X POST http://localhost:8082/user/42 -d "Hello, Zig!"

pub fn main() !void {
    const addr = try std.net.Address.resolveIp("127.0.0.1", 8082);
    var listener = try addr.listen(.{ .reuse_address = true });
    std.debug.print("Listening on {}\n", .{addr});
    while (true) {
        try handleConnection(try listener.accept());
    }
}

fn handleConnection(conn: std.net.Server.Connection) !void {
    defer conn.stream.close();
    var buffer: [1024]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buffer);
    var req = try http_server.receiveHead();
    std.debug.print("Req {s} \n", .{req.head.target});

    var body_buffer: [4096]u8 = undefined;
    const body_len = try (try req.reader()).readAll(&body_buffer);
    const body = body_buffer[0..body_len];

    std.debug.print("Received body: {s}\n", .{body});

    try req.respond("hello world\n", std.http.Server.Request.RespondOptions{});
}
