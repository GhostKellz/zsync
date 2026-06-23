//! zsync- Synchronization Primitives
//! Async-aware synchronization primitives for concurrent programming

const std = @import("std");
const compat = @import("compat/thread.zig");

fn timeoutExpired(start: compat.Instant, timeout_ms: u64) bool {
    const now = compat.Instant.now() catch return true;
    return now.since(start) >= timeout_ms * std.time.ns_per_ms;
}

/// Runtime-integrated semaphore backed by `std.Io.Semaphore`.
pub const IoSemaphore = struct {
    inner: std.Io.Semaphore,
    max_permits: usize,

    const Self = @This();

    pub fn init(permits: usize) Self {
        return .{ .inner = .{ .permits = permits }, .max_permits = permits };
    }

    pub fn acquire(self: *Self, io: std.Io) std.Io.Cancelable!void {
        try self.inner.wait(io);
    }

    pub fn acquireTimeout(self: *Self, io: std.Io, timeout: std.Io.Timeout) std.Io.Semaphore.WaitTimeoutError!void {
        try self.inner.waitTimeout(io, timeout);
    }

    pub fn tryAcquire(self: *Self, io: std.Io) bool {
        self.inner.mutex.lockUncancelable(io);
        defer self.inner.mutex.unlock(io);
        if (self.inner.permits == 0) return false;
        self.inner.permits -= 1;
        return true;
    }

    pub fn release(self: *Self, io: std.Io) void {
        self.inner.mutex.lockUncancelable(io);
        defer self.inner.mutex.unlock(io);
        if (self.inner.permits >= self.max_permits) return;
        self.inner.permits += 1;
        self.inner.cond.signal(io);
    }

    pub fn availablePermits(self: *Self, io: std.Io) usize {
        self.inner.mutex.lockUncancelable(io);
        defer self.inner.mutex.unlock(io);
        return self.inner.permits;
    }
};

/// Runtime-integrated mutex backed by `std.Io.Mutex`.
pub const IoMutex = struct {
    inner: std.Io.Mutex = .init,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn lock(self: *Self, io: std.Io) std.Io.Cancelable!void {
        try self.inner.lock(io);
    }

    pub fn lockUncancelable(self: *Self, io: std.Io) void {
        self.inner.lockUncancelable(io);
    }

    pub fn tryLock(self: *Self) bool {
        return self.inner.tryLock();
    }

    pub fn unlock(self: *Self, io: std.Io) void {
        self.inner.unlock(io);
    }
};

/// Runtime-integrated read-write lock backed by `std.Io.RwLock`.
pub const IoRwLock = struct {
    inner: std.Io.RwLock = .init,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn lockWrite(self: *Self, io: std.Io) std.Io.Cancelable!void {
        try self.inner.lock(io);
    }

    pub fn lockWriteUncancelable(self: *Self, io: std.Io) void {
        self.inner.lockUncancelable(io);
    }

    pub fn tryLockWrite(self: *Self, io: std.Io) bool {
        return self.inner.tryLock(io);
    }

    pub fn unlockWrite(self: *Self, io: std.Io) void {
        self.inner.unlock(io);
    }

    pub fn lockRead(self: *Self, io: std.Io) std.Io.Cancelable!void {
        try self.inner.lockShared(io);
    }

    pub fn lockReadUncancelable(self: *Self, io: std.Io) void {
        self.inner.lockSharedUncancelable(io);
    }

    pub fn tryLockRead(self: *Self, io: std.Io) bool {
        return self.inner.tryLockShared(io);
    }

    pub fn unlockRead(self: *Self, io: std.Io) void {
        self.inner.unlockShared(io);
    }
};

/// Runtime-integrated wait group backed by `std.Io.Mutex` and `std.Io.Condition`.
pub const IoWaitGroup = struct {
    counter: u32 = 0,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn add(self: *Self, io: std.Io, delta: u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.counter += delta;
    }

    pub fn done(self: *Self, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.counter == 0) return;
        self.counter -= 1;
        if (self.counter == 0) self.condition.broadcast(io);
    }

    pub fn wait(self: *Self, io: std.Io) std.Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.counter > 0) try self.condition.wait(io, &self.mutex);
    }

    pub fn waitTimeout(self: *Self, io: std.Io, timeout: std.Io.Timeout) (std.Io.Condition.WaitTimeoutError)!void {
        const deadline = timeout.toDeadline(io);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.counter > 0) try self.condition.waitTimeout(io, &self.mutex, deadline);
    }

    pub fn getCount(self: *Self, io: std.Io) u32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.counter;
    }
};

