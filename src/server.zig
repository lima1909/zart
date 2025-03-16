const std = @import("std");
const http = @import("std").http;

pub fn Server(comptime App: type) type {
    const Method = @import("router.zig").Method;
    const Router = @import("router.zig").Router(App, *http.Server.Request);

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

            const method = Method.fromStdMethod(req.head.method);
            const path = req.head.target;
            r.resolve(method, path, &req);

            // var body_buffer: [4096]u8 = undefined;
            // const body_len = try (try req.reader()).readAll(&body_buffer);
            // const body = body_buffer[0..body_len];
            //
            // std.debug.print("Received body: {s}\n", .{body});

            // try req.respond("hello world\n", std.http.Server.Request.RespondOptions{});
            try req.respond("", std.http.Server.Request.RespondOptions{ .status = .ok });
        }
    };
}
