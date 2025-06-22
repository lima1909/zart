const std = @import("std");

const KeyValue = @import("kv.zig").KeyValue;

inline fn stringValueAs(T: type, value: ?[]const u8) !?T {
    if (value) |v| {
        return switch (@typeInfo(T)) {
            .int => try std.fmt.parseInt(T, v, 10),
            .float => try std.fmt.parseFloat(T, v),
            .bool => {
                if (std.mem.eql(u8, v, "true")) {
                    return true;
                } else if (std.mem.eql(u8, v, "false")) {
                    return false;
                }
                return error.InvalidBool;
            },
            .pointer => |p| if (p.child == u8) v else @compileError("not supported type: " ++ @typeName(T) ++ " for value: " ++ value),
            else => @compileError("not supported type: " ++ @typeName(T) ++ " for value: " ++ value),
        };
    }

    return null;
}

pub const KeyValues = struct {
    ptr: *const anyopaque,
    valueFn: *const fn (ptr: *const anyopaque, key: []const u8) ?[]const u8,
    len: usize = 0,

    /// Is a mapping from a given Key to the Value.
    /// For example by a Query: ?foo=bar, return Value: bar for given Key: foo
    pub inline fn value(self: *const KeyValues, key: []const u8) ?[]const u8 {
        return self.valueFn(self.ptr, key);
    }
};

const TagFieldName = "__TAG__";

/// Create an instance of an given Struct from the given key-values.
fn createStructFromKV(comptime S: type, kvs: KeyValues) !S {
    var instance: S = undefined;

    const info = @typeInfo(S);
    if (info == .@"struct") {
        inline for (info.@"struct".fields) |field| {
            if (!comptime std.mem.eql(u8, TagFieldName, field.name)) {
                const string_value = kvs.value(field.name);
                @field(instance, field.name) = if (try stringValueAs(field.type, string_value)) |val| val else undefined;
            }
        }
    } else {
        @compileError(std.fmt.comptimePrint("parms T type must be a struct, not: {s}", .{@typeName(S)}));
    }

    return instance;
}

const Params = struct {
    kvs: []const KeyValue,

    pub inline fn value(self: *const Params, key: []const u8) ?[]const u8 {
        for (self.kvs) |v| {
            if (std.mem.eql(u8, key, v.key)) {
                return v.value;
            }
        }

        return null;
    }

    pub inline fn valueAs(self: *const Params, T: type, key: []const u8) !?T {
        return stringValueAs(T, self.value(key));
    }

    fn interfaceValueFn(ptr: *const anyopaque, key: []const u8) ?[]const u8 {
        const p: *const Params = @ptrCast(@alignCast(ptr));
        return p.value(key);
    }

    fn keyValues(self: *const Params) KeyValues {
        return .{ .ptr = self, .valueFn = interfaceValueFn, .len = self.kvs.len };
    }
};

const Query = struct {
    kvs: KeyValues,

    pub inline fn value(self: *const Query, key: []const u8) ?[]const u8 {
        return self.kvs.value(key);
    }

    pub inline fn valueAs(self: *const Query, T: type, key: []const u8) !?T {
        return stringValueAs(T, self.value(key));
    }
};

test "Params" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "aint", .value = "42" },
            .{ .key = "abool", .value = "true" },
            .{ .key = "afloat", .value = "4.2" },
            .{ .key = "atxt", .value = "foo" },
        },
    };

    try std.testing.expectEqual(42, (try p.valueAs(i32, "aint")).?);
    try std.testing.expectEqual(4.2, (try p.valueAs(f32, "afloat")).?);
    try std.testing.expectEqual(true, (try p.valueAs(bool, "abool")).?);
    try std.testing.expectEqual("foo", (try p.valueAs([]const u8, "atxt")).?);

    try std.testing.expectEqualStrings("foo", p.value("atxt").?);
    try std.testing.expectEqual(null, p.value("not_exist"));
}

test "Params to struct instance" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "name", .value = "Mario" },
            .{ .key = "maybe", .value = "true" },
            .{ .key = "inumber", .value = "42" },
            .{ .key = "fnumber", .value = "2.4" },
        },
    };

    const s = struct {
        name: []const u8,
        maybe: bool,
        inumber: i32,
        fnumber: f32,
    };

    const instance = try createStructFromKV(s, p.keyValues());

    try std.testing.expectEqualStrings("Mario", instance.name);
    try std.testing.expectEqual(true, instance.maybe);
    try std.testing.expectEqual(42, instance.inumber);
    try std.testing.expectEqual(2.4, instance.fnumber);
}

test "Query" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "aint", .value = "42" },
            .{ .key = "abool", .value = "true" },
            .{ .key = "afloat", .value = "4.2" },
            .{ .key = "atxt", .value = "foo" },
        },
    };
    const q = Query{ .kvs = p.keyValues() };

    try std.testing.expectEqual(4, q.kvs.len);

    try std.testing.expectEqual(42, (try q.valueAs(i32, "aint")).?);
    try std.testing.expectEqual(4.2, (try q.valueAs(f32, "afloat")).?);
    try std.testing.expectEqual(true, (try q.valueAs(bool, "abool")).?);
    try std.testing.expectEqual("foo", (try q.valueAs([]const u8, "atxt")).?);

    try std.testing.expectEqualStrings("foo", q.value("atxt").?);
    try std.testing.expectEqual(null, q.value("not_exist"));
}

test "Query to struct instance" {
    const p = Params{
        .kvs = &[_]KeyValue{
            .{ .key = "name", .value = "Mario" },
            .{ .key = "maybe", .value = "true" },
            .{ .key = "inumber", .value = "42" },
            .{ .key = "fnumber", .value = "2.4" },
        },
    };
    const q = Query{ .kvs = p.keyValues() };

    const s = struct {
        name: []const u8,
        maybe: bool,
        inumber: i32,
        fnumber: f32,
    };

    const instance = try createStructFromKV(s, q.kvs);
    try std.testing.expectEqualStrings("Mario", instance.name);
    try std.testing.expectEqual(true, instance.maybe);
    try std.testing.expectEqual(42, instance.inumber);
    try std.testing.expectEqual(2.4, instance.fnumber);
}
