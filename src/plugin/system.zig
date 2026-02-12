//! Zsync v0.6.0 - Plugin System Support
//! Dynamic plugin loading and lifecycle management for GShell

const std = @import("std");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../runtime.zig").Runtime;

/// Plugin State
pub const PluginState = enum {
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

        return Self{
            .allocator = allocator,
            .metadata = metadata,
            .state = std.atomic.Value(PluginState).init(.unloaded),
            .hooks = hooks,
            .path = owned_path,
            .enabled = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
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
            .plugin_dirs = std.ArrayList([]const u8){ .allocator = allocator },
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
        self.plugin_dirs.deinit();
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

    /// Load all plugins in directory
    pub fn loadDirectory(self: *Self, dir: []const u8) !void {
        _ = self;
        _ = dir;
        // TODO: Scan directory for plugins
        // TODO: Load each plugin found
    }

    /// Get list of loaded plugins
    pub fn listPlugins(self: *Self) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var names = std.ArrayList([]const u8){ .allocator = self.allocator };
        var it = self.plugins.iterator();

        while (it.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }

        return names.toOwnedSlice();
    }

    /// Get plugin count
    pub fn pluginCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.plugins.count();
    }
};

/// Plugin Discovery - scan directories for plugins
pub fn discoverPlugins(
    allocator: std.mem.Allocator,
    dir: []const u8,
) ![][]const u8 {
    var plugins = std.ArrayList([]const u8){ .allocator = allocator };

    var dir_handle = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer dir_handle.close();

    var it = dir_handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            // Check if it's a plugin file (e.g., .gza for GShell)
            if (std.mem.endsWith(u8, entry.name, ".gza")) {
                const plugin_name = try allocator.dupe(u8, entry.name);
                try plugins.append(allocator, plugin_name);
            }
        }
    }

    return plugins.toOwnedSlice();
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

test "plugin manager" {
    const testing = std.testing;

    var config = @import("../runtime.zig").Config.optimal();
    var runtime = try @import("../runtime.zig").Runtime.init(testing.allocator, &config);
    defer runtime.deinit();

    var manager = PluginManager.init(testing.allocator, runtime);
    defer manager.deinit();

    try testing.expectEqual(0, manager.pluginCount());
}
