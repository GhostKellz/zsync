const std = @import("std");
const builtin = @import("builtin");
const zsync = @import("zsync");

/// Cross-platform runtime demonstration.
///
/// This executable showcases zsync running on top of `std.Io.Threaded` across
/// every supported target. It is NOT a supported API surface - it exists to
/// confirm the runtime cross-compiles and runs a simple async workload on each
/// platform.
///
/// Scheduling and I/O backend selection are owned by `std.Io`; zsync no longer
/// ships its own per-platform reactor. On freestanding targets (e.g. WASM) there
/// is no host runtime to drive, so `main` returns immediately.
pub fn main() !void {
    if (comptime builtin.target.os.tag == .freestanding) {
        // Force-reference the wasm async surface so its JS host bindings are
        // continuously compiled for the freestanding/wasm target. Tests cannot
        // run here, so this is what keeps the wasm-only code path from rotting.
        comptime {
            _ = &zsync.wasm_async.fetch;
            _ = &zsync.wasm_async.defer_;
            _ = zsync.wasm_async.AsyncContext.sleep;
            _ = zsync.wasm_async.FetchResponse.json;

            // Force-compile the wasm host-bridged networking surface. Tests
            // cannot run on freestanding, so this keeps the JS host bindings
            // continuously analyzed by `zig build cross-compile`/`wasm`.
            _ = &zsync.UdpSocket.bind;
            _ = &zsync.UdpSocket.sendTo;
            _ = &zsync.UdpSocket.recvFrom;
            _ = &zsync.UdpSocket.close;
            _ = &zsync.networking.DnsResolver.resolve;
            _ = &zsync.networking.HttpClient.request;
            _ = &zsync.networking.TlsStream.connect;
            _ = &zsync.networking.WebSocketConnection.connect;
            _ = &zsync.createHttpClient;
        }
        return;
    }

    std.debug.print("zsync v{s} - Cross-Platform Async Runtime\n", .{zsync.VERSION});
    std.debug.print("============================================================\n", .{});
    std.debug.print("OS:   {s}\n", .{@tagName(builtin.target.os.tag)});
    std.debug.print("Arch: {s}\n", .{@tagName(builtin.target.cpu.arch)});
    std.debug.print("Backend: std.Io.Threaded\n\n", .{});

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const Demo = struct {
        fn add(a: u32, b: u32) u32 {
            return a + b;
        }
        fn task() void {
            const io = zsync.getGlobalIo() orelse return;
            var future = io.async(add, .{ @as(u32, 40), @as(u32, 2) });
            const sum = future.await(io);
            std.debug.print("Async task result: {d}\n", .{sum});
        }
    };

    zsync.run(gpa.allocator(), Demo.task, .{});

    std.debug.print("\nCross-platform demo completed.\n", .{});
}
