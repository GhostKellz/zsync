//! Use `zig init --strip` next time to generate a project without comments.
const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // zsync v0.1 - Async Runtime Module
    // Now with full support for Zig's new async I/O paradigm
    // Same code works across blocking, threaded, green threads, and stackless execution models
    const mod = b.addModule("zsync", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // business logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Real async implementation tests
    const real_async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples_real_async.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_real_async_tests = b.addRunArtifact(real_async_tests);
    
    const real_test_step = b.step("test-real", "Run real async implementation tests");
    real_test_step.dependOn(&run_real_async_tests.step);

    // Concurrent future tests
    const concurrent_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/concurrent_future_real.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_concurrent_tests = b.addRunArtifact(concurrent_tests);
    
    const concurrent_test_step = b.step("test-concurrent", "Run concurrent future tests");
    concurrent_test_step.dependOn(&run_concurrent_tests.step);

    // v0.3.2 feature tests
    const v032_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_v032_features.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    const run_v032_tests = b.addRunArtifact(v032_tests);
    
    const v032_test_step = b.step("test-v032", "Run v0.3.2 feature tests");
    v032_test_step.dependOn(&run_v032_tests.step);

    // Performance benchmarks
    const bench_exe = b.addExecutable(.{
        .name = "zsync-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples_real_async.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.addArg("--benchmark");
    
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // WASM build target
    const wasm_exe = b.addExecutable(.{
        .name = "zsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .abi = .musl,
            }),
            .optimize = .ReleaseSmall, // Optimize for size in WASM
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    
    // Configure WASM-specific settings
    wasm_exe.entry = .disabled; // WASM modules don't have a traditional main
    wasm_exe.rdynamic = true; // Allow dynamic linking for JS FFI
    
    const wasm_step = b.step("wasm", "Build for WebAssembly");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
    
    // WASM example/demo
    const wasm_demo = b.addExecutable(.{
        .name = "zsync-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/wasm_demo.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .abi = .musl,
            }),
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    
    wasm_demo.entry = .disabled;
    wasm_demo.rdynamic = true;
    
    const wasm_demo_step = b.step("wasm-demo", "Build WASM demo");
    wasm_demo_step.dependOn(&b.addInstallArtifact(wasm_demo, .{}).step);
    
    // v0.3.2 feature demo
    const v032_demo_exe = b.addExecutable(.{
        .name = "zsync-v032-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/v032_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    
    const v032_demo_cmd = b.addRunArtifact(v032_demo_exe);
    const v032_demo_step = b.step("demo-v032", "Run v0.3.2 feature demonstration");
    v032_demo_step.dependOn(&v032_demo_cmd.step);
    
    // ARM64 build targets
    const arm64_exe = b.addExecutable(.{
        .name = "zsync-arm64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .gnu,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    
    const arm64_step = b.step("arm64", "Build for ARM64/AArch64");
    arm64_step.dependOn(&b.addInstallArtifact(arm64_exe, .{}).step);
    
    // ARM64 macOS target
    const arm64_macos_exe = b.addExecutable(.{
        .name = "zsync-arm64-macos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
                .abi = .none,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsync", .module = mod },
            },
        }),
    });
    
    const arm64_macos_step = b.step("arm64-macos", "Build for ARM64 macOS");
    arm64_macos_step.dependOn(&b.addInstallArtifact(arm64_macos_exe, .{}).step);
    
    // Cross-compilation test step
    const cross_compile_step = b.step("cross-compile", "Test cross-compilation for all targets");
    cross_compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);          // Native
    cross_compile_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);     // WASM
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_exe, .{}).step);    // ARM64 Linux
    cross_compile_step.dependOn(&b.addInstallArtifact(arm64_macos_exe, .{}).step); // ARM64 macOS

    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
