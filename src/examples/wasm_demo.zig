const std = @import("std");
const builtin = @import("builtin");

// External JS functions
extern "env" fn js_console_log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "env" fn js_setTimeout(callback_id: u32, delay_ms: u32) void;

// Simple console logging
fn consoleLog(msg: []const u8) void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        js_console_log(msg.ptr, msg.len);
    }
}

// Export functions for JavaScript to call
export fn demo_init() void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        consoleLog("🚀 zsync WASM Demo Initialized!");
        consoleLog("✅ Basic WASM integration working!");
    }
}

export fn demo_fetch(url_ptr: [*]const u8, url_len: usize) void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        const url = url_ptr[0..url_len];
        _ = url; // Use url parameter
        consoleLog("📡 HTTP fetch demo triggered from WASM!");
        consoleLog("✅ URL parameter received successfully");
    }
}

export fn demo_websocket(url_ptr: [*]const u8, url_len: usize) void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        const url = url_ptr[0..url_len];
        _ = url; // Use url parameter
        consoleLog("🔌 WebSocket demo triggered from WASM!");
        consoleLog("✅ WebSocket URL parameter received successfully");
    }
}

// Add a simple math function to demonstrate WASM functionality
export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

// Main entry point for non-WASM targets
pub fn main() !void {
    if (comptime !builtin.target.cpu.arch.isWasm()) {
        std.debug.print("This demo is designed for WASM targets.\n");
        std.debug.print("Build with: zig build wasm-demo\n");
        return;
    }
    
    // For WASM, the entry point is controlled by JavaScript
    // The export functions above are called directly from JS
}