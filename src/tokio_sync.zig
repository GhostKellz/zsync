//! Tokio-style synchronization helpers that sit above the lower-level sync
//! primitives in `sync.zig`.

const std = @import("std");
const compat = @import("compat/thread.zig");

/// Broadcast channel - multiple producers, multiple consumers.
/// Each message is delivered to all consumers with configurable capacity.
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        subscribers: std.ArrayList(*Subscriber),
        allocator: std.mem.Allocator,
        capacity: usize,
        mutex: compat.Mutex = .{},
        notify: compat.Condition = .{},

        const Self = @This();
        pub const default_capacity: usize = 16;

        const Subscriber = struct {
            queue: std.ArrayList(T),
            allocator: std.mem.Allocator,
            capacity: usize,
            lagged: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            mutex: compat.Mutex = .{},

            pub fn initWithCapacity(allocator: std.mem.Allocator, cap: usize) Subscriber {
                return .{ .queue = .empty, .allocator = allocator, .capacity = cap };
            }

            pub fn deinit(self: *Subscriber) void {
                self.queue.deinit(self.allocator);
            }

            pub fn lagCount(self: *Subscriber) usize {
                return self.lagged.swap(0, .acquire);
            }

            pub fn recv(self: *Subscriber) ?T {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.queue.items.len > 0) {
                    return self.queue.orderedRemove(0);
                }
                return null;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithCapacity(allocator, default_capacity);
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{ .subscribers = .empty, .allocator = allocator, .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            for (self.subscribers.items) |sub| {
                sub.deinit();
                self.allocator.destroy(sub);
            }
            self.subscribers.deinit(self.allocator);
        }

        pub fn subscribe(self: *Self) !*Subscriber {
            self.mutex.lock();
            defer self.mutex.unlock();

            const sub = try self.allocator.create(Subscriber);
            sub.* = Subscriber.initWithCapacity(self.allocator, self.capacity);
            try self.subscribers.append(self.allocator, sub);
            return sub;
        }

        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.subscribers.items) |sub| {
                sub.mutex.lock();
                defer sub.mutex.unlock();
                if (sub.queue.items.len >= sub.capacity) {
                    _ = sub.queue.orderedRemove(0);
                    _ = sub.lagged.fetchAdd(1, .monotonic);
                }
                try sub.queue.append(sub.allocator, value);
            }
            self.notify.broadcast();
        }

        pub fn recv(sub: *Subscriber) ?T {
            return sub.recv();
        }

        pub fn recvBlocking(self: *Self, sub: *Subscriber) T {
            self.mutex.lock();

            while (true) {
                sub.mutex.lock();
                if (sub.queue.items.len > 0) {
                    const item = sub.queue.orderedRemove(0);
                    sub.mutex.unlock();
                    self.mutex.unlock();
                    return item;
                }
                sub.mutex.unlock();
                self.notify.wait(&self.mutex);
            }
        }

        pub fn recvBlockingTimeout(self: *Self, sub: *Subscriber, timeout_ms: u64) ?T {
            _ = self;
            const start = compat.Instant.now() catch return null;
            while (true) {
                if (sub.recv()) |item| return item;
                const now = compat.Instant.now() catch return null;
                if (now.since(start) >= timeout_ms * std.time.ns_per_ms) return null;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
        }

        pub fn recvBlockingCancellable(self: *Self, sub: *Subscriber, token: anytype) !T {
            _ = self;
            while (true) {
                if (token.isCancelled()) return error.Cancelled;
                if (sub.recv()) |item| return item;
                compat.sleepNanos(1 * std.time.ns_per_ms);
            }
        }

        pub fn unsubscribe(self: *Self, sub: *Subscriber) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.subscribers.items, 0..) |s, i| {
                if (s == sub) {
                    _ = self.subscribers.orderedRemove(i);
                    break;
                }
            }

            sub.deinit();
            self.allocator.destroy(sub);
        }

        pub fn subscriberCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.subscribers.items.len;
        }
    };
}

/// Watch channel - single value that can be watched for changes.
pub fn WatchChannel(comptime T: type) type {
    return struct {
        value: T,
        version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        mutex: compat.Mutex = .{},
        changed_cond: compat.Condition = .{},

        const Self = @This();

        pub const Watcher = struct {
            channel: *Self,
            last_seen: u64 = 0,

            pub fn borrow(self: *Watcher) T {
                self.channel.mutex.lock();
                defer self.channel.mutex.unlock();
                self.last_seen = self.channel.version.load(.acquire);
                return self.channel.value;
            }

            pub fn hasChanged(self: *const Watcher) bool {
                return self.channel.version.load(.acquire) != self.last_seen;
            }

            pub fn changed(self: *Watcher) T {
                self.channel.mutex.lock();
                defer self.channel.mutex.unlock();

                while (self.channel.version.load(.acquire) == self.last_seen) {
                    self.channel.changed_cond.wait(&self.channel.mutex);
                }
                self.last_seen = self.channel.version.load(.acquire);
                return self.channel.value;
            }

            pub fn changedTimeout(self: *Watcher, timeout_ms: u64) ?T {
                const start = compat.Instant.now() catch return null;
                while (true) {
                    if (self.hasChanged()) return self.borrow();
                    const now = compat.Instant.now() catch return null;
                    if (now.since(start) >= timeout_ms * std.time.ns_per_ms) return null;
                    compat.sleepNanos(1 * std.time.ns_per_ms);
                }
            }

            pub fn changedCancellable(self: *Watcher, token: anytype) !T {
                while (true) {
                    if (token.isCancelled()) return error.Cancelled;
                    if (self.hasChanged()) return self.borrow();
                    compat.sleepNanos(1 * std.time.ns_per_ms);
                }
            }
        };

        pub fn init(initial: T) Self {
            return .{ .value = initial };
        }

        pub fn subscribe(self: *Self) Watcher {
            return .{ .channel = self };
        }

        pub fn send(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value = value;
            _ = self.version.fetchAdd(1, .release);
            self.changed_cond.broadcast();
        }

        pub fn borrow(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.value;
        }

        pub fn getVersion(self: *Self) u64 {
            return self.version.load(.acquire);
        }
    };
}

