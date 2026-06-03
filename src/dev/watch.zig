//! zsync File Watcher
//! Cross-platform file watching with debouncing

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat/thread.zig");

/// File watcher event types
pub const WatchEvent = enum {
    created,
    modified,
    deleted,
    renamed,
};

/// File watcher callback
pub const WatchCallback = *const fn (path: []const u8, event: WatchEvent) void;

/// File Watcher
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8),
    callback: WatchCallback,
    debounce_ms: u64,
    recursive: bool,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        callback: WatchCallback,
        debounce_ms: u64,
        recursive: bool,
    ) !Self {
        return Self{
            .allocator = allocator,
            .paths = .empty,
            .callback = callback,
            .debounce_ms = debounce_ms,
            .recursive = recursive,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit(self.allocator);
    }

    /// Add path to watch
    pub fn watch(self: *Self, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.paths.append(self.allocator, owned_path);
    }

    /// Start watching
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        // Platform-specific implementation
        return switch (builtin.os.tag) {
            .linux => self.watchLinux(),
            .macos => self.watchMacOS(),
            .windows => self.watchWindows(),
            else => error.PlatformNotSupported,
        };
    }

    /// Stop watching
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Linux inotify implementation.
    ///
    /// Registers an inotify watch for every path and blocks in a `poll` loop
    /// until `stop()` flips the running flag. The `poll` timeout is bounded by
    /// `debounce_ms` so a stopped watcher returns promptly even when the
    /// filesystem is idle.
    fn watchLinux(self: *Self) !void {
        if (builtin.os.tag != .linux) return error.PlatformNotSupported;

        const linux = std.os.linux;

        const init_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        switch (linux.errno(init_rc)) {
            .SUCCESS => {},
            else => return error.InotifyInitFailed,
        }
        const inotify_fd: i32 = @intCast(init_rc);
        defer _ = linux.close(inotify_fd);

        const mask: u32 = linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE |
            linux.IN.MOVED_FROM | linux.IN.MOVED_TO;

        // Maps each watch descriptor back to the path the caller registered.
        // Values borrow from `self.paths`, which outlives this loop.
        var wd_map = std.AutoHashMap(i32, []const u8).init(self.allocator);
        defer wd_map.deinit();

        for (self.paths.items) |path| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (path.len >= path_buf.len) continue;
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&path_buf);
            const wd_rc = linux.inotify_add_watch(inotify_fd, path_z, mask);
            switch (linux.errno(wd_rc)) {
                .SUCCESS => try wd_map.put(@intCast(wd_rc), path),
                else => {}, // skip paths that cannot be watched (e.g. missing)
            }
        }

        var fds = [_]std.posix.pollfd{.{
            .fd = inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (self.running.load(.acquire)) {
            const timeout: i32 = @intCast(@min(self.debounce_ms, std.math.maxInt(i32)));
            const ready = try std.posix.poll(&fds, timeout);
            if (ready == 0) continue; // timeout: re-check the running flag
            if (fds[0].revents & std.posix.POLL.IN == 0) continue;

            const bytes_read = std.posix.read(inotify_fd, &event_buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= bytes_read) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&event_buf[offset]));
                const watched_path = wd_map.get(event.wd) orelse "";

                const watch_event = classifyMask(event.mask);

                // Directory watches report the affected child via `getName`;
                // surface the full child path so callbacks receive something
                // actionable. File watches report the watched path directly.
                if (event.getName()) |name| {
                    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ watched_path, name }) catch watched_path;
                    self.callback(full, watch_event);
                } else if (watched_path.len != 0) {
                    self.callback(watched_path, watch_event);
                }

                offset += @sizeOf(linux.inotify_event) + event.len;
            }
        }
    }

    /// Translate an inotify event mask into a `WatchEvent`. Move events are
    /// reported as renames; the remaining bits map to their direct equivalents.
    fn classifyMask(event_mask: u32) WatchEvent {
        const linux = std.os.linux;
        if (event_mask & (linux.IN.MOVED_FROM | linux.IN.MOVED_TO) != 0) return .renamed;
        if (event_mask & linux.IN.CREATE != 0) return .created;
        if (event_mask & linux.IN.DELETE != 0) return .deleted;
        return .modified;
    }

    /// macOS watcher.
    ///
    /// A native FSEvents backend is not wired up yet, so this falls back to
    /// portable modification-time polling, which is correct (it fires the same
    /// `WatchEvent` callbacks) if less efficient than FSEvents.
    fn watchMacOS(self: *Self) !void {
        if (builtin.os.tag != .macos) return error.PlatformNotSupported;
        return self.watchByPolling();
    }

    /// Windows watcher.
    ///
    /// A native `ReadDirectoryChangesW` backend is not wired up yet, so this
    /// falls back to portable modification-time polling, which is correct if
    /// less efficient than the native API.
    fn watchWindows(self: *Self) !void {
        if (builtin.os.tag != .windows) return error.PlatformNotSupported;
        return self.watchByPolling();
    }

    /// Portable fallback that detects changes by comparing file modification
    /// times between polls via `std.Io` filesystem access. Used on platforms
    /// without a native change-notification backend wired up. Blocks until
    /// `stop()` clears the running flag, sleeping `debounce_ms` between scans.
    fn watchByPolling(self: *Self) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // path -> last observed mtime in nanoseconds; null means absent.
        // Keys borrow from `self.paths`, which outlives this loop.
        var seen = std.StringHashMap(?i96).init(self.allocator);
        defer seen.deinit();

        for (self.paths.items) |path| {
            const mtime: ?i96 = if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat|
                stat.mtime.nanoseconds
            else |_|
                null;
            try seen.put(path, mtime);
        }

        while (self.running.load(.acquire)) {
            for (self.paths.items) |path| {
                const entry = seen.getPtr(path) orelse continue;
                const previous = entry.*;

                if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
                    const current = stat.mtime.nanoseconds;
                    if (previous == null) {
                        self.callback(path, .created);
                        entry.* = current;
                    } else if (current != previous.?) {
                        self.callback(path, .modified);
                        entry.* = current;
                    }
                } else |_| {
                    if (previous != null) {
                        self.callback(path, .deleted);
                        entry.* = null;
                    }
                }
            }

            compat.sleepNanos(self.debounce_ms * std.time.ns_per_ms);
        }
    }
};

