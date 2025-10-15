//! Reactor for async I/O operations
//! Handles epoll/kqueue/poll integration for non-blocking I/O

const std = @import("std");
const builtin = @import("builtin");

/// I/O events that can be monitored
pub const IoEvent = packed struct {
    readable: bool = false,
    writable: bool = false,
    error_condition: bool = false,
    hangup: bool = false,
};

/// File descriptor interest registration
pub const Interest = struct {
    fd: std.posix.fd_t,
    events: IoEvent,
    user_data: usize = 0,
};

/// I/O event result
pub const Event = struct {
    fd: std.posix.fd_t,
    events: IoEvent,
    user_data: usize,
};

/// Reactor configuration
pub const ReactorConfig = struct {
    max_events: u32 = 1024,
    use_io_uring: bool = false, // Future feature
};

/// Cross-platform reactor implementation
pub const Reactor = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    config: ReactorConfig,

    const Self = @This();

    /// Initialize the reactor
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self.initWithConfig(allocator, .{});
    }
    
    /// Initialize the reactor with configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: ReactorConfig) !Self {
        return Self{
            .allocator = allocator,
            .backend = try Backend.initWithConfig(allocator, config),
            .config = config,
        };
    }

    /// Deinitialize the reactor
    pub fn deinit(self: *Self) void {
        self.backend.deinit();
    }

    /// Register interest in a file descriptor
    pub fn register(self: *Self, interest: Interest) !void {
        return self.backend.register(interest);
    }

    /// Modify interest for an existing file descriptor
    pub fn modify(self: *Self, interest: Interest) !void {
        return self.backend.modify(interest);
    }

    /// Unregister a file descriptor
    pub fn unregister(self: *Self, fd: std.posix.fd_t) !void {
        return self.backend.unregister(fd);
    }

    /// Poll for I/O events
    pub fn poll(self: *Self, timeout_ms: i32) !u32 {
        return self.backend.poll(timeout_ms);
    }

    /// Get the next event from the last poll
    pub fn nextEvent(self: *Self) !?Event {
        return try self.backend.nextEvent();
    }
};

// Platform-specific backend implementations

const Backend = switch (builtin.os.tag) {
    .linux => EpollBackend,
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => KqueueBackend,
    else => PollBackend,
};

/// Linux epoll backend
const EpollBackend = struct {
    allocator: std.mem.Allocator,
    epoll_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    event_count: u32,
    event_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self.initWithConfig(allocator, .{});
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, config: ReactorConfig) !Self {
        const epoll_fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        const events = try allocator.alloc(std.os.linux.epoll_event, config.max_events);

        return Self{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .events = events,
            .event_count = 0,
            .event_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.epoll_fd);
        self.allocator.free(self.events);
    }

    pub fn register(self: *Self, interest: Interest) !void {
        var event = std.os.linux.epoll_event{
            .events = self.ioEventToEpoll(interest.events),
            .data = std.os.linux.epoll_data{ .ptr = interest.user_data },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, interest.fd, &event);
    }

    pub fn modify(self: *Self, interest: Interest) !void {
        var event = std.os.linux.epoll_event{
            .events = self.ioEventToEpoll(interest.events),
            .data = std.os.linux.epoll_data{ .ptr = interest.user_data },
        };

        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, interest.fd, &event);
    }

    pub fn unregister(self: *Self, fd: std.posix.fd_t) !void {
        // Note: event parameter is ignored in CTL_DEL but required by the API
        var dummy_event: std.os.linux.epoll_event = undefined;
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, &dummy_event);
    }

    pub fn poll(self: *Self, timeout_ms: i32) !u32 {
        const count = std.posix.epoll_wait(self.epoll_fd, self.events, timeout_ms);
        self.event_count = @intCast(count);
        self.event_index = 0;
        return self.event_count;
    }

    pub fn nextEvent(self: *Self) !?Event {
        if (self.event_index >= self.event_count) {
            return null;
        }

        const epoll_event = self.events[self.event_index];
        self.event_index += 1;

        return Event{
            .fd = @intCast(epoll_event.data.fd),
            .events = try self.epollToIoEvent(epoll_event.events),
            .user_data = epoll_event.data.ptr,
        };
    }

    fn ioEventToEpoll(self: *Self, events: IoEvent) u32 {
        _ = self;
        var epoll_events: u32 = 0;
        
        if (events.readable) epoll_events |= std.os.linux.EPOLL.IN;
        if (events.writable) epoll_events |= std.os.linux.EPOLL.OUT;
        if (events.error_condition) epoll_events |= std.os.linux.EPOLL.ERR;
        if (events.hangup) epoll_events |= std.os.linux.EPOLL.HUP;
        
        return epoll_events;
    }

    fn epollToIoEvent(self: *Self, epoll_events: u32) !IoEvent {
        _ = self;
        // Validate that we have recognized epoll events
        const valid_events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | 
                            std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | 
                            std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.PRI |
                            std.os.linux.EPOLL.ET | std.os.linux.EPOLL.ONESHOT;
        
        if (epoll_events & ~valid_events != 0) {
            return error.InvalidEpollEvents;
        }
        
        return IoEvent{
            .readable = (epoll_events & std.os.linux.EPOLL.IN) != 0,
            .writable = (epoll_events & std.os.linux.EPOLL.OUT) != 0,
            .error_condition = (epoll_events & std.os.linux.EPOLL.ERR) != 0,
            .hangup = (epoll_events & std.os.linux.EPOLL.HUP) != 0,
        };
    }
};

