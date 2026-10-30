const std = @import("std");

// Single executable, no exposed library module — laptopd is a multi-call CLI,
// not a package other Zig code imports (unlike, say, a shared internal
// module the Go daemons might eventually extract to). Mirrors the shape of
// zig init's exe target while dropping the addModule() half nothing here
// needs.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "laptopd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Strip debug info in non-Debug builds, matching the Go daemons'
            // -ldflags="-s -w" — this project treats binary size as worth
            // watching, not just runtime footprint.
            .strip = optimize != .Debug,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run laptopd");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
