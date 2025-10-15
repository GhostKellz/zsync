//! Package Manager Async Operations
//! Parallel download/install operations for AUR helper and CLI tools
//! High-performance dependency management with async coordination

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const net = std.net;
const http = std.http;

/// Package manager configuration
pub const PackageConfig = struct {
    max_parallel_downloads: u32 = 8,
    max_parallel_installs: u32 = 4,
    download_timeout_ms: u64 = 30000,
    install_timeout_ms: u64 = 300000,
    cache_dir: []const u8 = "/tmp/zsync_cache",
    temp_dir: []const u8 = "/tmp/zsync_temp",
    max_retries: u32 = 3,
    retry_delay_ms: u64 = 1000,
    verification_enabled: bool = true,
    compression_enabled: bool = true,
};

/// Package dependency resolution types
pub const DependencyType = enum {
    required,
    optional,
    build_only,
    runtime_only,
    dev_only,
};

/// Package installation status
pub const InstallStatus = enum {
    not_installed,
    downloading,
    downloaded,
    installing,
    installed,
    failed,
    outdated,
    conflict,
};

/// Package metadata structure
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    maintainer: []const u8,
    url: []const u8,
    download_url: []const u8,
    dependencies: []Dependency,
    conflicts: [][]const u8,
    provides: [][]const u8,
    size: u64,
    checksum: [32]u8,
    build_script: ?[]const u8,
    install_script: ?[]const u8,
    status: InstallStatus,
    
    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.maintainer);
        allocator.free(self.url);
        allocator.free(self.download_url);
        
        for (self.dependencies) |*dep| {
            dep.deinit(allocator);
        }
        allocator.free(self.dependencies);
        
        for (self.conflicts) |conflict| {
            allocator.free(conflict);
        }
        allocator.free(self.conflicts);
        
        for (self.provides) |provide| {
            allocator.free(provide);
        }
        allocator.free(self.provides);
        
        if (self.build_script) |script| {
            allocator.free(script);
        }
        
        if (self.install_script) |script| {
            allocator.free(script);
        }
    }
};

/// Package dependency specification
pub const Dependency = struct {
    name: []const u8,
    version_constraint: []const u8,
    dependency_type: DependencyType,
    optional: bool = false,
    
    pub fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version_constraint);
    }
};

/// Download task for package files
pub const DownloadTask = struct {
    package: *Package,
    url: []const u8,
    destination: []const u8,
    progress: std.atomic.Value(u64),
    total_size: u64,
    started_at: i64,
    completed_at: ?i64,
    worker_id: u32,
    retry_count: u32,
    
    pub fn getProgress(self: *const DownloadTask) f64 {
        if (self.total_size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.progress.load(.acquire))) / @as(f64, @floatFromInt(self.total_size));
    }
    
    pub fn isComplete(self: *const DownloadTask) bool {
        return self.completed_at != null;
    }
};

/// Installation task for packages
pub const InstallTask = struct {
    package: *Package,
    source_path: []const u8,
    install_path: []const u8,
    build_required: bool,
    progress: std.atomic.Value(u32), // 0-100
    started_at: i64,
    completed_at: ?i64,
    worker_id: u32,
    error_message: ?[]const u8,
    
    pub fn getProgress(self: *const InstallTask) f64 {
        return @as(f64, @floatFromInt(self.progress.load(.acquire))) / 100.0;
    }
    
    pub fn isComplete(self: *const InstallTask) bool {
        return self.completed_at != null;
    }
};

