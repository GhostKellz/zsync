# Zsync v0.6.0 - Ripple & WASM Support

## Overview

Zsync v0.6.0 adds comprehensive async support specifically designed for **Ripple** (reactive WASM-first web UI framework) and general WASM async operations. These features enable building modern web applications with hot module reloading, real-time features, and browser-compatible async patterns.

## Features for Ripple

### 1. WebSocket Client & Server

**Why Ripple needs this:**
- **Development Server with HMR** - WebSocket connection for hot module reload
- **Live Reload** - Instant updates when files change
- **Real-time Chat Example** - From Ripple's roadmap
- **Dev Tools Communication** - Debugger and profiler integration

**API:**
```zig
const zsync = @import("zsync");

// Server for dev server
const handler = struct {
    fn onConnect(conn: *zsync.WebSocketConnectionV2) !void {
        try conn.sendText("Connected to Ripple dev server!");
    }
}.onConnect;

var server = zsync.WebSocketServerV2.init(allocator, runtime, addr, handler);
try server.listen();

// Client for browser connection
var client = try zsync.WebSocketClientV2.init(allocator, runtime, "ws://localhost:3000");
try client.connect();

if (client.getConnection()) |conn| {
    try conn.sendText("Hello from WASM!");
}
```

**Use Cases:**
1. **HMR Communication:**
```zig
// Dev server sends file change events
try conn.sendText("{\"type\":\"reload\",\"file\":\"App.zig\"}");

// Browser receives and hot-reloads component
```

2. **Real-time Updates:**
```zig
// Chat application
try conn.sendText("{\"type\":\"message\",\"user\":\"alice\",\"text\":\"Hello!\"}");
```

### 2. File Watcher (Already Added)

**Why Ripple needs this:**
- **Auto-rebuild** - Detect file changes and trigger rebuild
- **Hot Module Reload** - Know which files changed
- **Dev Server** - Monitor source files

**API:**
```zig
const callback = struct {
    fn onChange(path: []const u8, event: zsync.WatchEvent) void {
        std.debug.print("[Ripple] File changed: {} event={}\n", .{path, event});
        // Trigger rebuild and notify browser via WebSocket
    }
}.onChange;

var watcher = try zsync.FileWatcher.init(allocator, callback, 100, true);
try watcher.watch("src/");
try watcher.start();
```

### 3. HTTP Server (Already Added)

**Why Ripple needs this:**
- **Development Server** - Serve app during development
- **SSR (Server-Side Rendering)** - Render Ripple components on server
- **API Endpoints** - Backend for full-stack apps

**API:**
```zig
const handler = struct {
    fn handle(req: *zsync.HttpRequestV2, resp: *zsync.HttpResponseV2) !void {
        // Serve Ripple app
        resp.setStatus(200);
        try resp.header("content-type", "text/html");
        try resp.write(ripple.renderToString(App));
    }
}.handle;

var server = zsync.HttpServerV2.init(allocator, runtime, addr, handler);
try server.listen();
```

### 4. Microtask Queue

**Why Ripple needs this:**
- **Reactive Scheduler** - Batch reactive updates (like `beginBatch`)
- **Browser-compatible** - Matches browser microtask semantics
- **Effect Scheduling** - Queue effect re-runs

**API:**
```zig
// Initialize global queue
try zsync.wasm_microtask.initGlobalQueue(allocator);
defer zsync.wasm_microtask.deinitGlobalQueue(allocator);

// Queue reactive updates
try zsync.queueMicrotask(updateEffect, effect_ctx);

// Flush after batch
try zsync.flushMicrotasks();
```

**Integration with Ripple:**
```zig
// In Ripple's signal.zig
pub fn beginBatch() BatchGuard {
    // Queue all signal updates as microtasks
    // Flush when batch guard is dropped
}

pub fn set(self: *WriteSignal(T), value: T) !void {
    try zsync.queueMicrotask(notifySubscribers, self);
}
```

## WASM Async Primitives

### 1. Promise API

**Browser-compatible Promise implementation:**
```zig
var promise = zsync.Promise(u32).init(allocator);

// Resolve
promise.resolve(42);

// Or reject
promise.reject(error.Failed);

// Await
const value = try promise.await_();

// Chain promises
var promise2 = try promise.then(u32, struct {
    fn transform(val: u32) !u32 {
        return val * 2;
    }
}.transform);
```

