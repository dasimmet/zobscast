const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const obs = b.dependency("obs", .{});
    const c_head = b.addTranslateC(.{
        // .root_source_file = obs.path("libobs/obs-module.h"),
        .root_source_file = b.path("src/obs_api.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_head.addIncludePath(b.path("src/include"));
    c_head.addIncludePath(obs.path("frontend/api"));
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

    const ffmpeg = b.dependency("ffmpeg", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zobscast",
        .root_module = b.addModule("zobscast", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "av",
                    .module = ffmpeg.module("av"),
                },
                .{
                    .name = "c",
                    .module = c_head.createModule(),
                },
            },
        }),
        .linkage = .dynamic,
    });
    if (target.result.os.tag == .linux) {
        lib.setVersionScript(b.path("src/zobscast.version"));
    } else if (target.result.os.tag.isDarwin()) {
        lib.linker_allow_shlib_undefined = true;
    } else if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("ws2_32", .{});

        const machine_flag = switch (target.result.cpu.arch) {
            .x86_64 => "i386:x86-64",
            .aarch64 => "arm64",
            .x86 => "i386",
            else => "i386:x86-64",
        };

        const dlltool_obs = b.addSystemCommand(&.{
            b.graph.zig_exe, "dlltool", "-m", machine_flag, "-d",
        });
        dlltool_obs.addFileArg(b.path("src/windows/obs.def"));
        dlltool_obs.addArgs(&.{ "-l" });
        const obs_lib = dlltool_obs.addOutputFileArg("obs.lib");
        dlltool_obs.addArgs(&.{ "-D", "obs.dll" });
        lib.root_module.addObjectFile(obs_lib);

        const dlltool_fe = b.addSystemCommand(&.{
            b.graph.zig_exe, "dlltool", "-m", machine_flag, "-d",
        });
        dlltool_fe.addFileArg(b.path("src/windows/obs-frontend-api.def"));
        dlltool_fe.addArgs(&.{ "-l" });
        const obs_fe_lib = dlltool_fe.addOutputFileArg("obs-frontend-api.lib");
        dlltool_fe.addArgs(&.{ "-D", "obs-frontend-api.dll" });
        lib.root_module.addObjectFile(obs_fe_lib);
    }

    const rel_path = b.fmt(
        "{d}bit/{s}{s}",
        .{
            target.result.ptrBitWidth(),
            lib.name,
            target.result.dynamicLibSuffix(),
        },
    );
    const ext_install = b.addInstallBinFile(lib.getEmittedBin(), rel_path);
    b.getInstallStep().dependOn(&ext_install.step);
    b.installDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .prefix,
        .install_subdir = "data",
    });

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_enum.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
