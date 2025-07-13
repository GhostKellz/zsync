# TokioZ + zquic Integration Guide

> **🚀 TokioZ is now production-ready for your zquic QUIC/HTTP3 library integration!**

This guide explains how to integrate TokioZ async runtime with your `github.com/ghostkellz/zquic` QUIC implementation for high-performance async networking.

---

## 🎯 Integration Overview

TokioZ provides the perfect async foundation for QUIC because:

- **✅ I/O-optimized runtime** - Specifically designed for high-throughput network protocols
- **✅ Cross-platform polling** - Works on Linux (epoll), macOS (kqueue), Windows (poll)
- **✅ Priority task scheduling** - Critical for QUIC handshakes and urgent packet processing
- **✅ Timer coordination** - Essential for QUIC retransmissions and timeouts
- **✅ Memory-efficient** - Frame pooling and zero-copy where possible

---

## 🏗️ Architecture Integration

### **QUIC Connection Management with TokioZ**

```zig
// In your zquic library
const TokioZ = @import("tokioz");

pub const QuicServer = struct {
    runtime: *TokioZ.Runtime,
    socket: std.net.UdpSocket,
    connections: std.HashMap(ConnectionId, *QuicConnection),
    
    pub fn init(allocator: std.mem.Allocator, addr: std.net.Address) !QuicServer {
        // Use TokioZ I/O-optimized runtime for QUIC
        const runtime = try TokioZ.Runtime.init(allocator, .{
            .event_loop_config = TokioZ.EventLoopConfig{
                .max_events_per_poll = 4096,  // High-throughput QUIC
                .poll_timeout_ms = 1,         // Low-latency polling
                .max_tasks_per_tick = 64,     // Handle many connections
            }
        });
        
        const socket = try std.net.UdpSocket.init(addr.any.family);
        try socket.bind(addr);
        
        return QuicServer{
            .runtime = runtime,
            .socket = socket,
            .connections = std.HashMap(ConnectionId, *QuicConnection).init(allocator),
        };
    }
    
    pub fn run(self: *QuicServer) !void {
        // Use TokioZ I/O-focused runtime for optimal QUIC performance
        try TokioZ.runIoFocused(self.serverLoop);
    }
    
    fn serverLoop(self: *QuicServer) !void {
        // Register UDP socket for async I/O
        const waker = self.runtime.createWaker();
        try TokioZ.registerIo(self.socket.fd, .{ .read = true }, &waker);
        
        while (true) {
            // Wait for incoming packets
            const packet = try self.receivePacket();
            
            // Spawn urgent task for QUIC packet processing
            _ = try TokioZ.spawnUrgent(self.processPacket, .{packet});
        }
    }
};
```

---

## 🔥 Critical QUIC Use Cases

### **1. QUIC Handshake (High Priority)**

```zig
// QUIC handshakes are time-sensitive - use urgent priority
fn handleQuicHandshake(self: *QuicConnection, initial_packet: QuicPacket) !void {
    // Process Initial packet
    const server_hello = try self.processInitial(initial_packet);
    
    // Send response with timeout
    _ = try TokioZ.spawnUrgent(self.sendWithTimeout, .{ server_hello, 3000 });
    
    // Set handshake timeout
    try TokioZ.sleep(5000); // 5 second handshake timeout
    if (!self.handshake_complete) {
        return error.HandshakeTimeout;
    }
}

fn sendWithTimeout(self: *QuicConnection, packet: QuicPacket, timeout_ms: u64) !void {
    const start_time = std.time.milliTimestamp();
    
    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        if (try self.trySend(packet)) {
            return; // Success
        }
        try TokioZ.sleep(10); // Retry every 10ms
    }
    
    return error.SendTimeout;
}
```

### **2. QUIC Stream Management**