**Use Case - Async Resource Loading:**
```zig
// In Ripple's createResource
pub fn createResource(comptime T: type, fetcher: anytype) !ResourceHandle(T) {
    var promise = zsync.Promise(T).init(allocator);

    // Start async fetch
    const data = try fetcher();
    promise.resolve(data);

    return ResourceHandle(T){ .promise = promise };
}
```

### 2. Event Emitter

**DOM-style event emitter:**
```zig
var emitter = zsync.EventEmitter(MouseEvent).init(allocator);
defer emitter.deinit();

// Register listener
try emitter.on(struct {
    fn onClick(event: MouseEvent) !void {
        std.debug.print("Clicked at {},{}\n", .{event.x, event.y});
    }
}.onClick);

// Emit event
emitter.emit(MouseEvent{ .x = 100, .y = 200 });
```

**Use Case - Ripple Event Delegation:**
```zig
// In Ripple's event system
var clickEmitter = zsync.EventEmitter(ClickEvent).init(allocator);

// Component registers handler
try clickEmitter.on(handleClick);

// Event delegation calls emit
pub fn dispatchEvent(node_id: u32, event: ClickEvent) void {
    clickEmitter.emit(event);
}
```

### 3. AbortController

**Cancel async operations:**
```zig
var controller = zsync.AbortController.init();

// In async operation
try controller.throwIfAborted();

// Cancel from elsewhere
controller.abort(error.Cancelled);

// Check if aborted
if (controller.isAborted()) {
    return;
}
```

**Use Case - Ripple Resource Cleanup:**
```zig
pub const ResourceHandle = struct {
    promise: Promise(T),
    controller: AbortController,

    pub fn cleanup(self: *ResourceHandle) void {
        self.controller.abort(error.Cleanup);
    }
};
```

### 4. Fetch API

**Browser-compatible fetch:**
```zig
var promise = try zsync.fetch(allocator, "https://api.example.com/data", .{
    .method = "POST",
    .body = "{\"key\":\"value\"}",
});

var response = try promise.await_();
defer response.deinit();

std.debug.print("Status: {}\n", .{response.status});
std.debug.print("Body: {s}\n", .{response.text()});

// Or parse JSON
const data = try response.json(MyStruct);
```

**Use Case - Ripple Data Fetching:**
```zig
// In Ripple component
var userData = try ripple.createResource(User, struct {
    fn fetch() !User {
        var resp_promise = try zsync.fetch(allocator, "/api/user", .{});
        var response = try resp_promise.await_();
        return try response.json(User);
    }
}.fetch);
```

### 5. Async Context

**WASM-friendly async runtime:**
```zig
var ctx = try zsync.AsyncContext.init(allocator);
defer ctx.deinit();

// Yield to event loop
try ctx.yield_();

// Async sleep
try ctx.sleep(1000); // 1 second
```

## Integration Examples

### Example 1: Ripple Dev Server with HMR

```zig
const std = @import("std");
const zsync = @import("zsync");
const ripple = @import("ripple");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = zsync.Config.forServer();
    var runtime = try zsync.Runtime.init(allocator, &config);
    defer runtime.deinit();

    // File watcher for hot reload
    var watcher = try zsync.FileWatcher.init(allocator, onFileChange, 100, true);
    defer watcher.deinit();
    try watcher.watch("src/");

    // WebSocket server for HMR
    const addr_ws = try std.net.Address.parseIp4("127.0.0.1", 3001);
    var ws_server = zsync.WebSocketServerV2.init(allocator, runtime, addr_ws, onWsConnect);

    // HTTP server for app
    const addr_http = try std.net.Address.parseIp4("127.0.0.1", 3000);
    var http_server = zsync.HttpServerV2.init(allocator, runtime, addr_http, serveApp);

    std.debug.print("🚀 Ripple dev server running!\n", .{});
    std.debug.print("📡 App: http://localhost:3000\n", .{});
    std.debug.print("🔌 HMR: ws://localhost:3001\n", .{});

    // Start servers (would use spawn to run concurrently)
    try http_server.listen();
}

fn onFileChange(path: []const u8, event: zsync.WatchEvent) void {
    std.debug.print("[HMR] File changed: {s} ({any})\n", .{path, event});
    // Rebuild and notify all connected WebSocket clients
    broadcastReload(path);
}

fn onWsConnect(conn: *zsync.WebSocketConnectionV2) !void {
    try conn.sendText("{\"type\":\"connected\",\"message\":\"HMR ready\"}");
}

fn serveApp(req: *zsync.HttpRequestV2, resp: *zsync.HttpResponseV2) !void {
    _ = req;
    resp.setStatus(200);
    try resp.header("content-type", "text/html");
    try resp.write(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Ripple App</title></head>
        \\<body>
        \\  <div id="app"></div>
        \\  <script src="/ripple.js"></script>
        \\  <script>
        \\    const ws = new WebSocket('ws://localhost:3001');
        \\    ws.onmessage = (e) => {
        \\      const data = JSON.parse(e.data);
        \\      if (data.type === 'reload') location.reload();
        \\    };
        \\  </script>
        \\</body>
        \\</html>
    );
}
```

