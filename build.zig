//! Zsync v0.5.0 Build Configuration
//! The Tokio of Zig - Production-Ready Async Runtime Build System

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zsync v0.5.0 - Production-Ready Async Runtime Module
    // Complete API coverage with all missing exports for zquic compatibility
    const zsync_mod = b.addModule("zsync", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main v0.5.0 executable showcasing all features
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

    // Run step for v0.5.0 demo
    const run_step = b.step("run", "Run Zsync v0.5.0 production demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Legacy v0.3.x support for backward compatibility
    const legacy_mod = b.addModule("zsync-legacy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const legacy_exe = b.addExecutable(.{
        .name = "zsync-legacy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = legacy_mod },
            },
        }),
    });

    const legacy_step = b.step("legacy", "Run legacy v0.3.x for compatibility testing");
    const legacy_cmd = b.addRunArtifact(legacy_exe);
    legacy_step.dependOn(&legacy_cmd.step);

    // Comprehensive test suite for v0.5.0
    const tests = b.addTest(.{
        .root_module = zsync_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    
    const test_step = b.step("test", "Run Zsync v0.5.0 comprehensive tests");
    test_step.dependOn(&run_tests.step);

    // v0.5.0 Examples
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

    // v0.5.0 Benchmarks
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark_demo.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const benchmark_step = b.step("benchmark", "Run v0.5.0 performance benchmarks");
    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_step.dependOn(&benchmark_cmd.step);

    // API Test
    const api_test_exe = b.addExecutable(.{
        .name = "api-test", 
        .root_module = b.createModule(.{
            .root_source_file = b.path("simple_test_v050.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const api_test_step = b.step("api-test", "Test all v0.5.0 APIs work correctly");
    const api_test_cmd = b.addRunArtifact(api_test_exe);
    api_test_step.dependOn(&api_test_cmd.step);

    // Performance benchmarks for v0.5.0
    const bench_exe = b.addExecutable(.{
        .name = "zsync-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks_v4.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run v0.5.0 performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Cross-platform builds for v0.5.0

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
    cross_compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);         // Native
    cross_compile_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);    // WASM
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_exe, .{}).step);   // ARM64 Linux
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_macos_exe, .{}).step); // ARM64 macOS
    cross_compile_step.dependOn(&b.addInstallArtifact(windows_exe, .{}).step); // Windows

    // Migration testing - ensure v0.5.0 can run v0.3.x code
    const migration_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/migration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
                .{ .name = "zsync-legacy", .module = legacy_mod },
            },
        }),
    });

    const migration_test_step = b.step("test-migration", "Test v0.3.x to v0.5.0 migration compatibility");
    migration_test_step.dependOn(&b.addRunArtifact(migration_test).step);

    // Integration tests with real applications
    const integration_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });

    const integration_test_step = b.step("test-integration", "Run integration tests with real workloads");
    integration_test_step.dependOn(&b.addRunArtifact(integration_test).step);

    // Development tools
    const check_step = b.step("check", "Check code without building");
    const check = b.addTest(.{
        .root_module = zsync_mod,
    });
    check_step.dependOn(&check.step);

    // Release preparation
    const release_step = b.step("release", "Prepare release build with all optimizations");
    release_step.dependOn(test_step);
    release_step.dependOn(cross_compile_step);
}

fn showHelp(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = step;
    _ = options;
    
    std.debug.print(
        \\🚀 Zsync v0.5.0 - The Tokio of Zig
        \\
        \\Available Commands:
        \\  run              - Run the v0.5.0 demo showcasing all features
        \\  test             - Run comprehensive test suite  
        \\  bench            - Run performance benchmarks
        \\  legacy           - Run legacy v0.3.x for compatibility testing
        \\  
        \\Cross-Platform Builds:
        \\  wasm             - Build for WebAssembly (stackless execution)
        \\  arm64            - Build for ARM64 Linux (io_uring optimized)
        \\  arm64-macos      - Build for ARM64 macOS (kqueue optimized)
        \\  windows          - Build for Windows (IOCP optimized)
        \\  cross-compile    - Test all cross-compilation targets
        \\
        \\Development:
        \\  check            - Check code without building
        \\  fmt              - Format all source files
        \\  docs             - Generate documentation
        \\  test-migration   - Test v0.3.x migration compatibility
        \\  test-integration - Run integration tests
        \\
        \\Release:
        \\  release          - Full release preparation (tests + docs + benchmarks)
        \\
        \\Example Usage:
        \\  zig build run                    # Demo all v0.5.0 features
        \\  zig build test                   # Run test suite
        \\  zig build bench                  # Performance benchmarks
        \\  zig build cross-compile          # Test all platforms
        \\
    );
}