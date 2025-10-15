//! Zsync v0.6.0 - Rate Limiting
//! Token bucket, leaky bucket, and sliding window rate limiters

const std = @import("std");

/// Token Bucket Rate Limiter
pub const TokenBucket = struct {
    capacity: u32,
    tokens: std.atomic.Value(u32),
    refill_rate: u32, // tokens per second
    last_refill: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,

    const Self = @This();

    /// Initialize token bucket
    pub fn init(capacity: u32, refill_rate: u32) Self {
        const now = std.time.milliTimestamp();
        return Self{
            .capacity = capacity,
            .tokens = std.atomic.Value(u32).init(capacity),
            .refill_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(now),
            .mutex = .{},
        };
    }

    /// Try to consume N tokens
    pub fn tryConsume(self: *Self, tokens: u32) bool {
        self.refill();

        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.tokens.load(.acquire);
        if (current >= tokens) {
            self.tokens.store(current - tokens, .release);
            return true;
        }

        return false;
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *Self) void {
        const now = std.time.milliTimestamp();
        const last = self.last_refill.load(.acquire);
        const elapsed_ms = now - last;

        if (elapsed_ms < 100) return; // Refill every 100ms minimum

        const tokens_to_add = @as(u32, @intCast(@divTrunc(elapsed_ms * @as(i64, @intCast(self.refill_rate)), 1000)));

        if (tokens_to_add > 0) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const current = self.tokens.load(.acquire);
            const new_tokens = @min(current + tokens_to_add, self.capacity);
            self.tokens.store(new_tokens, .release);
            self.last_refill.store(now, .release);
        }
    }

    /// Get current token count
    pub fn available(self: *Self) u32 {
        self.refill();
        return self.tokens.load(.monotonic);
    }
};

/// Leaky Bucket Rate Limiter
pub const LeakyBucket = struct {
    capacity: u32,
    level: std.atomic.Value(u32),
    leak_rate: u32, // items per second
    last_leak: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(capacity: u32, leak_rate: u32) Self {
        const now = std.time.milliTimestamp();
        return Self{
            .capacity = capacity,
            .level = std.atomic.Value(u32).init(0),
            .leak_rate = leak_rate,
            .last_leak = std.atomic.Value(i64).init(now),
            .mutex = .{},
        };
    }

    /// Try to add item to bucket
    pub fn tryAdd(self: *Self) bool {
        self.leak();

        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.level.load(.acquire);
        if (current < self.capacity) {
            self.level.store(current + 1, .release);
            return true;
        }

        return false;
    }

    /// Leak items based on elapsed time
    fn leak(self: *Self) void {
        const now = std.time.milliTimestamp();
        const last = self.last_leak.load(.acquire);
        const elapsed_ms = now - last;

        if (elapsed_ms < 100) return;

        const items_to_leak = @as(u32, @intCast(@divTrunc(elapsed_ms * @as(i64, @intCast(self.leak_rate)), 1000)));

        if (items_to_leak > 0) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const current = self.level.load(.acquire);
            const new_level = if (current > items_to_leak) current - items_to_leak else 0;
            self.level.store(new_level, .release);
            self.last_leak.store(now, .release);
        }
    }

    /// Get current bucket level
    pub fn getLevel(self: *Self) u32 {
        self.leak();
        return self.level.load(.monotonic);
    }
};

/// Sliding Window Rate Limiter
pub const SlidingWindow = struct {
    max_requests: u32,
    window_ms: u64,
    timestamps: std.ArrayList(i64),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_requests: u32, window_ms: u64) Self {
        return Self{
            .max_requests = max_requests,
            .window_ms = window_ms,
            .timestamps = std.ArrayList(i64).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.timestamps.deinit();
    }

    /// Try to record a request
    pub fn tryAllow(self: *Self) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const window_start = now - @as(i64, @intCast(self.window_ms));

        // Remove old timestamps
        var i: usize = 0;
        while (i < self.timestamps.items.len) {
            if (self.timestamps.items[i] < window_start) {
                _ = self.timestamps.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check if we can allow this request
        if (self.timestamps.items.len < self.max_requests) {
            try self.timestamps.append(now);
            return true;
        }

        return false;
    }

    /// Get requests in current window
    pub fn getCount(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const window_start = now - @as(i64, @intCast(self.window_ms));

        var count: u32 = 0;
        for (self.timestamps.items) |ts| {
            if (ts >= window_start) {
                count += 1;
            }
        }

        return count;
    }
};

// Tests
test "token bucket basic" {
    const testing = std.testing;

    var bucket = TokenBucket.init(10, 10); // 10 tokens, refill 10/sec

    try testing.expect(bucket.tryConsume(5));
    try testing.expectEqual(5, bucket.available());

    try testing.expect(bucket.tryConsume(5));
    try testing.expectEqual(0, bucket.available());

    try testing.expect(!bucket.tryConsume(1)); // Should fail, no tokens
}

test "leaky bucket basic" {
    const testing = std.testing;

    var bucket = LeakyBucket.init(5, 10); // capacity 5, leak 10/sec

    try testing.expect(bucket.tryAdd());
    try testing.expect(bucket.tryAdd());
    try testing.expectEqual(2, bucket.getLevel());
}
