const http = require("http");
const fs = require("fs");
const { WebSocketServer } = require("ws");

const PORT = Number(process.env.SERVER_PORT || process.env.PORT || 2044);
const HOST = "0.0.0.0";

let activeSender = null;
let packetCount = 0;
let bytesReceived = 0;
let connectedAt = 0;

const httpServer = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end(JSON.stringify({
      ok: true,
      senderConnected: !!activeSender,
      viewers: Math.max(0, [...wss.clients].filter(x => !x.isSender).length),
      packets: packetCount,
      bytes: bytesReceived
    }));
    return;
  }

  if (req.url === "/" || req.url === "/viewer") {
    const html = fs.readFileSync(__dirname + "/public/index.html");
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end(html);
    return;
  }
  res.writeHead(404);
  res.end("Not found");
});

const wss = new WebSocketServer({ server: httpServer, path: "/ws" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  ws.isSender = url.searchParams.get("role") === "sender";
  ws._connectedAt = Date.now();

  if (ws.isSender) {
    if (activeSender && activeSender.readyState === activeSender.OPEN) {
      try { activeSender.close(4001, "replaced by new sender"); } catch {}
    }
    activeSender = ws;
  }

  ws.on("message", (data, isBinary) => {
    if (!ws.isSender || !isBinary) return;

    const buf = Buffer.from(data);
    packetCount++;
    bytesReceived += buf.length;

    // Broadcast the already-encoded H.264 packet to browser viewers.
    for (const peer of wss.clients) {
      if (peer !== ws && peer.readyState === peer.OPEN) {
        try { peer.send(buf, { binary: true }); } catch {}
      }
    }
  });

  ws.on("close", () => {
    if (activeSender === ws) activeSender = null;
  });
});

setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN) {
      try { ws.ping(); } catch {}
    }
  }
}, 25000);

httpServer.listen(PORT, HOST, () => {
  console.log(`Excellent Mirror server listening on ${HOST}:${PORT}`);
  console.log(`WebSocket: ws://0.0.0.0:${PORT}/ws`);
});