/// Dependency resolution graph
pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    packages: std.hash_map.HashMap([]const u8, *Package, std.hash_map.StringContext, 80),
    dependencies: std.hash_map.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, 80),
    resolved_order: std.ArrayList([]const u8),
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return DependencyGraph{
            .allocator = allocator,
            .packages = std.hash_map.HashMap([]const u8, *Package, std.hash_map.StringContext, 80).init(allocator),
            .dependencies = std.hash_map.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, 80).init(allocator),
            .resolved_order = std.ArrayList([]const u8){ .allocator = allocator },
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *DependencyGraph) void {
        var pkg_iter = self.packages.iterator();
        while (pkg_iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.packages.deinit();
        
        var dep_iter = self.dependencies.iterator();
        while (dep_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.dependencies.deinit();
        
        self.resolved_order.deinit();
    }
    
    pub fn addPackage(self: *DependencyGraph, package: *Package) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.packages.put(package.name, package);
        
        var deps = std.ArrayList([]const u8){ .allocator = self.allocator };
        for (package.dependencies) |dep| {
            try deps.append(allocator, dep.name);
        }
        try self.dependencies.put(package.name, deps);
    }
    
    pub fn resolveOrder(self: *DependencyGraph) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.resolved_order.clearRetainingCapacity();
        
        var visited = std.hash_map.HashMap([]const u8, bool, std.hash_map.StringContext, 80).init(self.allocator);
        defer visited.deinit();
        
        var in_progress = std.hash_map.HashMap([]const u8, bool, std.hash_map.StringContext, 80).init(self.allocator);
        defer in_progress.deinit();
        
        var pkg_iter = self.packages.iterator();
        while (pkg_iter.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                try self.topologicalSort(entry.key_ptr.*, &visited, &in_progress);
            }
        }
    }
    
    fn topologicalSort(
        self: *DependencyGraph,
        package_name: []const u8,
        visited: *std.hash_map.HashMap([]const u8, bool, std.hash_map.StringContext, 80),
        in_progress: *std.hash_map.HashMap([]const u8, bool, std.hash_map.StringContext, 80),
    ) !void {
        try in_progress.put(package_name, true);
        
        if (self.dependencies.get(package_name)) |deps| {
            for (deps.items) |dep_name| {
                if (in_progress.contains(dep_name)) {
                    return error.CircularDependency;
                }
                
                if (!visited.contains(dep_name)) {
                    try self.topologicalSort(dep_name, visited, in_progress);
                }
            }
        }
        
        _ = in_progress.remove(package_name);
        try visited.put(package_name, true);
        try self.resolved_order.append(self.allocator, package_name);
    }
};

