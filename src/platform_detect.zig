//! Platform Detection Module for Zsync v0.6.0
//! Detects distributions, package managers, and system capabilities

const std = @import("std");
const builtin = @import("builtin");

/// Linux distribution information
pub const LinuxDistro = enum {
    arch,
    debian,
    ubuntu,
    fedora,
    rhel,
    centos,
    opensuse,
    gentoo,
    alpine,
    nixos,
    void,
    manjaro,
    mint,
    pop_os,
    elementary,
    kali,
    parrot,
    unknown,
};

/// System capabilities
pub const SystemCapabilities = struct {
    distro: LinuxDistro,
    kernel_version: KernelVersion,
    has_io_uring: bool,
    has_epoll: bool,
    has_systemd: bool,
    cpu_count: u32,
    total_memory: u64,
    
    pub const KernelVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,
        
        pub fn supports_io_uring(self: KernelVersion) bool {
            // io_uring requires kernel 5.1+
            return self.major > 5 or (self.major == 5 and self.minor >= 1);
        }
        
        pub fn supports_io_uring_advanced(self: KernelVersion) bool {
            // Advanced features like IORING_SETUP_SQPOLL require 5.11+
            return self.major > 5 or (self.major == 5 and self.minor >= 11);
        }
    };
};

/// Detect the current Linux distribution
pub fn detectLinuxDistro() LinuxDistro {
    // Try /etc/os-release first (systemd standard)
    if (parseOsRelease()) |distro| {
        return distro;
    }
    
    // Try legacy detection methods
    if (std.fs.accessAbsolute("/etc/arch-release", .{})) |_| {
        return .arch;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/debian_version", .{})) |_| {
        return .debian;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/fedora-release", .{})) |_| {
        return .fedora;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/redhat-release", .{})) |_| {
        // Could be RHEL, CentOS, or Fedora
        const content = std.fs.cwd().readFileAlloc(
            "/etc/redhat-release",
            std.heap.page_allocator,
            std.Io.Limit.limited(1024)
        ) catch return .unknown;
        defer std.heap.page_allocator.free(content);
        
        if (std.mem.indexOf(u8, content, "Fedora") != null) return .fedora;
        if (std.mem.indexOf(u8, content, "CentOS") != null) return .centos;
        if (std.mem.indexOf(u8, content, "Red Hat") != null) return .rhel;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/gentoo-release", .{})) |_| {
        return .gentoo;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/alpine-release", .{})) |_| {
        return .alpine;
    } else |_| {}
    
    if (std.fs.accessAbsolute("/etc/void-release", .{})) |_| {
        return .void;
    } else |_| {}
    
    return .unknown;
}

/// Parse /etc/os-release for distribution information
fn parseOsRelease() ?LinuxDistro {
    const file = std.fs.openFileAbsolute("/etc/os-release", .{}) catch return null;
    defer file.close();
    
    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];
    
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID=")) {
            const id = line[3..];
            const distro_id = std.mem.trim(u8, id, "\"");
            
            return parseDistroId(distro_id);
        }
    }
    
    return null;
}

/// Parse distribution ID string
fn parseDistroId(id: []const u8) LinuxDistro {
    if (std.mem.eql(u8, id, "arch")) return .arch;
    if (std.mem.eql(u8, id, "debian")) return .debian;
    if (std.mem.eql(u8, id, "ubuntu")) return .ubuntu;
    if (std.mem.eql(u8, id, "fedora")) return .fedora;
    if (std.mem.eql(u8, id, "rhel")) return .rhel;
    if (std.mem.eql(u8, id, "centos")) return .centos;
    if (std.mem.eql(u8, id, "opensuse") or std.mem.eql(u8, id, "opensuse-leap") or std.mem.eql(u8, id, "opensuse-tumbleweed")) return .opensuse;
    if (std.mem.eql(u8, id, "gentoo")) return .gentoo;
    if (std.mem.eql(u8, id, "alpine")) return .alpine;
    if (std.mem.eql(u8, id, "nixos")) return .nixos;
    if (std.mem.eql(u8, id, "void")) return .void;
    if (std.mem.eql(u8, id, "manjaro")) return .manjaro;
    if (std.mem.eql(u8, id, "linuxmint")) return .mint;
    if (std.mem.eql(u8, id, "pop")) return .pop_os;
    if (std.mem.eql(u8, id, "elementary")) return .elementary;
    if (std.mem.eql(u8, id, "kali")) return .kali;
    if (std.mem.eql(u8, id, "parrot")) return .parrot;
    
    return .unknown;
}

