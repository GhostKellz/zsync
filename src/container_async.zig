//! Container runtime async operations for zsync v0.5.0
//! Provides async cgroups/namespace operations and container lifecycle management

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const error_management = @import("error_management.zig");

/// Container resource limits
pub const ResourceLimits = struct {
    memory_limit: ?u64 = null,      // bytes
    cpu_limit: ?u64 = null,         // CPU shares
    cpu_period: ?u64 = null,        // microseconds
    cpu_quota: ?u64 = null,         // microseconds
    pids_limit: ?u32 = null,        // max processes
    swap_limit: ?u64 = null,        // bytes
    blkio_weight: ?u16 = null,      // 10-1000
    
    pub fn init() ResourceLimits {
        return ResourceLimits{};
    }
    
    pub fn withMemoryLimit(self: ResourceLimits, limit: u64) ResourceLimits {
        var new_limits = self;
        new_limits.memory_limit = limit;
        return new_limits;
    }
    
    pub fn withCpuLimit(self: ResourceLimits, shares: u64) ResourceLimits {
        var new_limits = self;
        new_limits.cpu_limit = shares;
        return new_limits;
    }
    
    pub fn withPidsLimit(self: ResourceLimits, limit: u32) ResourceLimits {
        var new_limits = self;
        new_limits.pids_limit = limit;
        return new_limits;
    }
};

/// Container namespace configuration
pub const NamespaceConfig = struct {
    pid_namespace: bool = true,
    net_namespace: bool = true,
    mount_namespace: bool = true,
    uts_namespace: bool = true,
    ipc_namespace: bool = true,
    user_namespace: bool = false,
    cgroup_namespace: bool = true,
    
    pub fn init() NamespaceConfig {
        return NamespaceConfig{};
    }
    
    pub fn withUserNamespace(self: NamespaceConfig, enabled: bool) NamespaceConfig {
        var new_config = self;
        new_config.user_namespace = enabled;
        return new_config;
    }
};

/// Container status
pub const ContainerStatus = enum {
    created,
    running,
    paused,
    stopped,
    error,
    
    pub fn toString(self: ContainerStatus) []const u8 {
        return switch (self) {
            .created => "created",
            .running => "running",
            .paused => "paused",
            .stopped => "stopped",
            .error => "error",
        };
    }
};

/// Container information
pub const ContainerInfo = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    command: []const []const u8,
    status: ContainerStatus,
    pid: ?std.os.pid_t,
    created_at: u64,
    started_at: ?u64,
    finished_at: ?u64,
    exit_code: ?i32,
    resource_limits: ResourceLimits,
    namespace_config: NamespaceConfig,
    
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        name: []const u8,
        image: []const u8,
        command: []const []const u8,
    ) !ContainerInfo {
        return ContainerInfo{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .image = try allocator.dupe(u8, image),
            .command = try allocator.dupe([]const u8, command),
            .status = .created,
            .pid = null,
            .created_at = std.time.milliTimestamp(),
            .started_at = null,
            .finished_at = null,
            .exit_code = null,
            .resource_limits = ResourceLimits.init(),
            .namespace_config = NamespaceConfig.init(),
        };
    }
    
    pub fn deinit(self: *ContainerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.image);
        allocator.free(self.command);
    }
};