/// Async package manager
pub const AsyncPackageManager = struct {
    allocator: std.mem.Allocator,
    io: io_v2.Io,
    config: PackageConfig,
    
    // Package tracking
    dependency_graph: DependencyGraph,
    installed_packages: std.hash_map.HashMap([]const u8, *Package, std.hash_map.StringContext, 80),
    
    // Download management
    download_queue: std.ArrayList(DownloadTask),
    active_downloads: std.ArrayList(DownloadTask),
    download_workers: []std.Thread,
    download_semaphore: std.Thread.Semaphore,
    
    // Installation management
    install_queue: std.ArrayList(InstallTask),
    active_installs: std.ArrayList(InstallTask),
    install_workers: []std.Thread,
    install_semaphore: std.Thread.Semaphore,
    
    // Worker management
    worker_active: std.atomic.Value(bool),
    
    // Statistics and monitoring
    stats: PackageStats,
    stats_mutex: std.Thread.Mutex,
    
    // Global synchronization
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, config: PackageConfig) !Self {
        // Create directories if they don't exist
        std.fs.cwd().makeDir(config.cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        std.fs.cwd().makeDir(config.temp_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        return Self{
            .allocator = allocator,
            .io = io,
            .config = config,
            .dependency_graph = DependencyGraph.init(allocator),
            .installed_packages = std.hash_map.HashMap([]const u8, *Package, std.hash_map.StringContext, 80).init(allocator),
            .download_queue = std.ArrayList(DownloadTask){ .allocator = allocator },
            .active_downloads = std.ArrayList(DownloadTask){ .allocator = allocator },
            .download_workers = try allocator.alloc(std.Thread, config.max_parallel_downloads),
            .download_semaphore = std.Thread.Semaphore{ .permits = config.max_parallel_downloads },
            .install_queue = std.ArrayList(InstallTask){ .allocator = allocator },
            .active_installs = std.ArrayList(InstallTask){ .allocator = allocator },
            .install_workers = try allocator.alloc(std.Thread, config.max_parallel_installs),
            .install_semaphore = std.Thread.Semaphore{ .permits = config.max_parallel_installs },
            .worker_active = std.atomic.Value(bool).init(false),
            .stats = PackageStats{},
            .stats_mutex = .{},
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stopWorkers();
        
        self.dependency_graph.deinit();
        
        var pkg_iter = self.installed_packages.iterator();
        while (pkg_iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.installed_packages.deinit();
        
        self.download_queue.deinit();
        self.active_downloads.deinit();
        self.allocator.free(self.download_workers);
        
        self.install_queue.deinit();
        self.active_installs.deinit();
        self.allocator.free(self.install_workers);
    }
    
    /// Start package manager workers
    pub fn startWorkers(self: *Self) !void {
        if (self.worker_active.swap(true, .acquire)) return;
        
        // Start download workers
        for (self.download_workers, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, downloadWorker, .{ self, i });
        }
        
        // Start install workers
        for (self.install_workers, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, installWorker, .{ self, i });
        }
    }
    
    /// Stop package manager workers
    pub fn stopWorkers(self: *Self) void {
        if (!self.worker_active.swap(false, .release)) return;
        
        // Signal all workers to stop
        for (0..self.config.max_parallel_downloads) |_| {
            self.download_semaphore.post();
        }
        
        for (0..self.config.max_parallel_installs) |_| {
            self.install_semaphore.post();
        }
        
        // Wait for download workers
        for (self.download_workers) |thread| {
            thread.join();
        }
        
        // Wait for install workers
        for (self.install_workers) |thread| {
            thread.join();
        }
    }
    
    /// Install package with dependency resolution
    pub fn installPackageAsync(self: *Self, allocator: std.mem.Allocator, package_name: []const u8) !io_v2.Future {
        const ctx = try allocator.create(InstallPackageContext);
        ctx.* = .{
            .manager = self,
            .package_name = try allocator.dupe(u8, package_name),
            .allocator = allocator,
            .completed_packages = std.ArrayList([]const u8){ .allocator = allocator },
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = installPackagePoll,
                    .deinit_fn = installPackageDeinit,
                },
            },
        };
    }
    
    /// Download package files asynchronously
    pub fn downloadPackageAsync(self: *Self, allocator: std.mem.Allocator, package: *Package) !io_v2.Future {
        const ctx = try allocator.create(DownloadPackageContext);
        ctx.* = .{
            .manager = self,
            .package = package,
            .allocator = allocator,
            .download_complete = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = downloadPackagePoll,
                    .deinit_fn = downloadPackageDeinit,
                },
            },
        };
    }
    
    /// Search for packages asynchronously
    pub fn searchPackagesAsync(self: *Self, allocator: std.mem.Allocator, query: []const u8) !io_v2.Future {
        const ctx = try allocator.create(SearchPackagesContext);
        ctx.* = .{
            .manager = self,
            .query = try allocator.dupe(u8, query),
            .allocator = allocator,
            .results = std.ArrayList(*Package){ .allocator = allocator },
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = searchPackagesPoll,
                    .deinit_fn = searchPackagesDeinit,
                },
            },
        };
    }
    
    /// Update package database asynchronously
    pub fn updateDatabaseAsync(self: *Self, allocator: std.mem.Allocator) !io_v2.Future {
        const ctx = try allocator.create(UpdateDatabaseContext);
        ctx.* = .{
            .manager = self,
            .allocator = allocator,
            .update_complete = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = updateDatabasePoll,
                    .deinit_fn = updateDatabaseDeinit,
                },
            },
        };
    }
    
    /// Batch install multiple packages
    pub fn batchInstallAsync(self: *Self, allocator: std.mem.Allocator, package_names: []const []const u8) !io_v2.Future {
        const ctx = try allocator.create(BatchInstallContext);
        ctx.* = .{
            .manager = self,
            .package_names = try allocator.dupe([]const u8, package_names),
            .allocator = allocator,
            .completed_count = std.atomic.Value(u32).init(0),
            .failed_packages = std.ArrayList([]const u8){ .allocator = allocator },
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = batchInstallPoll,
                    .deinit_fn = batchInstallDeinit,
                },
            },
        };
    }
    
    fn downloadWorker(self: *Self, worker_id: usize) void {
        while (self.worker_active.load(.acquire)) {
            self.download_semaphore.wait();
            
            if (!self.worker_active.load(.acquire)) break;
            
            self.processDownloadQueue(@intCast(worker_id)) catch |err| {
                std.log.err("Download worker {} error: {}", .{ worker_id, err });
            };
        }
    }
    
    fn installWorker(self: *Self, worker_id: usize) void {
        while (self.worker_active.load(.acquire)) {
            self.install_semaphore.wait();
            
            if (!self.worker_active.load(.acquire)) break;
            
            self.processInstallQueue(@intCast(worker_id)) catch |err| {
                std.log.err("Install worker {} error: {}", .{ worker_id, err });
            };
        }
    }
    
    fn processDownloadQueue(self: *Self, worker_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.download_queue.items.len == 0) return;
        
        var task = self.download_queue.orderedRemove(0);
        task.worker_id = worker_id;
        task.started_at = std.time.timestamp();
        
        try self.active_downloads.append(self.allocator, task);
        
        // Simulate download process
        defer {
            self.mutex.lock();
            for (self.active_downloads.items, 0..) |*active_task, i| {
                if (active_task.worker_id == worker_id) {
                    active_task.completed_at = std.time.timestamp();
                    active_task.progress.store(task.total_size, .release);
                    _ = self.active_downloads.orderedRemove(i);
                    break;
                }
            }
            self.mutex.unlock();
        }
        
        // Simulate progressive download
        const chunk_size = task.total_size / 20; // 20 chunks
        for (0..20) |i| {
            if (!self.worker_active.load(.acquire)) return;
            
            const progress = (i + 1) * chunk_size;
            task.progress.store(progress, .release);
            
            // Simulate download time
            std.time.sleep(50_000_000); // 50ms
        }
        
        // Update statistics
        self.updateStats(.{ .packages_downloaded = 1, .bytes_downloaded = task.total_size });
    }
    
    fn processInstallQueue(self: *Self, worker_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.install_queue.items.len == 0) return;
        
        var task = self.install_queue.orderedRemove(0);
        task.worker_id = worker_id;
        task.started_at = std.time.timestamp();
        
        try self.active_installs.append(self.allocator, task);
        
        // Simulate installation process
        defer {
            self.mutex.lock();
            for (self.active_installs.items, 0..) |*active_task, i| {
                if (active_task.worker_id == worker_id) {
                    active_task.completed_at = std.time.timestamp();
                    active_task.progress.store(100, .release);
                    _ = self.active_installs.orderedRemove(i);
                    break;
                }
            }
            self.mutex.unlock();
        }
        
        // Simulate installation stages
        const stages = [_]u32{ 10, 25, 50, 75, 90, 100 };
        for (stages, 0..) |progress, i| {
            if (!self.worker_active.load(.acquire)) return;
            
            task.progress.store(progress, .release);
            
            // Simulate installation time (longer for build-required packages)
            const delay = if (task.build_required) 200_000_000 else 100_000_000; // 200ms or 100ms
            std.time.sleep(delay);
            
            // Simulate potential failure
            if (i == 3 and task.package.name.len % 10 == 0) { // Simulate 10% failure rate
                task.error_message = "Simulated installation failure";
                return;
            }
        }
        
        // Mark package as installed
        task.package.status = .installed;
        
        // Update statistics
        self.updateStats(.{ .packages_installed = 1 });
    }
    
    fn updateStats(self: *Self, delta: PackageStatsDelta) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        
        self.stats.packages_downloaded += delta.packages_downloaded;
        self.stats.packages_installed += delta.packages_installed;
        self.stats.packages_failed += delta.packages_failed;
        self.stats.bytes_downloaded += delta.bytes_downloaded;
        self.stats.total_operations += delta.total_operations;
    }
    
    pub fn getStats(self: *Self) PackageStats {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        return self.stats;
    }
    
    pub fn getActiveDownloads(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.active_downloads.items.len);
    }
    
    pub fn getActiveInstalls(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.active_installs.items.len);
    }
};