/// BSD/macOS kqueue backend
const KqueueBackend = struct {
    allocator: std.mem.Allocator,
    kqueue_fd: std.posix.fd_t,
    events: []std.posix.Kevent,
    event_count: u32,
    event_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self.initWithConfig(allocator, .{});
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, config: ReactorConfig) !Self {
        const kqueue_fd = try std.posix.kqueue();
        const events = try allocator.alloc(std.posix.Kevent, config.max_events);

        return Self{
            .allocator = allocator,
            .kqueue_fd = kqueue_fd,
            .events = events,
            .event_count = 0,
            .event_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.kqueue_fd);
        self.allocator.free(self.events);
    }

    pub fn register(self: *Self, interest: Interest) !void {
        var changes: [2]std.posix.Kevent = undefined;
        var change_count: usize = 0;

        if (interest.events.readable) {
            changes[change_count] = std.posix.Kevent{
                .ident = @intCast(interest.fd),
                .filter = std.posix.system.EVFILT_READ,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = interest.user_data,
            };
            change_count += 1;
        }

        if (interest.events.writable) {
            changes[change_count] = std.posix.Kevent{
                .ident = @intCast(interest.fd),
                .filter = std.posix.system.EVFILT_WRITE,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = interest.user_data,
            };
            change_count += 1;
        }

        if (change_count > 0) {
            _ = try std.posix.kevent(self.kqueue_fd, changes[0..change_count], &[_]std.posix.Kevent{}, null);
        }
    }

    pub fn modify(self: *Self, interest: Interest) !void {
        // For kqueue, modify is the same as register
        return self.register(interest);
    }

    pub fn unregister(self: *Self, fd: std.posix.fd_t) !void {
        const changes = [_]std.posix.Kevent{
            std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_READ,
                .flags = std.posix.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            std.posix.Kevent{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT_WRITE,
                .flags = std.posix.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };

        // Attempt to unregister events, but don't fail if fd was not registered
        const result = std.posix.kevent(self.kqueue_fd, &changes, &[_]std.posix.Kevent{}, null);
        if (result) |_| {
            // Successfully unregistered
        } else |err| switch (err) {
            error.FileDescriptorNotFound => {
                // Expected for fd not registered for this event type
            },
            else => {
                // Log error but don't fail - could be a genuine issue
                std.log.warn("Failed to unregister fd {}: {}", .{ fd, err });
            },
        }
    }

    pub fn poll(self: *Self, timeout_ms: i32) !u32 {
        const timeout = if (timeout_ms >= 0) 
            std.posix.timespec{ .tv_sec = @divTrunc(timeout_ms, 1000), .tv_nsec = (@mod(timeout_ms, 1000)) * 1_000_000 }
        else 
            null;

        const count = try std.posix.kevent(self.kqueue_fd, &[_]std.posix.Kevent{}, self.events, if (timeout) |*ts| ts else null);
        self.event_count = @intCast(count);
        self.event_index = 0;
        return self.event_count;
    }

    pub fn nextEvent(self: *Self) ?Event {
        if (self.event_index >= self.event_count) {
            return null;
        }

        const kevent = self.events[self.event_index];
        self.event_index += 1;

        var events = IoEvent{};
        if (kevent.filter == std.posix.system.EVFILT_READ) events.readable = true;
        if (kevent.filter == std.posix.system.EVFILT_WRITE) events.writable = true;
        if ((kevent.flags & std.posix.system.EV_EOF) != 0) events.hangup = true;
        if ((kevent.flags & std.posix.system.EV_ERROR) != 0) events.error_condition = true;

        return Event{
            .fd = @intCast(kevent.ident),
            .events = events,
            .user_data = kevent.udata,
        };
    }
};