```zig
pub const QuicStream = struct {
    id: StreamId,
    connection: *QuicConnection,
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    
    pub fn write(self: *QuicStream, data: []const u8) !void {
        // Add data to send buffer
        try self.send_buffer.appendSlice(data);
        
        // Schedule async send (normal priority)
        _ = try TokioZ.spawn(self.flushSendBuffer, .{});
    }
    
    pub fn read(self: *QuicStream, buffer: []u8) !usize {
        // Check if data is available
        if (self.recv_buffer.items.len == 0) {
            // Wait for data with timeout
            _ = try TokioZ.spawn(self.waitForData, .{});
            try TokioZ.sleep(100); // 100ms read timeout
        }
        
        const bytes_to_copy = @min(buffer.len, self.recv_buffer.items.len);
        @memcpy(buffer[0..bytes_to_copy], self.recv_buffer.items[0..bytes_to_copy]);
        
        // Remove copied data from buffer
        self.recv_buffer.replaceRange(0, bytes_to_copy, &[_]u8{}) catch {};
        
        return bytes_to_copy;
    }
    
    fn flushSendBuffer(self: *QuicStream) !void {
        while (self.send_buffer.items.len > 0) {
            const chunk_size = @min(self.send_buffer.items.len, 1200); // MTU limit
            const chunk = self.send_buffer.items[0..chunk_size];
            
            // Send chunk as QUIC STREAM frame
            try self.connection.sendStreamFrame(self.id, chunk);
            
            // Remove sent data
            self.send_buffer.replaceRange(0, chunk_size, &[_]u8{}) catch {};
            
            // Yield to other tasks
            TokioZ.yieldNow();
        }
    }
};
```

### **3. QUIC Retransmission (Timer-based)**

```zig
pub const QuicRetransmission = struct {
    packets: std.ArrayList(PendingPacket),
    connection: *QuicConnection,
    
    pub fn scheduleRetransmission(self: *QuicRetransmission, packet: QuicPacket) !void {
        const pending = PendingPacket{
            .packet = packet,
            .sent_time = std.time.milliTimestamp(),
            .retransmit_time = std.time.milliTimestamp() + self.calculateRTO(),
        };
        
        try self.packets.append(pending);
        
        // Schedule retransmission check (normal priority)
        _ = try TokioZ.spawn(self.checkRetransmissions, .{});
    }
    
    fn checkRetransmissions(self: *QuicRetransmission) !void {
        while (true) {
            const now = std.time.milliTimestamp();
            
            var i: usize = 0;
            while (i < self.packets.items.len) {
                const pending = &self.packets.items[i];
                
                if (now >= pending.retransmit_time) {
                    // Retransmit packet (urgent priority)
                    _ = try TokioZ.spawnUrgent(self.retransmitPacket, .{pending.packet});
                    
                    // Update retransmission time
                    pending.retransmit_time = now + self.calculateRTO();
                }
                
                i += 1;
            }
            
            // Check every 10ms
            try TokioZ.sleep(10);
        }
    }
    
    fn calculateRTO(self: *QuicRetransmission) u64 {
        // QUIC RTO calculation based on RTT measurements
        return @max(self.connection.srtt + 4 * self.connection.rttvar, 25);
    }
};
```

---

## 🌐 HTTP/3 Integration

### **HTTP/3 Server with TokioZ**

```zig
pub const Http3Server = struct {
    quic_server: QuicServer,
    request_handlers: std.HashMap([]const u8, RequestHandler),
    
    pub fn init(allocator: std.mem.Allocator, addr: std.net.Address) !Http3Server {
        return Http3Server{
            .quic_server = try QuicServer.init(allocator, addr),
            .request_handlers = std.HashMap([]const u8, RequestHandler).init(allocator),
        };
    }
    
    pub fn handle(self: *Http3Server, path: []const u8, handler: RequestHandler) !void {
        try self.request_handlers.put(path, handler);
    }
    
    pub fn run(self: *Http3Server) !void {
        // Start QUIC server with TokioZ I/O-optimized runtime
        try self.quic_server.run();
    }
    
    fn processHttp3Request(self: *Http3Server, stream: *QuicStream) !void {
        // Parse HTTP/3 request headers
        const request = try self.parseHttp3Headers(stream);
        
        // Find handler
        if (self.request_handlers.get(request.path)) |handler| {
            // Process request (normal priority)
            _ = try TokioZ.spawn(handler, .{ request, stream });
        } else {
            // Send 404 (urgent priority for quick response)
            _ = try TokioZ.spawnUrgent(self.send404, .{stream});
        }
    }
};

// Example HTTP/3 handler
fn apiHandler(request: Http3Request, stream: *QuicStream) !void {
    const response = "HTTP/3 API Response from TokioZ + zquic!";
    
    // Send HTTP/3 response headers
    try stream.write("HTTP/3 200 OK\r\n");
    try stream.write("content-length: ");
    try stream.write(std.fmt.allocPrint(stream.connection.allocator, "{}\r\n", .{response.len}));
    try stream.write("\r\n");
    
    // Send response body
    try stream.write(response);
    
    // Close stream
    try stream.close();
}
```

