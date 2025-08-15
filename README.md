# 🚀 Zsync v0.4.0 - "The Tokio of Zig"

![zig-version](https://img.shields.io/badge/zig-v0.12+-orange?style=flat-square)
[![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-green.svg?style=flat-square)](https://github.com/ziglang/zig)

**Complete Production-Ready Async Runtime with True Colorblind Async/Await**

Zsync v0.4.0 represents the **cutting edge of async programming in Zig**. Unlike traditional async runtimes, Zsync implements **true colorblind async** - the same code works identically across ALL execution models.

🎯 **Revolutionary Paradigm** • ⚡ **Excellent Performance** • 🚀 **Production Ready**

---

## ✨ What Makes Zsync v0.4.0 Special

### 🎯 Revolutionary Colorblind Async

```zig
// This EXACT code works in ALL execution models:
fn myTask(io: Io) !void {
    var future = try io.write("Hello World!");
    defer future.destroy(io.getAllocator());
    try future.await(); // Works everywhere!
}

// Run in blocking mode (C-equivalent performance)
try zsync.runBlocking(myTask, {});

// Run with thread pool (parallel execution)  
try zsync.runHighPerf(myTask, {});

// Run with automatic detection
try zsync.run(myTask, {}); // Detects optimal model
```

## 🌟 Core Features

### ⚡ Multiple Execution Models
- **Blocking**: Direct syscalls, C-equivalent performance
- **Thread Pool**: True parallelism with work-stealing threads
- **Green Threads**: Cooperative multitasking with io_uring (Linux)
- **Auto**: Intelligent runtime detection

### 📊 High-Performance I/O
- **Vectorized Operations**: `readv()`/`writev()` for multi-buffer I/O
- **Zero-Copy**: `sendfile()` and `copy_file_range()` on Linux  
- **Platform Optimizations**: Automatic detection for Arch, Fedora, Debian
- **Buffer Management**: Zero-allocation fast paths

### 🔗 Advanced Future System
- **Combinators**: `race()`, `all()`, `timeout()` for complex patterns
- **Cancellation**: Cooperative cancellation with propagation chains
- **Memory Safe**: Proper cleanup and lifecycle management

### 🐧 Platform Intelligence
- **Linux**: io_uring support, distribution-specific optimizations
- **Automatic Detection**: Kernel version, CPU count, capabilities

## 🚀 Quick Start

```zig
const std = @import("std");
const zsync = @import("src/runtime.zig");

fn fileProcessor(io: zsync.Io) !void {
    // Vectorized I/O operations
    var buffers = [_]zsync.IoBuffer{
        zsync.IoBuffer.init(&buffer1),
        zsync.IoBuffer.init(&buffer2),
    };
    
    var read_future = try io.readv(&buffers);
    defer read_future.destroy(io.getAllocator());
    try read_future.await();
    
    // Zero-copy operations (Linux)
    if (io.supportsZeroCopy()) {
        var copy_future = try io.copyFileRange(src_fd, dst_fd, size);
        defer copy_future.destroy(io.getAllocator());
        try copy_future.await();
    }
}

pub fn main() !void {
    try zsync.run(fileProcessor, {}); // Auto-detects best execution model
}
```

## 📈 Performance Benchmarks

**Validated on production hardware:**

```
🖥️  System: Arch Linux 6.16.0
💾 Hardware: 32 CPU cores, 63GB RAM
⚡ Features: io_uring support, zero-copy enabled

📊 Results:
   ✅ Vectorized I/O: 1000 operations, multiple buffers
   ✅ Zero-Copy: sendfile() 505 bytes transferred  
   ✅ Thread Pool: Work-stealing parallelization
   ✅ Platform Detection: Arch Linux optimizations
```

---

## 🔍 Goals

* Support native `async`/`await` with low overhead
* Build foundation for QUIC, HTTP/3, blockchain P2P protocols
* Modular runtime suitable for embedded systems, servers, and mesh agents
* Foundation layer for `Jarvis`, `GhostMesh`, and `Zion`-based apps

---

*zsync is actively developed for integration into the CK Technology & Ghostctl ecosystem.*

**Repository:** [github.com/ghostkellz/zsync](https://github.com/ghostkellz/zsync)