/// CGroups controller
pub const CGroupsController = struct {
    cgroup_path: []const u8,
    controllers: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, cgroup_path: []const u8) !Self {
        return Self{
            .cgroup_path = try allocator.dupe(u8, cgroup_path),
            .controllers = std.ArrayList([]const u8){ .allocator = allocator },
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.controllers.items) |controller| {
            self.allocator.free(controller);
        }
        self.controllers.deinit();
        self.allocator.free(self.cgroup_path);
    }
    
    pub fn addController(self: *Self, controller: []const u8) !void {
        const controller_copy = try self.allocator.dupe(u8, controller);
        try self.controllers.append(self.allocator, controller_copy);
    }
    
    pub fn setMemoryLimit(self: *Self, limit: u64) !void {
        const limit_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/memory.limit_in_bytes",
            .{self.cgroup_path},
        );
        defer self.allocator.free(limit_path);
        
        const limit_str = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_str);
        
        try self.writeCGroupFile(limit_path, limit_str);
    }
    
    pub fn setCpuShares(self: *Self, shares: u64) !void {
        const shares_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cpu.shares",
            .{self.cgroup_path},
        );
        defer self.allocator.free(shares_path);
        
        const shares_str = try std.fmt.allocPrint(self.allocator, "{d}", .{shares});
        defer self.allocator.free(shares_str);
        
        try self.writeCGroupFile(shares_path, shares_str);
    }
    
    pub fn setCpuQuota(self: *Self, period: u64, quota: u64) !void {
        // Set CPU period
        const period_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cpu.cfs_period_us",
            .{self.cgroup_path},
        );
        defer self.allocator.free(period_path);
        
        const period_str = try std.fmt.allocPrint(self.allocator, "{d}", .{period});
        defer self.allocator.free(period_str);
        
        try self.writeCGroupFile(period_path, period_str);
        
        // Set CPU quota
        const quota_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cpu.cfs_quota_us",
            .{self.cgroup_path},
        );
        defer self.allocator.free(quota_path);
        
        const quota_str = try std.fmt.allocPrint(self.allocator, "{d}", .{quota});
        defer self.allocator.free(quota_str);
        
        try self.writeCGroupFile(quota_path, quota_str);
    }
    
    pub fn setPidsLimit(self: *Self, limit: u32) !void {
        const limit_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/pids.max",
            .{self.cgroup_path},
        );
        defer self.allocator.free(limit_path);
        
        const limit_str = try std.fmt.allocPrint(self.allocator, "{d}", .{limit});
        defer self.allocator.free(limit_str);
        
        try self.writeCGroupFile(limit_path, limit_str);
    }
    
    pub fn addProcess(self: *Self, pid: std.os.pid_t) !void {
        const cgroup_procs_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cgroup.procs",
            .{self.cgroup_path},
        );
        defer self.allocator.free(cgroup_procs_path);
        
        const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
        defer self.allocator.free(pid_str);
        
        try self.writeCGroupFile(cgroup_procs_path, pid_str);
    }
    
    pub fn getMemoryUsage(self: *Self) !u64 {
        const usage_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/memory.usage_in_bytes",
            .{self.cgroup_path},
        );
        defer self.allocator.free(usage_path);
        
        const usage_str = try self.readCGroupFile(usage_path);
        defer self.allocator.free(usage_str);
        
        return std.fmt.parseInt(u64, std.mem.trim(u8, usage_str, " \n\r\t"), 10) catch 0;
    }
    
    pub fn getCpuUsage(self: *Self) !u64 {
        const usage_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cpuacct.usage",
            .{self.cgroup_path},
        );
        defer self.allocator.free(usage_path);
        
        const usage_str = try self.readCGroupFile(usage_path);
        defer self.allocator.free(usage_str);
        
        return std.fmt.parseInt(u64, std.mem.trim(u8, usage_str, " \n\r\t"), 10) catch 0;
    }
    
    fn writeCGroupFile(self: *Self, path: []const u8, content: []const u8) !void {
        // Simplified file writing
        // In real implementation, would actually write to cgroup filesystem
        std.log.info("Writing to cgroup file {s}: {s}", .{ path, content });
        _ = self;
    }
    
    fn readCGroupFile(self: *Self, path: []const u8) ![]const u8 {
        // Simplified file reading
        // In real implementation, would actually read from cgroup filesystem
        std.log.info("Reading from cgroup file {s}", .{path});
        _ = self;
        return try self.allocator.dupe(u8, "1024");
    }
};

/// Namespace manager
pub const NamespaceManager = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    pub fn createNamespaces(self: *Self, config: NamespaceConfig) !void {
        var flags: u32 = 0;
        
        if (config.pid_namespace) {
            flags |= std.os.linux.CLONE.NEWPID;
            std.log.info("Creating PID namespace");
        }
        
        if (config.net_namespace) {
            flags |= std.os.linux.CLONE.NEWNET;
            std.log.info("Creating network namespace");
        }
        
        if (config.mount_namespace) {
            flags |= std.os.linux.CLONE.NEWNS;
            std.log.info("Creating mount namespace");
        }
        
        if (config.uts_namespace) {
            flags |= std.os.linux.CLONE.NEWUTS;
            std.log.info("Creating UTS namespace");
        }
        
        if (config.ipc_namespace) {
            flags |= std.os.linux.CLONE.NEWIPC;
            std.log.info("Creating IPC namespace");
        }
        
        if (config.user_namespace) {
            flags |= std.os.linux.CLONE.NEWUSER;
            std.log.info("Creating user namespace");
        }
        
        if (config.cgroup_namespace) {
            flags |= std.os.linux.CLONE.NEWCGROUP;
            std.log.info("Creating cgroup namespace");
        }
        
        // In real implementation, would call unshare() or clone() with these flags
        std.log.info("Created namespaces with flags: 0x{x}", .{flags});
        _ = self;
    }
    
    pub fn enterNamespace(self: *Self, namespace_type: []const u8, namespace_path: []const u8) !void {
        std.log.info("Entering {s} namespace at {s}", .{ namespace_type, namespace_path });
        // In real implementation, would call setns()
        _ = self;
    }
    
    pub fn setupNetworkNamespace(self: *Self, container_id: []const u8) !void {
        std.log.info("Setting up network namespace for container {s}", .{container_id});
        // In real implementation, would:
        // 1. Create veth pair
        // 2. Move one end to container namespace
        // 3. Configure IP addresses
        // 4. Set up routing
        _ = self;
    }
    
    pub fn setupMountNamespace(self: *Self, container_id: []const u8, rootfs: []const u8) !void {
        std.log.info("Setting up mount namespace for container {s} with rootfs {s}", .{ container_id, rootfs });
        // In real implementation, would:
        // 1. Create private mount namespace
        // 2. Mount rootfs
        // 3. Set up /proc, /sys, /dev
        // 4. Pivot root or chroot
        _ = self;
    }
};

