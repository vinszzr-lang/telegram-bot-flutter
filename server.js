const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const PORT = Number(process.env.PORT || 8787);
const ADB_PORT = Number(process.env.ADB_PORT || 27183);
const PUBLIC = path.join(__dirname, 'public');

function runAdbForward() {
  try {
    execFileSync('adb', ['forward', `tcp:${ADB_PORT}`, `tcp:${ADB_PORT}`], {
      stdio: 'inherit'
    });
    console.log(`[ADB] forward tcp:${ADB_PORT} -> phone tcp:${ADB_PORT}`);
  } catch (e) {
    console.error('\nADB forward failed.');
    console.error('Make sure adb is installed, USB debugging is enabled, and the phone is authorized.');
    console.error(`Run manually: adb forward tcp:${ADB_PORT} tcp:${ADB_PORT}\n`);
  }
}

function mime(file) {
  if (file.endsWith('.html')) return 'text/html; charset=utf-8';
  if (file.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (file.endsWith('.css')) return 'text/css; charset=utf-8';
  return 'application/octet-stream';
}

const server = http.createServer((req, res) => {
  if (req.url === '/stream') {
    res.writeHead(200, {
      'Content-Type': 'video/mp4',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      'Pragma': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*'
    });

    const input = net.createConnection({host: '127.0.0.1', port: ADB_PORT});
    input.setNoDelay(true);

    // Android sends Annex-B H.264. FFmpeg repackages it into fragmented MP4
    // which the browser can consume through MediaSource.
    const ff = spawn('ffmpeg', [
      '-hide_banner',
      '-loglevel', 'error',
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-f', 'h264',
      '-i', 'pipe:0',
      '-an',
      '-c:v', 'copy',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
      '-f', 'mp4',
      'pipe:1'
    ], {stdio: ['pipe', 'pipe', 'pipe']});

    let closed = false;
    const closeAll = () => {
      if (closed) return;
      closed = true;
      input.destroy();
      ff.stdin.destroy();
      ff.stdout.destroy();
      try { ff.kill('SIGKILL'); } catch {}
    };

    input.on('error', closeAll);
    ff.on('error', (e) => {
      console.error('[FFmpeg]', e.message);
      closeAll();
    });
    ff.stderr.on('data', d => {
      const s = d.toString().trim();
      if (s) console.error('[FFmpeg]', s);
    });

    input.pipe(ff.stdin);
    ff.stdout.pipe(res);

    req.on('close', closeAll);
    res.on('close', closeAll);
    return;
  }

  let file = req.url === '/' ? '/index.html' : req.url;
  file = file.split('?')[0];
  const safe = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
  const target = path.join(PUBLIC, safe);
  if (!target.startsWith(PUBLIC)) {
    res.writeHead(403); return res.end('Forbidden');
  }

  fs.readFile(target, (err, data) => {
    if (err) {
      res.writeHead(404, {'Content-Type': 'text/plain'});
      return res.end('Not found');
    }
    res.writeHead(200, {'Content-Type': mime(target), 'Cache-Control': 'no-store'});
    res.end(data);
  });
});

runAdbForward();

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\nExcellent Mirror JS receiver`);
  console.log(`Open: http://127.0.0.1:${PORT}`);
  console.log(`Phone stream: tcp://127.0.0.1:${ADB_PORT}`);
  console.log(`\nKeep the Android app running with START MIRRORING.`);
  console.log(`Press Ctrl+C to stop.\n`);
});