/// Package manager statistics
pub const PackageStats = struct {
    packages_downloaded: u64 = 0,
    packages_installed: u64 = 0,
    packages_failed: u64 = 0,
    bytes_downloaded: u64 = 0,
    total_operations: u64 = 0,
    
    pub fn getSuccessRate(self: PackageStats) f64 {
        const total = self.packages_installed + self.packages_failed;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.packages_installed)) / @as(f64, @floatFromInt(total));
    }
    
    pub fn getAverageDownloadSpeed(self: PackageStats, duration_seconds: f64) f64 {
        if (duration_seconds == 0.0) return 0.0;
        return @as(f64, @floatFromInt(self.bytes_downloaded)) / duration_seconds;
    }
};

/// Statistics delta for atomic updates
pub const PackageStatsDelta = struct {
    packages_downloaded: u64 = 0,
    packages_installed: u64 = 0,
    packages_failed: u64 = 0,
    bytes_downloaded: u64 = 0,
    total_operations: u64 = 0,
};

/// AUR (Arch User Repository) specific operations
pub const AURHelper = struct {
    package_manager: *AsyncPackageManager,
    aur_base_url: []const u8 = "https://aur.archlinux.org",
    build_dir: []const u8 = "/tmp/aur_build",
    
    pub fn init(package_manager: *AsyncPackageManager) AURHelper {
        return AURHelper{
            .package_manager = package_manager,
        };
    }
    
    /// Search AUR packages
    pub fn searchAURAsync(self: *AURHelper, allocator: std.mem.Allocator, query: []const u8) !io_v2.Future {
        const ctx = try allocator.create(AURSearchContext);
        ctx.* = .{
            .helper = self,
            .query = try allocator.dupe(u8, query),
            .allocator = allocator,
            .results = std.ArrayList(AURPackage){ .allocator = allocator },
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = aurSearchPoll,
                    .deinit_fn = aurSearchDeinit,
                },
            },
        };
    }
    
    /// Install AUR package with build process
    pub fn installAURPackageAsync(self: *AURHelper, allocator: std.mem.Allocator, package_name: []const u8) !io_v2.Future {
        const ctx = try allocator.create(AURInstallContext);
        ctx.* = .{
            .helper = self,
            .package_name = try allocator.dupe(u8, package_name),
            .allocator = allocator,
            .install_complete = false,
            .build_output = std.ArrayList(u8){ .allocator = allocator },
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = aurInstallPoll,
                    .deinit_fn = aurInstallDeinit,
                },
            },
        };
    }
};

