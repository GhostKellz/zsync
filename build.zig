//! Zsync v0.7.4 Build Configuration
//! The Tokio of Zig - Production-Ready Async Runtime Build System

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zsync v0.7.4 - Production-Ready Async Runtime Module
    const zsync_mod = b.addModule("zsync", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run Zsync demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test suite
    const tests = b.addTest(.{
        .root_module = zsync_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Zsync test suite");
    test_step.dependOn(&run_tests.step);

    // Performance benchmarks
    const bench_exe = b.addExecutable(.{
        .name = "zsync-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/linux_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Examples
    const http_server_exe = b.addExecutable(.{
        .name = "http-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/high_performance_server.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const http_server_step = b.step("http-server", "Run high-performance HTTP server example");
    const http_server_cmd = b.addRunArtifact(http_server_exe);
    http_server_step.dependOn(&http_server_cmd.step);

    // Cross-platform builds

    // WASM build with stackless execution model
    const wasm_exe = b.addExecutable(.{
        .name = "zsync-wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cross.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .abi = .musl,
            }),
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_step = b.step("wasm", "Build for WebAssembly (stackless execution)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // ARM64 Linux build with io_uring optimization
    const arm64_exe = b.addExecutable(.{
        .name = "zsync-arm64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cross.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .gnu,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const arm64_step = b.step("arm64", "Build for ARM64 Linux (io_uring optimized)");
    arm64_step.dependOn(&b.addInstallArtifact(arm64_exe, .{}).step);

    // ARM64 macOS build with kqueue optimization
    const arm64_macos_exe = b.addExecutable(.{
        .name = "zsync-arm64-macos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cross.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
                .abi = .none,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const arm64_macos_step = b.step("arm64-macos", "Build for ARM64 macOS (kqueue optimized)");
    arm64_macos_step.dependOn(&b.addInstallArtifact(arm64_macos_exe, .{}).step);

    // Windows build with IOCP optimization
    const windows_exe = b.addExecutable(.{
        .name = "zsync-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cross.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const windows_step = b.step("windows", "Build for Windows (IOCP optimized)");
    windows_step.dependOn(&b.addInstallArtifact(windows_exe, .{}).step);

    // Cross-compilation test for all platforms
    const cross_compile_step = b.step("cross-compile", "Test cross-compilation for all supported platforms");
    cross_compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    cross_compile_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_exe, .{}).step);
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_macos_exe, .{}).step);
    cross_compile_step.dependOn(&b.addInstallArtifact(windows_exe, .{}).step);

    // Development tools
    const check_step = b.step("check", "Check code without building");
    const check = b.addTest(.{
        .root_module = zsync_mod,
    });
    check_step.dependOn(&check.step);

    // Examples - build all example files
    const examples_step = b.step("examples", "Build all examples");

    const example_files = [_][]const u8{
        "examples/basic.zig",
        "examples/channels.zig",
        "examples/timers.zig",
        "examples/sync.zig",
    };

    for (example_files) |example_path| {
        const example_exe = b.addExecutable(.{
            .name = std.fs.path.stem(example_path),
            .root_module = b.createModule(.{
                .root_source_file = b.path(example_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zsync", .module = zsync_mod },
                },
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
    }

    // Release preparation
    const release_step = b.step("release", "Prepare release build with all optimizations");
    release_step.dependOn(test_step);
    release_step.dependOn(cross_compile_step);
    release_step.dependOn(examples_step);
}
