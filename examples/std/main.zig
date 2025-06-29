//!
//! Run:  zig build std
//!
const std = @import("std");
const http = std.http;

const zart = @import("zart");
const Route = zart.Route;
const server = @import("server.zig");
const share = @import("zart_share");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .zart, .level = .debug },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const router = try server.Router.init(
        allocator,
        null,
        .{
            Route("/", .{ .{ .GET, share.index }, .{ .POST, share.index } }),
            Route("/str", .{ .GET, staticStr }),
            Route("/echo", .{ .GET, share.echoUser }),
            Route("/params/:id", .{ .GET, share.params }),
            Route("/query", .{ .GET, share.query }),
            Route("/forbidden", .{ .GET, share.forbidden }),
        },
        .configWithMiddleware(
            .{ .error_handler = server.ErrorHandler },
            .{
                share.printDurationMiddleware,
            },
        ),
    );
    defer router.deinit();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
    var listener = try addr.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });
    defer listener.deinit();
    std.debug.print("Listening on {}\n", .{addr});

    while (true) {
        // handle BLOCKING connection
        try server.handleConnection(&router, try listener.accept());
    }
}

// a second handler which return a static string
fn staticStr(r: http.Server.Request) !void {
    var req = r;
    try req.respond("hello world", .{ .status = .ok });
}
