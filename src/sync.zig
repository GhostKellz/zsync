//! zsync- Synchronization Primitives
//! Async-aware synchronization primitives for concurrent programming

const std = @import("std");
const compat = @import("compat/thread.zig");

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
