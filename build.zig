const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // --- Unit-Tests ---
    //
    const zart_unit_tests = b.addTest(.{
        .name = "zart_unit_tests",
        .root_source_file = b.path("src/zart.zig"),
    });

    const run_test = b.addRunArtifact(zart_unit_tests);
    // run: build test --summary new
    const test_step = b.step("test", "Run ZART unit tests");
    test_step.dependOn(&run_test.step);

    //
    // --- Examples ---
    //
    const zart = b.createModule(.{
        .root_source_file = b.path("src/zart.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zart_share = b.createModule(.{
        .root_source_file = b.path("examples/share.zig"),
        .target = target,
        .optimize = optimize,
    });
    zart_share.addImport("zart", zart);

    const Dependency = struct {
        name: []const u8,
        dep: *std.Build.Dependency,
    };

    const Examples = [_]struct {
        name: []const u8,
        file: []const u8,
        dep: ?Dependency = null,
    }{
        .{
            .name = "std",
            .file = "examples/std/main.zig",
        },
        .{
            .name = "zap",
            .file = "examples/zap/main.zig",
            .dep = .{
                .name = "zap",
                .dep = b.dependency("zap", .{
                    .target = target,
                    .optimize = optimize,
                }),
            },
        },
    };

    inline for (Examples) |ex| {
        const example = b.addExecutable(.{
            .name = ex.name,
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(ex.file),
        });

        example.root_module.addImport("zart", zart);

        if (ex.dep) |d| {
            example.root_module.addImport(d.name, d.dep.module(d.name));
        }

        // add shared handler and middleware
        example.root_module.addImport("zart_share", zart_share);

        // create an executable
        b.installArtifact(example);

        const run_cmd = b.addRunArtifact(example);
        run_cmd.step.dependOn(b.getInstallStep());

        var buffer: [100]u8 = undefined;
        const description = std.fmt.bufPrint(&buffer, "Run ZART example: '{s}', with file: {s}", .{ ex.name, ex.file }) catch ex.file;
        const run_step = b.step(ex.name, description);
        run_step.dependOn(&run_cmd.step);
    }
}
