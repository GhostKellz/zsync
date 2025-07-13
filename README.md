# zsync — Asynchronous Runtime for Zig

![zig-version](https://img.shields.io/badge/zig-v0.15.0-blue?style=flat-square)

**zsync** is a blazing fast, lightweight, and modular async runtime for [Zig](https://ziglang.org), inspired by Rust's [Tokio](https://tokio.rs), but optimized for Zig's zero-cost abstractions and manual memory control.

zsync is built to serve as the backbone for event-driven applications: from microservices and HTTP/QUIC servers to embedded and blockchain nodes.

> **Note:** tokioZ v1 is still maintained as a legacy implementation for existing projects. zsync v0.1 represents the new clean implementation.

---

## 🚀 Features

* 🔁 **Task Executor** – spawn, yield, await
* ⏱ **High-resolution Timers** – delay, timeout, interval
* 📬 **Channel System** – `Sender`/`Receiver` patterns
* 📡 **Non-blocking I/O** – async TCP, UDP, QUIC\*
* 🧠 **Waker API** – integrates with Zig's async/await and `@asyncCall`
* 🧩 **Composable Futures** – future combinators and polling
* 🧰 **Custom Event Loop** – configurable per-core executor
* 🌐 **Pluggable I/O Backend** – epoll, kqueue, io\_uring (planned)

> ✨ Future Support: TLS (via `zcrypto`), HTTP3 (via `zquic`), DNS (via `zigDNS`), async-native `zion` library integration

---

## 🔧 Architecture

```
zsync
├── zsync.zig           # Runtime entry point
├── executor.zig        # Task queue, waker, async poller
├── time.zig            # Delay, Interval, Sleep
├── net/
│   ├── tcp.zig         # Non-blocking TCP
│   ├── udp.zig         # Non-blocking UDP
│   └── quic.zig        # [Planned] QUIC via zquic
├── task/
│   ├── future.zig      # Future trait, combinators
│   ├── waker.zig       # Waker implementation
│   └── spawner.zig     # spawn(), join_handle
└── util/               # Internal utilities
```

---

## 🧪 Example Usage

```zig
const zsync = @import("zsync");

pub fn main() !void {
    try zsync.runtime.run(async {
        const tcp = try zsync.net.TcpStream.connect("127.0.0.1", 8080);
        try tcp.writeAll("ping");
        const buf = try tcp.readAll();
        std.debug.print("received: {}\n", .{buf});
    });
}
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
