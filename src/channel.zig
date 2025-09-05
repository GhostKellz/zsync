//! Channel implementation for Zsync
//! Provides async message passing between tasks

const std = @import("std");

/// Channel errors
pub const ChannelError = error{
    ChannelClosed,
    ChannelFull,
    ChannelEmpty,
    ReceiverDropped,
    SenderDropped,
};

/// Channel capacity types
pub const Capacity = union(enum) {
    unbounded,
    bounded: u32,
};

/// Message wrapper for the channel
fn Message(comptime T: type) type {
    return struct {
        data: T,
        sequence: u64,
    };
}

/// Generic channel implementation
pub fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        capacity: Capacity,
        buffer: std.ArrayList(u8),
        closed: std.atomic.Value(bool),
        sender_count: std.atomic.Value(u32),
        receiver_count: std.atomic.Value(u32),
        sequence: std.atomic.Value(u64),
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,

        const Self = @This();
        const MessageType = Message(T);

        /// Initialize a new channel
        pub fn init(allocator: std.mem.Allocator, capacity: Capacity) !Self {
            return Self{
                .allocator = allocator,
                .capacity = capacity,
                .buffer = std.ArrayList(u8).empty,
                .closed = std.atomic.Value(bool).init(false),
                .sender_count = std.atomic.Value(u32).init(0),
                .receiver_count = std.atomic.Value(u32).init(0),
                .sequence = std.atomic.Value(u64).init(0),
                .mutex = std.Thread.Mutex{},
                .not_empty = std.Thread.Condition{},
                .not_full = std.Thread.Condition{},
            };
        }

        /// Deinitialize the channel
        pub fn deinit(self: *Self) void {
            self.close();
            self.buffer.deinit(self.allocator);
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Check if the channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        /// Create a sender for this channel
        pub fn sender(self: *Self) Sender(T) {
            _ = self.sender_count.fetchAdd(1, .monotonic);
            return Sender(T){
                .channel = self,
            };
        }

        /// Create a receiver for this channel
        pub fn receiver(self: *Self) Receiver(T) {
            _ = self.receiver_count.fetchAdd(1, .monotonic);
            return Receiver(T){
                .channel = self,
            };
        }

        /// Internal send implementation
        fn sendInternal(self: *Self, data: T) !void {
            if (self.isClosed()) {
                return ChannelError.ChannelClosed;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if we have space
            const element_size = @sizeOf(MessageType);
            if (self.capacity == .bounded) {
                const bounded_size = switch (self.capacity) {
                    .bounded => |size| size * element_size,
                    .unbounded => unreachable,
                };
                if (self.buffer.items.len + element_size > bounded_size) {
                    return ChannelError.ChannelFull;
                }
            }

            const message = MessageType{
                .data = data,
                .sequence = self.sequence.fetchAdd(1, .monotonic),
            };

            const bytes = std.mem.asBytes(&message);
            self.buffer.appendSlice(self.allocator, bytes) catch return ChannelError.ChannelFull;
            
            // Signal while still holding the lock to prevent race conditions
            self.not_empty.signal();
        }

        /// Internal receive implementation
        fn receiveInternal(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.buffer.items.len < @sizeOf(MessageType)) {
                if (self.isClosed() and self.sender_count.load(.monotonic) == 0) {
                    return ChannelError.ChannelClosed;
                }
                
                self.not_empty.wait(&self.mutex);
            }

            var message: MessageType = undefined;
            const bytes = std.mem.asBytes(&message);
            
            if (self.buffer.items.len < bytes.len) {
                return ChannelError.ChannelEmpty;
            }
            
            @memcpy(bytes, self.buffer.items[0..bytes.len]);
            
            // Remove the consumed bytes
            var i: usize = 0;
            while (i < bytes.len) {
                _ = self.buffer.orderedRemove(0);
                i += 1;
            }
            
            self.not_full.signal();
            return message.data;
        }
    };
}

/// Sender half of a channel
pub fn Sender(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        const Self = @This();

        /// Send a value through the channel
        pub fn send(self: Self, data: T) !void {
            return self.channel.sendInternal(data);
        }

        /// Try to send without blocking
        pub fn trySend(self: Self, data: T) !void {
            if (self.channel.isClosed()) {
                return ChannelError.ChannelClosed;
            }

            return self.channel.sendInternal(data);
        }

        /// Close the sender
        pub fn close(self: Self) void {
            _ = self.channel.sender_count.fetchSub(1, .monotonic);
            if (self.channel.sender_count.load(.monotonic) == 0) {
                self.channel.close();
            }
        }
    };
}

