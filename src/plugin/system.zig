//! zsync Plugin System Support
//! Dynamic plugin loading and lifecycle management for GShell

const std = @import("std");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../std_runtime.zig").Runtime;

/// Plugin State
pub const PluginState = enum(u8) {
    unloaded,
    loading,
    loaded,
    unloading,
    failed,
};

/// Plugin Lifecycle Hooks
pub const PluginHooks = struct {
    on_load: ?*const fn (*Plugin) anyerror!void = null,
    on_unload: ?*const fn (*Plugin) anyerror!void = null,
    on_enable: ?*const fn (*Plugin) anyerror!void = null,
    on_disable: ?*const fn (*Plugin) anyerror!void = null,
    on_reload: ?*const fn (*Plugin) anyerror!void = null,
};

/// Plugin Metadata
pub const PluginMetadata = struct {
    name: []const u8,
    version: []const u8,
    author: ?[]const u8 = null,
    description: ?[]const u8 = null,
    dependencies: []const []const u8 = &.{},
    api_version: []const u8 = "1.0",
};

/// Plugin
pub const Plugin = struct {
    allocator: std.mem.Allocator,
    metadata: PluginMetadata,
    state: std.atomic.Value(PluginState),
    hooks: PluginHooks,
    data: ?*anyopaque = null,
    path: []const u8,
    enabled: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        metadata: PluginMetadata,
        path: []const u8,
        hooks: PluginHooks,
    ) !Self {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        // Own the plugin name so it can outlive the caller's metadata buffer.
        var owned_metadata = metadata;
        owned_metadata.name = try allocator.dupe(u8, metadata.name);

        return Self{
            .allocator = allocator,
            .metadata = owned_metadata,
            .state = std.atomic.Value(PluginState).init(.unloaded),
            .hooks = hooks,
            .path = owned_path,
            .enabled = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.metadata.name);
        self.allocator.free(self.path);
    }

    /// Load plugin
    pub fn load(self: *Self) !void {
        if (self.state.load(.acquire) != .unloaded) {
            return error.AlreadyLoaded;
        }

        self.state.store(.loading, .release);

        if (self.hooks.on_load) |hook| {
            hook(self) catch |err| {
                self.state.store(.failed, .release);
                return err;
            };
        }

        self.state.store(.loaded, .release);
    }

    /// Unload plugin
    pub fn unload(self: *Self) !void {
        if (self.state.load(.acquire) != .loaded) {
            return error.NotLoaded;
        }

        self.state.store(.unloading, .release);

        if (self.hooks.on_unload) |hook| {
            try hook(self);
        }

        self.state.store(.unloaded, .release);
    }

    /// Enable plugin
    pub fn enable(self: *Self) !void {
        if (self.state.load(.acquire) != .loaded) {
            return error.NotLoaded;
        }

        if (self.hooks.on_enable) |hook| {
            try hook(self);
        }

        self.enabled.store(true, .release);
    }

    /// Disable plugin
    pub fn disable(self: *Self) !void {
        if (self.state.load(.acquire) != .loaded) {
            return error.NotLoaded;
        }

        if (self.hooks.on_disable) |hook| {
            try hook(self);
        }

        self.enabled.store(false, .release);
    }

    /// Reload plugin
    pub fn reload(self: *Self) !void {
        try self.unload();
        try self.load();

        if (self.hooks.on_reload) |hook| {
            try hook(self);
        }
    }

    /// Get plugin state
    pub fn getState(self: *const Self) PluginState {
        return self.state.load(.acquire);
    }

    /// Check if plugin is enabled
    pub fn isEnabled(self: *const Self) bool {
        return self.enabled.load(.acquire);
    }
};

/// Plugin Manager
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    plugins: std.StringHashMap(*Plugin),
    plugin_dirs: std.ArrayList([]const u8),
    mutex: compat.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .plugins = std.StringHashMap(*Plugin).init(allocator),
            .plugin_dirs = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.plugins.deinit();

        for (self.plugin_dirs.items) |dir| {
            self.allocator.free(dir);
        }
        self.plugin_dirs.deinit(self.allocator);
    }

    /// Add plugin search directory
    pub fn addPluginDir(self: *Self, dir: []const u8) !void {
        const owned_dir = try self.allocator.dupe(u8, dir);
        try self.plugin_dirs.append(self.allocator, owned_dir);
    }

    /// Register plugin
    pub fn registerPlugin(self: *Self, plugin: *Plugin) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const name = try self.allocator.dupe(u8, plugin.metadata.name);
        try self.plugins.put(name, plugin);
    }

    /// Get plugin by name
    pub fn getPlugin(self: *Self, name: []const u8) ?*Plugin {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.plugins.get(name);
    }

    /// Load plugin by name
    pub fn loadPlugin(self: *Self, name: []const u8) !void {
        if (self.getPlugin(name)) |plugin| {
            try plugin.load();
        } else {
            return error.PluginNotFound;
        }
    }

    /// Unload plugin by name
    pub fn unloadPlugin(self: *Self, name: []const u8) !void {
        if (self.getPlugin(name)) |plugin| {
            try plugin.unload();
        } else {
            return error.PluginNotFound;
        }
    }

    /// Enable plugin by name
    pub fn enablePlugin(self: *Self, name: []const u8) !void {
        if (self.getPlugin(name)) |plugin| {
            try plugin.enable();
        } else {
            return error.PluginNotFound;
        }
    }

    /// Disable plugin by name
    pub fn disablePlugin(self: *Self, name: []const u8) !void {
        if (self.getPlugin(name)) |plugin| {
            try plugin.disable();
        } else {
            return error.PluginNotFound;
        }
    }

    /// Reload plugin by name
    pub fn reloadPlugin(self: *Self, name: []const u8) !void {
        if (self.getPlugin(name)) |plugin| {
            try plugin.reload();
        } else {
            return error.PluginNotFound;
        }
    }

    /// Scan `dir` for plugin files (`.gza`) and register each one with this
    /// manager in the `unloaded` state. Returns the number of plugins newly
    /// registered. Plugins already known by name are skipped.
    pub fn loadDirectory(self: *Self, dir: []const u8) !usize {
        const io = self.runtime.io();

        const names = try discoverPlugins(self.allocator, io, dir);
        defer {
            for (names) |name| self.allocator.free(name);
            self.allocator.free(names);
        }

        var registered: usize = 0;
        for (names) |file_name| {
            const stem = file_name[0 .. file_name.len - ".gza".len];

            if (self.getPlugin(stem) != null) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ dir, file_name });
            defer self.allocator.free(full_path);

            const plugin = try self.allocator.create(Plugin);
            errdefer self.allocator.destroy(plugin);

            plugin.* = try Plugin.init(self.allocator, .{
                .name = stem,
                .version = "0.0.0",
            }, full_path, .{});
            errdefer plugin.deinit();

            try self.registerPlugin(plugin);
            registered += 1;
        }

        return registered;
    }

    /// Get list of loaded plugins
    pub fn listPlugins(self: *Self) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(self.allocator);
        var it = self.plugins.iterator();

        while (it.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }

        return names.toOwnedSlice(self.allocator);
    }

    /// Get plugin count
    pub fn pluginCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.plugins.count();
    }
};

