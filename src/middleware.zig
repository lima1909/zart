const std = @import("std");

const KeyValue = @import("kv.zig").KeyValue;
const ResponseWriter = @import("handler.zig").ResponseWriter;

/// The interface to create a Middleware.
pub fn Middleware(Context: type, Request: type) type {
    return struct {
        const Self = @This();
        const Exec = Executor(Context, Request);

        ptr: *anyopaque,
        executeFn: *const fn (ptr: *anyopaque, ctx: *Context, r: *const Request, w: *ResponseWriter, exc: *Exec) anyerror!void,

        pub fn execute(self: Self, ctx: *Context, r: *const Request, w: *ResponseWriter, exc: *Exec) anyerror!void {
            return self.executeFn(self.ptr, ctx, r, w, exc);
        }
    };
}

/// AN Example for creating a logging middleware.
pub fn LoggingMiddleware(Context: type, Request: type) type {
    const log = std.log.scoped(.zart);

    return struct {
        const Self = @This();

        elapsed: i128 = 0,

        pub fn execute(ptr: *anyopaque, _: *Context, _: *const Request, w: *ResponseWriter, exc: *Executor(Context, Request)) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const start = std.time.nanoTimestamp();

            defer {
                self.elapsed = std.time.nanoTimestamp() - start;
                log.info("Elapsed time: {d}ns and status: {}", .{ self.elapsed, w.status });
            }

            try exc.next();
        }

        pub fn middleware(self: *Self) Middleware(Context, Request) {
            return .{
                .ptr = self,
                .executeFn = execute,
            };
        }
    };
}

pub fn Executor(Context: type, Request: type) type {
    return struct {
        const Self = @This();

        index: usize = 0,
        middlewares: []const Middleware(Context, Request) = &.{},

        context: Context,
        request: *const Request,
        responseWriter: ResponseWriter = ResponseWriter{},

        pub fn next(self: *Self) !void {
            if (self.index >= self.middlewares.len) {
                return;
            }

            const m = &self.middlewares[self.index];
            self.index += 1;
            try m.execute(&self.context, self.request, &self.responseWriter, self);
        }
    };
}

test "no middlewares" {
    const e = Executor(void, bool){ .context = {}, .request = &true };
    try std.testing.expectEqual(0, e.index);
}

test "debug middlewares" {
    var l = LoggingMiddleware(void, bool){};
    var e = Executor(void, bool){
        .context = {},
        .request = &true,
        .middlewares = &.{ l.middleware(), l.middleware(), l.middleware() },
    };

    // const start = std.time.nanoTimestamp();
    try e.next();
    // std.debug.print("Elapsed time: {d}ns\n", .{std.time.nanoTimestamp() - start});
    try std.testing.expectEqual(3, e.index);
}
