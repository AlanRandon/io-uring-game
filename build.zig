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

fn addRunCommand(b: *std.Build, step: *std.Build.Step.Compile, name: []const u8, description: []const u8) void {
    const run_cmd = b.addRunArtifact(step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    addLibUring(b, server);
    b.installArtifact(server);
    addRunCommand(b, server, "server", "Run the server");

    const client = b.addExecutable(.{
        .name = "client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(client);
    addRunCommand(b, client, "client", "Run the client");

    const server_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });

    addLibUring(b, server_unit_tests);

    const client_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(server_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(client_unit_tests).step);
}
