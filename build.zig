const std = @import("std");

fn addLibUring(b: *std.Build, step: *std.Build.Step.Compile) void {
    step.linkLibC();

    const include = std.process.getEnvVarOwned(b.allocator, "INCLUDE") catch null;
    if (include) |i| {
        step.addIncludePath(.{ .cwd_relative = i });
    }
    step.linkSystemLibrary("uring");

    step.addCSourceFile(.{
        .file = .{
            .cwd_relative = "src/wrapper.c",
        },
        .flags = &.{},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "io-uring-game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addLibUring(b, exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addLibUring(b, exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
