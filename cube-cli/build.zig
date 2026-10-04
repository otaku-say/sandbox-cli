const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cube-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // 需要 libc：std.c.getenv 读环境变量（0.17 里挂在 root_module 上）
    exe.root_module.link_libc = true;
    // 去掉调试符号（ReleaseFast + musl 后单文件约 1MB）
    exe.root_module.strip = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "运行");
    run_step.dependOn(&run_cmd.step);
}