---

## 📊 Performance Optimization

### **TokioZ Configuration for QUIC**

```zig
// Optimal TokioZ configuration for QUIC workloads
const quic_optimized_config = TokioZ.Runtime.Config{
    .max_tasks = 2048,              // Handle many concurrent connections
    .enable_io = true,              // Essential for QUIC
    .enable_timers = true,          // Critical for QUIC timeouts
    .event_loop_config = .{
        .max_events_per_poll = 4096,    // High-throughput UDP
        .poll_timeout_ms = 1,           // Low-latency for real-time protocols
        .max_tasks_per_tick = 64,       // Balance throughput vs latency
        .enable_timers = true,          // QUIC timer wheel
        .enable_io = true,              // UDP I/O events
    },
};

// Use I/O-focused runtime variant
try TokioZ.runIoFocused(quicServerMain);
```

### **Memory Management for QUIC**

```zig
// Efficient packet buffer management with TokioZ
pub const QuicPacketPool = struct {
    allocator: std.mem.Allocator,
    free_packets: std.ArrayList(*QuicPacket),
    
    pub fn getPacket(self: *QuicPacketPool) !*QuicPacket {
        if (self.free_packets.items.len > 0) {
            return self.free_packets.pop();
        }
        
        // Allocate new packet (will be reused)
        return try self.allocator.create(QuicPacket);
    }
    
    pub fn returnPacket(self: *QuicPacketPool, packet: *QuicPacket) !void {
        // Reset packet state
        packet.reset();
        
        // Return to pool for reuse
        try self.free_packets.append(packet);
    }
};
```

---

## 🧪 Testing Integration

### **QUIC + TokioZ Integration Tests**

```zig
test "QUIC handshake with TokioZ" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create QUIC client and server
    var server = try QuicServer.init(allocator, try std.net.Address.parseIp4("127.0.0.1", 4433));
    defer server.deinit();
    
    var client = try QuicClient.init(allocator);
    defer client.deinit();
    
    // Start server in background
    const server_task = try TokioZ.spawnAsync(server.run, .{});
    
    // Connect client
    const connection = try client.connect(try std.net.Address.parseIp4("127.0.0.1", 4433));
    
    // Test data transfer
    const test_data = "Hello QUIC with TokioZ!";
    const stream = try connection.openStream();
    try stream.write(test_data);
    
    var buffer: [1024]u8 = undefined;
    const bytes_read = try stream.read(&buffer);
    
    try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
    
    // Cleanup
    try connection.close();
    server_task.cancel();
}

test "HTTP/3 request with TokioZ" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Setup HTTP/3 server
    var http3_server = try Http3Server.init(allocator, try std.net.Address.parseIp4("127.0.0.1", 8443));
    defer http3_server.deinit();
    
    try http3_server.handle("/api/test", apiHandler);
    
    // Start server
    const server_task = try TokioZ.spawnAsync(http3_server.run, .{});
    defer server_task.cancel();
    
    // Make HTTP/3 request
    var client = try Http3Client.init(allocator);
    defer client.deinit();
    
    const response = try client.get("https://127.0.0.1:8443/api/test");
    try testing.expect(response.status == 200);
}
```

---

## 🚀 Real-world Example

### **Complete QUIC Echo Server**

