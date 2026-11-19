const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "saver", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the screensaver").dependOn(&run.step);

    // main.zig pulls every module's tests in with `_ = @import(...)`.
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