/// Plugin Discovery - scan a directory for plugin files (`.gza`) through the
/// runtime's `std.Io`. Caller owns the returned slice and each name; free each
/// item then the slice with `allocator`.
pub fn discoverPlugins(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) ![][]const u8 {
    var plugins: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (plugins.items) |name| allocator.free(name);
        plugins.deinit(allocator);
    }

    var dir_handle = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer dir_handle.close(io);

    var it = dir_handle.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            // Check if it's a plugin file (e.g., .gza for GShell)
            if (std.mem.endsWith(u8, entry.name, ".gza")) {
                const plugin_name = try allocator.dupe(u8, entry.name);
                try plugins.append(allocator, plugin_name);
            }
        }
    }

    return plugins.toOwnedSlice(allocator);
}

// Tests
test "plugin lifecycle" {
    const testing = std.testing;

    const hooks = PluginHooks{};
    const metadata = PluginMetadata{
        .name = "test-plugin",
        .version = "1.0.0",
    };

    var plugin = try Plugin.init(testing.allocator, metadata, "/path/to/plugin", hooks);
    defer plugin.deinit();

    try testing.expectEqual(PluginState.unloaded, plugin.getState());

    try plugin.load();
    try testing.expectEqual(PluginState.loaded, plugin.getState());

    try plugin.enable();
    try testing.expect(plugin.isEnabled());

    try plugin.disable();
    try testing.expect(!plugin.isEnabled());

    try plugin.unload();
    try testing.expectEqual(PluginState.unloaded, plugin.getState());
}

test "plugin load hook failure marks failed" {
    const testing = std.testing;

    const Hooks = struct {
        fn failLoad(_: *Plugin) anyerror!void {
            return error.BadMetadata;
        }
    };

    var plugin = try Plugin.init(testing.allocator, .{
        .name = "bad-plugin",
        .version = "1.0.0",
    }, "/path/to/bad-plugin", .{ .on_load = Hooks.failLoad });
    defer plugin.deinit();

    try testing.expectError(error.BadMetadata, plugin.load());
    try testing.expectEqual(PluginState.failed, plugin.getState());
}

test "plugin manager" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var manager = PluginManager.init(testing.allocator, &runtime);
    defer manager.deinit();

    try testing.expectEqual(0, manager.pluginCount());
}

test "plugin discovery and loadDirectory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    const dir_name = "zsync_plugin_test_dir";
    try std.Io.Dir.cwd().createDir(io, dir_name, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var test_dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
    defer test_dir.close(io);

    inline for (.{ "alpha.gza", "beta.gza", "notes.txt" }) |fname| {
        var f = try test_dir.createFile(io, fname, .{});
        f.close(io);
    }

    // discoverPlugins finds only .gza files.
    const discovered = try discoverPlugins(allocator, io, dir_name);
    defer {
        for (discovered) |n| allocator.free(n);
        allocator.free(discovered);
    }
    try testing.expectEqual(@as(usize, 2), discovered.len);

    // loadDirectory registers each discovered plugin once.
    var manager = PluginManager.init(allocator, &runtime);
    defer manager.deinit();

    try testing.expectEqual(@as(usize, 2), try manager.loadDirectory(dir_name));
    try testing.expectEqual(@as(usize, 2), manager.pluginCount());

    // Idempotent: re-loading registers nothing new.
    try testing.expectEqual(@as(usize, 0), try manager.loadDirectory(dir_name));

    try testing.expect(manager.getPlugin("alpha") != null);
    try testing.expect(manager.getPlugin("beta") != null);
}

test "plugin discovery reports missing directory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = Runtime.init(allocator, .{});
    defer runtime.deinit();

    try testing.expectError(error.FileNotFound, discoverPlugins(allocator, runtime.io(), "missing-zsync-plugin-dir"));
}
