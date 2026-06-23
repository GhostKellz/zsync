//! zsync- Channel API
//! Bounded and unbounded channels for async communication

const std = @import("std");
const compat = @import("compat/thread.zig");

fn timeoutExpired(start: compat.Instant, timeout_ms: u64) bool {
    const now = compat.Instant.now() catch return true;
    return now.since(start) >= timeout_ms * std.time.ns_per_ms;
}

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
        mutex: compat.Mutex,
        not_empty: compat.Condition,
        not_full: compat.Condition,
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

        /// Send an item, returning false if the timeout expires before space is available.
        pub fn sendTimeout(self: *Self, item: T, timeout_ms: u64) !bool {
            const start = try compat.Instant.now();
            while (true) {
                if (try self.trySend(item)) return true;
                if (timeoutExpired(start, timeout_ms)) return false;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
        }

        /// Send an item unless cancelled first.
        pub fn sendCancellable(self: *Self, item: T, token: anytype) !void {
            while (true) {
                if (token.isCancelled()) return error.Cancelled;
                if (try self.trySend(item)) return;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
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

        /// Receive an item, returning null if the timeout expires before a value arrives.
        pub fn recvTimeout(self: *Self, timeout_ms: u64) !?T {
            const start = try compat.Instant.now();
            while (true) {
                if (self.tryRecv()) |item| return item;
                if (self.closed.load(.acquire)) return error.ChannelClosed;
                if (timeoutExpired(start, timeout_ms)) return null;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
        }

        /// Receive an item unless cancelled first.
        pub fn recvCancellable(self: *Self, token: anytype) !T {
            while (true) {
                if (token.isCancelled()) return error.Cancelled;
                if (self.tryRecv()) |item| return item;
                if (self.closed.load(.acquire)) return error.ChannelClosed;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
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
        mutex: compat.Mutex,
        not_empty: compat.Condition,
        closed: std.atomic.Value(bool),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .items = .empty,
                .mutex = .{},
                .not_empty = .{},
                .closed = std.atomic.Value(bool).init(false),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Send an item to the channel (never blocks)
        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed.load(.acquire)) {
                return error.ChannelClosed;
            }

            try self.items.append(self.allocator, item);
            self.not_empty.signal();
        }

        /// Send an item. Unbounded channels never wait for capacity.
        pub fn sendTimeout(self: *Self, item: T, timeout_ms: u64) !bool {
            _ = timeout_ms;
            try self.send(item);
            return true;
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

        /// Receive an item, returning null if the timeout expires before a value arrives.
        pub fn recvTimeout(self: *Self, timeout_ms: u64) !?T {
            const start = try compat.Instant.now();
            while (true) {
                if (self.tryRecv()) |item| return item;
                if (self.closed.load(.acquire)) return error.ChannelClosed;
                if (timeoutExpired(start, timeout_ms)) return null;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
        }

        /// Receive an item unless cancelled first.
        pub fn recvCancellable(self: *Self, token: anytype) !T {
            while (true) {
                if (token.isCancelled()) return error.Cancelled;
                if (self.tryRecv()) |item| return item;
                if (self.closed.load(.acquire)) return error.ChannelClosed;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
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

test "bounded channel timeout variants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ch = try bounded(i32, allocator, 1);
    defer ch.deinit();

    try testing.expect(try ch.sendTimeout(1, 1));
    try testing.expect(!(try ch.sendTimeout(2, 1)));
    try testing.expectEqual(@as(?i32, 1), try ch.recvTimeout(1));
    try testing.expectEqual(@as(?i32, null), try ch.recvTimeout(1));
}

test "bounded channel cancellable variants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Token = struct {
        cancelled: bool,
        pub fn isCancelled(self: *const @This()) bool {
            return self.cancelled;
        }
    };

    var ch = try bounded(i32, allocator, 1);
    defer ch.deinit();

    const open = Token{ .cancelled = false };
    try ch.sendCancellable(1, &open);
    try testing.expectEqual(@as(i32, 1), try ch.recvCancellable(&open));

    const cancelled = Token{ .cancelled = true };
    try testing.expectError(error.Cancelled, ch.recvCancellable(&cancelled));
    try ch.send(2);
    try testing.expectError(error.Cancelled, ch.sendCancellable(3, &cancelled));
}

test "unbounded channel timeout variants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ch = try unbounded(i32, allocator);
    defer ch.deinit();

    try testing.expect(try ch.sendTimeout(7, 1));
    try testing.expectEqual(@as(?i32, 7), try ch.recvTimeout(1));
    try testing.expectEqual(@as(?i32, null), try ch.recvTimeout(1));
}
