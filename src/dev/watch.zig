//! Zsync v0.6.0 - File Watcher
//! Cross-platform file watching with debouncing

const std = @import("std");
const builtin = @import("builtin");

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
            .paths = std.ArrayList([]const u8).init(allocator),
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
        self.paths.deinit();
    }

    /// Add path to watch
    pub fn watch(self: *Self, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.paths.append(owned_path);
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

    /// Linux inotify implementation
    fn watchLinux(self: *Self) !void {
        if (builtin.os.tag != .linux) return error.PlatformNotSupported;

        // TODO: Implement with inotify
        // For now, just poll
        while (self.running.load(.acquire)) {
            std.Thread.sleep(self.debounce_ms * std.time.ns_per_ms);
            // Poll for changes
        }
    }

    /// macOS FSEvents implementation
    fn watchMacOS(self: *Self) !void {
        if (builtin.os.tag != .macos) return error.PlatformNotSupported;

        // TODO: Implement with FSEvents
        // For now, just poll
        while (self.running.load(.acquire)) {
            std.Thread.sleep(self.debounce_ms * std.time.ns_per_ms);
        }
    }

    /// Windows ReadDirectoryChangesW implementation
    fn watchWindows(self: *Self) !void {
        if (builtin.os.tag != .windows) return error.PlatformNotSupported;

        // TODO: Implement with ReadDirectoryChangesW
        // For now, just poll
        while (self.running.load(.acquire)) {
            std.Thread.sleep(self.debounce_ms * std.time.ns_per_ms);
        }
    }
};

/// Simple polling-based watcher (works everywhere)
pub const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    paths: std.StringHashMap(i64), // path -> mtime
    callback: WatchCallback,
    poll_interval_ms: u64,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        callback: WatchCallback,
        poll_interval_ms: u64,
    ) Self {
        return Self{
            .allocator = allocator,
            .paths = std.StringHashMap(i64).init(allocator),
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
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        try self.paths.put(path, stat.mtime);
    }

    /// Start watching
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            var it = self.paths.iterator();
            while (it.next()) |entry| {
                const path = entry.key_ptr.*;
                const old_mtime = entry.value_ptr.*;

                // Check if file still exists
                const file = std.fs.cwd().openFile(path, .{}) catch {
                    self.callback(path, .deleted);
                    continue;
                };
                defer file.close();

                const stat = file.stat() catch continue;

                if (stat.mtime != old_mtime) {
                    self.callback(path, .modified);
                    entry.value_ptr.* = stat.mtime;
                }
            }

            std.Thread.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Stop watching
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
};
