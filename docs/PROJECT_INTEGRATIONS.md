# Zsync v0.6.0 - Project Integration Guide

## Overview

Zsync v0.6.0 provides specialized features for **all your projects**. This guide shows how to integrate zsync with each project in your ecosystem.

---

## 🪐 Ripple - Reactive WASM Web UI

**Project**: `/data/projects/ripple`
**What it is**: Reactive, WASM-first web UI framework (Leptos/Yew-style)
**Status**: Alpha

### What Ripple Needs from Zsync

1. **Development Server with HMR**
2. **Real-time features** (WebSocket)
3. **Browser-compatible async** (Promise, microtasks)
4. **File watching** for hot reload

### Integration

```zig
const zsync = @import("zsync");
const ripple = @import("ripple");

// Dev server with HMR
pub fn rippleDevServer() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var config = zsync.Config.forServer();
    var runtime = try zsync.Runtime.init(allocator, &config);
    defer runtime.deinit();

    // File watcher
    var watcher = try zsync.FileWatcher.init(allocator, onFileChange, 100, true);
    defer watcher.deinit();
    try watcher.watch("src/");

    // WebSocket for HMR communication
    const ws_addr = try std.net.Address.parseIp4("127.0.0.1", 3001);
    var ws_server = zsync.WebSocketServerV2.init(allocator, runtime, ws_addr, onWsConnect);

    // HTTP server for app
    const http_addr = try std.net.Address.parseIp4("127.0.0.1", 3000);
    var http_server = zsync.HttpServerV2.init(allocator, runtime, http_addr, serveApp);

    std.debug.print("🚀 Ripple dev server running!\n", .{});
    try http_server.listen();
}

fn onFileChange(path: []const u8, event: zsync.WatchEvent) void {
    std.debug.print("[HMR] File changed: {s}\n", .{path});
    // Notify all WebSocket clients to reload
}
```

### Microtask Integration

```zig
// In Ripple's signal.zig - integrate with zsync microtask queue
pub fn queueEffectUpdate(effect: *Effect) !void {
    try zsync.queueMicrotask(runEffect, effect);
}

pub fn flushEffects() !void {
    try zsync.flushMicrotasks();
}
```

**Full documentation**: [`docs/wasm/RIPPLE_WASM_FEATURES.md`](wasm/RIPPLE_WASM_FEATURES.md)

---

## 👻 Ghostshell - Terminal Emulator

**Project**: `/data/projects/ghostshell`
**What it is**: NVIDIA-optimized terminal emulator (Ghostty fork)
**Status**: Beta, zsync integration in progress (step 8)

### What Ghostshell Needs from Zsync

1. **PTY (Pseudo-Terminal) handling**
2. **Async I/O** for terminal rendering
3. **Non-blocking read/write** to child processes
4. **Event loop integration** with GPU rendering

### Integration

```zig
const zsync = @import("zsync");

// Create PTY for shell process
pub fn spawnShell(allocator: std.mem.Allocator) !zsync.Pty {
    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);

    const pty_config = zsync.PtyConfig{
        .rows = 24,
        .cols = 80,
        .cwd = std.os.getenv("HOME"),
    };

    var pty = try zsync.Pty.init(allocator, pty_config);

    // Spawn shell
    const argv = &[_][]const u8{"/bin/zsh"};
    try pty.spawn(argv);

    return pty;
}

// Async read from PTY
pub fn readPtyAsync(pty: *zsync.Pty) ![]const u8 {
    return try pty.read(); // Non-blocking async read
}

// Async write to PTY
pub fn writePtyAsync(pty: *zsync.Pty, data: []const u8) !void {
    _ = try pty.write(data);
}

// Handle terminal resize
pub fn resizeTerminal(pty: *zsync.Pty, rows: u16, cols: u16) !void {
    try pty.resize(rows, cols);
}
```

### Terminal Attributes

```zig
// Make terminal raw mode (disable echo, etc.)
pub fn setupRawMode(fd: std.posix.fd_t) !void {
    var attr = try zsync.TermAttr.get(fd);
    attr.makeRaw();
    try attr.set(fd);
}
```

**Features**:
- ✅ Non-blocking PTY I/O
- ✅ Async read/write to child process
- ✅ Window resize handling
- ✅ Terminal attribute management
- ✅ Child process lifecycle

---

## 🐚 GShell - Modern Shell

**Project**: `/data/projects/gshell`
**What it is**: Next-gen shell with Ghostlang scripting (Bash/Zsh alternative)
**Status**: Beta Ready

### What GShell Needs from Zsync

1. **Plugin system** for loading Ghostlang plugins
2. **Async command execution**
3. **Job control** with task spawning
4. **Script integration** with Ghostlang engine