/// Receiver half of a channel
pub fn Receiver(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        const Self = @This();

        /// Receive a value from the channel
        pub fn recv(self: Self) !T {
            return self.channel.receiveInternal();
        }

        /// Try to receive without blocking
        pub fn tryRecv(self: Self) !T {
            if (self.channel.isClosed()) {
                return ChannelError.ChannelClosed;
            }

            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if (self.channel.buffer.items.len < @sizeOf(Message(T))) {
                return ChannelError.ChannelEmpty;
            }

            var message: Message(T) = undefined;
            const bytes = std.mem.asBytes(&message);
            
            if (self.channel.buffer.items.len < bytes.len) {
                return ChannelError.ChannelEmpty;
            }
            
            @memcpy(bytes, self.channel.buffer.items[0..bytes.len]);
            
            // Remove the consumed bytes
            var i: usize = 0;
            while (i < bytes.len) {
                _ = self.channel.buffer.orderedRemove(0);
                i += 1;
            }
            
            self.channel.not_full.signal();
            return message.data;
        }

        /// Close the receiver
        pub fn close(self: Self) void {
            _ = self.channel.receiver_count.fetchSub(1, .monotonic);
            if (self.channel.receiver_count.load(.monotonic) == 0) {
                self.channel.close();
            }
        }
    };
}

/// Create a bounded channel
pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: u32) !struct {
    channel: *Channel(T),
    sender: Sender(T),
    receiver: Receiver(T),
} {
    const channel = try allocator.create(Channel(T));
    channel.* = try Channel(T).init(allocator, .{ .bounded = capacity });
    
    return .{
        .channel = channel,
        .sender = channel.sender(),
        .receiver = channel.receiver(),
    };
}

/// Create an unbounded channel
pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !struct {
    channel: *Channel(T),
    sender: Sender(T),
    receiver: Receiver(T),
} {
    const channel = try allocator.create(Channel(T));
    channel.* = try Channel(T).init(allocator, .unbounded);
    
    return .{
        .channel = channel,
        .sender = channel.sender(),
        .receiver = channel.receiver(),
    };
}

/// OneShot channel for single-value communication
pub fn OneShot(comptime T: type) type {
    return struct {
        value: ?T,
        completed: std.atomic.Value(bool),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .value = null,
                .completed = std.atomic.Value(bool).init(false),
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
            };
        }

        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.completed.load(.acquire)) {
                return ChannelError.ChannelClosed;
            }

            self.value = value;
            self.completed.store(true, .release);
            self.condition.broadcast();
        }

        pub fn recv(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.completed.load(.acquire)) {
                self.condition.wait(&self.mutex);
            }

            return self.value orelse ChannelError.ChannelClosed;
        }

        pub fn tryRecv(self: *Self) !T {
            if (!self.completed.load(.acquire)) {
                return ChannelError.ChannelEmpty;
            }

            return self.value orelse ChannelError.ChannelClosed;
        }
    };
}

// Select-like functionality for multiple channels
pub const SelectResult = union(enum) {
    channel_0: void,
    channel_1: void,
    channel_2: void,
    timeout: void,
};

/// Simple select implementation (proof of concept)
pub fn select2(
    comptime T1: type,
    comptime T2: type,
    recv1: Receiver(T1),
    recv2: Receiver(T2),
    timeout_ms: ?u64,
) !SelectResult {
    _ = recv1;
    _ = recv2;
    _ = timeout_ms;
    
    // This is a simplified implementation
    // A real select would use the reactor for async waiting
    return SelectResult.timeout;
}

// Tests
test "channel creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const ch = try bounded(i32, allocator, 10);
    defer {
        ch.channel.deinit();
        allocator.destroy(ch.channel);
    }
    
    try testing.expect(!ch.channel.isClosed());
}

test "channel send and receive" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const ch = try bounded(i32, allocator, 10);
    defer {
        ch.channel.deinit();
        allocator.destroy(ch.channel);
    }
    
    try ch.sender.send(42);
    const value = try ch.receiver.recv();
    try testing.expect(value == 42);
}

test "oneshot channel" {
    const testing = std.testing;
    
    var oneshot = OneShot(i32).init();
    
    try oneshot.send(100);
    const value = try oneshot.recv();
    try testing.expect(value == 100);
}

test "channel try operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const ch = try bounded(i32, allocator, 1);
    defer {
        ch.channel.deinit();
        allocator.destroy(ch.channel);
    }
    
    // Try receive on empty channel
    const empty_result = ch.receiver.tryRecv();
    try testing.expectError(ChannelError.ChannelEmpty, empty_result);
    
    // Send and try receive
    try ch.sender.trySend(99);
    const value = try ch.receiver.tryRecv();
    try testing.expect(value == 99);
}