/// Semaphore for limiting concurrency
pub const Semaphore = struct {
    permits: std.atomic.Value(isize),
    mutex: compat.Mutex,
    condition: compat.Condition,
    max_permits: usize,

    const Self = @This();

    /// Create a new semaphore with the given number of permits
    pub fn init(permits: usize) Self {
        return Self{
            .permits = std.atomic.Value(isize).init(@intCast(permits)),
            .mutex = .{},
            .condition = .{},
            .max_permits = permits,
        };
    }

    /// Acquire a permit (blocks if none available)
    pub fn acquire(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.permits.load(.monotonic) <= 0) {
            self.condition.wait(&self.mutex);
        }

        _ = self.permits.fetchSub(1, .release);
    }

    /// Try to acquire a permit without blocking
    pub fn tryAcquire(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.permits.load(.monotonic);
        if (current <= 0) {
            return false;
        }

        _ = self.permits.fetchSub(1, .release);
        return true;
    }

    /// Acquire a permit, returning false if the timeout expires first.
    pub fn acquireTimeout(self: *Self, timeout_ms: u64) bool {
        const start = compat.Instant.now() catch return false;
        while (true) {
            if (self.tryAcquire()) return true;
            if (timeoutExpired(start, timeout_ms)) return false;
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
    }

    /// Release a permit. Does nothing if already at max permits.
    pub fn release(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.permits.load(.monotonic);
        // Don't exceed max_permits - silently ignore over-release
        if (current >= @as(isize, @intCast(self.max_permits))) {
            return;
        }

        _ = self.permits.fetchAdd(1, .release);
        self.condition.signal();
    }

    /// Get current number of available permits
    pub fn availablePermits(self: *Self) usize {
        const current = self.permits.load(.monotonic);
        if (current < 0) return 0;
        return @intCast(current);
    }
};

/// Barrier for synchronizing multiple tasks
pub const Barrier = struct {
    count: usize,
    waiting: usize = 0,
    generation: u32 = 0,
    mutex: compat.Mutex = .{},
    cond: compat.Condition = .{},

    const Self = @This();

    /// Create a new barrier for N tasks
    pub fn init(count: usize) Self {
        return Self{ .count = count };
    }

    /// Wait at the barrier until all tasks arrive
    pub fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gen = self.generation;
        self.waiting += 1;

        if (self.waiting == self.count) {
            self.waiting = 0;
            self.generation +%= 1;
            self.cond.broadcast();
        } else {
            while (self.generation == gen) {
                self.cond.wait(&self.mutex);
            }
        }
    }
};

/// Latch for one-time synchronization
pub const Latch = struct {
    count: std.atomic.Value(usize),
    mutex: compat.Mutex,
    condition: compat.Condition,

    const Self = @This();

    /// Create a new latch with initial count
    pub fn init(count: usize) Self {
        return Self{
            .count = std.atomic.Value(usize).init(count),
            .mutex = .{},
            .condition = .{},
        };
    }

    /// Decrement the latch count
    pub fn countDown(self: *Self) void {
        const old = self.count.fetchSub(1, .release);
        if (old == 1) {
            // Count reached zero
            self.mutex.lock();
            defer self.mutex.unlock();
            self.condition.broadcast();
        }
    }

    /// Wait for the latch count to reach zero
    pub fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count.load(.acquire) > 0) {
            self.condition.wait(&self.mutex);
        }
    }

    /// Get current count
    pub fn getCount(self: *Self) usize {
        return self.count.load(.monotonic);
    }
};

/// Async-aware Mutex
pub const AsyncMutex = struct {
    locked: std.atomic.Value(bool),
    mutex: compat.Mutex,
    condition: compat.Condition,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .locked = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .condition = .{},
        };
    }

    /// Lock the mutex (blocks until available)
    pub fn lock(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.locked.load(.acquire)) {
            self.condition.wait(&self.mutex);
        }

        self.locked.store(true, .release);
    }

    /// Try to lock without blocking
    pub fn tryLock(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.locked.load(.acquire)) {
            return false;
        }

        self.locked.store(true, .release);
        return true;
    }

    /// Unlock the mutex
    pub fn unlock(self: *Self) void {
        self.locked.store(false, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.condition.signal();
    }
};

