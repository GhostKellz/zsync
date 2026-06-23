// Minimal zsync WASM host adapter skeleton.
//
// This is not a full transport stack. It shows the concrete ABI shape a browser
// or native JavaScript host must provide under the `env` import namespace.

export function createZsyncEnv(instanceRef) {
  const tcp = new Map();
  const ws = new Map();
  let nextHandle = 1;

  const memory = () => instanceRef.instance.exports.memory;
  const bytes = () => new Uint8Array(memory().buffer);
  const text = (ptr, len) => new TextDecoder().decode(bytes().subarray(ptr, ptr + len));
  const copyIn = (ptr, data) => bytes().set(data, ptr);

  const allocHandle = (table, value) => {
    const handle = nextHandle++;
    table.set(handle, value);
    return handle;
  };

  return {
    zsync_sleep_ms(ms) {
      // Synchronous WASM imports cannot await. Production adapters should either
      // run WASM in a worker and block with Atomics.wait, or expose async through
      // a host scheduling layer that re-enters the guest when ready.
      const end = Date.now() + Number(ms);
      while (Date.now() < end) {}
    },

    zsync_fetch(methodPtr, methodLen, urlPtr, urlLen, bodyPtr, bodyLen, statusOut, lenOut) {
      void methodPtr;
      void methodLen;
      void urlPtr;
      void urlLen;
      void bodyPtr;
      void bodyLen;
      void statusOut;
      void lenOut;
      return -1; // Async fetch requires a real adapter queue.
    },

    zsync_fetch_read(handle, dest, len) {
      void handle;
      void dest;
      void len;
    },

    zsync_fetch_free(handle) {
      void handle;
    },

    zsync_tcp_connect(hostPtr, hostLen, port, tls) {
      void port;
      void tls;
      const host = text(hostPtr, hostLen);
      void host;
      return -1; // Browsers do not expose raw TCP. Native hosts can fill this.
    },

    zsync_tcp_send(handle, dataPtr, dataLen) {
      void handle;
      void dataPtr;
      void dataLen;
      return -1;
    },

    zsync_tcp_recv(handle, bufPtr, bufLen) {
      void handle;
      void bufPtr;
      void bufLen;
      return -1;
    },

    zsync_tcp_close(handle) {
      tcp.delete(handle);
    },

    zsync_ws_open(urlPtr, urlLen) {
      const socket = new WebSocket(text(urlPtr, urlLen));
      socket.binaryType = "arraybuffer";
      socket.zsyncQueue = [];
      socket.onmessage = (event) => {
        const data = typeof event.data === "string"
          ? new TextEncoder().encode(event.data)
          : new Uint8Array(event.data);
        socket.zsyncQueue.push(data);
      };
      return allocHandle(ws, socket);
    },

    zsync_ws_send(handle, dataPtr, dataLen, isBinary) {
      const socket = ws.get(handle);
      if (!socket || socket.readyState !== WebSocket.OPEN) return -1;
      const data = bytes().slice(dataPtr, dataPtr + dataLen);
      socket.send(isBinary ? data : new TextDecoder().decode(data));
      return dataLen;
    },

    zsync_ws_recv(handle, bufPtr, bufLen) {
      const socket = ws.get(handle);
      if (!socket || socket.zsyncQueue.length === 0) return -1;
      const data = socket.zsyncQueue.shift();
      const n = Math.min(bufLen, data.length);
      copyIn(bufPtr, data.subarray(0, n));
      return n;
    },

    zsync_ws_close(handle) {
      const socket = ws.get(handle);
      if (socket) socket.close();
      ws.delete(handle);
    },

    zsync_udp_bind(ipPtr, ipLen, port) {
      void ipPtr;
      void ipLen;
      void port;
      return -1;
    },

    zsync_udp_send(handle, dataPtr, dataLen, ipPtr, ipLen, port) {
      void handle;
      void dataPtr;
      void dataLen;
      void ipPtr;
      void ipLen;
      void port;
      return -1;
    },

    zsync_udp_recv(handle, bufPtr, bufLen, ipOut, ipOutLen, ipLenOut, portOut) {
      void handle;
      void bufPtr;
      void bufLen;
      void ipOut;
      void ipOutLen;
      void ipLenOut;
      void portOut;
      return -1;
    },

    zsync_udp_close(handle) {
      void handle;
    },

    zsync_dns_resolve(hostPtr, hostLen, outPtr, outLen, countOut) {
      void hostPtr;
      void hostLen;
      void outPtr;
      void outLen;
      void countOut;
      return -1;
    },
  };
}