### Integration

```zig
const zsync = @import("zsync");
const ghostlang = @import("ghostlang");

// Plugin manager for GShell
pub fn initPlugins(allocator: std.mem.Allocator) !*zsync.PluginManager {
    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);

    var manager = zsync.PluginManager.init(allocator, runtime);

    // Add plugin directories
    try manager.addPluginDir("~/.config/gshell/plugins");
    try manager.addPluginDir("/usr/share/gshell/plugins");

    // Discover and register plugins
    const plugins = try zsync.discoverPlugins(allocator, "~/.config/gshell/plugins");
    for (plugins) |plugin_path| {
        std.debug.print("Found plugin: {s}\n", .{plugin_path});
    }

    return &manager;
}

// Load Ghostlang plugin
pub fn loadGhostlangPlugin(
    manager: *zsync.PluginManager,
    name: []const u8,
    script_path: []const u8,
) !void {
    const metadata = zsync.PluginMetadata{
        .name = name,
        .version = "1.0.0",
        .description = "GShell plugin",
    };

    const hooks = zsync.PluginHooks{
        .on_load = onPluginLoad,
        .on_unload = onPluginUnload,
    };

    var plugin = try zsync.Plugin.init(
        manager.allocator,
        metadata,
        script_path,
        hooks,
    );

    try manager.registerPlugin(&plugin);
    try manager.loadPlugin(name);
}

fn onPluginLoad(plugin: *zsync.Plugin) !void {
    std.debug.print("Loading plugin: {s}\n", .{plugin.metadata.name});
    // Execute Ghostlang script
}

fn onPluginUnload(plugin: *zsync.Plugin) !void {
    std.debug.print("Unloading plugin: {s}\n", .{plugin.metadata.name});
}
```

### Async Command Execution

```zig
// Execute command asynchronously
pub fn execCommandAsync(cmd: []const u8) !void {
    var handle = try zsync.spawnTask(runCommand, .{cmd});
    try handle.join();
}

fn runCommand(cmd: []const u8) !void {
    // Execute shell command
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    std.debug.print("{s}", .{result.stdout});
}
```

**Features**:
- ✅ Dynamic plugin loading/unloading
- ✅ Plugin lifecycle management (load, enable, disable, reload)
- ✅ Plugin discovery in directories
- ✅ Ghostlang script integration
- ✅ Async command execution

---

## 👻 Ghostlang - Lua Alternative

**Project**: `/data/projects/ghostlang`
**What it is**: Lightweight embedded scripting engine (Lua replacement)
**Status**: v0.16.0-dev

### What Ghostlang Needs from Zsync

1. **Async function execution** from scripts
2. **Channel communication** between script and Zig
3. **Timer/setTimeout** for scripts
4. **Event emitters** for callbacks

### Integration

```zig
const zsync = @import("zsync");
const ghostlang = @import("ghostlang");

// Create script engine with zsync integration
pub fn createScriptEngine(allocator: std.mem.Allocator) !*zsync.ScriptEngine {
    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);

    var engine = zsync.ScriptEngine.init(allocator, runtime);

    // Register async Zig functions
    try engine.registerFunction("setTimeout", setTimeoutFromScript);
    try engine.registerFunction("fetch", fetchFromScript);
    try engine.registerFunction("spawn", spawnFromScript);

    return &engine;
}

// setTimeout implementation for scripts
fn setTimeoutFromScript(args: []const zsync.ScriptValue) zsync.ScriptValue {
    const callback = args[0].function;
    const delay_ms = @as(u64, @intFromFloat(args[1].number));

    // Create timer
    var timer = zsync.ScriptTimer.init(
        runtime,
        callback,
        delay_ms,
        false, // Don't repeat
    );

    // Start timer asynchronously
    _ = zsync.spawnTask(timer.start, .{}) catch return .nil;

    return .nil;
}
```

### Script Channels

```zig
// Create channel accessible from Ghostlang
pub fn createScriptChannel(comptime T: type, allocator: std.mem.Allocator) !zsync.ScriptChannel(T) {
    return try zsync.ScriptChannel(T).init(allocator);
}

// In Ghostlang script (pseudo-code):
// local chan = createChannel()
// chan.send(42)
// local value = chan.recv()
```

### FFI Type Conversion

```zig
// Convert Zig value to script value
const script_val = zsync.ScriptFFI.toScriptValue(42);
std.debug.print("Script value: {}\n", .{script_val.number}); // 42.0

// Convert script value to Zig value
const zig_val = zsync.ScriptFFI.fromScriptValue(i32, script_val);
std.debug.print("Zig value: {}\n", .{zig_val.?}); // 42
```

