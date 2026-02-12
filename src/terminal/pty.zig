//! Zsync v0.6.0 - PTY (Pseudo-Terminal) Support
//! Async PTY operations for Ghostshell terminal emulator

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../runtime.zig").Runtime;

/// PTY Configuration
pub const PtyConfig = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    pixel_width: u16 = 0,
    pixel_height: u16 = 0,
    env: ?std.StringHashMap([]const u8) = null,
    cwd: ?[]const u8 = null,
};

/// Window Size
pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// PTY Handle
pub const Pty = struct {
    allocator: std.mem.Allocator,
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
    child_pid: ?std.posix.pid_t,
    config: PtyConfig,
    read_buffer: []u8,
    mutex: compat.Mutex,

    const Self = @This();

    /// Create new PTY
    pub fn init(allocator: std.mem.Allocator, config: PtyConfig) !Self {
        if (builtin.os.tag != .linux) {
            return error.PlatformNotSupported;
        }

        // Open PTY master
        const master_fd = try std.posix.open("/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0);
        errdefer std.posix.close(master_fd);

        // Grant access to slave
        if (std.posix.system.grantpt(master_fd) != 0) {
            return error.GrantPtFailed;
        }

        // Unlock slave
        if (std.posix.system.unlockpt(master_fd) != 0) {
            return error.UnlockPtFailed;
        }

        // Get slave name
        var slave_name_buf: [256]u8 = undefined;
        _ = std.posix.system.ptsname_r(master_fd, &slave_name_buf, slave_name_buf.len);
        const slave_name = std.mem.sliceTo(&slave_name_buf, 0);

        // Open slave
        const slave_fd = try std.posix.open(slave_name, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0);

        // Set window size
        const ws = Winsize{
            .ws_row = config.rows,
            .ws_col = config.cols,
            .ws_xpixel = config.pixel_width,
            .ws_ypixel = config.pixel_height,
        };

        const TIOCSWINSZ = 0x5414;
        _ = std.posix.system.ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&ws));

        const buffer = try allocator.alloc(u8, 4096);

        return Self{
            .allocator = allocator,
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .child_pid = null,
            .config = config,
            .read_buffer = buffer,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.read_buffer);
        std.posix.close(self.master_fd);
        std.posix.close(self.slave_fd);
    }

    /// Spawn process in PTY
    pub fn spawn(self: *Self, argv: []const []const u8) !void {
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process
            _ = std.posix.system.setsid();

            // Set controlling terminal
            const TIOCSCTTY = 0x540E;
            _ = std.posix.system.ioctl(self.slave_fd, TIOCSCTTY, 0);

            // Redirect stdio
            try std.posix.dup2(self.slave_fd, std.posix.STDIN_FILENO);
            try std.posix.dup2(self.slave_fd, std.posix.STDOUT_FILENO);
            try std.posix.dup2(self.slave_fd, std.posix.STDERR_FILENO);

            // Close master
            std.posix.close(self.master_fd);
            if (self.slave_fd > 2) {
                std.posix.close(self.slave_fd);
            }

            // Change directory if specified
            if (self.config.cwd) |cwd| {
                std.posix.chdir(cwd) catch {};
            }

            // Execute
            const err = std.posix.execvpeZ(argv[0], argv, std.os.environ);
            std.debug.print("exec failed: {}\n", .{err});
            std.posix.exit(1);
        } else {
            // Parent process
            self.child_pid = pid;
            std.posix.close(self.slave_fd);
        }
    }

    /// Read from PTY (async)
    pub fn read(self: *Self) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const n = try std.posix.read(self.master_fd, self.read_buffer);
        if (n == 0) return error.EndOfFile;

        return self.read_buffer[0..n];
    }

    /// Write to PTY (async)
    pub fn write(self: *Self, data: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return try std.posix.write(self.master_fd, data);
    }

    /// Resize PTY
    pub fn resize(self: *Self, rows: u16, cols: u16) !void {
        const ws = Winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = self.config.pixel_width,
            .ws_ypixel = self.config.pixel_height,
        };

        self.config.rows = rows;
        self.config.cols = cols;

        const TIOCSWINSZ = 0x5414;
        const result = std.posix.system.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
        if (result != 0) return error.ResizeFailed;
    }

    /// Check if child is alive
    pub fn isAlive(self: *const Self) bool {
        if (self.child_pid) |pid| {
            var status: i32 = 0;
            const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
            return result == 0;
        }
        return false;
    }

    /// Wait for child to exit
    pub fn wait(self: *Self) !i32 {
        if (self.child_pid) |pid| {
            const result = std.posix.waitpid(pid, 0);
            return result.status;
        }
        return error.NoChild;
    }

    /// Kill child process
    pub fn kill(self: *Self, signal: i32) !void {
        if (self.child_pid) |pid| {
            try std.posix.kill(pid, signal);
        }
    }
};

/// Terminal Attributes Helper
pub const TermAttr = struct {
    termios: std.posix.termios,

    pub fn get(fd: std.posix.fd_t) !TermAttr {
        var termios: std.posix.termios = undefined;
        if (std.posix.system.tcgetattr(fd, &termios) != 0) {
            return error.TcGetAttrFailed;
        }
        return TermAttr{ .termios = termios };
    }

    pub fn set(self: TermAttr, fd: std.posix.fd_t) !void {
        const TCSANOW = 0;
        if (std.posix.system.tcsetattr(fd, TCSANOW, &self.termios) != 0) {
            return error.TcSetAttrFailed;
        }
    }

    /// Make terminal raw (disable echo, canonical mode, etc.)
    pub fn makeRaw(self: *TermAttr) void {
        // Disable echo
        self.termios.lflag.ECHO = false;
        self.termios.lflag.ICANON = false;
        self.termios.lflag.ISIG = false;
        self.termios.lflag.IEXTEN = false;

        // Disable input processing
        self.termios.iflag.BRKINT = false;
        self.termios.iflag.ICRNL = false;
        self.termios.iflag.INPCK = false;
        self.termios.iflag.ISTRIP = false;
        self.termios.iflag.IXON = false;

        // Disable output processing
        self.termios.oflag.OPOST = false;

        // Set 8-bit characters
        self.termios.cflag.CS8 = true;

        // Minimal read
        self.termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        self.termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    }
};

// Tests
test "pty winsize" {
    const ws = Winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const testing = std.testing;
    try testing.expectEqual(24, ws.ws_row);
    try testing.expectEqual(80, ws.ws_col);
}
