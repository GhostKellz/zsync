const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const testing = std.testing;
const io = @import("io_v2.zig");
const syscall_async = @import("syscall_async.zig");
const linux = std.os.linux;
const builtin = @import("builtin");

pub const EventError = error{
    InvalidEventType,
    EventQueueFull,
    WatchLimitExceeded,
    InvalidPath,
    PermissionDenied,
    ResourceExhausted,
    SystemError,
    InvalidDescriptor,
    TimeoutError,
    OutOfMemory,
};

// File system events (inotify)
pub const FileEvent = enum(u32) {
    accessed = 0x00000001,
    modified = 0x00000002,
    metadata_changed = 0x00000004,
    closed_write = 0x00000008,
    closed_nowrite = 0x00000010,
    opened = 0x00000020,
    moved_from = 0x00000040,
    moved_to = 0x00000080,
    created = 0x00000100,
    deleted = 0x00000200,
    deleted_self = 0x00000400,
    moved_self = 0x00000800,
    unmount = 0x00002000,
    queue_overflow = 0x00004000,
    ignored = 0x00008000,
    
    pub fn toLinux(self: FileEvent) u32 {
        return switch (self) {
            .accessed => linux.IN.ACCESS,
            .modified => linux.IN.MODIFY,
            .metadata_changed => linux.IN.ATTRIB,
            .closed_write => linux.IN.CLOSE_WRITE,
            .closed_nowrite => linux.IN.CLOSE_NOWRITE,
            .opened => linux.IN.OPEN,
            .moved_from => linux.IN.MOVED_FROM,
            .moved_to => linux.IN.MOVED_TO,
            .created => linux.IN.CREATE,
            .deleted => linux.IN.DELETE,
            .deleted_self => linux.IN.DELETE_SELF,
            .moved_self => linux.IN.MOVE_SELF,
            .unmount => linux.IN.UNMOUNT,
            .queue_overflow => linux.IN.Q_OVERFLOW,
            .ignored => linux.IN.IGNORED,
        };
    }
};

pub const FileEventData = struct {
    watch_descriptor: i32,
    event_mask: u32,
    cookie: u32,
    name: ?[]const u8,
    timestamp: i64,
    
    pub fn deinit(self: *FileEventData, allocator: Allocator) void {
        if (self.name) |name| {
            allocator.free(name);
        }
    }
    
    pub fn hasEvent(self: *const FileEventData, event: FileEvent) bool {
        return (self.event_mask & event.toLinux()) != 0;
    }
};

// Signal events
pub const SignalType = enum(i32) {
    hangup = 1,
    interrupt = 2,
    quit = 3,
    illegal_instruction = 4,
    trap = 5,
    abort = 6,
    bus_error = 7,
    floating_point_exception = 8,
    kill = 9,
    user1 = 10,
    segmentation_violation = 11,
    user2 = 12,
    pipe = 13,
    alarm = 14,
    terminate = 15,
    child = 17,
    continue_signal = 18,
    stop = 19,
    terminal_stop = 20,
    terminal_input = 21,
    terminal_output = 22,
    urgent = 23,
    cpu_limit = 24,
    file_size_limit = 25,
    virtual_alarm = 26,
    profiling_alarm = 27,
    window_size_change = 28,
    io_ready = 29,
    power_failure = 30,
    bad_system_call = 31,
    
    pub fn toLinux(self: SignalType) i32 {
        return switch (self) {
            .hangup => linux.SIG.HUP,
            .interrupt => linux.SIG.INT,
            .quit => linux.SIG.QUIT,
            .illegal_instruction => linux.SIG.ILL,
            .trap => linux.SIG.TRAP,
            .abort => linux.SIG.ABRT,
            .bus_error => linux.SIG.BUS,
            .floating_point_exception => linux.SIG.FPE,
            .kill => linux.SIG.KILL,
            .user1 => linux.SIG.USR1,
            .segmentation_violation => linux.SIG.SEGV,
            .user2 => linux.SIG.USR2,
            .pipe => linux.SIG.PIPE,
            .alarm => linux.SIG.ALRM,
            .terminate => linux.SIG.TERM,
            .child => linux.SIG.CHLD,
            .continue_signal => linux.SIG.CONT,
            .stop => linux.SIG.STOP,
            .terminal_stop => linux.SIG.TSTP,
            .terminal_input => linux.SIG.TTIN,
            .terminal_output => linux.SIG.TTOU,
            .urgent => linux.SIG.URG,
            .cpu_limit => linux.SIG.XCPU,
            .file_size_limit => linux.SIG.XFSZ,
            .virtual_alarm => linux.SIG.VTALRM,
            .profiling_alarm => linux.SIG.PROF,
            .window_size_change => linux.SIG.WINCH,
            .io_ready => linux.SIG.IO,
            .power_failure => linux.SIG.PWR,
            .bad_system_call => linux.SIG.SYS,
        };
    }
};

pub const SignalEventData = struct {
    signal_number: i32,
    sender_pid: i32,
    sender_uid: u32,
    timestamp: i64,
    additional_data: ?*anyopaque,
    
    pub fn getSignalType(self: *const SignalEventData) SignalType {
        return @enumFromInt(self.signal_number);
    }
};

// Epoll events
pub const EpollEventType = enum(u32) {
    readable = 0x001,
    writable = 0x004,
    error_condition = 0x008,
    hang_up = 0x010,
    edge_triggered = 0x80000000,
    one_shot = 0x40000000,
    wake_up = 0x20000000,
    exclusive = 0x10000000,
    
    pub fn toLinux(self: EpollEventType) u32 {
        return switch (self) {
            .readable => linux.EPOLL.IN,
            .writable => linux.EPOLL.OUT,
            .error_condition => linux.EPOLL.ERR,
            .hang_up => linux.EPOLL.HUP,
            .edge_triggered => linux.EPOLL.ET,
            .one_shot => linux.EPOLL.ONESHOT,
            .wake_up => linux.EPOLL.WAKEUP,
            .exclusive => linux.EPOLL.EXCLUSIVE,
        };
    }
};

pub const EpollEventData = struct {
    file_descriptor: i32,
    event_mask: u32,
    user_data: u64,
    timestamp: i64,
    
    pub fn hasEvent(self: *const EpollEventData, event: EpollEventType) bool {
        return (self.event_mask & event.toLinux()) != 0;
    }
};