/// Fallback poll backend for other platforms
const PollBackend = struct {
    allocator: std.mem.Allocator,
    poll_fds: std.ArrayList(std.posix.pollfd),
    user_data: std.ArrayList(usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self.initWithConfig(allocator, .{});
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, config: ReactorConfig) !Self {
        _ = config; // PollBackend doesn't need max_events configuration
        return Self{
            .allocator = allocator,
            .poll_fds = std.ArrayList(std.posix.pollfd){ .allocator = allocator },
            .user_data = std.ArrayList(usize){ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.poll_fds.deinit();
        self.user_data.deinit();
    }

    pub fn register(self: *Self, interest: Interest) !void {
        var events: i16 = 0;
        if (interest.events.readable) events |= std.posix.POLL.IN;
        if (interest.events.writable) events |= std.posix.POLL.OUT;

        try self.poll_fds.append(self.allocator, .{
            .fd = interest.fd,
            .events = events,
            .revents = 0,
        });
        try self.user_data.append(self.allocator, interest.user_data);
    }

    pub fn modify(self: *Self, interest: Interest) !void {
        for (self.poll_fds.items, 0..) |*pfd, i| {
            if (pfd.fd == interest.fd) {
                var events: i16 = 0;
                if (interest.events.readable) events |= std.posix.POLL.IN;
                if (interest.events.writable) events |= std.posix.POLL.OUT;
                
                pfd.events = events;
                self.user_data.items[i] = interest.user_data;
                return;
            }
        }
        return error.NotFound;
    }

    pub fn unregister(self: *Self, fd: std.posix.fd_t) !void {
        var i: usize = 0;
        while (i < self.poll_fds.items.len) {
            if (self.poll_fds.items[i].fd == fd) {
                _ = self.poll_fds.orderedRemove(i);
                _ = self.user_data.orderedRemove(i);
                return;
            }
            i += 1;
        }
        return error.NotFound;
    }

    pub fn poll(self: *Self, timeout_ms: i32) !u32 {
        if (self.poll_fds.items.len == 0) return 0;
        
        const result = try std.posix.poll(self.poll_fds.items, timeout_ms);
        return @intCast(result);
    }

    pub fn nextEvent(self: *Self) ?Event {
        for (self.poll_fds.items, 0..) |*pfd, i| {
            if (pfd.revents != 0) {
                const events = IoEvent{
                    .readable = (pfd.revents & std.posix.POLL.IN) != 0,
                    .writable = (pfd.revents & std.posix.POLL.OUT) != 0,
                    .error_condition = (pfd.revents & std.posix.POLL.ERR) != 0,
                    .hangup = (pfd.revents & std.posix.POLL.HUP) != 0,
                };

                const event = Event{
                    .fd = pfd.fd,
                    .events = events,
                    .user_data = self.user_data.items[i],
                };

                // Clear revents for next poll
                pfd.revents = 0;
                return event;
            }
        }
        return null;
    }
};

// Tests
test "reactor creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var reactor = try Reactor.init(allocator);
    defer reactor.deinit();
}

test "io event conversion" {
    const event = IoEvent{
        .readable = true,
        .writable = false,
        .error_condition = false,
        .hangup = false,
    };
    
    const testing = std.testing;
    try testing.expect(event.readable);
    try testing.expect(!event.writable);
}
