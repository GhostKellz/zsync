# zsync API Q&A Guide

## Channel System Overview

The zsync library provides a powerful channel-based communication system for async message passing between tasks. This guide helps understand the API structure and usage patterns.

## Core Channel Types

### Channel(T)
The main channel implementation that supports both bounded and unbounded configurations.

```zig
// Basic channel structure
pub fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        capacity: Capacity,
        buffer: std.RingBuffer,
        // ... internal fields for synchronization
    };
}
```

### Capacity Types
```zig
pub const Capacity = union(enum) {
    unbounded,
    bounded: u32,
};
```

## Channel Creation Functions

### bounded() Function
Returns a struct with three fields: `channel`, `sender`, and `receiver`.

```zig
pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: u32) !struct {
    channel: *Channel(T),
    sender: Sender(T),
    receiver: Receiver(T),
}
```

**Usage Example:**
```zig
const ch = try zsync.bounded(i32, allocator, 10);
defer {
    ch.channel.deinit();
    allocator.destroy(ch.channel);
}

// Send data
try ch.sender.send(42);

// Receive data
const value = try ch.receiver.recv();
```

### unbounded() Function
Similar structure but with unlimited capacity (dynamically grows).

```zig
pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !struct {
    channel: *Channel(T),
    sender: Sender(T),
    receiver: Receiver(T),
}
```

## Sender and Receiver Types

### Sender(T)
Handle for sending messages to a channel.

```zig
pub fn Sender(comptime T: type) type {
    return struct {
        channel: *Channel(T),
        
        // Methods:
        pub fn send(self: Self, data: T) !void
        pub fn trySend(self: Self, data: T) !void
        pub fn close(self: Self) void
    };
}
```

### Receiver(T)
Handle for receiving messages from a channel.

```zig
pub fn Receiver(comptime T: type) type {
    return struct {
        channel: *Channel(T),
        
        // Methods:
        pub fn recv(self: Self) !T
        pub fn tryRecv(self: Self) !T
        pub fn close(self: Self) void
    };
}
```

## Error Handling

### ChannelError Enum
```zig
pub const ChannelError = error{
    ChannelClosed,
    ChannelFull,
    ChannelEmpty,
    ReceiverDropped,
    SenderDropped,
};
```

## Usage Patterns

### Basic Producer-Consumer Pattern
```zig
// Create channel
const ch = try bounded(i32, allocator, 10);
defer ch.channel.deinit();

// Producer function
fn producer(sender: Sender(i32)) !void {
    for (0..5) |i| {
        try sender.send(@intCast(i));
    }
}

// Consumer function  
fn consumer(receiver: Receiver(i32)) !void {
    while (true) {
        const value = receiver.recv() catch |err| switch (err) {
            error.ChannelClosed => break,
            else => return err,
        };
        // Process value...
    }
}
```

### Non-blocking Operations
```zig
// Try send without blocking
const result = ch.sender.trySend(42);
if (result) {
    // Success
} else |err| switch (err) {
    error.ChannelFull => {
        // Handle full channel
    },
    else => return err,
}

// Try receive without blocking
const value = ch.receiver.tryRecv() catch |err| switch (err) {
    error.ChannelEmpty => {
        // Handle empty channel
        return;
    },
    else => return err,
};
```

## OneShot Channels

For single-value communication:

```zig
pub fn OneShot(comptime T: type) type {
    return struct {
        // Methods:
        pub fn init() Self
        pub fn send(self: *Self, value: T) !void
        pub fn recv(self: *Self) !T
        pub fn tryRecv(self: *Self) !T
    };
}
```

**Usage:**
```zig
var oneshot = OneShot(i32).init();
try oneshot.send(100);
const value = try oneshot.recv();
```

## Integration with zsync Runtime

### Spawning Tasks with Channels
```zig
const runtime = try zsync.Runtime.init(allocator, .{});
defer runtime.deinit();

const ch = try zsync.bounded(i32, allocator, 10);
defer ch.channel.deinit();

// Spawn producer and consumer
_ = try runtime.spawn(producer, .{ch.sender});
_ = try runtime.spawn(consumer, .{ch.receiver});

// Run event loop
while (true) {
    const processed = try runtime.tick();
    if (processed == 0) {
        std.time.sleep(1 * std.time.ns_per_ms);
    }
}
```

## Memory Management

### Channel Lifecycle
1. Create channel with `bounded()` or `unbounded()`
2. Use sender/receiver for communication
3. Close senders/receivers when done
4. Call `channel.deinit()` to cleanup
5. Destroy channel pointer with allocator

### Reference Counting
- Channels track sender and receiver counts
- Auto-close when all senders/receivers are dropped
- Use `.close()` methods for explicit cleanup

## Thread Safety

- All channel operations are thread-safe
- Uses atomic operations and mutexes internally
- Safe to share senders/receivers across threads
- Condition variables for blocking operations

## Performance Characteristics

### Bounded Channels
- Fixed memory usage
- Can block on send when full
- Can block on receive when empty
- Better for backpressure control

### Unbounded Channels
- Dynamic memory growth
- Never blocks on send (until out of memory)
- Can grow indefinitely if consumer is slow
- Good for decoupling producer/consumer speeds

## Advanced Features

### Select-like Operations (Planned)
```zig
// Future API for selecting from multiple channels
const result = try zsync.select2(recv1, recv2, timeout_ms);
switch (result) {
    .channel_0 => // Handle recv1
    .channel_1 => // Handle recv2  
    .timeout => // Handle timeout
}
```

## Common Questions

**Q: What does the `bounded()` function return?**
A: It returns a struct with three fields: `channel` (pointer to Channel), `sender` (Sender instance), and `receiver` (Receiver instance).

**Q: How do I properly cleanup channels?**
A: Call `channel.deinit()` and then `allocator.destroy(channel)` when done.

**Q: Can I have multiple senders/receivers?**
A: Yes, call `channel.sender()` and `channel.receiver()` to create additional handles.

**Q: What happens when a channel is closed?**
A: Sends return `ChannelClosed` error, receives return existing buffered data then `ChannelClosed`.

**Q: Are channels thread-safe?**
A: Yes, all operations use proper synchronization primitives.

**Q: When should I use bounded vs unbounded channels?**
A: Use bounded for backpressure control and memory limits. Use unbounded when you need guaranteed non-blocking sends.