// Generic event union
pub const KernelEvent = union(enum) {
    file_event: FileEventData,
    signal_event: SignalEventData,
    epoll_event: EpollEventData,
    
    pub fn deinit(self: *KernelEvent, allocator: Allocator) void {
        switch (self.*) {
            .file_event => |*event| event.deinit(allocator),
            .signal_event => {},
            .epoll_event => {},
        }
    }
    
    pub fn getTimestamp(self: *const KernelEvent) i64 {
        return switch (self.*) {
            .file_event => |event| event.timestamp,
            .signal_event => |event| event.timestamp,
            .epoll_event => |event| event.timestamp,
        };
    }
};

// Event handler callback type
pub const EventHandler = *const fn (event: *const KernelEvent, user_data: ?*anyopaque) void;

// File system watcher (inotify wrapper)
pub const AsyncFileWatcher = struct {
    allocator: Allocator,
    inotify_fd: i32,
    watches: HashMap(i32, []const u8, std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage),
    watch_paths: HashMap([]const u8, i32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    event_buffer: ArrayList(u8),
    max_events: usize,
    event_handlers: ArrayList(EventHandler),
    user_data: ?*anyopaque,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        // In a real implementation, we'd call inotify_init1
        const inotify_fd = 3; // Simulated file descriptor
        
        return Self{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watches = HashMap(i32, []const u8, std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage).init(allocator),
            .watch_paths = HashMap([]const u8, i32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .event_buffer = ArrayList(u8){ .allocator = allocator },
            .max_events = 1024,
            .event_handlers = ArrayList(EventHandler){ .allocator = allocator },
            .user_data = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var watch_iterator = self.watches.iterator();
        while (watch_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.watches.deinit();
        
        var path_iterator = self.watch_paths.iterator();
        while (path_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watch_paths.deinit();
        
        self.event_buffer.deinit();
        self.event_handlers.deinit();
    }
    
    pub fn addWatch(self: *Self, path: []const u8, events: []const FileEvent) !i32 {
        var event_mask: u32 = 0;
        for (events) |event| {
            event_mask |= event.toLinux();
        }
        
        // In a real implementation, we'd call inotify_add_watch
        const watch_descriptor = @as(i32, @intCast(self.watches.count() + 1));
        
        const owned_path = try self.allocator.dupe(u8, path);
        try self.watches.put(watch_descriptor, owned_path);
        try self.watch_paths.put(owned_path, watch_descriptor);
        
        return watch_descriptor;
    }
    
    pub fn removeWatch(self: *Self, watch_descriptor: i32) !void {
        if (self.watches.fetchRemove(watch_descriptor)) |removed| {
            defer self.allocator.free(removed.value);
            _ = self.watch_paths.remove(removed.value);
        }
    }
    
    pub fn removeWatchByPath(self: *Self, path: []const u8) !void {
        if (self.watch_paths.get(path)) |watch_descriptor| {
            try self.removeWatch(watch_descriptor);
        }
    }
    
    pub fn addEventHandler(self: *Self, handler: EventHandler) !void {
        try self.event_handlers.append(self.allocator, handler);
    }
    
    pub fn setUserData(self: *Self, user_data: *anyopaque) void {
        self.user_data = user_data;
    }
    
    pub fn readEventsAsync(self: *Self, io_context: *io.Io) ![]KernelEvent {
        _ = io_context;
        
        // In a real implementation, we'd read from inotify_fd
        // For now, we'll simulate reading events
        var events = ArrayList(KernelEvent){ .allocator = self.allocator };
        
        // Simulate a file creation event
        const simulated_event = KernelEvent{
            .file_event = FileEventData{
                .watch_descriptor = 1,
                .event_mask = FileEvent.created.toLinux(),
                .cookie = 0,
                .name = try self.allocator.dupe(u8, "test_file.txt"),
                .timestamp = std.time.timestamp(),
            },
        };
        
        try events.append(allocator, simulated_event);
        
        // Notify event handlers
        for (events.items) |*event| {
            for (self.event_handlers.items) |handler| {
                handler(event, self.user_data);
            }
        }
        
        return events.toOwnedSlice();
    }
    
    pub fn getWatchPath(self: *Self, watch_descriptor: i32) ?[]const u8 {
        return self.watches.get(watch_descriptor);
    }
    
    pub fn getWatchDescriptor(self: *Self, path: []const u8) ?i32 {
        return self.watch_paths.get(path);
    }
};

// Signal handler
pub const AsyncSignalHandler = struct {
    allocator: Allocator,
    signal_handlers: HashMap(i32, ArrayList(EventHandler), std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage),
    signal_mask: linux.sigset_t,
    signal_fd: i32,
    user_data: ?*anyopaque,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .signal_handlers = HashMap(i32, ArrayList(EventHandler), std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage).init(allocator),
            .signal_mask = std.mem.zeroes(linux.sigset_t),
            .signal_fd = -1,
            .user_data = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.signal_handlers.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.signal_handlers.deinit();
    }
    
    pub fn addSignalHandler(self: *Self, signal: SignalType, handler: EventHandler) !void {
        const signal_num = signal.toLinux();
        
        var handlers = self.signal_handlers.get(signal_num) orelse blk: {
            var new_handlers = ArrayList(EventHandler){ .allocator = self.allocator };
            try self.signal_handlers.put(signal_num, new_handlers);
            break :blk self.signal_handlers.getPtr(signal_num).?;
        };
        
        try handlers.append(allocator, handler);
    }
    
    pub fn removeSignalHandler(self: *Self, signal: SignalType) void {
        const signal_num = signal.toLinux();
        if (self.signal_handlers.fetchRemove(signal_num)) |removed| {
            removed.value.deinit();
        }
    }
    
    pub fn blockSignal(self: *Self, signal: SignalType) !void {
        const signal_num = signal.toLinux();
        linux.sigaddset(&self.signal_mask, signal_num);
        
        // In a real implementation, we'd call sigprocmask or pthread_sigmask
        _ = signal_num;
    }
    
    pub fn unblockSignal(self: *Self, signal: SignalType) !void {
        const signal_num = signal.toLinux();
        linux.sigdelset(&self.signal_mask, signal_num);
        
        // In a real implementation, we'd call sigprocmask or pthread_sigmask
        _ = signal_num;
    }
    
    pub fn createSignalFd(self: *Self) !void {
        // In a real implementation, we'd call signalfd
        self.signal_fd = 4; // Simulated signal file descriptor
    }
    
    pub fn readSignalsAsync(self: *Self, io_context: *io.Io) ![]KernelEvent {
        _ = io_context;
        
        var events = ArrayList(KernelEvent){ .allocator = self.allocator };
        
        // Simulate receiving a SIGCHLD signal
        const simulated_event = KernelEvent{
            .signal_event = SignalEventData{
                .signal_number = SignalType.child.toLinux(),
                .sender_pid = 1234,
                .sender_uid = 1000,
                .timestamp = std.time.timestamp(),
                .additional_data = null,
            },
        };
        
        try events.append(allocator, simulated_event);
        
        // Notify signal handlers
        for (events.items) |*event| {
            if (event.* == .signal_event) {
                const signal_num = event.signal_event.signal_number;
                if (self.signal_handlers.get(signal_num)) |handlers| {
                    for (handlers.items) |handler| {
                        handler(event, self.user_data);
                    }
                }
            }
        }
        
        return events.toOwnedSlice();
    }
    
    pub fn setUserData(self: *Self, user_data: *anyopaque) void {
        self.user_data = user_data;
    }
};

// Epoll event manager
pub const AsyncEpollManager = struct {
    allocator: Allocator,
    epoll_fd: i32,
    watched_fds: HashMap(i32, u32, std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage),
    event_handlers: ArrayList(EventHandler),
    max_events: usize,
    timeout_ms: i32,
    user_data: ?*anyopaque,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        // In a real implementation, we'd call epoll_create1
        const epoll_fd = 5; // Simulated epoll file descriptor
        
        return Self{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .watched_fds = HashMap(i32, u32, std.hash_map.AutoContext(i32), std.hash_map.default_max_load_percentage).init(allocator),
            .event_handlers = ArrayList(EventHandler){ .allocator = allocator },
            .max_events = 1024,
            .timeout_ms = 1000,
            .user_data = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.watched_fds.deinit();
        self.event_handlers.deinit();
    }
    
    pub fn addFd(self: *Self, fd: i32, events: []const EpollEventType) !void {
        var event_mask: u32 = 0;
        for (events) |event| {
            event_mask |= event.toLinux();
        }
        
        try self.watched_fds.put(fd, event_mask);
        
        // In a real implementation, we'd call epoll_ctl with EPOLL_CTL_ADD
    }
    
    pub fn modifyFd(self: *Self, fd: i32, events: []const EpollEventType) !void {
        var event_mask: u32 = 0;
        for (events) |event| {
            event_mask |= event.toLinux();
        }
        
        try self.watched_fds.put(fd, event_mask);
        
        // In a real implementation, we'd call epoll_ctl with EPOLL_CTL_MOD
    }
    
    pub fn removeFd(self: *Self, fd: i32) !void {
        _ = self.watched_fds.remove(fd);
        
        // In a real implementation, we'd call epoll_ctl with EPOLL_CTL_DEL
    }
    
    pub fn addEventHandler(self: *Self, handler: EventHandler) !void {
        try self.event_handlers.append(self.allocator, handler);
    }
    
    pub fn setTimeout(self: *Self, timeout_ms: i32) void {
        self.timeout_ms = timeout_ms;
    }
    
    pub fn waitForEventsAsync(self: *Self, io_context: *io.Io) ![]KernelEvent {
        _ = io_context;
        
        var events = ArrayList(KernelEvent){ .allocator = self.allocator };
        
        // Simulate epoll events
        var fd_iterator = self.watched_fds.iterator();
        while (fd_iterator.next()) |entry| {
            const fd = entry.key_ptr.*;
            const event_mask = entry.value_ptr.*;
            
            // Simulate that the file descriptor is ready for reading
            if ((event_mask & EpollEventType.readable.toLinux()) != 0) {
                const simulated_event = KernelEvent{
                    .epoll_event = EpollEventData{
                        .file_descriptor = fd,
                        .event_mask = EpollEventType.readable.toLinux(),
                        .user_data = @bitCast(@as(u64, @intCast(fd))),
                        .timestamp = std.time.timestamp(),
                    },
                };
                
                try events.append(allocator, simulated_event);
            }
        }
        
        // Notify event handlers
        for (events.items) |*event| {
            for (self.event_handlers.items) |handler| {
                handler(event, self.user_data);
            }
        }
        
        return events.toOwnedSlice();
    }
    
    pub fn setUserData(self: *Self, user_data: *anyopaque) void {
        self.user_data = user_data;
    }
};

// Unified kernel event manager
pub const AsyncKernelEventManager = struct {
    allocator: Allocator,
    file_watcher: AsyncFileWatcher,
    signal_handler: AsyncSignalHandler,
    epoll_manager: AsyncEpollManager,
    event_queue: ArrayList(KernelEvent),
    queue_mutex: std.Thread.Mutex,
    running: std.atomic.Value(bool),
    worker_thread: ?std.Thread,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .file_watcher = try AsyncFileWatcher.init(allocator),
            .signal_handler = try AsyncSignalHandler.init(allocator),
            .epoll_manager = try AsyncEpollManager.init(allocator),
            .event_queue = ArrayList(KernelEvent){ .allocator = allocator },
            .queue_mutex = std.Thread.Mutex{},
            .running = std.atomic.Value(bool).init(false),
            .worker_thread = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        
        self.file_watcher.deinit();
        self.signal_handler.deinit();
        self.epoll_manager.deinit();
        
        self.queue_mutex.lock();
        for (self.event_queue.items) |*event| {
            event.deinit(self.allocator);
        }
        self.event_queue.deinit();
        self.queue_mutex.unlock();
    }
    
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;
        
        self.running.store(true, .seq_cst);
        self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }
    
    pub fn stop(self: *Self) void {
        if (!self.running.load(.seq_cst)) return;
        
        self.running.store(false, .seq_cst);
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }
    
    fn workerLoop(self: *Self) void {
        while (self.running.load(.seq_cst)) {
            self.processEvents() catch |err| {
                std.log.err("Event processing error: {}", .{err});
            };
            
            // Small delay to prevent busy waiting
            std.time.sleep(1_000_000); // 1ms
        }
    }
    
    fn processEvents(self: *Self) !void {
        // This would be a proper I/O context in a real implementation
        var dummy_io_context: io.Io = undefined;
        
        // Process file events
        const file_events = self.file_watcher.readEventsAsync(&dummy_io_context) catch &[_]KernelEvent{};
        defer self.allocator.free(file_events);
        
        // Process signal events
        const signal_events = self.signal_handler.readSignalsAsync(&dummy_io_context) catch &[_]KernelEvent{};
        defer self.allocator.free(signal_events);
        
        // Process epoll events
        const epoll_events = self.epoll_manager.waitForEventsAsync(&dummy_io_context) catch &[_]KernelEvent{};
        defer self.allocator.free(epoll_events);
        
        // Queue all events
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            
            try self.event_queue.appendSlice(file_events);
            try self.event_queue.appendSlice(signal_events);
            try self.event_queue.appendSlice(epoll_events);
        }
    }
    
    pub fn getEvents(self: *Self) ![]KernelEvent {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        const events = try self.allocator.dupe(KernelEvent, self.event_queue.items);
        self.event_queue.clearRetainingCapacity();
        
        return events;
    }
    
    pub fn getFileWatcher(self: *Self) *AsyncFileWatcher {
        return &self.file_watcher;
    }
    
    pub fn getSignalHandler(self: *Self) *AsyncSignalHandler {
        return &self.signal_handler;
    }
    
    pub fn getEpollManager(self: *Self) *AsyncEpollManager {
        return &self.epoll_manager;
    }
};