/// AUR package structure
pub const AURPackage = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    maintainer: []const u8,
    votes: u32,
    popularity: f32,
    out_of_date: bool,
    
    pub fn deinit(self: *AURPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.maintainer);
    }
};

// Context structures for async operations
const InstallPackageContext = struct {
    manager: *AsyncPackageManager,
    package_name: []const u8,
    allocator: std.mem.Allocator,
    completed_packages: std.ArrayList([]const u8),
};

const DownloadPackageContext = struct {
    manager: *AsyncPackageManager,
    package: *Package,
    allocator: std.mem.Allocator,
    download_complete: bool,
};

const SearchPackagesContext = struct {
    manager: *AsyncPackageManager,
    query: []const u8,
    allocator: std.mem.Allocator,
    results: std.ArrayList(*Package),
};

const UpdateDatabaseContext = struct {
    manager: *AsyncPackageManager,
    allocator: std.mem.Allocator,
    update_complete: bool,
};

const BatchInstallContext = struct {
    manager: *AsyncPackageManager,
    package_names: []const []const u8,
    allocator: std.mem.Allocator,
    completed_count: std.atomic.Value(u32),
    failed_packages: std.ArrayList([]const u8),
};

const AURSearchContext = struct {
    helper: *AURHelper,
    query: []const u8,
    allocator: std.mem.Allocator,
    results: std.ArrayList(AURPackage),
};

const AURInstallContext = struct {
    helper: *AURHelper,
    package_name: []const u8,
    allocator: std.mem.Allocator,
    install_complete: bool,
    build_output: std.ArrayList(u8),
};

// Poll functions for async operations
fn installPackagePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*InstallPackageContext, @ptrCast(@alignCast(context)));
    
    // Simulate dependency resolution and installation
    const packages_to_install = [_][]const u8{ ctx.package_name, "dependency1", "dependency2" };
    
    for (packages_to_install) |pkg_name| {
        var found = false;
        for (ctx.completed_packages.items) |completed| {
            if (std.mem.eql(u8, completed, pkg_name)) {
                found = true;
                break;
            }
        }
        
        if (!found) {
            ctx.completed_packages.append(ctx.allocator.dupe(u8, pkg_name) catch return .{ .ready = error.OutOfMemory }) catch return .{ .ready = error.OutOfMemory };
            return .{ .pending = {} };
        }
    }
    
    return .{ .ready = ctx.completed_packages.items.len };
}