/// Get kernel version
pub fn getKernelVersion() SystemCapabilities.KernelVersion {
    const uname = std.posix.uname();
    
    // Parse kernel version from uname.release
    // Format: major.minor.patch-extra
    var iter = std.mem.tokenizeAny(u8, &uname.release, ".-");
    const major = std.fmt.parseInt(u32, iter.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, iter.next() orelse "0", 10) catch 0;
    const patch = std.fmt.parseInt(u32, iter.next() orelse "0", 10) catch 0;
    
    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

/// Detect full system capabilities
pub fn detectSystemCapabilities() SystemCapabilities {
    const distro = if (builtin.os.tag == .linux) detectLinuxDistro() else .unknown;
    const kernel = getKernelVersion();
    
    return .{
        .distro = distro,
        .kernel_version = kernel,
        .has_io_uring = builtin.os.tag == .linux and kernel.supports_io_uring(),
        .has_epoll = builtin.os.tag == .linux,
        .has_systemd = checkSystemd(),
        .cpu_count = @intCast(std.Thread.getCpuCount() catch 1),
        .total_memory = getTotalMemory(),
    };
}

/// Check if systemd is available
fn checkSystemd() bool {
    if (builtin.os.tag != .linux) return false;
    
    // Check for systemd by looking for systemctl
    std.fs.accessAbsolute("/usr/bin/systemctl", .{}) catch return false;
    return true;
}

/// Get total system memory
fn getTotalMemory() u64 {
    if (builtin.os.tag != .linux) return 0;
    
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
    defer file.close();
    
    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return 0;
    const content = buf[0..bytes_read];
    
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            _ = parts.next(); // Skip "MemTotal:"
            const mem_kb = parts.next() orelse return 0;
            const kb = std.fmt.parseInt(u64, mem_kb, 10) catch return 0;
            return kb * 1024; // Convert to bytes
        }
    }
    
    return 0;
}

/// Get optimal settings for specific distributions
pub fn getDistroOptimalSettings(distro: LinuxDistro) DistroSettings {
    return switch (distro) {
        .arch => .{
            // Arch Linux: bleeding edge, aggressive optimizations
            .prefer_io_uring = true,
            .aggressive_threading = true,
            .buffer_size = 8192,
            .use_huge_pages = true,
        },
        .fedora => .{
            // Fedora: modern but stable
            .prefer_io_uring = true,
            .aggressive_threading = true,
            .buffer_size = 8192,
            .use_huge_pages = true,
        },
        .debian, .ubuntu => .{
            // Debian/Ubuntu: conservative, stability focused
            .prefer_io_uring = false, // Only on newer versions
            .aggressive_threading = false,
            .buffer_size = 4096,
            .use_huge_pages = false,
        },
        .gentoo => .{
            // Gentoo: highly optimized
            .prefer_io_uring = true,
            .aggressive_threading = true,
            .buffer_size = 16384,
            .use_huge_pages = true,
        },
        .alpine => .{
            // Alpine: minimal, musl-based
            .prefer_io_uring = false,
            .aggressive_threading = false,
            .buffer_size = 2048,
            .use_huge_pages = false,
        },
        .nixos => .{
            // NixOS: functional, reproducible
            .prefer_io_uring = true,
            .aggressive_threading = true,
            .buffer_size = 8192,
            .use_huge_pages = false,
        },
        else => .{
            // Default conservative settings
            .prefer_io_uring = false,
            .aggressive_threading = false,
            .buffer_size = 4096,
            .use_huge_pages = false,
        },
    };
}

pub const DistroSettings = struct {
    prefer_io_uring: bool,
    aggressive_threading: bool,
    buffer_size: usize,
    use_huge_pages: bool,
};

/// Print system information
pub fn printSystemInfo() void {
    if (builtin.os.tag != .linux) {
        std.debug.print("Platform: {} {}\n", .{ builtin.os.tag, builtin.cpu.arch });
        return;
    }

    const caps = detectSystemCapabilities();
    const settings = getDistroOptimalSettings(caps.distro);

    std.debug.print("🐧 Linux Distribution: {s}\n", .{@tagName(caps.distro)});
    std.debug.print("🔧 Kernel: {}.{}.{}\n", .{
        caps.kernel_version.major,
        caps.kernel_version.minor,
        caps.kernel_version.patch
    });
    std.debug.print("💾 CPU Cores: {}\n", .{caps.cpu_count});
    std.debug.print("🧠 Memory: {} MB\n", .{caps.total_memory / (1024 * 1024)});
    std.debug.print("⚡ io_uring: {}\n", .{caps.has_io_uring});
    std.debug.print("🔄 epoll: {}\n", .{caps.has_epoll});
    std.debug.print("🎯 Systemd: {}\n", .{caps.has_systemd});
    std.debug.print("\n📊 Optimal Settings for {s}:\n", .{@tagName(caps.distro)});
    std.debug.print("  • Prefer io_uring: {}\n", .{settings.prefer_io_uring});
    std.debug.print("  • Aggressive threading: {}\n", .{settings.aggressive_threading});
    std.debug.print("  • Buffer size: {} bytes\n", .{settings.buffer_size});
    std.debug.print("  • Huge pages: {}\n", .{settings.use_huge_pages});
}

/// Package manager types
pub const PackageManager = enum {
    homebrew,
    apt,
    pacman,
    yum,
    dnf,
    nix,
    guix,
    chocolatey,
    scoop,
    winget,
    unknown,
};