// Example event handlers
fn exampleFileEventHandler(event: *const KernelEvent, user_data: ?*anyopaque) void {
    _ = user_data;
    if (event.* == .file_event) {
        const file_event = event.file_event;
        std.log.info("File event: wd={}, mask=0x{x}, name={?s}", .{ file_event.watch_descriptor, file_event.event_mask, file_event.name });
    }
}

fn exampleSignalHandler(event: *const KernelEvent, user_data: ?*anyopaque) void {
    _ = user_data;
    if (event.* == .signal_event) {
        const signal_event = event.signal_event;
        std.log.info("Signal event: signal={}, pid={}, uid={}", .{ signal_event.signal_number, signal_event.sender_pid, signal_event.sender_uid });
    }
}

fn exampleEpollHandler(event: *const KernelEvent, user_data: ?*anyopaque) void {
    _ = user_data;
    if (event.* == .epoll_event) {
        const epoll_event = event.epoll_event;
        std.log.info("Epoll event: fd={}, mask=0x{x}, data={}", .{ epoll_event.file_descriptor, epoll_event.event_mask, epoll_event.user_data });
    }
}

// Hardware interrupt types for enhanced monitoring
pub const InterruptType = enum(u8) {
    timer = 0x20,
    keyboard = 0x21,
    cascade = 0x22,
    serial_port_2 = 0x23,
    serial_port_1 = 0x24,
    parallel_port_2 = 0x25,
    floppy_disk = 0x26,
    parallel_port_1 = 0x27,
    rtc = 0x28,
    acpi = 0x29,
    available_1 = 0x2A,
    available_2 = 0x2B,
    mouse = 0x2C,
    fpu = 0x2D,
    primary_ata = 0x2E,
    secondary_ata = 0x2F,
    network = 0x30,
    usb = 0x31,
    pci = 0x32,
    gpu = 0x33,
    custom = 0xFF,
};

