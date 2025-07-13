# zsync - Zig Async Runtime for the Future

## 🎯 Goal:

Develop a modern, performant async runtime in **Zig** that aligns with Zig's upcoming `std.Io` interface design. zsync bridges current Zig async capabilities with the future direction outlined in Zig 0.15+ roadmap.

## 🔍 Overview:

zsync is built to support Zig's new async I/O paradigm:

* **Dependency Injection**: `std.Io` interface provided by caller
* **Execution Model Independence**: Same code works with blocking, threaded, or async I/O
* **Colorblind Async**: No viral async/await spreading through codebase
* **Multiple I/O Backends**: blocking, thread pool, green threads, stackless coroutines
* **Modern Abstractions**:
  * `io.async(fn, args)` - spawn async operations
  * `future.await(io)` - await completion
  * `future.cancel(io)` - proper cancellation
  * High-precision timers and channels

## 📦 Core Architecture:

### 1. `zsync.zig`

* Runtime entry point and main interface
* Multiple `std.Io` implementations
* Execution model selection

### 2. `io/`

* `blocking.zig` - Direct syscall mapping (zero overhead)
* `thread_pool.zig` - OS thread-based parallelism
* `green_threads.zig` - Stack-swapping coroutines (Linux x86_64)
* `stackless.zig` - Future WASM-compatible coroutines

### 3. `executor.zig`

* Task scheduling and waker system
* Future management and cancellation
* Cross-platform event loop abstraction

### 4. `time.zig`

* High-resolution timers
* Sleep and timeout operations
* Timer wheel implementation

### 5. `net/`

* `tcp.zig` - Non-blocking TCP with io_uring/epoll
* `udp.zig` - UDP socket operations
* `quic.zig` - QUIC protocol support (future)

### 6. `sync/`

* `channel.zig` - Async channels (mpsc/spsc)
* `mutex.zig` - Async-aware synchronization
* `semaphore.zig` - Resource limiting

## 💡 Key Features (v0.1.0):

* **Future-Ready API**: Compatible with Zig's upcoming `std.Io` interface
* **Multiple Execution Models**: blocking, thread pool, green threads
* **Colorblind Async**: Same code works across all execution models
* **Zero-Cost Abstractions**: Blocking I/O compiles to C-equivalent code
* **io_uring Integration**: High-performance async I/O on Linux
* **Proper Cancellation**: Resource cleanup with `defer future.cancel(io)`
* **Cross-Platform**: Linux, macOS, Windows support planned

## 🚀 Roadmap to v0.2.0:

* **Zig 0.15 Alignment**: Full `std.Io` interface compatibility
* **Stackless Coroutines**: WASM-compatible execution model
* **Advanced I/O**: `sendFile`, vectorized writes, buffer management
* **Multi-Platform**: Complete macOS and Windows support
* **HTTP/3 & QUIC**: Modern networking protocols
* **Production Hardening**: Memory safety, error handling, monitoring

---

This KB defines the architecture, design goals, and starter prompt for building a full-featured Zig async runtime. Ideal for Copilot, GPT-4, or any code-gen LLM.

Let me know when you're ready to scaffold the repo or want to generate the core files automatically.