```zig
// examples/quic_echo_server.zig
const std = @import("std");
const TokioZ = @import("tokioz");
const zquic = @import("zquic");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🚀 Starting QUIC Echo Server with TokioZ...\n", .{});
    
    // Create QUIC server with TokioZ runtime
    var server = try zquic.QuicServer.init(allocator, try std.net.Address.parseIp4("0.0.0.0", 4433));
    defer server.deinit();
    
    // Set connection handler
    server.onConnection(handleConnection);
    
    // Run with TokioZ I/O-optimized runtime
    try TokioZ.runIoFocused(server.run);
}

fn handleConnection(connection: *zquic.QuicConnection) !void {
    std.debug.print("📡 New QUIC connection: {}\n", .{connection.id});
    
    while (connection.isActive()) {
        // Wait for new stream
        if (try connection.acceptStream()) |stream| {
            // Handle stream in parallel (normal priority)
            _ = try TokioZ.spawn(handleStream, .{stream});
        }
        
        // Yield to other connections
        TokioZ.yieldNow();
    }
}

fn handleStream(stream: *zquic.QuicStream) !void {
    std.debug.print("📨 New stream: {}\n", .{stream.id});
    
    var buffer: [4096]u8 = undefined;
    
    while (true) {
        // Read data with timeout
        const bytes_read = stream.read(&buffer) catch |err| switch (err) {
            error.StreamClosed => break,
            error.Timeout => continue,
            else => return err,
        };
        
        if (bytes_read == 0) break;
        
        // Echo data back
        try stream.write(buffer[0..bytes_read]);
        
        std.debug.print("↪️  Echoed {} bytes\n", .{bytes_read});
    }
    
    std.debug.print("✅ Stream {} closed\n", .{stream.id});
}
```

---

## 📋 Integration Checklist

### **TokioZ Setup** ✅
- [x] TokioZ runtime initialized and working
- [x] I/O-optimized configuration ready
- [x] Cross-platform polling functional
- [x] Timer system integrated
- [x] Task scheduling with priorities

### **zquic Integration Tasks**
- [ ] Import TokioZ into your zquic project
- [ ] Replace existing event loop with `TokioZ.runIoFocused()`
- [ ] Use `TokioZ.spawnUrgent()` for handshake processing
- [ ] Use `TokioZ.spawn()` for normal packet processing
- [ ] Use `TokioZ.registerIo()` for UDP socket management
- [ ] Use `TokioZ.sleep()` for timeout implementations
- [ ] Integrate timer wheel for retransmissions

### **Performance Testing**
- [ ] Benchmark QUIC handshake latency
- [ ] Test concurrent connection handling
- [ ] Measure packet processing throughput
- [ ] Validate timer accuracy for retransmissions
- [ ] Memory usage profiling

### **Production Readiness**
- [ ] Error handling integration
- [ ] Logging and monitoring setup
- [ ] Configuration management
- [ ] Security considerations
- [ ] Load testing under high concurrency

---

## 🎯 Expected Benefits

### **Performance Gains**
- **🚀 Lower Latency**: Optimized polling reduces packet processing delay
- **📊 Higher Throughput**: Efficient task scheduling handles more connections
- **💾 Memory Efficiency**: Frame pooling reduces allocation overhead
- **⚡ Real-time Response**: Priority scheduling for critical QUIC operations

### **Development Benefits**
- **🛠️ Async-First**: Built for async networking protocols like QUIC
- **🔧 Cross-Platform**: Works on Linux, macOS, Windows
- **📚 Zig-Native**: No FFI overhead, direct Zig integration
- **🧪 Testable**: Comprehensive testing framework

---

## 🤝 Next Steps

1. **Import TokioZ** into your zquic project
2. **Replace event loop** with TokioZ runtime
3. **Implement QUIC handlers** using TokioZ async primitives
4. **Test integration** with provided examples
5. **Optimize performance** based on your QUIC requirements
6. **Deploy and monitor** in production

---

**🎉 Ready to build high-performance QUIC with TokioZ + zquic!**

*For questions or issues during integration, refer to the TokioZ documentation or create an issue in the repository.*