pub const InterruptPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
};

pub const InterruptContext = struct {
    interrupt_type: InterruptType,
    priority: InterruptPriority,
    vector: u32,
    data: ?*anyopaque = null,
    timestamp: u64,
    cpu_id: u8,
    duration_ns: u64 = 0,
    frequency_hz: f64 = 0.0,
};

pub const InterruptHandler = struct {
    context: InterruptContext,
    callback: *const fn (ctx: *InterruptContext) anyerror!void,
    next: ?*InterruptHandler = null,
    invocation_count: std.atomic.Value(u64),
    total_duration_ns: std.atomic.Value(u64),
    last_invocation: std.atomic.Value(u64),
};

pub const AsyncInterruptMonitor = struct {
    allocator: Allocator,
    io_context: *io.Io,
    handlers: HashMap(u32, *InterruptHandler, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    pending_interrupts: io.RingBuffer(InterruptContext),
    monitoring_active: std.atomic.Value(bool),
    worker_threads: []std.Thread,
    interrupt_count: std.atomic.Value(u64),
    last_optimization: std.atomic.Value(u64),
    optimization_threshold: u64,
    hot_interrupts: ArrayList(u32),
    cold_interrupts: ArrayList(u32),
    stats_mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, io_context: *io.Io, thread_count: u32) !Self {
        return Self{
            .allocator = allocator,
            .io_context = io_context,
            .handlers = HashMap(u32, *InterruptHandler, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .pending_interrupts = try io.RingBuffer(InterruptContext).init(allocator, 1024),
            .monitoring_active = std.atomic.Value(bool).init(false),
            .worker_threads = try allocator.alloc(std.Thread, thread_count),
            .interrupt_count = std.atomic.Value(u64).init(0),
            .last_optimization = std.atomic.Value(u64).init(0),
            .optimization_threshold = 10000,
            .hot_interrupts = ArrayList(u32){ .allocator = allocator },
            .cold_interrupts = ArrayList(u32){ .allocator = allocator },
            .stats_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopMonitoring();
        
        var iterator = self.handlers.iterator();
        while (iterator.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.handlers.deinit();
        self.pending_interrupts.deinit();
        self.allocator.free(self.worker_threads);
        self.hot_interrupts.deinit();
        self.cold_interrupts.deinit();
    }

    pub fn registerHandler(self: *Self, vector: u32, handler: *InterruptHandler) !void {
        try self.handlers.put(vector, handler);
    }

    pub fn unregisterHandler(self: *Self, vector: u32) void {
        if (self.handlers.fetchRemove(vector)) |entry| {
            self.allocator.destroy(entry.value);
        }
    }

    pub fn startMonitoring(self: *Self) !void {
        if (self.monitoring_active.swap(true, .acquire)) return;

        for (self.worker_threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, monitorWorker, .{ self, i });
        }
    }

    pub fn stopMonitoring(self: *Self) void {
        if (!self.monitoring_active.swap(false, .release)) return;

        for (self.worker_threads) |thread| {
            thread.join();
        }
    }

    pub fn triggerInterrupt(self: *Self, ctx: InterruptContext) !void {
        _ = self.interrupt_count.fetchAdd(1, .monotonic);
        
        if (self.pending_interrupts.tryPush(ctx)) {
            self.maybeOptimize();
            return;
        }
        
        return error.InterruptQueueFull;
    }

    fn monitorWorker(self: *Self, worker_id: usize) void {
        _ = worker_id;
        
        while (self.monitoring_active.load(.acquire)) {
            if (self.pending_interrupts.tryPop()) |interrupt_ctx| {
                self.handleInterrupt(interrupt_ctx) catch |err| {
                    std.log.err("Interrupt handling failed: {}", .{err});
                };
            } else {
                std.time.sleep(1000);
            }
        }
    }

    fn handleInterrupt(self: *Self, ctx: InterruptContext) !void {
        const start_time = std.time.Instant.now() catch unreachable;
        
        if (self.handlers.get(ctx.vector)) |handler| {
            var mutable_ctx = ctx;
            _ = handler.invocation_count.fetchAdd(1, .monotonic);
            _ = handler.last_invocation.store(@intCast(start_time), .monotonic);
            
            try handler.callback(&mutable_ctx);
            
            const end_time = std.time.Instant.now() catch unreachable;
            const duration = @as(u64, @intCast(end_time - start_time));
            _ = handler.total_duration_ns.fetchAdd(duration, .monotonic);
        }
    }

    fn maybeOptimize(self: *Self) void {
        const current_count = self.interrupt_count.load(.monotonic);
        const last_opt = self.last_optimization.load(.monotonic);
        
        if (current_count - last_opt > self.optimization_threshold) {
            if (self.last_optimization.cmpxchgWeak(last_opt, current_count, .acquire, .monotonic) == null) {
                self.optimizeInterruptHandling() catch {};
            }
        }
    }

    fn optimizeInterruptHandling(self: *Self) !void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        
        self.hot_interrupts.clearRetainingCapacity();
        self.cold_interrupts.clearRetainingCapacity();
        
        var iterator = self.handlers.iterator();
        while (iterator.next()) |entry| {
            const vector = entry.key_ptr.*;
            const handler = entry.value_ptr.*;
            const count = handler.invocation_count.load(.monotonic);
            
            if (count > 1000) {
                try self.hot_interrupts.append(self.allocator, vector);
            } else if (count < 10) {
                try self.cold_interrupts.append(self.allocator, vector);
            }
        }
        
        std.log.info("Interrupt optimization: {} hot, {} cold interrupts", .{ self.hot_interrupts.items.len, self.cold_interrupts.items.len });
    }

    pub fn getInterruptStats(self: *Self) InterruptStats {
        return InterruptStats{
            .total_count = self.interrupt_count.load(.monotonic),
            .queue_depth = self.pending_interrupts.len(),
            .handler_count = self.handlers.count(),
            .monitoring_active = self.monitoring_active.load(.acquire),
            .hot_interrupt_count = self.hot_interrupts.items.len,
            .cold_interrupt_count = self.cold_interrupts.items.len,
        };
    }
};

pub const InterruptStats = struct {
    total_count: u64,
    queue_depth: u32,
    handler_count: u32,
    monitoring_active: bool,
    hot_interrupt_count: usize,
    cold_interrupt_count: usize,
};

pub fn createTimerInterrupt(allocator: Allocator, interval_ns: u64, callback: *const fn (*InterruptContext) anyerror!void) !*InterruptHandler {
    const handler = try allocator.create(InterruptHandler);
    handler.* = InterruptHandler{
        .context = InterruptContext{
            .interrupt_type = .timer,
            .priority = .normal,
            .vector = 0x20,
            .timestamp = @intCast(std.time.Instant.now() catch unreachable),
            .cpu_id = 0,
        },
        .callback = callback,
        .invocation_count = std.atomic.Value(u64).init(0),
        .total_duration_ns = std.atomic.Value(u64).init(0),
        .last_invocation = std.atomic.Value(u64).init(0),
    };
    
    _ = interval_ns;
    return handler;
}

pub fn createNetworkInterrupt(allocator: Allocator, callback: *const fn (*InterruptContext) anyerror!void) !*InterruptHandler {
    const handler = try allocator.create(InterruptHandler);
    handler.* = InterruptHandler{
        .context = InterruptContext{
            .interrupt_type = .network,
            .priority = .high,
            .vector = 0x30,
            .timestamp = @intCast(std.time.Instant.now() catch unreachable),
            .cpu_id = 0,
        },
        .callback = callback,
        .invocation_count = std.atomic.Value(u64).init(0),
        .total_duration_ns = std.atomic.Value(u64).init(0),
        .last_invocation = std.atomic.Value(u64).init(0),
    };
    
    return handler;
}

// Real-time scheduling integration
pub const RealTimeScheduler = struct {
    allocator: Allocator,
    task_queue: io.RingBuffer(RealTimeTask),
    priority_queues: [4]ArrayList(RealTimeTask),
    current_task: ?*RealTimeTask,
    scheduler_active: std.atomic.Value(bool),
    preemption_timer: std.time.Timer,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .task_queue = try io.RingBuffer(RealTimeTask).init(allocator, 256),
            .priority_queues = [4]ArrayList(RealTimeTask){
                ArrayList(RealTimeTask){ .allocator = allocator },
                ArrayList(RealTimeTask){ .allocator = allocator },
                ArrayList(RealTimeTask){ .allocator = allocator },
                ArrayList(RealTimeTask){ .allocator = allocator },
            },
            .current_task = null,
            .scheduler_active = std.atomic.Value(bool).init(false),
            .preemption_timer = try std.time.Timer.start(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.task_queue.deinit();
        for (&self.priority_queues) |*queue| {
            queue.deinit();
        }
    }
    
    pub fn scheduleTask(self: *Self, task: RealTimeTask) !void {
        const priority_idx = @intFromEnum(task.priority);
        try self.priority_queues[priority_idx].append(self.allocator, task);
    }
    
    pub fn getNextTask(self: *Self) ?RealTimeTask {
        for (&self.priority_queues) |*queue| {
            if (queue.items.len > 0) {
                return queue.orderedRemove(0);
            }
        }
        return null;
    }
    
    pub fn preemptCurrentTask(self: *Self) void {
        if (self.current_task) |task| {
            const priority_idx = @intFromEnum(task.priority);
            self.priority_queues[priority_idx].append(self.allocator, task.*) catch {};
            self.current_task = null;
        }
    }
};

pub const RealTimeTask = struct {
    id: u64,
    priority: InterruptPriority,
    deadline_ns: u64,
    execution_time_ns: u64,
    callback: *const fn (*RealTimeTask) anyerror!void,
    user_data: ?*anyopaque = null,
    
    pub fn execute(self: *RealTimeTask) !void {
        try self.callback(self);
    }
    
    pub fn isDeadlineMissed(self: *const RealTimeTask) bool {
        return @as(u64, @intCast(std.time.Instant.now() catch unreachable)) > self.deadline_ns;
    }
};

/// Enhanced Real-Time Task Scheduler with deadline handling and priority management
pub const EnhancedRealTimeScheduler = struct {
    allocator: Allocator,
    io_context: *io.Io,
    
    // Priority queues for different priority levels
    critical_queue: io.RingBuffer(ScheduledTask),
    high_queue: io.RingBuffer(ScheduledTask),
    normal_queue: io.RingBuffer(ScheduledTask),
    low_queue: io.RingBuffer(ScheduledTask),
    
    // Deadline management
    deadline_tracker: DeadlineTracker,
    
    // Current execution state
    current_task: ?*ScheduledTask,
    scheduler_active: std.atomic.Value(bool),
    preemption_enabled: std.atomic.Value(bool),
    
    // Worker threads for parallel processing
    worker_threads: []std.Thread,
    worker_active: std.atomic.Value(bool),
    
    // Statistics and metrics
    stats: SchedulerStats,
    stats_mutex: std.Thread.Mutex,
    
    // Configuration
    config: SchedulerConfig,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, io_context: *io.Io, config: SchedulerConfig) !Self {
        return Self{
            .allocator = allocator,
            .io_context = io_context,
            .critical_queue = try io.RingBuffer(ScheduledTask).init(allocator, config.queue_size),
            .high_queue = try io.RingBuffer(ScheduledTask).init(allocator, config.queue_size),
            .normal_queue = try io.RingBuffer(ScheduledTask).init(allocator, config.queue_size),
            .low_queue = try io.RingBuffer(ScheduledTask).init(allocator, config.queue_size),
            .deadline_tracker = try DeadlineTracker.init(allocator),
            .current_task = null,
            .scheduler_active = std.atomic.Value(bool).init(false),
            .preemption_enabled = std.atomic.Value(bool).init(true),
            .worker_threads = try allocator.alloc(std.Thread, config.worker_count),
            .worker_active = std.atomic.Value(bool).init(false),
            .stats = SchedulerStats{},
            .stats_mutex = .{},
            .config = config,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stopScheduler();
        
        self.critical_queue.deinit();
        self.high_queue.deinit();
        self.normal_queue.deinit();
        self.low_queue.deinit();
        self.deadline_tracker.deinit();
        self.allocator.free(self.worker_threads);
    }
    
    pub fn startScheduler(self: *Self) !void {
        if (self.scheduler_active.swap(true, .acquire)) return;
        
        self.worker_active.store(true, .release);
        
        for (self.worker_threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, schedulerWorker, .{ self, i });
        }
    }
    
    pub fn stopScheduler(self: *Self) void {
        if (!self.scheduler_active.swap(false, .release)) return;
        
        self.worker_active.store(false, .release);
        
        for (self.worker_threads) |thread| {
            thread.join();
        }
    }
    
    pub fn scheduleTaskAsync(self: *Self, allocator: Allocator, task: ScheduledTask) !io.Future {
        const ctx = try allocator.create(ScheduleTaskContext);
        ctx.* = .{
            .scheduler = self,
            .task = task,
            .allocator = allocator,
            .scheduled = false,
        };
        
        return io.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = scheduleTaskPoll,
                    .deinit_fn = scheduleTaskDeinit,
                },
            },
        };
    }
    
    pub fn scheduleTask(self: *Self, task: ScheduledTask) !void {
        // Update statistics
        self.stats_mutex.lock();
        self.stats.tasks_scheduled += 1;
        self.stats_mutex.unlock();
        
        // Register deadline if specified
        if (task.deadline_ns > 0) {
            try self.deadline_tracker.addDeadline(task.id, task.deadline_ns);
        }
        
        // Route to appropriate priority queue
        switch (task.priority) {
            .critical => {
                if (!self.critical_queue.tryPush(task)) {
                    return error.QueueFull;
                }
            },
            .high => {
                if (!self.high_queue.tryPush(task)) {
                    return error.QueueFull;
                }
            },
            .normal => {
                if (!self.normal_queue.tryPush(task)) {
                    return error.QueueFull;
                }
            },
            .low => {
                if (!self.low_queue.tryPush(task)) {
                    return error.QueueFull;
                }
            },
        }
    }
    
    pub fn getNextTask(self: *Self) ?ScheduledTask {
        // Check critical tasks first
        if (self.critical_queue.tryPop()) |task| {
            return task;
        }
        
        // Check for deadline violations
        if (self.deadline_tracker.getNextExpiredTask()) |task_id| {
            // Try to find and prioritize the task with expired deadline
            if (self.findAndPromoteTask(task_id)) |task| {
                return task;
            }
        }
        
        // Normal priority order
        if (self.high_queue.tryPop()) |task| {
            return task;
        }
        
        if (self.normal_queue.tryPop()) |task| {
            return task;
        }
        
        if (self.low_queue.tryPop()) |task| {
            return task;
        }
        
        return null;
    }
    
    fn findAndPromoteTask(self: *Self, task_id: u64) ?ScheduledTask {
        // This is a simplified implementation
        // In practice, you'd search through queues and promote the task
        _ = self;
        _ = task_id;
        return null;
    }
    
    pub fn preemptCurrentTask(self: *Self, reason: PreemptionReason) void {
        if (self.current_task) |task| {
            // Update statistics
            self.stats_mutex.lock();
            self.stats.preemptions += 1;
            switch (reason) {
                .higher_priority => self.stats.priority_preemptions += 1,
                .deadline_violation => self.stats.deadline_preemptions += 1,
                .time_slice_expired => self.stats.timeslice_preemptions += 1,
            }
            self.stats_mutex.unlock();
            
            // Reschedule the task based on priority
            self.scheduleTask(task.*) catch {};
            self.current_task = null;
        }
    }
    
    pub fn handleDeadlineViolation(self: *Self, task_id: u64) void {
        self.stats_mutex.lock();
        self.stats.deadline_misses += 1;
        self.stats_mutex.unlock();
        
        // Log deadline violation
        std.log.warn("Deadline violation detected for task {}", .{task_id});
        
        // Trigger preemption if this task has higher priority
        if (self.current_task) |current| {
            if (current.priority != .critical) {
                self.preemptCurrentTask(.deadline_violation);
            }
        }
    }
    
    fn schedulerWorker(self: *Self, worker_id: usize) void {
        while (self.worker_active.load(.acquire)) {
            if (self.getNextTask()) |task| {
                self.executeTask(task, worker_id) catch |err| {
                    std.log.err("Task execution failed in worker {}: {}", .{ worker_id, err });
                };
            } else {
                // No tasks available, sleep briefly
                std.time.sleep(100_000); // 100μs
            }
        }
    }
    
    fn executeTask(self: *Self, task: ScheduledTask, worker_id: usize) !void {
        const start_time = std.time.Instant.now() catch unreachable;
        
        // Set current task
        self.current_task = @constCast(&task);
        
        // Update statistics
        self.stats_mutex.lock();
        self.stats.tasks_executed += 1;
        self.stats_mutex.unlock();
        
        // Execute the task
        var mutable_task = task;
        mutable_task.worker_id = @intCast(worker_id);
        mutable_task.start_time = @intCast(start_time);
        
        try mutable_task.execute();
        
        // Update completion statistics
        const end_time = std.time.Instant.now() catch unreachable;
        const execution_time = @as(u64, @intCast(end_time - start_time));
        
        self.stats_mutex.lock();
        self.stats.tasks_completed += 1;
        self.stats.total_execution_time += execution_time;
        if (execution_time > self.stats.max_execution_time) {
            self.stats.max_execution_time = execution_time;
        }
        self.stats_mutex.unlock();
        
        // Remove deadline tracking
        self.deadline_tracker.removeDeadline(task.id);
        
        // Clear current task
        self.current_task = null;
    }
    
    pub fn getSchedulerStats(self: *Self) SchedulerStats {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        return self.stats;
    }
    
    pub fn adjustPriority(self: *Self, task_id: u64, new_priority: InterruptPriority) !void {
        // This would search through queues and adjust task priority
        // Simplified implementation
        _ = self;
        _ = task_id;
        _ = new_priority;
        
        self.stats_mutex.lock();
        self.stats.priority_adjustments += 1;
        self.stats_mutex.unlock();
    }
};

