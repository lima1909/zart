///
/// Sharing Handler and Middleware between different examples.
///
const std = @import("std");

const zart = @import("zart");
const arg = zart.handler.arg;
const ResponseWriter = zart.ResponseWriter;

// User: with default values, because, the client maybe didn't set the values
const User = struct {
    id: i32 = -1,
    name: []const u8 = "no name",
};

// with Body
// curl -X GET http://localhost:8080/echo -d '{"id": 41, "name": "its me"}'
pub fn echoUser(b: arg.B(User)) User {
    return .{ .id = b.id, .name = b.name };
}

// with URL parameter
// curl -X GET http://localhost:8080/params/42
pub fn params(p: arg.Params, w: *ResponseWriter) !void {
    const param_id = try p.valueAs(i32, "id");
    if (param_id) |id| {
        std.debug.print("- Param ID: {d}\n", .{id});
    } else {
        w.status = .not_found;
    }
}

// with query parameter
// curl -X GET http://localhost:8080/query?name=me
pub fn query(q: arg.Query) void {
    if (q.value("name")) |name| {
        std.debug.print("- Query name: {s} ({d})\n", .{ name, q.len.? });
    }
}

// a simple handler which return a static string
// curl -X GET http://localhost:8080/
pub fn index() []const u8 {
    return "index";
}

// a simple handler which return a http error: forbidden
// curl -X GET http://localhost:8080/forbidden
pub fn forbidden(w: *zart.ResponseWriter) void {
    w.status = .forbidden;
}

// Middleware with printing the execution duration.
pub fn printDurationMiddleware(h: zart.Handle) !void {
    const start = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start;
        std.log.info("duration from middleware: {d} micro seconds", .{duration});
    }

    // calling the next middleware
    try h.next();
}
