//! Zsync v0.7.0 - Async Streams API
//! Tokio-style async iteration with combinators

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const io_interface = @import("io_interface.zig");

const Runtime = runtime_mod.Runtime;
const Future = io_interface.Future;
const Io = io_interface.Io;

/// Stream trait for async iteration
pub fn Stream(comptime T: type) type {
    return struct {
        vtable: *const StreamVTable,
        context: *anyopaque,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub const StreamVTable = struct {
            next: *const fn (context: *anyopaque) ?T,
            destroy: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,
        };

        /// Get next item from stream (returns null when exhausted)
        pub fn next(self: *Self) ?T {
            return self.vtable.next(self.context);
        }

        /// Map stream values through a function
        pub fn map(self: *Self, comptime func: anytype) !*Stream(@TypeOf(func(undefined))) {
            return MapStream(T, @TypeOf(func(undefined))).init(
                self.allocator,
                self,
                func,
            );
        }

        /// Filter stream values by predicate
        pub fn filter(self: *Self, comptime predicate: anytype) !*Stream(T) {
            return FilterStream(T).init(self.allocator, self, predicate);
        }

        /// Take first N items
        pub fn take(self: *Self, n: usize) !*Stream(T) {
            return TakeStream(T).init(self.allocator, self, n);
        }

        /// Skip first N items
        pub fn skip(self: *Self, n: usize) !*Stream(T) {
            return SkipStream(T).init(self.allocator, self, n);
        }

        /// Collect all items into a list
        pub fn collect(self: *Self) !std.ArrayList(T) {
            var list = std.ArrayList(T).init(self.allocator);
            errdefer list.deinit();

            while (self.next()) |item| {
                try list.append(item);
            }

            return list;
        }

        /// Fold stream into single value
        pub fn fold(self: *Self, init: anytype, comptime func: anytype) @TypeOf(init) {
            var accumulator = init;
            while (self.next()) |item| {
                accumulator = func(accumulator, item);
            }
            return accumulator;
        }

        /// Count items in stream
        pub fn count(self: *Self) usize {
            var n: usize = 0;
            while (self.next()) |_| {
                n += 1;
            }
            return n;
        }

        /// Check if any item matches predicate
        pub fn any(self: *Self, comptime predicate: anytype) bool {
            while (self.next()) |item| {
                if (predicate(item)) return true;
            }
            return false;
        }

        /// Check if all items match predicate
        pub fn all(self: *Self, comptime predicate: anytype) bool {
            while (self.next()) |item| {
                if (!predicate(item)) return false;
            }
            return true;
        }

        /// Find first item matching predicate
        pub fn find(self: *Self, comptime predicate: anytype) ?T {
            while (self.next()) |item| {
                if (predicate(item)) return item;
            }
            return null;
        }

        /// Destroy stream and free resources
        pub fn deinit(self: *Self) void {
            self.vtable.destroy(self.context, self.allocator);
            self.allocator.destroy(self);
        }
    };
}

/// Create stream from slice
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, items: []const T) !*Stream(T) {
    const SliceStream = struct {
        items: []const T,
        index: usize,

        fn next(ctx: *anyopaque) ?T {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.index >= self.items.len) return null;
            const item = self.items[self.index];
            self.index += 1;
            return item;
        }

        fn destroy(ctx: *anyopaque, alloc: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        const vtable = Stream(T).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };

    const ctx = try allocator.create(SliceStream);
    ctx.* = .{
        .items = items,
        .index = 0,
    };

    const stream = try allocator.create(Stream(T));
    stream.* = .{
        .vtable = &SliceStream.vtable,
        .context = ctx,
        .allocator = allocator,
    };

    return stream;
}

/// Create stream from range
pub fn range(allocator: std.mem.Allocator, start: i64, end: i64) !*Stream(i64) {
    const RangeStream = struct {
        current: i64,
        end: i64,

        fn next(ctx: *anyopaque) ?i64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.current >= self.end) return null;
            const val = self.current;
            self.current += 1;
            return val;
        }

        fn destroy(ctx: *anyopaque, alloc: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        const vtable = Stream(i64).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };

    const ctx = try allocator.create(RangeStream);
    ctx.* = .{
        .current = start,
        .end = end,
    };

    const stream = try allocator.create(Stream(i64));
    stream.* = .{
        .vtable = &RangeStream.vtable,
        .context = ctx,
        .allocator = allocator,
    };

    return stream;
}

