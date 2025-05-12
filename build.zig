const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zart = b.createModule(.{
        .root_source_file = b.path("src/zart.zig"),
        .target = target,
        .optimize = optimize,
    });

    //
    // --- Unit-Tests ---
    //
    const zart_unit_tests = b.addTest(.{
        .name = "zart_unit_tests",
        .root_source_file = b.path("src/zart.zig"),
    });
    // create an executable
    // b.installArtifact(zart_unit_tests);

    const run_test = b.addRunArtifact(zart_unit_tests);
    // run_test.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run ZART unit tests");
    test_step.dependOn(&run_test.step);

    //
    // --- Examples ---
    //
    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
    }{
        .{ .file = "examples/std/main.zig", .name = "zart_std" },
    };

    for (examples) |ex| {
        const example = b.addExecutable(.{
            .name = ex.name,
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(ex.file),
        });
        example.root_module.addImport("zart", zart);
        // create an executable
        b.installArtifact(example);

        const run_cmd = b.addRunArtifact(example);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);
    }
}
