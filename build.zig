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

    const terminal_test_module = b.createModule(.{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
    });
    const terminal_tests = b.addTest(.{
        .root_module = terminal_test_module,
    });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{.{ .name = "risu", .module = risu }},
    });
    const example = b.addExecutable(.{
        .name = "risu-example",
        .root_module = example_module,
    });
    const install_example = b.addInstallArtifact(example, .{});
    const example_step = b.step("example", "Build the basic Risu example");
    example_step.dependOn(&install_example.step);

    const run_example = b.addRunArtifact(example);
    // This example reads individual key bytes, so it must share the caller's
    // terminal instead of using the build runner's default stdio handling.
    run_example.stdio = .inherit;
    const run_example_step = b.step("run-example", "Run the basic Risu example");
    run_example_step.dependOn(&run_example.step);

    const example_tests = b.addTest(.{
        .root_module = example_module,
    });
    const run_example_tests = b.addRunArtifact(example_tests);

    const test_step = b.step("test", "Run library and example tests");
    test_step.dependOn(&run_risu_tests.step);
    test_step.dependOn(&run_terminal_tests.step);
    test_step.dependOn(&run_example_tests.step);
}