/// Async-aware Read-Write Lock
pub const AsyncRwLock = struct {
    readers: std.atomic.Value(u32),
    writer: std.atomic.Value(bool),
    mutex: compat.Mutex,
    read_condition: compat.Condition,
    write_condition: compat.Condition,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .readers = std.atomic.Value(u32).init(0),
            .writer = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .read_condition = .{},
            .write_condition = .{},
        };
    }

    /// Acquire read lock
    pub fn lockRead(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.writer.load(.acquire)) {
            self.read_condition.wait(&self.mutex);
        }

        _ = self.readers.fetchAdd(1, .release);
    }

    /// Release read lock
    pub fn unlockRead(self: *Self) void {
        const old = self.readers.fetchSub(1, .release);
        if (old == 1) {
            // Last reader, wake writer
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_condition.signal();
        }
    }

    /// Acquire write lock
    pub fn lockWrite(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.writer.load(.acquire) or self.readers.load(.acquire) > 0) {
            self.write_condition.wait(&self.mutex);
        }

        self.writer.store(true, .release);
    }

    /// Release write lock
    pub fn unlockWrite(self: *Self) void {
        self.writer.store(false, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_condition.broadcast();
        self.write_condition.signal();
    }
};

/// WaitGroup for coordinating multiple tasks (like Go's sync.WaitGroup)
pub const WaitGroup = struct {
    counter: std.atomic.Value(u32),
    mutex: compat.Mutex,
    condition: compat.Condition,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .counter = std.atomic.Value(u32).init(0),
            .mutex = .{},
            .condition = .{},
        };
    }

    /// Add to the wait group counter
    pub fn add(self: *Self, delta: u32) void {
        _ = self.counter.fetchAdd(delta, .release);
    }

    /// Decrement the counter (called when task completes)
    pub fn done(self: *Self) void {
        const old = self.counter.fetchSub(1, .release);
        if (old == 1) {
            // Last task done
            self.mutex.lock();
            defer self.mutex.unlock();
            self.condition.broadcast();
        }
    }

    /// Wait for counter to reach zero
    pub fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.counter.load(.acquire) > 0) {
            self.condition.wait(&self.mutex);
        }
    }

    /// Wait for counter to reach zero, returning false on timeout.
    pub fn waitTimeout(self: *Self, timeout_ms: u64) bool {
        const start = compat.Instant.now() catch return false;
        while (true) {
            if (self.counter.load(.acquire) == 0) return true;
            if (timeoutExpired(start, timeout_ms)) return false;
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
    }

    /// Get current counter value
    pub fn getCount(self: *Self) u32 {
        return self.counter.load(.monotonic);
    }
};

// Tests
test "semaphore acquire and release" {
    const testing = std.testing;

    var sem = Semaphore.init(2);

    try testing.expectEqual(2, sem.availablePermits());

    sem.acquire();
    try testing.expectEqual(1, sem.availablePermits());

    sem.acquire();
    try testing.expectEqual(0, sem.availablePermits());

    sem.release();
    try testing.expectEqual(1, sem.availablePermits());

    sem.release();
    try testing.expectEqual(2, sem.availablePermits());
}

test "semaphore tryAcquire" {
    const testing = std.testing;

    var sem = Semaphore.init(1);

    try testing.expect(sem.tryAcquire());
    try testing.expect(!sem.tryAcquire());

    sem.release();
    try testing.expect(sem.tryAcquire());
}

test "semaphore acquireTimeout" {
    const testing = std.testing;

    var sem = Semaphore.init(1);
    try testing.expect(sem.acquireTimeout(1));
    try testing.expect(!sem.acquireTimeout(1));
    sem.release();
    try testing.expect(sem.acquireTimeout(1));
}

test "semaphore over-release is bounded" {
    const testing = std.testing;

    var sem = Semaphore.init(2);
    try testing.expectEqual(2, sem.availablePermits());

    // Extra releases should not exceed max_permits
    sem.release();
    try testing.expectEqual(2, sem.availablePermits());

    sem.release();
    try testing.expectEqual(2, sem.availablePermits());

    // Normal acquire/release still works
    sem.acquire();
    try testing.expectEqual(1, sem.availablePermits());

    sem.release();
    try testing.expectEqual(2, sem.availablePermits());
}

