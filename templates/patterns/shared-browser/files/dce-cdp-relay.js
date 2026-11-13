// dce-cdp-relay.js <listen-port> <target-port>: expose a loopback-bound
// Chromium DevTools endpoint on 0.0.0.0:<listen-port>. Rewrites the client
// request's Host header to <container-ip>:<listen-port> so Chromium accepts
// it and advertises a webSocketDebuggerUrl that routes back through here.
'use strict';
const net = require('net');
const os = require('os');

const listenPort = Number(process.argv[2]);
const targetPort = Number(process.argv[3]);
if (!Number.isInteger(listenPort) || !Number.isInteger(targetPort)) {
  console.error('usage: dce-cdp-relay.js <listen-port> <target-port>');
  process.exit(1);
}

// Primary container IPv4, eth0 first. Used as the rewritten Host value.
const advertiseIp = (() => {
  const ifaces = os.networkInterfaces();
  const pick = (addrs) =>
    addrs && addrs.find((a) => a.family === 'IPv4' && !a.internal);
  for (const name of Object.keys(ifaces)) {
    const hit = pick(ifaces[name]);
    if (hit) return hit.address;
  }
  return '127.0.0.1';
})();

const server = net.createServer((client) => {
  // Chromium binds DevTools to loopback but picks IPv4 or IPv6 per run
  // (127.0.0.1 or ::1), so try both families on every connection.
  const targets = ['127.0.0.1', '::1'];
  let upstream = null;
  let raw = false; // switch to raw pipe once the request head is handled
  let headDone = false;
  let headBuf = Buffer.alloc(0);
  let headOut = null;
  let tailBuf = Buffer.alloc(0);

  const teardown = () => {
    client.destroy();
    if (upstream) upstream.destroy();
  };
  client.on('error', teardown);

  const flush = () => {
    // Raw mode is entered exactly once; upstream.pipe(client) is already
    // attached by the connect handler, so only the rewritten head and the
    // client->upstream pipe are added here.
    if (raw || !headDone || !upstreamConnected) return;
    raw = true;
    client.removeListener('data', onData);
    upstream.write(Buffer.concat([headOut, tailBuf]));
    client.pipe(upstream);
  };

  let upstreamConnected = false;
  function onData(chunk) {
    if (raw) return;
    headBuf = Buffer.concat([headBuf, chunk]);
    const idx = headBuf.indexOf('\r\n\r\n');
    if (idx === -1) {
      // HTTP request heads are tiny; a runt this big is not CDP traffic.
      if (headBuf.length > 32768) teardown();
      return;
    }
    const head = headBuf.slice(0, idx + 4).toString('latin1').replace(
      /^Host:[^\r\n]*/im,
      `Host: ${advertiseIp}:${listenPort}`
    );
    headOut = Buffer.from(head, 'latin1');
    tailBuf = headBuf.slice(idx + 4);
    headDone = true;
    flush();
  }
  client.on('data', onData);

  const connect = (i) => {
    // localAddress pins the SOURCE to loopback: Chromium's DevTools closes
    // WS sessions from non-loopback peers even after a 101 handshake, and
    // the relay's egress would otherwise show the container's eth0 IP.
    const s = net.connect({
      port: targetPort,
      host: targets[i],
      localAddress: targets[i],
    });
    upstream = s;
    s.once('error', (err) => {
      // Fall back to the other loopback family; give up if both refuse.
      if (err.code === 'ECONNREFUSED' && i + 1 < targets.length) {
        connect(i + 1);
        return;
      }
      teardown();
    });
    s.once('connect', () => {
      upstreamConnected = true;
      s.on('close', () => client.end());
      client.on('close', () => s.end());
      s.pipe(client); // responses are forwarded untouched
      flush();
    });
  };
  connect(0);
});
server.listen(listenPort, '0.0.0.0');
