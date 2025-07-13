# zsync Future Roadmap

## Alignment with Zig's New Async I/O

Based on Zig's `std.Io` interface design (Zig 0.15+), zsync is positioned to be the reference implementation for the new async paradigm. This document outlines our evolution strategy.

## Current State vs Future Vision

### Current zsync v0.1.x
- Foundation implementation with future-compatible API
- Multiple execution models (blocking, thread pool, green threads)
- Partial `std.Io` interface compatibility
- Works with Zig 0.15.x

### Future zsync v0.2.x
- Full `std.Io` interface implementation
- Stackless coroutines support (WASM-compatible)
- Complete colorblind async (zero function coloring)
- Production-ready for Zig 0.16+ applications

## Roadmap to v0.2.0

### Phase 1: v0.1.x Stabilization (Current - Q3 2025)
- [x] Implement core `io.async()` and `Future.await()` patterns
- [x] Blocking I/O implementation (C-equivalent performance)
- [x] Thread pool I/O with work stealing
- [x] Green threads with stack swapping (Linux x86_64)
- [ ] Enhanced error handling and resource management
- [ ] Comprehensive testing and benchmarking

### Phase 2: Zig 0.15 Alignment (Q4 2025)
- [ ] Full `std.Io` interface compatibility
- [ ] Integration with official Zig stdlib changes
- [ ] `Future.cancel()` with proper resource cleanup
- [ ] Advanced I/O operations (`sendFile`, vectorized writes)
- [ ] Cross-platform support (macOS, Windows)
- [ ] Performance optimization and de-virtualization

### Phase 3: Stackless Coroutines Integration (Target: Zig 0.16+)
- [ ] Stackless execution model implementation
  - [ ] Frame buffer management and recycling
  - [ ] Suspend/resume state machines
  - [ ] Integration with `@asyncFrameSize`, `@asyncInit`, etc.
- [ ] WASM compatibility layer
  - [ ] JavaScript event loop integration
  - [ ] Browser-compatible async operations
  - [ ] WebAssembly-specific optimizations
- [ ] Advanced features
  - [ ] Tail call optimization for async chains
  - [ ] Zero-allocation fast paths
  - [ ] Memory-efficient frame reuse

### Phase 4: Production Readiness (Target: v0.2.0 Stable)
- [ ] Multi-platform green threads (ARM64, Windows, macOS)
- [ ] Guaranteed de-virtualization in single-Io programs
- [ ] Advanced buffer management and zero-copy operations
- [ ] Hybrid execution models (stackful + stackless)
- [ ] HTTP/3, QUIC, and modern networking protocols

### Phase 5: Ecosystem Maturity
- [ ] Integration with major Zig projects
- [ ] Community-driven I/O implementations
- [ ] Educational content and best practices
- [ ] Real-world application examples
- [ ] Long-term maintenance and evolution strategy

## Technical Considerations

### Key Design Principles
1. **Execution Model Independence**: Same code works with blocking, threaded, or async I/O
2. **Zero Function Coloring**: No viral async/await spreading through codebase
3. **Resource Management**: Proper cancellation and cleanup via defer patterns
4. **Performance**: Leverage guaranteed de-virtualization when possible

### Implementation Strategy

#### zsync v0.2.x API Design
```zig
// zsync v0.2 API structure aligned with std.Io
const zsync = @import("zsync");
const std = @import("std");

// Various Io implementations
const BlockingIo = zsync.BlockingIo;
const ThreadPoolIo = zsync.ThreadPoolIo;
const GreenThreadsIo = zsync.GreenThreadsIo;
const StacklessIo = zsync.StacklessIo; // WASM-compatible

// Colorblind async - same code works everywhere
fn saveData(io: std.Io, data: []const u8) !void {
    var a_future = io.async(saveFile, .{io, data, "saveA.txt"});
    defer a_future.cancel(io) catch {};
    
    var b_future = io.async(saveFile, .{io, data, "saveB.txt"});
    defer b_future.cancel(io) catch {};
    
    try a_future.await(io);
    try b_future.await(io);
    
    const out: std.Io.File = .stdout();
    try out.writeAll(io, "save complete");
}
```

#### Low-Level Stackless Primitives (Future Integration)
```zig
// Low-level stackless coroutine integration
const std = @import("std");

fn stacklessTask(data: *anyopaque) void {
    const frame = @asyncFrame() orelse unreachable;
    
    // Suspend with context data
    const result = @asyncSuspend(data);
    
    // Process resumed with result
    handleResult(result);
}

fn runStacklessAsync(allocator: Allocator, func: anytype) !void {
    const frame_size = @asyncFrameSize(func);
    const frame_buf = try allocator.alloc(u8, frame_size);
    defer allocator.free(frame_buf);
    
    const frame = @asyncInit(frame_buf, func);
    
    // Start execution
    var suspend_data = @asyncResume(frame, &initial_data);
    
    while (suspend_data) |data| {
        // Handle suspended operation
        const result = handleSuspension(data);
        
        // Resume with result
        suspend_data = @asyncResume(frame, result);
    }
    // Function completed
}
```

### Migration Path
- **v1.x**: Continue maintenance for current Zig versions
- **v2.0-alpha**: Early adopter version with Zig 0.15+
- **v2.0**: Stable release aligned with Zig's async redesign
- **v1.x EOL**: Deprecate once v2.x is stable and widely adopted

## Success Metrics

### Technical Goals
- [ ] Zero overhead blocking implementation (equivalent to C)
- [ ] Efficient green threads with stack swapping
- [ ] WASM-compatible stackless coroutines
- [ ] Single codebase works across all execution models

### Ecosystem Goals
- [ ] Reference implementation for Zig's new async patterns
- [ ] Smooth migration path for existing users
- [ ] Educational resources for the new paradigm
- [ ] Community adoption of colorblind async practices

## Timeline Estimates

- **Q3 2025**: zsync v0.1.0 stable - core functionality complete
- **Q4 2025**: Zig 0.15 release, zsync v0.1.x updates for compatibility
- **Q1 2026**: zsync v0.2.0-alpha with full `std.Io` implementation
- **Q2 2026**: zsync v0.2.0-beta with stackless coroutines
- **Q3 2026**: zsync v0.2.0 stable - production ready
- **H2 2026**: Ecosystem adoption and advanced features

## Notes

This roadmap is subject to change based on:
- Zig language development timeline
- Community feedback and adoption
- Technical challenges discovered during implementation
- Ecosystem needs and priorities

The goal is to establish zsync as the reference implementation for Zig's new async I/O paradigm, providing a smooth path from current async patterns to the future colorblind async ecosystem.