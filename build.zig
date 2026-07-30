const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const risu = b.addModule("risu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const risu_tests = b.addTest(.{
        .root_module = risu,
    });
    const run_risu_tests = b.addRunArtifact(risu_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_risu_tests.step);
}