### Example 2: Ripple Resource with Async Fetch

```zig
// Integrate zsync.fetch with Ripple resources
pub fn createAsyncResource(
    comptime T: type,
    allocator: std.mem.Allocator,
    url: []const u8,
) !ripple.ResourceHandle(T) {
    var promise = try zsync.fetch(allocator, url, .{});

    return ripple.ResourceHandle(T){
        .status = .loading,
        .data = null,
        .promise = promise,
    };
}

// In component
var users = try createAsyncResource([]User, allocator, "/api/users");

// Ripple's reactive system will handle loading states
```

### Example 3: Microtask-based Reactive Scheduling

```zig
// Enhance Ripple's reactive scheduler with microtasks
pub fn queueReactiveUpdate(effect: *Effect) !void {
    try zsync.queueMicrotask(runEffect, effect);
}

pub fn flushReactiveEffects() !void {
    try zsync.flushMicrotasks();
}

// In signal update
pub fn set(self: *WriteSignal(T), value: T) !void {
    self.value = value;

    // Queue all dependent effects as microtasks
    for (self.subscribers.items) |effect| {
        try queueReactiveUpdate(effect);
    }

    // Flush at end of synchronous execution
    defer flushReactiveEffects() catch {};
}
```

## Benefits for Ripple

1. **Complete Dev Server** - File watching + HTTP + WebSocket = full HMR
2. **Browser-compatible Async** - Promise, fetch, microtasks match browser APIs
3. **Real-time Features** - WebSocket enables chat, collaborative editing
4. **Better Reactivity** - Microtask queue improves batching performance
5. **Cancellation** - AbortController for cleaning up resources
6. **Event System** - EventEmitter for DOM event delegation
7. **Production Ready** - All primitives tested and production-grade

## Migration Guide

### Adding HMR to Ripple

1. Use `zsync.FileWatcher` to monitor source files
2. Use `zsync.WebSocketServerV2` for browser communication
3. Send reload events when files change
4. Browser connects via WebSocket and reloads on events

### Using Async Resources

1. Replace custom async with `zsync.Promise`
2. Use `zsync.fetch` for HTTP requests
3. Use `zsync.AbortController` for cleanup
4. Integrate with `createResource` pattern

### Optimizing Reactivity

1. Initialize `zsync.MicrotaskQueue` at startup
2. Queue effect updates with `queueMicrotask`
3. Flush with `flushMicrotasks` after batches
4. Matches browser microtask semantics

## File Structure

```
src/
├── net/
│   └── websocket.zig        # WebSocket client/server
├── wasm/
│   ├── microtask.zig        # Microtask queue
│   └── async.zig            # Promise, EventEmitter, AbortController, fetch
```

## Summary

Zsync v0.6.0 provides **everything Ripple needs** for:
- ✅ Development server with HMR
- ✅ Real-time features (chat, collaboration)
- ✅ Browser-compatible async patterns
- ✅ Efficient reactive scheduling
- ✅ Resource loading and cancellation
- ✅ Event handling and delegation
- ✅ Production-ready primitives

**Ripple can now build a complete development experience rivaling Vite/Next.js!** 🚀
