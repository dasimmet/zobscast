const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addLibrary(.{
        .name = "zobscast",
        .root_module = b.addModule("zobscast", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    b.installArtifact(lib);
    // lib.linkSystemLibrary("obs");

    const obs = b.dependency("obs", .{});
    const c_head = b.addTranslateC(.{
        .root_source_file = obs.path("libobs/obs-module.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_head.out_basename = "obs_module.zig";
    c_head.addIncludePath(obs.path("libobs"));
    const obsconfig = b.addConfigHeader(.{
        .style = .{ .cmake = obs.path("libobs/obsconfig.h.in") },
    }, .{
        .OBS_DATA_PATH = "",
        .OBS_PLUGIN_PATH = "",
        .OBS_PLUGIN_DESTINATION = "",
        .OBS_RELEASE_CANDIDATE = "",
        .OBS_BETA = "",
    });
    c_head.addIncludePath(obsconfig.getOutputDir());

    const simde = b.dependency("simde", .{});
    c_head.addIncludePath(simde.path(""));

    lib.root_module.addImport("c", c_head.createModule());
}