/// Map combinator
fn MapStream(comptime T: type, comptime U: type) type {
    return struct {
        source: *Stream(T),
        map_fn: *const fn (T) U,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, source: *Stream(T), map_fn: anytype) !*Stream(U) {
            const ctx = try allocator.create(Self);
            ctx.* = .{
                .source = source,
                .map_fn = map_fn,
            };

            const stream = try allocator.create(Stream(U));
            stream.* = .{
                .vtable = &vtable,
                .context = ctx,
                .allocator = allocator,
            };

            return stream;
        }

        fn next(ctx: *anyopaque) ?U {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const item = self.source.next() orelse return null;
            return self.map_fn(item);
        }

        fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }

        const vtable = Stream(U).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };
}

/// Filter combinator
fn FilterStream(comptime T: type) type {
    return struct {
        source: *Stream(T),
        predicate: *const fn (T) bool,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, source: *Stream(T), predicate: anytype) !*Stream(T) {
            const ctx = try allocator.create(Self);
            ctx.* = .{
                .source = source,
                .predicate = predicate,
            };

            const stream = try allocator.create(Stream(T));
            stream.* = .{
                .vtable = &vtable,
                .context = ctx,
                .allocator = allocator,
            };

            return stream;
        }

        fn next(ctx: *anyopaque) ?T {
            const self: *Self = @ptrCast(@alignCast(ctx));
            while (self.source.next()) |item| {
                if (self.predicate(item)) return item;
            }
            return null;
        }

        fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }

        const vtable = Stream(T).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };
}

/// Take combinator
fn TakeStream(comptime T: type) type {
    return struct {
        source: *Stream(T),
        remaining: usize,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, source: *Stream(T), count: usize) !*Stream(T) {
            const ctx = try allocator.create(Self);
            ctx.* = .{
                .source = source,
                .remaining = count,
            };

            const stream = try allocator.create(Stream(T));
            stream.* = .{
                .vtable = &vtable,
                .context = ctx,
                .allocator = allocator,
            };

            return stream;
        }

        fn next(ctx: *anyopaque) ?T {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.remaining == 0) return null;
            const item = self.source.next() orelse return null;
            self.remaining -= 1;
            return item;
        }

        fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }

        const vtable = Stream(T).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };
}

/// Skip combinator
fn SkipStream(comptime T: type) type {
    return struct {
        source: *Stream(T),
        to_skip: usize,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, source: *Stream(T), count: usize) !*Stream(T) {
            const ctx = try allocator.create(Self);
            ctx.* = .{
                .source = source,
                .to_skip = count,
            };

            const stream = try allocator.create(Stream(T));
            stream.* = .{
                .vtable = &vtable,
                .context = ctx,
                .allocator = allocator,
            };

            return stream;
        }

        fn next(ctx: *anyopaque) ?T {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Skip initial items
            while (self.to_skip > 0) {
                _ = self.source.next() orelse return null;
                self.to_skip -= 1;
            }

            return self.source.next();
        }

        fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            allocator.destroy(self);
        }

        const vtable = Stream(T).StreamVTable{
            .next = next,
            .destroy = destroy,
        };
    };
}

// Tests
test "stream from slice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var stream = try fromSlice(i32, allocator, &items);
    defer stream.deinit();

    try testing.expectEqual(@as(?i32, 1), stream.next());
    try testing.expectEqual(@as(?i32, 2), stream.next());
    try testing.expectEqual(@as(?i32, 3), stream.next());
}

test "stream map combinator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const items = [_]i32{ 1, 2, 3 };
    var stream = try fromSlice(i32, allocator, &items);
    defer stream.deinit();

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    var mapped = try stream.map(double);
    defer mapped.deinit();

    try testing.expectEqual(@as(?i32, 2), mapped.next());
    try testing.expectEqual(@as(?i32, 4), mapped.next());
    try testing.expectEqual(@as(?i32, 6), mapped.next());
}

test "stream filter combinator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var stream = try fromSlice(i32, allocator, &items);
    defer stream.deinit();

    const isEven = struct {
        fn f(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.f;

    var filtered = try stream.filter(isEven);
    defer filtered.deinit();

    try testing.expectEqual(@as(?i32, 2), filtered.next());
    try testing.expectEqual(@as(?i32, 4), filtered.next());
    try testing.expectEqual(@as(?i32, 6), filtered.next());
}

test "stream chaining" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = try range(allocator, 0, 100);
    defer stream.deinit();

    const double = struct {
        fn f(x: i64) i64 {
            return x * 2;
        }
    }.f;

    const isEven = struct {
        fn f(x: i64) bool {
            return @mod(x, 2) == 0;
        }
    }.f;

    var mapped = try stream.map(double);
    defer mapped.deinit();

    var filtered = try mapped.filter(isEven);
    defer filtered.deinit();

    var taken = try filtered.take(5);
    defer taken.deinit();

    const result = try taken.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.items.len);
}