**Features**:
- ✅ Script → Zig FFI helpers
- ✅ Async function execution from scripts
- ✅ Channels for script-Zig communication
- ✅ Timers/setTimeout for scripts
- ✅ Event emitters for callbacks
- ✅ Type conversion helpers

---

## 🌲 Grove - Tree-sitter Wrapper

**Project**: `/data/projects/grove`
**What it is**: High-performance Tree-sitter wrapper for Grim editor
**Status**: Phase 2 - Production Integration

### What Grove Needs from Zsync

1. **LSP Server** for Grim editor
2. **Async parsing** for large files
3. **File watching** for incremental re-parsing
4. **Background highlighting**

### Integration

```zig
const zsync = @import("zsync");
const grove = @import("grove");

// LSP server for Grim
pub fn startGrimLsp(allocator: std.mem.Allocator) !void {
    var config = zsync.Config.forServer();
    var runtime = try zsync.Runtime.init(allocator, &config);

    const server_config = zsync.LspServerConfig{
        .name = "grim-lsp",
        .version = "0.1.0",
        .capabilities = .{
            .text_document_sync = .full,
            .completion_provider = true,
            .hover_provider = true,
            .definition_provider = true,
            .document_highlight_provider = true,
            .document_symbol_provider = true,
            .semantic_tokens_provider = true,
        },
    };

    var server = try zsync.LspServer.init(allocator, runtime, server_config);
    defer server.deinit();

    // Register handlers
    try server.registerHandler("textDocument/completion", handleCompletion);
    try server.registerHandler("textDocument/hover", handleHover);
    try server.registerHandler("textDocument/definition", handleDefinition);
    try server.registerHandler("textDocument/documentHighlight", handleHighlight);

    // Start server
    try server.run();
}

fn handleCompletion(params: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    _ = params;
    _ = allocator;
    // Use Grove to parse and provide completions
    return .null;
}

fn handleHover(params: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    _ = params;
    _ = allocator;
    // Use Grove syntax tree for hover info
    return .null;
}
```

### Async Parsing

```zig
// Parse file asynchronously
pub fn parseFileAsync(path: []const u8, lang: grove.Language) !void {
    var handle = try zsync.spawnTask(parseFile, .{ path, lang });
    const tree = try handle.join();
    std.debug.print("Parsed: {s}\n", .{path});
    _ = tree;
}

fn parseFile(path: []const u8, lang: grove.Language) !void {
    // Use Grove to parse
    _ = path;
    _ = lang;
}
```

### File Watching for Incremental Updates

```zig
// Watch files and re-parse on change
pub fn watchAndParse(allocator: std.mem.Allocator) !void {
    var watcher = try zsync.FileWatcher.init(allocator, onFileChange, 100, true);
    defer watcher.deinit();

    try watcher.watch("src/");
    try watcher.start();
}

fn onFileChange(path: []const u8, event: zsync.WatchEvent) void {
    if (event == .modified) {
        std.debug.print("Re-parsing: {s}\n", .{path});
        // Re-parse with Grove
    }
}
```

**Features**:
- ✅ Complete LSP server implementation
- ✅ JSON-RPC message handling
- ✅ LSP method registration
- ✅ Position, Range, Location types
- ✅ Diagnostic support
- ✅ Text edits
- ✅ Async parsing support

---

## Summary Table

| Project | Status | Zsync Features Used |
|---------|--------|---------------------|
| **Ripple** | Alpha | WebSocket, File Watcher, Microtask Queue, Promise, HTTP Server |
| **Ghostshell** | Beta (Step 8) | PTY, TermAttr, Async I/O, Terminal Resize |
| **GShell** | Beta Ready | Plugin System, Async Commands, Ghostlang Integration |
| **Ghostlang** | v0.16.0-dev | Script Runtime, FFI, Channels, Timers, Event Emitters |
| **Grove** | Phase 2 | LSP Server, Async Parsing, File Watcher |

---

## Build All Projects with Zsync

```bash
# Build zsync
cd /data/projects/zsync
zig build

# Each project can now use zsync
cd /data/projects/ripple && zig build
cd /data/projects/ghostshell && zig build
cd /data/projects/gshell && zig build
cd /data/projects/ghostlang && zig build
cd /data/projects/grove && zig build
```

---

## Next Steps

1. **Ripple**: Integrate WebSocket HMR and microtask queue
2. **Ghostshell**: Complete step 8 - zsync async runtime integration
3. **GShell**: Add plugin loading with Ghostlang scripts
4. **Ghostlang**: Expose async FFI functions
5. **Grove**: Implement LSP handlers using zsync

---

**Zsync v0.6.0 - Powering Your Entire Ecosystem! 🚀**
