const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("h264_dump", "src/main.zig");
    exe.setBuildMode(mode);
    exe.addIncludeDir(".");
    exe.addPackagePath("zig-clap", "zig-clap/clap.zig");
    exe.setOutputDir("zig-cache");

    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
