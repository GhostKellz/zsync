//! Zsync v0.6.0 - Channel API
//! Bounded and unbounded channels for async communication

const std = @import("std");

/// Create a bounded channel with fixed capacity
pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !Channel(T) {
    return Channel(T).init(allocator, capacity);
}

/// Create an unbounded channel that grows dynamically
pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !UnboundedChannel(T) {
    return UnboundedChannel(T).init(allocator);
}

/// Bounded channel with backpressure
pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        capacity: usize,
        head: usize,
        tail: usize,
        size: std.atomic.Value(usize),
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        closed: std.atomic.Value(bool),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);

            return Self{
                .buffer = buffer,
                .capacity = capacity,
                .head = 0,
                .tail = 0,
                .size = std.atomic.Value(usize).init(0),
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .closed = std.atomic.Value(bool).init(false),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Send an item to the channel (blocks if full)
        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if closed
            if (self.closed.load(.acquire)) {
                return error.ChannelClosed;
            }

            // Wait until space is available
            while (self.size.load(.monotonic) >= self.capacity) {
                if (self.closed.load(.acquire)) {
                    return error.ChannelClosed;
                }
                self.not_full.wait(&self.mutex);
            }

            // Add item to buffer
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            _ = self.size.fetchAdd(1, .release);

            // Signal that channel is not empty
            self.not_empty.signal();
        }

        /// Receive an item from the channel (blocks if empty)
        pub fn recv(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait until item is available
            while (self.size.load(.monotonic) == 0) {
                if (self.closed.load(.acquire)) {
                    return error.ChannelClosed;
                }
                self.not_empty.wait(&self.mutex);
            }

            // Get item from buffer
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            _ = self.size.fetchSub(1, .release);

            // Signal that channel is not full
            self.not_full.signal();

            return item;
        }

        /// Try to send without blocking
        pub fn trySend(self: *Self, item: T) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed.load(.acquire)) {
                return error.ChannelClosed;
            }

            if (self.size.load(.monotonic) >= self.capacity) {
                return false;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            _ = self.size.fetchAdd(1, .release);
            self.not_empty.signal();

            return true;
        }

        /// Try to receive without blocking
        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size.load(.monotonic) == 0) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            _ = self.size.fetchSub(1, .release);
            self.not_full.signal();

            return item;
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        /// Get current number of items in channel
        pub fn len(self: *Self) usize {
            return self.size.load(.monotonic);
        }
    };
}

/// Unbounded channel that grows dynamically
pub fn UnboundedChannel(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        closed: std.atomic.Value(bool),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .items = std.ArrayList(T).init(allocator),
                .mutex = .{},
                .not_empty = .{},
                .closed = std.atomic.Value(bool).init(false),
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        /// Send an item to the channel (never blocks)
        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed.load(.acquire)) {
                return error.ChannelClosed;
            }

            try self.items.append(item);
            self.not_empty.signal();
        }

        /// Receive an item from the channel (blocks if empty)
        pub fn recv(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.items.items.len == 0) {
                if (self.closed.load(.acquire)) {
                    return error.ChannelClosed;
                }
                self.not_empty.wait(&self.mutex);
            }

            return self.items.orderedRemove(0);
        }

        /// Try to receive without blocking
        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len == 0) {
                return null;
            }

            return self.items.orderedRemove(0);
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            self.not_empty.broadcast();
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        /// Get current number of items in channel
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }
    };
}

// Tests
test "bounded channel send/recv" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ch = try bounded(i32, allocator, 10);
    defer ch.deinit();

    try ch.send(42);
    try ch.send(100);

    const val1 = try ch.recv();
    const val2 = try ch.recv();

    try testing.expectEqual(42, val1);
    try testing.expectEqual(100, val2);
}

test "unbounded channel send/recv" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ch = try unbounded(i32, allocator);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    try testing.expectEqual(3, ch.len());

    const val1 = try ch.recv();
    const val2 = try ch.recv();
    const val3 = try ch.recv();

    try testing.expectEqual(1, val1);
    try testing.expectEqual(2, val2);
    try testing.expectEqual(3, val3);
}

test "channel close behavior" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ch = try bounded(i32, allocator, 5);
    defer ch.deinit();

    ch.close();

    try testing.expect(ch.isClosed());
    try testing.expectError(error.ChannelClosed, ch.send(42));
    try testing.expectError(error.ChannelClosed, ch.recv());
}