test "latch countdown" {
    const testing = std.testing;

    var latch = Latch.init(3);

    try testing.expectEqual(3, latch.getCount());

    latch.countDown();
    try testing.expectEqual(2, latch.getCount());

    latch.countDown();
    try testing.expectEqual(1, latch.getCount());

    latch.countDown();
    try testing.expectEqual(0, latch.getCount());
}

test "AsyncMutex contention" {
    const testing = std.testing;

    var mutex = AsyncMutex.init();
    var counter: u32 = 0;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(m: *AsyncMutex, c: *u32) void {
                for (0..100) |_| {
                    m.lock();
                    defer m.unlock();
                    c.* += 1;
                }
            }
        }.run, .{ &mutex, &counter });
    }

    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 400), counter);
}

test "AsyncRwLock concurrent reads" {
    const testing = std.testing;

    var rwlock = AsyncRwLock.init();
    var shared_value: u32 = 42;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(rw: *AsyncRwLock, val: *u32) void {
                for (0..10) |_| {
                    rw.lockRead();
                    defer rw.unlockRead();
                    std.debug.assert(val.* == 42);
                }
            }
        }.run, .{ &rwlock, &shared_value });
    }

    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 42), shared_value);
}

test "Barrier synchronization" {
    const testing = std.testing;

    var barrier = Barrier.init(4);
    var arrivals: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(b: *Barrier, a: *std.atomic.Value(u32)) void {
                _ = a.fetchAdd(1, .monotonic);
                b.wait();
                // After barrier, all 4 threads arrived
                std.debug.assert(a.load(.monotonic) == 4);
            }
        }.run, .{ &barrier, &arrivals });
    }

    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 4), arrivals.load(.monotonic));
}

test "WaitGroup add and done" {
    const testing = std.testing;

    var wg = WaitGroup.init();
    var completed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    wg.add(4);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(w: *WaitGroup, c: *std.atomic.Value(u32)) void {
                defer w.done();
                _ = c.fetchAdd(1, .release);
            }
        }.run, .{ &wg, &completed });
    }

    wg.wait();
    try testing.expectEqual(@as(u32, 4), completed.load(.acquire));
}

test "WaitGroup waitTimeout" {
    const testing = std.testing;

    var wg = WaitGroup.init();
    try testing.expect(wg.waitTimeout(1));
    wg.add(1);
    try testing.expect(!wg.waitTimeout(1));
    wg.done();
    try testing.expect(wg.waitTimeout(1));
}

test "runtime-integrated sync primitives" {
    const RuntimeTask = struct {
        fn run() void {
            const io = @import("std_runtime.zig").getGlobalIo().?;

            var sem = IoSemaphore.init(1);
            std.testing.expect(sem.tryAcquire(io)) catch unreachable;
            std.testing.expectError(error.Timeout, sem.acquireTimeout(io, .{ .duration = .{
                .raw = .fromMilliseconds(1),
                .clock = .awake,
            } })) catch unreachable;
            sem.release(io);
            sem.acquire(io) catch unreachable;
            sem.release(io);

            var mutex = IoMutex.init();
            mutex.lock(io) catch unreachable;
            std.testing.expect(!mutex.tryLock()) catch unreachable;
            mutex.unlock(io);

            var rw = IoRwLock.init();
            rw.lockRead(io) catch unreachable;
            std.testing.expect(rw.tryLockRead(io)) catch unreachable;
            rw.unlockRead(io);
            rw.unlockRead(io);
            rw.lockWrite(io) catch unreachable;
            std.testing.expect(!rw.tryLockRead(io)) catch unreachable;
            rw.unlockWrite(io);

            var wg = IoWaitGroup.init();
            wg.add(io, 1);
            std.testing.expectError(error.Timeout, wg.waitTimeout(io, .{ .duration = .{
                .raw = .fromMilliseconds(1),
                .clock = .awake,
            } })) catch unreachable;
            wg.done(io);
            wg.wait(io) catch unreachable;
            std.testing.expectEqual(@as(u32, 0), wg.getCount(io)) catch unreachable;
        }
    };

    @import("std_runtime.zig").run(std.testing.allocator, RuntimeTask.run, .{});
}
