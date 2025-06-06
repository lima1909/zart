const std = @import("std");

const KeyValue = @import("kv.zig").KeyValue;
const ResponseWriter = @import("handler.zig").ResponseWriter;

pub const Iterator = struct {
    ptr: *anyopaque,
    nextFn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn next(self: Iterator) anyerror!void {
        return self.nextFn(self.ptr);
    }
};

/// The interface to create a Middleware.
pub fn Middleware(Request: type, Context: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        executeFn: *const fn (ptr: *anyopaque, ctx: *Context, r: *const Request, w: *ResponseWriter, it: Iterator) anyerror!void,

        pub fn execute(self: Self, ctx: *Context, r: *const Request, w: *ResponseWriter, it: Iterator) anyerror!void {
            return self.executeFn(self.ptr, ctx, r, w, it);
        }
    };
}

pub fn Executor(Request: type) type {
    return struct {
        pub fn new(context: anytype) type {
            return struct {
                const Self = @This();

                context: @TypeOf(context) = context,
                middlewares: []const Middleware(Request, @TypeOf(context)) = &.{},
                index: usize = 0,

                request: *const Request,
                response: *ResponseWriter,

                pub fn next(ptr: *anyopaque) !void {
                    const self: *Self = @ptrCast(@alignCast(ptr));

                    if (self.index >= self.middlewares.len) {
                        return;
                    }

                    const m = &self.middlewares[self.index];
                    self.index += 1;
                    try m.execute(&self.context, self.request, self.response, self.iterator());
                }

                pub fn iterator(self: *Self) Iterator {
                    return .{ .ptr = self, .nextFn = next };
                }
            };
        }
    };
}

/// AN Example for creating a logging middleware.
pub fn LoggingMiddleware(Request: type, Context: type) type {
    const log = std.log.scoped(.zart);

    return struct {
        const Self = @This();

        elapsed: i128 = 0,

        pub fn execute(ptr: *anyopaque, _: *Context, _: *const Request, w: *ResponseWriter, it: Iterator) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const start = std.time.nanoTimestamp();

            defer {
                self.elapsed = std.time.nanoTimestamp() - start;
                log.info("Elapsed time: {d}ns and status: {}", .{ self.elapsed, w.status });
            }

            try it.next();
        }

        pub fn middleware(self: *Self) Middleware(Request, Context) {
            return .{
                .ptr = self,
                .executeFn = execute,
            };
        }
    };
}

test "no middlewares" {
    var w = ResponseWriter{};
    const req = true;

    const e = Executor(bool).new({}){
        .request = &req,
        .response = &w,
    };
    try std.testing.expectEqual(0, e.index);
}

test "debug middlewares" {
    var l = LoggingMiddleware(bool, void){};
    var w = ResponseWriter{};
    const req = true;

    var e = Executor(bool).new({}){
        .request = &req,
        .response = &w,
        .middlewares = &.{ l.middleware(), l.middleware(), l.middleware() },
    };
    var it = e.iterator();

    // const start = std.time.nanoTimestamp();
    try it.next();
    // std.debug.print("Elapsed time: {d}ns\n", .{std.time.nanoTimestamp() - start});
    try std.testing.expectEqual(3, e.index);
}
