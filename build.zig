const std = @import("std");

/// The release version: `ffs --version` and `ffs_version()` in C.
const version = "0.0.9";

// `zig build` produces:
//   zig-out/debug/ffs     (Debug: safety checks, debug info)
//   zig-out/release/ffs   (ReleaseFast: production)
//   zig-out/lib/libffs.a  (ReleaseFast C library) + zig-out/include/ffs.h
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const variants = [_]struct { dir: []const u8, optimize: std.builtin.OptimizeMode, strip: bool }{
        .{ .dir = "debug", .optimize = .Debug, .strip = false },
        // Stripping halves the size (450 -> 256 KB) and changes no code.
        .{ .dir = "release", .optimize = .ReleaseFast, .strip = true },
    };

    for (variants) |v| {
        const exe = b.addExecutable(.{
            .name = "ffs",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = v.optimize,
                .strip = v.strip,
            }),
        });
        exe.root_module.addOptions("build_options", options);
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = v.dir } },
        });
        b.getInstallStep().dependOn(&install.step);
    }

    // The C library: src/c_api.zig behind include/ffs.h.
    //
    // `link_libc` is required, not a preference: without it the library
    // brings its own threading runtime into a host program that already has
    // libc's, and on Linux `ffs_search` then hangs forever on the first
    // search, at any thread count (EXPERIMENTS.md, Experiment 15). macOS
    // needed libc here anyway, for `sysctlbyname` in `search.autoJobs`.
    const lib = b.addLibrary(.{
        .name = "ffs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    lib.root_module.addOptions("build_options", options);
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/ffs.h"), "ffs.h");
    b.installArtifact(lib);

    // `zig build c-example -- <folder> <term>`: examples/count.c against libffs.
    const example = b.addExecutable(.{
        .name = "count",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    example.root_module.addCSourceFile(.{ .file = b.path("examples/count.c") });
    example.root_module.addIncludePath(b.path("include"));
    example.root_module.linkLibrary(lib);
    const example_run = b.addRunArtifact(example);
    example_run.addPassthruArgs();
    b.step("c-example", "Run examples/count.c, linked against libffs").dependOn(&example_run.step);

    // `zig build bench-match -- <corpus> [runs]`: time match.findLines alone.
    const bench = b.addExecutable(.{
        .name = "bench-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_match.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench-match", "Benchmark match.findLines on an in-memory corpus").dependOn(&bench_run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `zig build test-bin` writes the test binary to zig-out/test/ instead of
    // running it, so a coverage tool can drive it (kcov in CI; Zig has no
    // coverage of its own). The binary keeps debug info, which kcov needs.
    const test_bin = b.addInstallArtifact(tests, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    b.step("test-bin", "Build the test binary without running it").dependOn(&test_bin.step);
}