pub const ScheduledTask = struct {
    id: u64,
    priority: InterruptPriority,
    deadline_ns: u64,
    estimated_duration_ns: u64,
    callback: *const fn (*ScheduledTask) anyerror!void,
    user_data: ?*anyopaque = null,
    
    // Runtime information
    worker_id: u32 = 0,
    start_time: u64 = 0,
    actual_duration_ns: u64 = 0,
    retry_count: u32 = 0,
    max_retries: u32 = 3,
    
    pub fn execute(self: *ScheduledTask) !void {
        const start_time = std.time.Instant.now() catch unreachable;
        
        try self.callback(self);
        
        const end_time = std.time.Instant.now() catch unreachable;
        self.actual_duration_ns = @intCast(end_time - start_time);
    }
    
    pub fn isDeadlineMissed(self: *const ScheduledTask) bool {
        return @as(u64, @intCast(std.time.Instant.now() catch unreachable)) > self.deadline_ns;
    }
    
    pub fn getRemainingTime(self: *const ScheduledTask) i64 {
        const current_time = @as(u64, @intCast(std.time.Instant.now() catch unreachable));
        if (current_time >= self.deadline_ns) {
            return 0;
        }
        return @intCast(self.deadline_ns - current_time);
    }
};

pub const SchedulerConfig = struct {
    queue_size: u32 = 1024,
    worker_count: u32 = 4,
    preemption_enabled: bool = true,
    deadline_checking_enabled: bool = true,
    time_slice_ns: u64 = 10_000_000, // 10ms default
};