fn installPackageDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*InstallPackageContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.package_name);
    
    for (ctx.completed_packages.items) |pkg| {
        allocator.free(pkg);
    }
    ctx.completed_packages.deinit();
    
    allocator.destroy(ctx);
}

fn downloadPackagePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*DownloadPackageContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.download_complete) {
        // Simulate adding to download queue
        const task = DownloadTask{
            .package = ctx.package,
            .url = ctx.package.download_url,
            .destination = "/tmp/package_file",
            .progress = std.atomic.Value(u64).init(0),
            .total_size = ctx.package.size,
            .started_at = std.time.timestamp(),
            .completed_at = null,
            .worker_id = 0,
            .retry_count = 0,
        };
        
        ctx.manager.mutex.lock();
        ctx.manager.download_queue.append(ctx.allocator, task) catch {};
        ctx.manager.mutex.unlock();
        
        ctx.download_complete = true;
        return .{ .ready = true };
    }
    
    return .{ .pending = {} };
}

fn downloadPackageDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*DownloadPackageContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn searchPackagesPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*SearchPackagesContext, @ptrCast(@alignCast(context)));
    
    // Simulate search results
    const mock_results = [_][]const u8{ "package1", "package2", "package3" };
    
    for (mock_results) |pkg_name| {
        if (std.mem.indexOf(u8, pkg_name, ctx.query) != null) {
            const package = ctx.allocator.create(Package) catch return .{ .ready = error.OutOfMemory };
            package.* = Package{
                .name = ctx.allocator.dupe(u8, pkg_name) catch return .{ .ready = error.OutOfMemory },
                .version = ctx.allocator.dupe(u8, "1.0.0") catch return .{ .ready = error.OutOfMemory },
                .description = ctx.allocator.dupe(u8, "Mock package description") catch return .{ .ready = error.OutOfMemory },
                .maintainer = ctx.allocator.dupe(u8, "Mock Maintainer") catch return .{ .ready = error.OutOfMemory },
                .url = ctx.allocator.dupe(u8, "https://example.com") catch return .{ .ready = error.OutOfMemory },
                .download_url = ctx.allocator.dupe(u8, "https://example.com/package.tar.gz") catch return .{ .ready = error.OutOfMemory },
                .dependencies = &[_]Dependency{},
                .conflicts = &[_][]const u8{},
                .provides = &[_][]const u8{},
                .size = 1024 * 1024, // 1MB
                .checksum = [_]u8{0} ** 32,
                .build_script = null,
                .install_script = null,
                .status = .not_installed,
            };
            
            ctx.results.append(ctx.allocator, package) catch return .{ .ready = error.OutOfMemory };
        }
    }
    
    return .{ .ready = ctx.results.items.len };
}

fn searchPackagesDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*SearchPackagesContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.query);
    
    for (ctx.results.items) |package| {
        package.deinit(allocator);
        allocator.destroy(package);
    }
    ctx.results.deinit();
    
    allocator.destroy(ctx);
}

fn updateDatabasePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*UpdateDatabaseContext, @ptrCast(@alignCast(context)));
    
    // Simulate database update
    if (!ctx.update_complete) {
        ctx.update_complete = true;
        return .{ .ready = true };
    }
    
    return .{ .pending = {} };
}

fn updateDatabaseDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*UpdateDatabaseContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn batchInstallPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*BatchInstallContext, @ptrCast(@alignCast(context)));
    
    const current_count = ctx.completed_count.load(.acquire);
    if (current_count < ctx.package_names.len) {
        // Simulate installing next package
        _ = ctx.completed_count.fetchAdd(1, .acq_rel);
        return .{ .pending = {} };
    }
    
    return .{ .ready = current_count };
}

fn batchInstallDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*BatchInstallContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.package_names);
    
    for (ctx.failed_packages.items) |pkg| {
        allocator.free(pkg);
    }
    ctx.failed_packages.deinit();
    
    allocator.destroy(ctx);
}

