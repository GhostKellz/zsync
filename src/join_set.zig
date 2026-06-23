//! JoinSet for managing blocking work on dedicated OS threads.

const std = @import("std");
const compat = @import("compat/thread.zig");

/// JoinSet for managing multiple concurrent blocking tasks.
/// Tasks are spawned on separate threads and run concurrently.
/// Each task entry is heap-allocated to ensure pointer stability across spawns.
pub fn JoinSet(comptime T: type) type {
    return struct {
        entries: std.ArrayList(*TaskEntry),
        allocator: std.mem.Allocator,
        mutex: compat.Mutex = .{},
        completed_cond: compat.Condition = .{},
        completed_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        const TaskEntry = struct {
            thread: ?std.Thread = null,
            result: ?T = null,
            err: ?anyerror = null,
            completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            joined: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .entries = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.joinAll();
            for (self.entries.items) |entry| {
                self.allocator.destroy(entry);
            }
            self.entries.deinit(self.allocator);
        }

        /// Spawn a task on a new thread.
        pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !usize {
            const entry = try self.allocator.create(TaskEntry);
            entry.* = TaskEntry{};

            const idx = self.entries.items.len;
            try self.entries.append(self.allocator, entry);

            const Wrapper = struct {
                fn run(task_entry: *TaskEntry, set: *Self, func_args: anytype) void {
                    const result = @call(.auto, func, func_args);
                    task_entry.result = result;
                    task_entry.completed.store(true, .release);
                    _ = set.completed_count.fetchAdd(1, .release);
                    set.completed_cond.signal();
                }
            };

            entry.thread = try std.Thread.spawn(.{}, Wrapper.run, .{ entry, self, args });
            return idx;
        }

        /// Spawn a task that may return an error.
        pub fn spawnErrorable(self: *Self, comptime func: anytype, args: anytype) !usize {
            const entry = try self.allocator.create(TaskEntry);
            entry.* = TaskEntry{};

            const idx = self.entries.items.len;
            try self.entries.append(self.allocator, entry);

            const Wrapper = struct {
                fn run(task_entry: *TaskEntry, set: *Self, func_args: anytype) void {
                    if (@call(.auto, func, func_args)) |result| {
                        task_entry.result = result;
                    } else |err| {
                        task_entry.err = err;
                    }
                    task_entry.completed.store(true, .release);
                    _ = set.completed_count.fetchAdd(1, .release);
                    set.completed_cond.signal();
                }
            };

            entry.thread = try std.Thread.spawn(.{}, Wrapper.run, .{ entry, self, args });
            return idx;
        }

        /// Wait for all tasks to complete and join threads.
        pub fn joinAll(self: *Self) void {
            for (self.entries.items) |entry| {
                if (!entry.joined) {
                    if (entry.thread) |thread| {
                        thread.join();
                        entry.thread = null;
                    }
                    entry.joined = true;
                }
            }
        }

        /// Wait for any task to complete and return its result.
        /// Returns null if no tasks remain.
        pub fn joinNext(self: *Self) ?JoinResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.entries.items, 0..) |entry, idx| {
                if (entry.completed.load(.acquire) and !entry.joined) {
                    return self.joinEntry(entry, idx);
                }
            }

            var has_pending = false;
            for (self.entries.items) |entry| {
                if (!entry.joined) {
                    has_pending = true;
                    break;
                }
            }
            if (!has_pending) return null;

            self.completed_cond.wait(&self.mutex);

            for (self.entries.items, 0..) |entry, idx| {
                if (entry.completed.load(.acquire) and !entry.joined) {
                    return self.joinEntry(entry, idx);
                }
            }

            return null;
        }

        fn joinEntry(self: *Self, entry: *TaskEntry, idx: usize) JoinResult {
            _ = self;
            if (entry.thread) |thread| {
                thread.join();
                entry.thread = null;
            }
            entry.joined = true;

            if (entry.err) |err| {
                return JoinResult{ .idx = idx, .value = .{ .err = err } };
            }
            return JoinResult{ .idx = idx, .value = .{ .ok = entry.result } };
        }

        /// Get number of pending (not yet joined) tasks.
        pub fn len(self: *const Self) usize {
            var pending: usize = 0;
            for (self.entries.items) |entry| {
                if (!entry.joined) pending += 1;
            }
            return pending;
        }

        /// Check if all tasks have been joined.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub const JoinResult = struct {
            idx: usize,
            value: union(enum) {
                ok: ?T,
                err: anyerror,
            },
        };
    };
}

test "JoinSet joinNext returns completed results" {
    const testing = std.testing;
    var set = JoinSet(u32).init(testing.allocator);
    defer set.deinit();

    _ = try set.spawn(struct {
        fn run(value: u32) u32 {
            return value;
        }
    }.run, .{@as(u32, 42)});

    const result = set.joinNext().?;
    try testing.expectEqual(@as(u32, 42), result.value.ok.?);
    try testing.expect(set.isEmpty());
}
