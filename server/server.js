const http = require("http");
const net = require("net");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");

const TCP_PORT = Number(process.env.MIRROR_TCP_PORT || 27183);
const HTTP_PORT = Number(process.env.MIRROR_HTTP_PORT || 8080);
const HOST = process.env.MIRROR_HOST || "0.0.0.0";

let sourceSocket = null;
let ffmpeg = null;
const viewers = new Set();

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function stopTranscoder() {
  if (ffmpeg) {
    try { ffmpeg.stdin.destroy(); } catch {}
    try { ffmpeg.kill("SIGTERM"); } catch {}
    ffmpeg = null;
  }
}

function startTranscoder(socket) {
  stopTranscoder();

  // Android sends Annex-B H.264. FFmpeg converts it to MPEG-TS/MPEG-1 for
  // JSMpeg in the browser. The pipeline is deliberately unbuffered.
  ffmpeg = spawn("ffmpeg", [
    "-hide_banner",
    "-loglevel", "warning",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-probesize", "32",
    "-analyzeduration", "0",
    "-f", "h264",
    "-i", "pipe:0",
    "-an",
    "-c:v", "mpeg1video",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-b:v", "2M",
    "-maxrate", "2M",
    "-bufsize", "256K",
    "-g", "30",
    "-bf", "0",
    "-f", "mpegts",
    "-muxdelay", "0",
    "-muxpreload", "0",
    "pipe:1"
  ], { stdio: ["pipe", "pipe", "pipe"] });

  socket.on("data", chunk => {
    if (ffmpeg && !ffmpeg.stdin.destroyed) ffmpeg.stdin.write(chunk);
  });

  socket.on("close", stopTranscoder);
  socket.on("error", stopTranscoder);

  ffmpeg.stdout.on("data", chunk => {
    for (const ws of viewers) {
      if (ws.readyState !== WebSocket.OPEN) {
        viewers.delete(ws);
        continue;
      }
      // WebSocket.send queues only the current encoded chunks. If a browser
      // becomes unhealthy, drop it rather than building an unbounded queue.
      if (ws.bufferedAmount > 512 * 1024) {
        try { ws.close(1013, "viewer too slow"); } catch {}
        viewers.delete(ws);
        continue;
      }
      ws.send(chunk, { binary: true });
    }
  });

  ffmpeg.stderr.on("data", d => log("ffmpeg:", d.toString().trim()));
  ffmpeg.on("exit", (code, signal) => {
    log(`ffmpeg exited code=${code} signal=${signal}`);
    if (ffmpeg && ffmpeg.exitCode !== null) ffmpeg = null;
  });

  log("H.264 -> MPEG-TS transcoder started");
}

const tcpServer = net.createServer(socket => {
  if (sourceSocket) {
    socket.destroy();
    log("Rejected second mirror source");
    return;
  }

  sourceSocket = socket;
  socket.setNoDelay(true);
  socket.setKeepAlive(true);
  log(`Android source connected from ${socket.remoteAddress}:${socket.remotePort}`);

  startTranscoder(socket);

  const clear = () => {
    if (sourceSocket === socket) sourceSocket = null;
    stopTranscoder();
    log("Android source disconnected");
  };
  socket.once("close", clear);
  socket.once("error", clear);
});

tcpServer.listen(TCP_PORT, HOST, () => {
  log(`Mirror TCP receiver listening on ${HOST}:${TCP_PORT}`);
});

const httpServer = http.createServer((req, res) => {
  let urlPath = req.url.split("?")[0];
  if (urlPath === "/") urlPath = "/index.html";

  const file = path.join(__dirname, "public", path.normalize(urlPath).replace(/^(\.\.(\/|\\|$))+/, ""));
  if (!file.startsWith(path.join(__dirname, "public"))) {
    res.writeHead(403); return res.end("Forbidden");
  }

  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404, {"Content-Type": "text/plain"});
      return res.end("Not found");
    }
    const type = file.endsWith(".html") ? "text/html; charset=utf-8" : "application/octet-stream";
    res.writeHead(200, {"Content-Type": type, "Cache-Control": "no-store"});
    res.end(data);
  });
});

const wss = new WebSocket.Server({ server: httpServer, path: "/stream" });
wss.on("connection", ws => {
  ws.binaryType = "arraybuffer";
  viewers.add(ws);
  log(`Viewer connected; viewers=${viewers.size}`);
  ws.on("close", () => {
    viewers.delete(ws);
    log(`Viewer disconnected; viewers=${viewers.size}`);
  });
  ws.on("error", () => viewers.delete(ws));
});

httpServer.listen(HTTP_PORT, HOST, () => {
  log(`Viewer available at http://${HOST}:${HTTP_PORT}`);
});

function shutdown() {
  log("Shutting down");
  for (const ws of viewers) {
    try { ws.close(); } catch {}
  }
  stopTranscoder();
  if (sourceSocket) sourceSocket.destroy();
  tcpServer.close();
  httpServer.close(() => process.exit(0));
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