pub const SchedulerStats = struct {
    tasks_scheduled: u64 = 0,
    tasks_executed: u64 = 0,
    tasks_completed: u64 = 0,
    preemptions: u64 = 0,
    priority_preemptions: u64 = 0,
    deadline_preemptions: u64 = 0,
    timeslice_preemptions: u64 = 0,
    deadline_misses: u64 = 0,
    priority_adjustments: u64 = 0,
    total_execution_time: u64 = 0,
    max_execution_time: u64 = 0,
    
    pub fn getAverageExecutionTime(self: *const SchedulerStats) f64 {
        if (self.tasks_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_execution_time)) / @as(f64, @floatFromInt(self.tasks_completed));
    }
    
    pub fn getPreemptionRate(self: *const SchedulerStats) f64 {
        if (self.tasks_executed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.preemptions)) / @as(f64, @floatFromInt(self.tasks_executed));
    }
    
    pub fn getDeadlineMissRate(self: *const SchedulerStats) f64 {
        if (self.tasks_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.deadline_misses)) / @as(f64, @floatFromInt(self.tasks_completed));
    }
};

pub const PreemptionReason = enum {
    higher_priority,
    deadline_violation,
    time_slice_expired,
};

pub const DeadlineTracker = struct {
    allocator: Allocator,
    deadlines: std.PriorityQueue(DeadlineEntry, void, compareDeadlines),
    task_deadlines: HashMap(u64, u64, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .deadlines = std.PriorityQueue(DeadlineEntry, void, compareDeadlines).init(allocator, {}),
            .task_deadlines = HashMap(u64, u64, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.deadlines.deinit();
        self.task_deadlines.deinit();
    }
    
    pub fn addDeadline(self: *Self, task_id: u64, deadline_ns: u64) !void {
        try self.deadlines.add(DeadlineEntry{ .task_id = task_id, .deadline_ns = deadline_ns });
        try self.task_deadlines.put(task_id, deadline_ns);
    }
    
    pub fn removeDeadline(self: *Self, task_id: u64) void {
        _ = self.task_deadlines.remove(task_id);
        // Note: For simplicity, not removing from priority queue
        // In production, you'd maintain a more efficient structure
    }
    
    pub fn getNextExpiredTask(self: *Self) ?u64 {
        const current_time = @as(u64, @intCast(std.time.Instant.now() catch unreachable));
        
        while (self.deadlines.peek()) |entry| {
            if (entry.deadline_ns <= current_time) {
                const expired_entry = self.deadlines.remove();
                return expired_entry.task_id;
            } else {
                break;
            }
        }
        
        return null;
    }
    
    fn compareDeadlines(context: void, a: DeadlineEntry, b: DeadlineEntry) std.math.Order {
        _ = context;
        return std.math.order(a.deadline_ns, b.deadline_ns);
    }
};

pub const DeadlineEntry = struct {
    task_id: u64,
    deadline_ns: u64,
};

// Context structures for async operations
const ScheduleTaskContext = struct {
    scheduler: *EnhancedRealTimeScheduler,
    task: ScheduledTask,
    allocator: Allocator,
    scheduled: bool,
};

fn scheduleTaskPoll(context: *anyopaque, io_ctx: io.Io) io.Future.PollResult {
    _ = io_ctx;
    const ctx = @as(*ScheduleTaskContext, @ptrCast(@alignCast(context)));
    
    ctx.scheduler.scheduleTask(ctx.task) catch |err| {
        return .{ .ready = err };
    };
    
    ctx.scheduled = true;
    return .{ .ready = {} };
}

fn scheduleTaskDeinit(context: *anyopaque, allocator: Allocator) void {
    const ctx = @as(*ScheduleTaskContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

// Priority management functions
pub fn promotePriority(priority: InterruptPriority) InterruptPriority {
    return switch (priority) {
        .low => .normal,
        .normal => .high,
        .high => .critical,
        .critical => .critical, // Already at max
    };
}

pub fn demotePriority(priority: InterruptPriority) InterruptPriority {
    return switch (priority) {
        .critical => .high,
        .high => .normal,
        .normal => .low,
        .low => .low, // Already at min
    };
}

pub fn calculateDynamicPriority(base_priority: InterruptPriority, deadline_pressure: f64, load_factor: f64) InterruptPriority {
    const pressure_boost = if (deadline_pressure > 0.8) @as(i32, 1) else 0;
    const load_penalty = if (load_factor > 0.9) @as(i32, -1) else 0;
    
    const priority_value = @as(i32, @intFromEnum(base_priority)) + pressure_boost + load_penalty;
    const clamped_value = @max(0, @min(3, priority_value));
    
    return @enumFromInt(clamped_value);
}

// Device driver async callback infrastructure
pub const DeviceDriverCallbacks = struct {
    allocator: Allocator,
    io_context: *io.Io,
    callback_registry: HashMap(u32, *DriverCallback, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    pending_callbacks: io.RingBuffer(CallbackEvent),
    callback_workers: []std.Thread,
    worker_active: std.atomic.Value(bool),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, io_context: *io.Io, worker_count: u32) !Self {
        return Self{
            .allocator = allocator,
            .io_context = io_context,
            .callback_registry = HashMap(u32, *DriverCallback, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .pending_callbacks = try io.RingBuffer(CallbackEvent).init(allocator, 1024),
            .callback_workers = try allocator.alloc(std.Thread, worker_count),
            .worker_active = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stopCallbacks();
        
        var iterator = self.callback_registry.iterator();
        while (iterator.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.callback_registry.deinit();
        self.pending_callbacks.deinit();
        self.allocator.free(self.callback_workers);
    }
    
    pub fn registerCallback(self: *Self, device_id: u32, callback: *DriverCallback) !void {
        try self.callback_registry.put(device_id, callback);
    }
    
    pub fn unregisterCallback(self: *Self, device_id: u32) void {
        if (self.callback_registry.fetchRemove(device_id)) |entry| {
            self.allocator.destroy(entry.value);
        }
    }
    
    pub fn startCallbacks(self: *Self) !void {
        if (self.worker_active.swap(true, .acquire)) return;
        
        for (self.callback_workers, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, callbackWorker, .{ self, i });
        }
    }
    
    pub fn stopCallbacks(self: *Self) void {
        if (!self.worker_active.swap(false, .release)) return;
        
        for (self.callback_workers) |thread| {
            thread.join();
        }
    }
    
    pub fn triggerCallback(self: *Self, event: CallbackEvent) !void {
        if (!self.pending_callbacks.tryPush(event)) {
            return error.CallbackQueueFull;
        }
    }
    
    fn callbackWorker(self: *Self, worker_id: usize) void {
        _ = worker_id;
        
        while (self.worker_active.load(.acquire)) {
            if (self.pending_callbacks.tryPop()) |event| {
                self.processCallback(event) catch |err| {
                    std.log.err("Callback processing failed: {}", .{err});
                };
            } else {
                std.time.sleep(1000); // 1μs
            }
        }
    }
    
    fn processCallback(self: *Self, event: CallbackEvent) !void {
        if (self.callback_registry.get(event.device_id)) |callback| {
            try callback.execute(event);
        }
    }
};

pub const DriverCallback = struct {
    device_id: u32,
    callback_type: CallbackType,
    priority: InterruptPriority,
    handler: *const fn (event: CallbackEvent) anyerror!void,
    user_data: ?*anyopaque = null,
    
    pub fn execute(self: *DriverCallback, event: CallbackEvent) !void {
        try self.handler(event);
    }
};

pub const CallbackType = enum {
    interrupt,
    dma_complete,
    error_condition,
    status_change,
    data_ready,
    device_connected,
    device_disconnected,
};

pub const CallbackEvent = struct {
    device_id: u32,
    callback_type: CallbackType,
    data: ?*anyopaque = null,
    data_size: usize = 0,
    timestamp: u64,
    priority: InterruptPriority = .normal,
};

// Example usage and testing
test "file event enum conversion" {
    try testing.expect(FileEvent.created.toLinux() == linux.IN.CREATE);
    try testing.expect(FileEvent.modified.toLinux() == linux.IN.MODIFY);
}

test "signal type conversion" {
    try testing.expect(SignalType.interrupt.toLinux() == linux.SIG.INT);
    try testing.expect(SignalType.terminate.toLinux() == linux.SIG.TERM);
}

test "epoll event type conversion" {
    try testing.expect(EpollEventType.readable.toLinux() == linux.EPOLL.IN);
    try testing.expect(EpollEventType.writable.toLinux() == linux.EPOLL.OUT);
}

test "file watcher initialization" {
    var watcher = try AsyncFileWatcher.init(testing.allocator);
    defer watcher.deinit();
    
    const events = [_]FileEvent{ FileEvent.created, FileEvent.modified };
    const wd = try watcher.addWatch("/tmp/test", &events);
    
    try testing.expect(wd > 0);
    try testing.expect(watcher.getWatchPath(wd) != null);
}

test "signal handler setup" {
    var handler = try AsyncSignalHandler.init(testing.allocator);
    defer handler.deinit();
    
    try handler.addSignalHandler(SignalType.child, exampleSignalHandler);
    try handler.blockSignal(SignalType.child);
    
    try testing.expect(handler.signal_handlers.count() == 1);
}

test "epoll manager operations" {
    var manager = try AsyncEpollManager.init(testing.allocator);
    defer manager.deinit();
    
    const events = [_]EpollEventType{ EpollEventType.readable, EpollEventType.writable };
    try manager.addFd(1, &events);
    
    try testing.expect(manager.watched_fds.count() == 1);
}

test "kernel event manager" {
    var event_manager = try AsyncKernelEventManager.init(testing.allocator);
    defer event_manager.deinit();
    
    try event_manager.getFileWatcher().addEventHandler(exampleFileEventHandler);
    try event_manager.getSignalHandler().addSignalHandler(SignalType.child, exampleSignalHandler);
    try event_manager.getEpollManager().addEventHandler(exampleEpollHandler);
    
    // Test would start and stop the event manager in a real scenario
}