pub const Notify = struct {
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    one_shot_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: compat.Mutex = .{},
    cond: compat.Condition = .{},

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn wait(self: *Self) void {
        if (self.one_shot_pending.swap(false, .acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.waiters.fetchAdd(1, .monotonic);
        defer _ = self.waiters.fetchSub(1, .monotonic);

        const my_gen = self.generation.load(.acquire);
        while (self.generation.load(.acquire) == my_gen and !self.one_shot_pending.load(.acquire)) {
            self.cond.wait(&self.mutex);
        }

        _ = self.one_shot_pending.swap(false, .acquire);
    }

    pub fn waitTimeout(self: *Self, timeout_ms: u64) bool {
        if (self.one_shot_pending.swap(false, .acquire)) return true;

        const start = compat.Instant.now() catch return false;
        const my_gen = self.generation.load(.acquire);
        _ = self.waiters.fetchAdd(1, .monotonic);
        defer _ = self.waiters.fetchSub(1, .monotonic);

        while (true) {
            const notified = self.one_shot_pending.swap(false, .acquire);
            const generation_changed = self.generation.load(.acquire) != my_gen;

            if (notified or generation_changed) return true;

            const now = compat.Instant.now() catch return false;
            if (now.since(start) >= timeout_ms * std.time.ns_per_ms) return false;
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
    }

    pub fn waitCancellable(self: *Self, token: anytype) !void {
        while (true) {
            if (token.isCancelled()) return error.Cancelled;
            if (self.waitTimeout(1)) return;
        }
    }

    pub fn notifyOne(self: *Self) void {
        self.one_shot_pending.store(true, .release);
        self.cond.signal();
    }

    pub fn notifyAll(self: *Self) void {
        _ = self.generation.fetchAdd(1, .release);
        self.cond.broadcast();
    }

    pub fn hasWaiters(self: *const Self) bool {
        return self.waiters.load(.acquire) > 0;
    }
};

pub fn OnceCell(comptime T: type) type {
    return struct {
        value: ?T = null,
        initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mutex: compat.Mutex = .{},

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn getOrInit(self: *Self, comptime initFn: fn () T) T {
            if (self.initialized.load(.acquire)) return self.value.?;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.initialized.load(.acquire)) {
                self.value = initFn();
                self.initialized.store(true, .release);
            }

            return self.value.?;
        }

        pub fn getOrTryInit(self: *Self, comptime initFn: fn () anyerror!T) !T {
            if (self.initialized.load(.acquire)) return self.value.?;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.initialized.load(.acquire)) {
                self.value = try initFn();
                self.initialized.store(true, .release);
            }

            return self.value.?;
        }

        pub fn get(self: *const Self) ?T {
            if (self.initialized.load(.acquire)) return self.value;
            return null;
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.initialized.load(.acquire);
        }

        pub fn set(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.initialized.load(.acquire)) return false;

            self.value = value;
            self.initialized.store(true, .release);
            return true;
        }
    };
}

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    children: std.ArrayList(*CancellationToken) = .empty,
    allocator: std.mem.Allocator = undefined,
    mutex: compat.Mutex = .{},
    notify: Notify = Notify.init(),
    initialized: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .children = .empty, .allocator = allocator, .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            for (self.children.items) |child_token| {
                child_token.deinit();
                self.allocator.destroy(child_token);
            }
            self.children.deinit(self.allocator);
        }
    }

    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);
        self.notify.notifyAll();

        if (self.initialized) {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.children.items) |child_token| {
                child_token.cancel();
            }
        }
    }

    pub fn waitForCancellation(self: *Self) void {
        while (!self.isCancelled()) {
            self.notify.wait();
        }
    }

    pub fn child(self: *Self) !*CancellationToken {
        if (!self.initialized) return error.NotInitialized;

        self.mutex.lock();
        defer self.mutex.unlock();

        const child_token = try self.allocator.create(CancellationToken);
        child_token.* = Self.init(self.allocator);

        if (self.isCancelled()) {
            child_token.cancelled.store(true, .release);
        }

        try self.children.append(self.allocator, child_token);
        return child_token;
    }
};

test "tokio sync facades compile and behave" {
    var cell = OnceCell(u32).init();
    try std.testing.expect(cell.set(42));
    try std.testing.expectEqual(@as(u32, 42), cell.get().?);

    var watch = WatchChannel(u32).init(0);
    var watcher = watch.subscribe();
    _ = watcher.borrow();
    watch.send(1);
    try std.testing.expectEqual(@as(u32, 1), watcher.changedTimeout(1).?);

    var notify = Notify.init();
    try std.testing.expect(!notify.waitTimeout(1));
    notify.notifyOne();
    try std.testing.expect(notify.waitTimeout(1));
}