fn aurSearchPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*AURSearchContext, @ptrCast(@alignCast(context)));
    
    // Simulate AUR search results
    const mock_aur_packages = [_]AURPackage{
        .{
            .name = ctx.allocator.dupe(u8, "aur-package-1") catch return .{ .ready = error.OutOfMemory },
            .version = ctx.allocator.dupe(u8, "2.1.0") catch return .{ .ready = error.OutOfMemory },
            .description = ctx.allocator.dupe(u8, "AUR package from community") catch return .{ .ready = error.OutOfMemory },
            .maintainer = ctx.allocator.dupe(u8, "community-maintainer") catch return .{ .ready = error.OutOfMemory },
            .votes = 42,
            .popularity = 0.85,
            .out_of_date = false,
        },
        .{
            .name = ctx.allocator.dupe(u8, "aur-package-2") catch return .{ .ready = error.OutOfMemory },
            .version = ctx.allocator.dupe(u8, "1.5.3") catch return .{ .ready = error.OutOfMemory },
            .description = ctx.allocator.dupe(u8, "Another AUR package") catch return .{ .ready = error.OutOfMemory },
            .maintainer = ctx.allocator.dupe(u8, "other-maintainer") catch return .{ .ready = error.OutOfMemory },
            .votes = 15,
            .popularity = 0.32,
            .out_of_date = true,
        },
    };
    
    for (mock_aur_packages) |package| {
        if (std.mem.indexOf(u8, package.name, ctx.query) != null) {
            ctx.results.append(ctx.allocator, package) catch return .{ .ready = error.OutOfMemory };
        }
    }
    
    return .{ .ready = ctx.results.items.len };
}

fn aurSearchDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*AURSearchContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.query);
    
    for (ctx.results.items) |*package| {
        package.deinit(allocator);
    }
    ctx.results.deinit();
    
    allocator.destroy(ctx);
}

fn aurInstallPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*AURInstallContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.install_complete) {
        // Simulate AUR package build and install
        const build_log = "Building AUR package...\nCompiling source...\nInstalling files...\nDone!";
        ctx.build_output.appendSlice(build_log) catch return .{ .ready = error.OutOfMemory };
        ctx.install_complete = true;
        return .{ .ready = true };
    }
    
    return .{ .pending = {} };
}

fn aurInstallDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*AURInstallContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.package_name);
    ctx.build_output.deinit();
    allocator.destroy(ctx);
}

test "package manager initialization" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = PackageConfig{
        .max_parallel_downloads = 4,
        .max_parallel_installs = 2,
    };
    
    var manager = try AsyncPackageManager.init(allocator, io, config);
    defer manager.deinit();
    
    try std.testing.expect(manager.config.max_parallel_downloads == 4);
    try std.testing.expect(manager.config.max_parallel_installs == 2);
}

test "dependency graph resolution" {
    const allocator = std.testing.allocator;
    
    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();
    
    const pkg1 = try allocator.create(Package);
    pkg1.* = Package{
        .name = try allocator.dupe(u8, "package1"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .description = try allocator.dupe(u8, "Test package 1"),
        .maintainer = try allocator.dupe(u8, "maintainer"),
        .url = try allocator.dupe(u8, "https://example.com"),
        .download_url = try allocator.dupe(u8, "https://example.com/pkg1.tar.gz"),
        .dependencies = &[_]Dependency{},
        .conflicts = &[_][]const u8{},
        .provides = &[_][]const u8{},
        .size = 1024,
        .checksum = [_]u8{0} ** 32,
        .build_script = null,
        .install_script = null,
        .status = .not_installed,
    };
    
    try graph.addPackage(pkg1);
    try graph.resolveOrder();
    
    try std.testing.expect(graph.resolved_order.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, graph.resolved_order.items[0], "package1"));
}

test "aur helper search" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = PackageConfig{};
    var manager = try AsyncPackageManager.init(allocator, io, config);
    defer manager.deinit();
    
    var aur_helper = AURHelper.init(&manager);
    
    var search_future = try aur_helper.searchAURAsync(allocator, "test");
    defer search_future.deinit();
    
    const result = try search_future.await_op(io, .{});
    try std.testing.expect(@as(u32, @intCast(result)) >= 0);
}