/// Package manager paths for common package managers
pub const PackageManagerPaths = struct {
    bin_path: []const u8,
    lib_path: []const u8,
    include_path: []const u8,

    pub fn forPackageManager(pm: PackageManager) ?PackageManagerPaths {
        return switch (pm) {
            .homebrew => .{
                .bin_path = if (builtin.cpu.arch == .aarch64)
                    "/opt/homebrew/bin"
                else
                    "/usr/local/bin",
                .lib_path = if (builtin.cpu.arch == .aarch64)
                    "/opt/homebrew/lib"
                else
                    "/usr/local/lib",
                .include_path = if (builtin.cpu.arch == .aarch64)
                    "/opt/homebrew/include"
                else
                    "/usr/local/include",
            },
            .apt => .{
                .bin_path = "/usr/bin",
                .lib_path = "/usr/lib",
                .include_path = "/usr/include",
            },
            .pacman => .{
                .bin_path = "/usr/bin",
                .lib_path = "/usr/lib",
                .include_path = "/usr/include",
            },
            .yum, .dnf => .{
                .bin_path = "/usr/bin",
                .lib_path = "/usr/lib64",
                .include_path = "/usr/include",
            },
            .nix => .{
                .bin_path = "/nix/var/nix/profiles/default/bin",
                .lib_path = "/nix/var/nix/profiles/default/lib",
                .include_path = "/nix/var/nix/profiles/default/include",
            },
            .chocolatey => .{
                .bin_path = "C:\\ProgramData\\chocolatey\\bin",
                .lib_path = "C:\\ProgramData\\chocolatey\\lib",
                .include_path = "",
            },
            .scoop => .{
                .bin_path = "%USERPROFILE%\\scoop\\shims",
                .lib_path = "%USERPROFILE%\\scoop",
                .include_path = "",
            },
            .winget => .{
                .bin_path = "C:\\Program Files\\WindowsApps",
                .lib_path = "",
                .include_path = "",
            },
            else => null,
        };
    }
};

/// Detect installed package manager
pub fn detectPackageManager() PackageManager {
    // Check for Homebrew (macOS/Linux)
    if (std.fs.accessAbsolute("/opt/homebrew/bin/brew", .{}) catch false or
        std.fs.accessAbsolute("/usr/local/bin/brew", .{}) catch false or
        std.fs.accessAbsolute("/home/linuxbrew/.linuxbrew/bin/brew", .{}) catch false)
    {
        return .homebrew;
    }

    // Check for apt (Debian/Ubuntu)
    if (std.fs.accessAbsolute("/usr/bin/apt", .{}) catch false or
        std.fs.accessAbsolute("/usr/bin/apt-get", .{}) catch false)
    {
        return .apt;
    }

    // Check for pacman (Arch Linux)
    if (std.fs.accessAbsolute("/usr/bin/pacman", .{}) catch false) {
        return .pacman;
    }

    // Check for dnf (Fedora 22+)
    if (std.fs.accessAbsolute("/usr/bin/dnf", .{}) catch false) {
        return .dnf;
    }

    // Check for yum (RHEL/CentOS/older Fedora)
    if (std.fs.accessAbsolute("/usr/bin/yum", .{}) catch false) {
        return .yum;
    }

    // Check for nix
    if (std.fs.accessAbsolute("/nix/var/nix/profiles/default/bin/nix", .{}) catch false or
        std.fs.accessAbsolute("/run/current-system/sw/bin/nix", .{}) catch false)
    {
        return .nix;
    }

    // Check for guix
    if (std.fs.accessAbsolute("/usr/bin/guix", .{}) catch false or
        std.fs.accessAbsolute("/var/guix/profiles/per-user/root/current-guix/bin/guix", .{}) catch false)
    {
        return .guix;
    }

    // Windows package managers
    if (builtin.os.tag == .windows) {
        // Check for Chocolatey
        if (std.fs.accessAbsolute("C:\\ProgramData\\chocolatey\\bin\\choco.exe", .{}) catch false) {
            return .chocolatey;
        }

        // Check for Scoop (in user profile)
        // Note: This is a simplified check
        if (std.posix.getenv("SCOOP")) |_| {
            return .scoop;
        }

        // Check for winget
        if (std.fs.accessAbsolute("C:\\Program Files\\WindowsApps", .{}) catch false) {
            return .winget;
        }
    }

    return .unknown;
}

// Tests
test "detect Linux distribution" {
    if (builtin.os.tag != .linux) return;
    
    const distro = detectLinuxDistro();
    std.debug.print("\nDetected distro: {s}\n", .{@tagName(distro)});
}

test "kernel version parsing" {
    const kernel = getKernelVersion();
    std.debug.print("\nKernel version: {}.{}.{}\n", .{ 
        kernel.major, 
        kernel.minor, 
        kernel.patch 
    });
    std.debug.print("Supports io_uring: {}\n", .{kernel.supports_io_uring()});
    std.debug.print("Supports advanced io_uring: {}\n", .{kernel.supports_io_uring_advanced()});
}

test "system capabilities" {
    if (builtin.os.tag != .linux) return;
    
    printSystemInfo();
}