/// Async container runtime
pub const AsyncContainerRuntime = struct {
    containers: std.HashMap([]const u8, ContainerInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    cgroup_controllers: std.HashMap([]const u8, CGroupsController, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    namespace_manager: NamespaceManager,
    worker_pool: std.ArrayList(*ContainerWorker),
    operation_queue: std.atomic.Queue(ContainerOperation),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    is_running: std.atomic.Value(bool),
    
    const Self = @This();
    
    const ContainerOperation = struct {
        operation_type: OperationType,
        container_id: []const u8,
        callback: ?*const fn([]const u8, OperationResult) void,
        submitted_at: u64,
        timeout_ms: u64,
        
        pub const OperationType = enum {
            create,
            start,
            stop,
            pause,
            unpause,
            remove,
            inspect,
        };
    };
    
    const OperationResult = struct {
        success: bool,
        message: []const u8,
        error_code: ?error_management.AsyncError,
        
        pub fn init(success: bool, message: []const u8) OperationResult {
            return OperationResult{
                .success = success,
                .message = message,
                .error_code = null,
            };
        }
    };
    
    const ContainerWorker = struct {
        thread: std.Thread,
        runtime: *AsyncContainerRuntime,
        worker_id: u32,
        
        fn run(self: *ContainerWorker) void {
            while (self.runtime.is_running.load(.acquire)) {
                if (self.runtime.operation_queue.get()) |operation| {
                    const result = self.processOperation(operation);
                    
                    if (operation.callback) |callback| {
                        callback(operation.container_id, result);
                    }
                } else {
                    std.time.sleep(1_000_000); // 1ms
                }
            }
        }
        
        fn processOperation(self: *ContainerWorker, operation: ContainerOperation) OperationResult {
            const start_time = std.time.milliTimestamp();
            
            // Check timeout
            if (start_time - operation.submitted_at > operation.timeout_ms) {
                return OperationResult.init(false, "Operation timeout");
            }
            
            switch (operation.operation_type) {
                .create => return self.createContainer(operation.container_id),
                .start => return self.startContainer(operation.container_id),
                .stop => return self.stopContainer(operation.container_id),
                .pause => return self.pauseContainer(operation.container_id),
                .unpause => return self.unpauseContainer(operation.container_id),
                .remove => return self.removeContainer(operation.container_id),
                .inspect => return self.inspectContainer(operation.container_id),
            }
        }
        
        fn createContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} creating container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.contains(container_id)) {
                return OperationResult.init(false, "Container already exists");
            }
            
            // Create container info (simplified)
            const container_info = ContainerInfo.init(
                self.runtime.allocator,
                container_id,
                container_id,
                "ubuntu:latest",
                &[_][]const u8{"/bin/bash"},
            ) catch {
                return OperationResult.init(false, "Failed to create container info");
            };
            
            self.runtime.containers.put(container_id, container_info) catch {
                return OperationResult.init(false, "Failed to store container info");
            };
            
            return OperationResult.init(true, "Container created successfully");
        }
        
        fn startContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} starting container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.getPtr(container_id)) |container| {
                if (container.status != .created) {
                    return OperationResult.init(false, "Container not in created state");
                }
                
                // Setup cgroups
                self.setupCGroups(container_id, container.resource_limits) catch {
                    return OperationResult.init(false, "Failed to setup cgroups");
                };
                
                // Create namespaces
                self.runtime.namespace_manager.createNamespaces(container.namespace_config) catch {
                    return OperationResult.init(false, "Failed to create namespaces");
                };
                
                // Start the container process (simplified)
                const pid = std.os.linux.getpid();
                container.pid = pid;
                container.status = .running;
                container.started_at = std.time.milliTimestamp();
                
                return OperationResult.init(true, "Container started successfully");
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn stopContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} stopping container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.getPtr(container_id)) |container| {
                if (container.status != .running) {
                    return OperationResult.init(false, "Container not running");
                }
                
                // Stop the container process (simplified)
                if (container.pid) |pid| {
                    std.log.info("Sending SIGTERM to process {d}", .{pid});
                    // In real implementation, would send SIGTERM then SIGKILL
                }
                
                container.status = .stopped;
                container.finished_at = std.time.milliTimestamp();
                container.exit_code = 0;
                
                return OperationResult.init(true, "Container stopped successfully");
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn pauseContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} pausing container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.getPtr(container_id)) |container| {
                if (container.status != .running) {
                    return OperationResult.init(false, "Container not running");
                }
                
                // Pause using cgroup freezer (simplified)
                if (self.runtime.cgroup_controllers.getPtr(container_id)) |cgroup| {
                    cgroup.writeCGroupFile("/sys/fs/cgroup/freezer/FROZEN", "1") catch {
                        return OperationResult.init(false, "Failed to freeze container");
                    };
                }
                
                container.status = .paused;
                
                return OperationResult.init(true, "Container paused successfully");
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn unpauseContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} unpausing container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.getPtr(container_id)) |container| {
                if (container.status != .paused) {
                    return OperationResult.init(false, "Container not paused");
                }
                
                // Unpause using cgroup freezer (simplified)
                if (self.runtime.cgroup_controllers.getPtr(container_id)) |cgroup| {
                    cgroup.writeCGroupFile("/sys/fs/cgroup/freezer/THAWED", "1") catch {
                        return OperationResult.init(false, "Failed to thaw container");
                    };
                }
                
                container.status = .running;
                
                return OperationResult.init(true, "Container unpaused successfully");
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn removeContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} removing container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.fetchRemove(container_id)) |entry| {
                entry.value.deinit(self.runtime.allocator);
                
                // Clean up cgroups
                if (self.runtime.cgroup_controllers.fetchRemove(container_id)) |cgroup_entry| {
                    cgroup_entry.value.deinit();
                }
                
                return OperationResult.init(true, "Container removed successfully");
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn inspectContainer(self: *ContainerWorker, container_id: []const u8) OperationResult {
            std.log.info("Worker {d} inspecting container {s}", .{ self.worker_id, container_id });
            
            self.runtime.mutex.lock();
            defer self.runtime.mutex.unlock();
            
            if (self.runtime.containers.get(container_id)) |container| {
                const status_message = try std.fmt.allocPrint(
                    self.runtime.allocator,
                    "Container {s}: status={s}, pid={?d}, created={d}",
                    .{ container.id, container.status.toString(), container.pid, container.created_at },
                );
                
                return OperationResult.init(true, status_message);
            }
            
            return OperationResult.init(false, "Container not found");
        }
        
        fn setupCGroups(self: *ContainerWorker, container_id: []const u8, limits: ResourceLimits) !void {
            const cgroup_path = try std.fmt.allocPrint(
                self.runtime.allocator,
                "/sys/fs/cgroup/zsync/{s}",
                .{container_id},
            );
            defer self.runtime.allocator.free(cgroup_path);
            
            var cgroup = try CGroupsController.init(self.runtime.allocator, cgroup_path);
            
            // Set up resource limits
            if (limits.memory_limit) |memory_limit| {
                try cgroup.setMemoryLimit(memory_limit);
            }
            
            if (limits.cpu_limit) |cpu_shares| {
                try cgroup.setCpuShares(cpu_shares);
            }
            
            if (limits.cpu_period) |period| {
                if (limits.cpu_quota) |quota| {
                    try cgroup.setCpuQuota(period, quota);
                }
            }
            
            if (limits.pids_limit) |pids_limit| {
                try cgroup.setPidsLimit(pids_limit);
            }
            
            try self.runtime.cgroup_controllers.put(container_id, cgroup);
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, worker_count: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .containers = std.HashMap([]const u8, ContainerInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .cgroup_controllers = std.HashMap([]const u8, CGroupsController, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .namespace_manager = NamespaceManager.init(allocator),
            .worker_pool = std.ArrayList(*ContainerWorker){ .allocator = allocator },
            .operation_queue = std.atomic.Queue(ContainerOperation).init(),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .is_running = std.atomic.Value(bool).init(false),
        };
        
        // Create worker threads
        for (0..worker_count) |i| {
            const worker = try allocator.create(ContainerWorker);
            worker.* = ContainerWorker{
                .thread = undefined,
                .runtime = self,
                .worker_id = @intCast(i),
            };
            
            try self.worker_pool.append(self.allocator, worker);
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        
        // Clean up workers
        for (self.worker_pool.items) |worker| {
            self.allocator.destroy(worker);
        }
        self.worker_pool.deinit();
        
        // Clean up containers
        var container_iterator = self.containers.iterator();
        while (container_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.containers.deinit();
        
        // Clean up cgroups
        var cgroup_iterator = self.cgroup_controllers.iterator();
        while (cgroup_iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.cgroup_controllers.deinit();
        
        self.allocator.destroy(self);
    }
    
    pub fn start(self: *Self) !void {
        self.is_running.store(true, .release);
        
        // Start worker threads
        for (self.worker_pool.items) |worker| {
            worker.thread = try std.Thread.spawn(.{}, ContainerWorker.run, .{worker});
        }
        
        std.log.info("Container runtime started with {d} workers", .{self.worker_pool.items.len});
    }
    
    pub fn stop(self: *Self) void {
        self.is_running.store(false, .release);
        
        // Join worker threads
        for (self.worker_pool.items) |worker| {
            worker.thread.join();
        }
        
        std.log.info("Container runtime stopped");
    }
    
    pub fn submitOperation(
        self: *Self,
        operation_type: ContainerOperation.OperationType,
        container_id: []const u8,
        callback: ?*const fn([]const u8, OperationResult) void,
        timeout_ms: u64,
    ) !void {
        const operation = ContainerOperation{
            .operation_type = operation_type,
            .container_id = container_id,
            .callback = callback,
            .submitted_at = std.time.milliTimestamp(),
            .timeout_ms = timeout_ms,
        };
        
        self.operation_queue.put(operation);
    }
    
    pub fn getContainerInfo(self: *Self, container_id: []const u8) ?ContainerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.containers.get(container_id);
    }
    
    pub fn listContainers(self: *Self) ![]ContainerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var containers = std.ArrayList(ContainerInfo){ .allocator = self.allocator };
        
        var iterator = self.containers.iterator();
        while (iterator.next()) |entry| {
            try containers.append(allocator, entry.value_ptr.*);
        }
        
        return containers.toOwnedSlice();
    }
    
    pub fn getRuntimeStats(self: *Self) RuntimeStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var running_containers: u32 = 0;
        var stopped_containers: u32 = 0;
        var paused_containers: u32 = 0;
        
        var container_iterator = self.containers.iterator();
        while (container_iterator.next()) |entry| {
            switch (entry.value_ptr.status) {
                .running => running_containers += 1,
                .stopped => stopped_containers += 1,
                .paused => paused_containers += 1,
                else => {},
            }
        }
        
        return RuntimeStats{
            .total_containers = self.containers.count(),
            .running_containers = running_containers,
            .stopped_containers = stopped_containers,
            .paused_containers = paused_containers,
            .worker_count = self.worker_pool.items.len,
        };
    }
    
    pub const RuntimeStats = struct {
        total_containers: u32,
        running_containers: u32,
        stopped_containers: u32,
        paused_containers: u32,
        worker_count: usize,
    };
};

test "container resource limits" {
    const testing = std.testing;
    
    const limits = ResourceLimits.init()
        .withMemoryLimit(1024 * 1024 * 1024) // 1GB
        .withCpuLimit(1024)
        .withPidsLimit(100);
    
    try testing.expect(limits.memory_limit.? == 1024 * 1024 * 1024);
    try testing.expect(limits.cpu_limit.? == 1024);
    try testing.expect(limits.pids_limit.? == 100);
}

test "namespace configuration" {
    const testing = std.testing;
    
    const config = NamespaceConfig.init()
        .withUserNamespace(true);
    
    try testing.expect(config.user_namespace == true);
    try testing.expect(config.pid_namespace == true);
    try testing.expect(config.net_namespace == true);
}

test "container runtime" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var runtime = try AsyncContainerRuntime.init(allocator, 2);
    defer runtime.deinit();
    
    try runtime.start();
    defer runtime.stop();
    
    // Test runtime stats
    const stats = runtime.getRuntimeStats();
    try testing.expect(stats.total_containers == 0);
    try testing.expect(stats.worker_count == 2);
    
    // Test container operations
    const callback = struct {
        fn callback(container_id: []const u8, result: AsyncContainerRuntime.OperationResult) void {
            _ = container_id;
            _ = result;
        }
    }.callback;
    
    try runtime.submitOperation(.create, "test-container", callback, 5000);
    
    // Allow some processing time
    std.time.sleep(100_000_000); // 100ms
}