/// Simple polling-based watcher (works everywhere).
///
/// Uses `std.Io` filesystem access so it functions on platforms without a
/// native change-notification facility. Modification times are compared in
/// nanoseconds to detect changes between polls.
pub const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: std.StringHashMap(i96), // path -> mtime (nanoseconds)
    callback: WatchCallback,
    poll_interval_ms: u64,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        callback: WatchCallback,
        poll_interval_ms: u64,
    ) Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .paths = std.StringHashMap(i96).init(allocator),
            .callback = callback,
            .poll_interval_ms = poll_interval_ms,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.paths.deinit();
    }

    /// Add path to watch
    pub fn watch(self: *Self, path: []const u8) !void {
        const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});
        try self.paths.put(path, stat.mtime.nanoseconds);
    }

    /// Start watching
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            var it = self.paths.iterator();
            while (it.next()) |entry| {
                const path = entry.key_ptr.*;
                const old_mtime = entry.value_ptr.*;

                // Treat any stat failure (typically deletion) as removal.
                const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch {
                    self.callback(path, .deleted);
                    continue;
                };

                if (stat.mtime.nanoseconds != old_mtime) {
                    self.callback(path, .modified);
                    entry.value_ptr.* = stat.mtime.nanoseconds;
                }
            }

            compat.sleepNanos(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Stop watching
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
};

// Tests

var test_event_count = std.atomic.Value(u32).init(0);

fn testWatchCallback(path: []const u8, event: WatchEvent) void {
    _ = path;
    _ = event;
    _ = test_event_count.fetchAdd(1, .monotonic);
}

test "inotify file watcher detects directory changes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_name = "zsync_watch_test_dir";
    try std.Io.Dir.cwd().createDir(io, dir_name, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    test_event_count.store(0, .monotonic);

    var watcher = try FileWatcher.init(allocator, testWatchCallback, 20, false);
    defer watcher.deinit();
    try watcher.watch(dir_name);

    const Runner = struct {
        fn run(w: *FileWatcher) void {
            w.start() catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&watcher});

    // Give inotify time to register before generating events.
    compat.sleepNanos(50 * std.time.ns_per_ms);

    var test_dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
    defer test_dir.close(io);
    var f = try test_dir.createFile(io, "created.txt", .{});
    try f.writePositionalAll(io, "hello", 0);
    f.close(io);

    // Allow the event to propagate through the poll loop.
    compat.sleepNanos(100 * std.time.ns_per_ms);

    watcher.stop();
    thread.join();

    try testing.expect(test_event_count.load(.monotonic) >= 1);
}

test "polling watcher detects modification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_name = "zsync_poll_test_dir";
    try std.Io.Dir.cwd().createDir(io, dir_name, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var test_dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
    defer test_dir.close(io);
    {
        var f = try test_dir.createFile(io, "target.txt", .{});
        try f.writePositionalAll(io, "v1", 0);
        f.close(io);
    }

    const file_path = dir_name ++ "/target.txt";

    test_event_count.store(0, .monotonic);

    var watcher = PollingWatcher.init(allocator, io, testWatchCallback, 10);
    defer watcher.deinit();
    try watcher.watch(file_path);

    const Runner = struct {
        fn run(w: *PollingWatcher) void {
            w.start() catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&watcher});

    // Ensure the modification time advances relative to the recorded baseline.
    compat.sleepNanos(30 * std.time.ns_per_ms);
    {
        var f = try test_dir.createFile(io, "target.txt", .{ .truncate = true });
        try f.writePositionalAll(io, "v2-changed", 0);
        f.close(io);
    }

    compat.sleepNanos(80 * std.time.ns_per_ms);

    watcher.stop();
    thread.join();

    try testing.expect(test_event_count.load(.monotonic) >= 1);
}

test "FileWatcher polling fallback detects modification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_name = "zsync_watch_fallback_test_dir";
    try std.Io.Dir.cwd().createDir(io, dir_name, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var test_dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
    defer test_dir.close(io);
    {
        var f = try test_dir.createFile(io, "target.txt", .{});
        try f.writePositionalAll(io, "v1", 0);
        f.close(io);
    }

    const file_path = dir_name ++ "/target.txt";

    test_event_count.store(0, .monotonic);

    var watcher = try FileWatcher.init(allocator, testWatchCallback, 10, false);
    defer watcher.deinit();
    try watcher.watch(file_path);

    // Exercise the portable polling backend directly (the same code path
    // watchMacOS/watchWindows delegate to), independent of the host OS.
    const Runner = struct {
        fn run(w: *FileWatcher) void {
            w.running.store(true, .release);
            w.watchByPolling() catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&watcher});

    // Ensure the modification time advances relative to the recorded baseline.
    compat.sleepNanos(30 * std.time.ns_per_ms);
    {
        var f = try test_dir.createFile(io, "target.txt", .{ .truncate = true });
        try f.writePositionalAll(io, "v2-changed", 0);
        f.close(io);
    }

    compat.sleepNanos(80 * std.time.ns_per_ms);

    watcher.stop();
    thread.join();

    try testing.expect(test_event_count.load(.monotonic) >= 1);
}
