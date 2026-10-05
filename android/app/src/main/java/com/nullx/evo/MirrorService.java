package com.nullx.evo;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Display;
import android.view.Surface;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import org.json.JSONObject;
import java.nio.ByteBuffer;

/**
 * Excellent Mirror sender.
 *
 * Transport is remote WebSocket. The app fetches the current server URL from
 * the public GitHub server.json and connects directly to that Pterodactyl-hosted
 * Node.js service. If the server times out, server.json is refreshed and the
 * app keeps retrying.
 *
 * Wire format inside each WebSocket binary message:
 *   uint32 BE payload length
 *   uint8  type: 0=config(AVCDecoderConfigurationRecord), 1=key, 2=delta
 *   bytes  payload (H.264 AVCC)
 */
public class MirrorService extends Service {
    private static final int NOTIF_ID = 77;
    private static final String CHANNEL_ID = "mirror";
    private static final String CONFIG_URL =
        "https://raw.githubusercontent.com/vinszzr-lang/Project-Reskin-Gue/main/server.json";
    private static final int CONNECT_TIMEOUT_MS = 3500;
    private static final int CONFIG_TIMEOUT_MS = 5000;
    private static final long CONFIG_RETRY_MS = 5000L;
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String PREFS = "mirror_state";
    public static final String ACTION_STOP = "com.nullx.evo.STOP";

    private final Object pipelineLock = new Object();
    private MediaProjection projection;
    private VirtualDisplay display;
    private MediaCodec encoder;
    private Surface inputSurface;
    private volatile boolean running;
    private Thread streamThread;

    private int maxEdge = 720;
    private int bitrate = 4_000_000;
    private int fps = 60;
    private int currentW;
    private int currentH;

    private DisplayManager displayManager;
    private DisplayManager.DisplayListener displayListener;
    private byte[] cachedConfig;
    private long framesSent;
    private long bytesSent;
    private volatile boolean rebuildingPipeline;
    private final Handler displayHandler = new Handler(Looper.getMainLooper());
    private Runnable pendingDisplayRebuild;

    @Override public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel c = new NotificationChannel(
                CHANNEL_ID, "Mirroring", NotificationManager.IMPORTANCE_LOW);
            getSystemService(NotificationManager.class).createNotificationChannel(c);
        }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopMirrorNow();
            return START_NOT_STICKY;
        }
        if (running) return START_NOT_STICKY;

        int resultCode = intent != null ? intent.getIntExtra("resultCode", -1) : -1;
        Intent data = getProjectionIntent(intent);
        maxEdge = intent != null ? intent.getIntExtra("width", 720) : 720;
        bitrate = intent != null ? intent.getIntExtra("bitrate", 4_000_000) : 4_000_000;
        fps = intent != null ? intent.getIntExtra("fps", 60) : 60;

        startForegroundNow();
        setStatus("Izin screen capture diterima • memulai encoder...");

        new Thread(() -> startMirror(resultCode, data), "MirrorStart").start();
        return START_NOT_STICKY;
    }

    private void startForegroundNow() {
        Notification n;
        if (Build.VERSION.SDK_INT >= 26) {
            n = new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Excellent Mirror")
                .setContentText("Remote mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true).build();
        } else {
            n = new Notification.Builder(this)
                .setContentTitle("Excellent Mirror")
                .setContentText("Remote mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true).build();
        }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    @SuppressWarnings("deprecation")
    private Intent getProjectionIntent(Intent intent) {
        if (intent == null) return null;
        if (Build.VERSION.SDK_INT >= 33) return intent.getParcelableExtra("data", Intent.class);
        return intent.getParcelableExtra("data");
    }

    private void startMirror(int resultCode, Intent data) {
        try {
            if (resultCode != android.app.Activity.RESULT_OK || data == null) {
                fail("Token screen capture tidak valid"); return;
            }
            MediaProjectionManager mgr =
                (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
            projection = mgr.getMediaProjection(resultCode, data);
            if (projection == null) throw new IllegalStateException("MediaProjection gagal dibuat");

            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() {
                    setStatus("Screen capture dihentikan oleh Android");
                    stopSelf();
                }
            }, null);

            running = true;
            registerDisplayListener();
            synchronized (pipelineLock) { rebuildPipelineLocked(); }
            setStatus("Encoder aktif • mencari server...");

            streamThread = new Thread(this::streamLoop, "MirrorStream");
            streamThread.start();
        } catch (Throwable t) {
            fail("Gagal memulai: " + shortError(t));
        }
    }

    @SuppressWarnings("deprecation")
    private DisplayMetrics metrics() {
        DisplayMetrics d = new DisplayMetrics();
        android.view.WindowManager wm = (android.view.WindowManager)getSystemService(WINDOW_SERVICE);
        if (wm != null && wm.getDefaultDisplay() != null) wm.getDefaultDisplay().getRealMetrics(d);
        else d.setTo(getResources().getDisplayMetrics());
        return d;
    }

    private int[] outputSize() {
        DisplayMetrics d = metrics();
        int sw = Math.max(2, d.widthPixels), sh = Math.max(2, d.heightPixels);
        float scale = Math.min(1f, maxEdge / (float)Math.max(sw, sh));
        int w = Math.max(2, ((int)(sw * scale)) & ~1);
        int h = Math.max(2, ((int)(sh * scale)) & ~1);
        return new int[]{w, h};
    }

    private void rebuildPipelineLocked() throws Exception {
        rebuildingPipeline = true;
        try {
            stopEncoderLocked();
            // Rotation can report transient display metrics. The listener debounces
            // the rebuild, so this size is the settled portrait/landscape size.
            int[] size = outputSize(); currentW = size[0]; currentH = size[1];
            MediaFormat fmt = makeFormat(currentW, currentH);
        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        encoder.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = encoder.createInputSurface();
            encoder.start();
            cachedConfig = null;
            display = projection.createVirtualDisplay(
                "ExcellentMirror", currentW, currentH, metrics().densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface, null, null);
            setStatus("Encoder aktif • " + currentW + "x" + currentH + " • " + fps + " FPS");
            requestKeyFrame();
        } finally {
            rebuildingPipeline = false;
        }
    }

    private void stopEncoderLocked() {
        try { if (display != null) display.release(); } catch (Throwable ignored) {}
        display = null;
        try { if (inputSurface != null) inputSurface.release(); } catch (Throwable ignored) {}
        inputSurface = null;
        MediaCodec old = encoder; encoder = null;
        if (old != null) { try { old.stop(); } catch (Throwable ignored) {} try { old.release(); } catch (Throwable ignored) {} }
    }

    private void streamLoop() {
        Socket socket = null;
        OutputStream out = null;
        InputStreamHolder input = null;
        Thread reader = null;
        long lastConfigFetch = 0L;
        String currentServer = null;

        while (running) {
            try {
                boolean socketDead = socket == null || socket.isClosed() || !socket.isConnected();
                if (socketDead) {
                    long now = System.currentTimeMillis();

                    // Refresh GitHub whenever the connection is unavailable. This
                    // lets the owner change only server.json when moving servers.
                    if (currentServer == null || now - lastConfigFetch >= CONFIG_RETRY_MS) {
                        String fetched = fetchServerUrl();
                        lastConfigFetch = now;
                        if (fetched != null && !fetched.equals(currentServer)) {
                            currentServer = fetched;
                            setStatus("Server ditemukan • " + currentServer);
                        } else if (currentServer == null) {
                            setStatus("Mencari server dari GitHub...");
                        }
                    }

                    if (currentServer == null) {
                        drainOnce(null);
                        sleepQuietly(250);
                        continue;
                    }

                    try {
                        socket = connectWebSocket(currentServer);
                        socket.setTcpNoDelay(true);
                        socket.setKeepAlive(true);
                        socket.setSendBufferSize(64 * 1024);
                        out = socket.getOutputStream();

                        final Socket readerSocket = socket;
                        final InputStreamHolder readerInput =
                            new InputStreamHolder(socket.getInputStream());
                        input = readerInput;

                        reader = new Thread(() -> webSocketReadLoop(readerSocket, readerInput),
                            "MirrorWebSocketReader");
                        reader.setDaemon(true);
                        reader.start();

                        if (cachedConfig != null) {
                            writePacket(out, (byte)0, 0L, cachedConfig);
                        }
                        requestKeyFrame();
                        setStatus("SERVER CONNECTED • streaming...");
                    } catch (Throwable e) {
                        closeSocket(socket);
                        socket = null; out = null; input = null;
                        setStatus("Server timeout • cek GitHub lagi...");
                        sleepQuietly(300);
                        continue;
                    }
                }

                boolean ok = drainOnce(out);
                if (!ok || socket == null || socket.isClosed()) {
                    closeSocket(socket);
                    socket = null; out = null; input = null;
                    setStatus("Server terputus • mencari server lagi...");
                    sleepQuietly(150);
                }
            } catch (Throwable t) {
                closeSocket(socket);
                socket = null; out = null; input = null;
                setStatus("Stream error: " + shortError(t));
                sleepQuietly(300);
            }
        }
        closeSocket(socket);
    }

    private String fetchServerUrl() {
        HttpURLConnection c = null;
        try {
            URL url = new URL(CONFIG_URL);
            c = (HttpURLConnection) url.openConnection();
            c.setConnectTimeout(CONFIG_TIMEOUT_MS);
            c.setReadTimeout(CONFIG_TIMEOUT_MS);
            c.setRequestMethod("GET");
            c.setRequestProperty("Accept", "application/json");
            c.setRequestProperty("Cache-Control", "no-cache");
            int code = c.getResponseCode();
            if (code < 200 || code >= 300) return null;

            StringBuilder body = new StringBuilder();
            try (java.io.BufferedReader r = new java.io.BufferedReader(
                    new java.io.InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) body.append(line);
            }

            JSONObject json = new JSONObject(body.toString());
            String server = json.optString("server", "").trim();
            if (server.isEmpty()) return null;

            URI uri = URI.create(server);
            String scheme = uri.getScheme();
            String host = uri.getHost();
            int port = uri.getPort();

            if (host == null || scheme == null) return null;
            if (!scheme.equalsIgnoreCase("http") && !scheme.equalsIgnoreCase("https")
                    && !scheme.equalsIgnoreCase("ws") && !scheme.equalsIgnoreCase("wss")) {
                return null;
            }
            if (port < 0) port = scheme.equalsIgnoreCase("https")
                || scheme.equalsIgnoreCase("wss") ? 443 : 80;

            // Keep the configured URL exactly as supplied except for a trailing slash.
            // The WebSocket client will use its host/port and connect to /ws.
            return server;
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private Socket connectWebSocket(String serverUrl) throws Exception {
        URI uri = URI.create(serverUrl);
        String host = uri.getHost();
        int port = uri.getPort();
        if (port < 0) port = uri.getScheme().equalsIgnoreCase("https")
            || uri.getScheme().equalsIgnoreCase("wss") ? 443 : 80;

        if (uri.getScheme().equalsIgnoreCase("https")
                || uri.getScheme().equalsIgnoreCase("wss")) {
            throw new IOException("HTTPS/WSS requires a TLS endpoint; use http:// for this server");
        }

        Socket socket = new Socket();
        socket.setTcpNoDelay(true);
        socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);

        String keyBytes = randomWebSocketKey();
        String path = uri.getRawPath();
        if (path == null || path.isEmpty()) path = "/";
        if (!path.endsWith("/")) path += "/";
        path += "ws?role=sender";
        if (uri.getRawQuery() != null && !uri.getRawQuery().isEmpty()) {
            path += "&" + uri.getRawQuery();
        }
        String hostHeader = host + (uri.getPort() >= 0 ? ":" + uri.getPort() : "");

        OutputStream out = socket.getOutputStream();
        String request =
            "GET " + path + "ws HTTP/1.1\\r\\n"
          + "Host: " + hostHeader + "\\r\\n"
          + "Upgrade: websocket\\r\\n"
          + "Connection: Upgrade\\r\\n"
          + "Sec-WebSocket-Key: " + keyBytes + "\\r\\n"
          + "Sec-WebSocket-Version: 13\\r\\n\\r\\n";
        out.write(request.getBytes(StandardCharsets.US_ASCII));
        out.flush();

        java.io.InputStream in = socket.getInputStream();
        String headers = readHttpHeaders(in);
        if (!headers.startsWith("HTTP/1.1 101") && !headers.startsWith("HTTP/1.0 101")) {
            throw new IOException("WebSocket handshake failed: " + firstLine(headers));
        }
        return socket;
    }

    private String randomWebSocketKey() {
        byte[] bytes = new byte[16];
        RANDOM.nextBytes(bytes);
        return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP);
    }

    private String readHttpHeaders(java.io.InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev3 = -1, prev2 = -1, prev1 = -1, x;
        long deadline = System.currentTimeMillis() + CONNECT_TIMEOUT_MS;
        while ((x = in.read()) != -1) {
            b.write(x);
            prev3 = prev2; prev2 = prev1; prev1 = x;
            if (prev3 == '\r' && prev2 == '\n' && prev1 == '\r') {
                int y = in.read();
                if (y == '\n') { b.write(y); break; }
                b.write(y);
            }
            if (System.currentTimeMillis() > deadline) throw new IOException("WebSocket handshake timeout");
            if (b.size() > 16384) throw new IOException("WebSocket headers too large");
        }
        return b.toString(StandardCharsets.US_ASCII.name());
    }

    private String firstLine(String headers) {
        int p = headers.indexOf('\n');
        return p >= 0 ? headers.substring(0, p).trim() : headers.trim();
    }

    private void webSocketReadLoop(Socket socket, InputStreamHolder holder) {
        try {
            java.io.InputStream in = holder.in;
            while (running && !socket.isClosed()) {
                int b1 = in.read();
                if (b1 < 0) throw new IOException("server closed");
                int b2 = in.read();
                if (b2 < 0) throw new IOException("server closed");

                int opcode = b1 & 0x0f;
                boolean masked = (b2 & 0x80) != 0;
                long len = b2 & 0x7f;
                if (len == 126) {
                    len = ((in.read() & 255) << 8) | (in.read() & 255);
                } else if (len == 127) {
                    len = 0;
                    for (int i = 0; i < 8; i++) len = (len << 8) | (in.read() & 255);
                }
                if (len > 1024 * 1024) throw new IOException("WebSocket control frame too large");

                byte[] mask = null;
                if (masked) {
                    mask = new byte[4];
                    readFully(in, mask, 0, 4);
                }
                byte[] payload = new byte[(int)len];
                readFully(in, payload, 0, payload.length);
                if (masked && payload.length > 0) {
                    for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
                }

                if (opcode == 0x8) throw new IOException("server closed websocket");
                if (opcode == 0x9) sendWebSocketFrame(socket.getOutputStream(), (byte)0xA, payload);
            }
        } catch (Throwable ignored) {
            try { socket.close(); } catch (Throwable ignored2) {}
        }
    }

    private void readFully(java.io.InputStream in, byte[] data, int off, int len) throws IOException {
        int p = 0;
        while (p < len) {
            int n = in.read(data, off + p, len - p);
            if (n < 0) throw new IOException("unexpected EOF");
            p += n;
        }
    }

    private static final class InputStreamHolder {
        final java.io.InputStream in;
        InputStreamHolder(java.io.InputStream in) { this.in = in; }
    }

    private void sleepQuietly(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    private void requestKeyFrame() {
        try {
            MediaCodec local;
            synchronized (pipelineLock) { local = encoder; }
            if (local != null && Build.VERSION.SDK_INT >= 19) {
                Bundle b = new Bundle();
                b.putInt("request-sync", 0);
                local.setParameters(b);
            }
        } catch (Throwable ignored) {}
    }

    private boolean drainOnce(OutputStream out) {
        MediaCodec local;
        byte[] payload = null;
        long presentationTimeUs = 0L;
        byte packetType = 2;
        boolean produced = false;

        // Rotation replaces the MediaCodec. Keep the whole dequeue/read/release
        // operation inside the same lock as rebuildPipelineLocked(), so the old
        // codec can never be released while this thread is using it.
        synchronized (pipelineLock) {
            local = encoder;
            if (local == null) return true;

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            try {
                int idx = local.dequeueOutputBuffer(info, 0);

                if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat f = local.getOutputFormat();
                    byte[] config = makeAvcConfig(f);
                    if (config.length > 0) {
                        cachedConfig = config;
                        if (out != null) writePacket(out, (byte)0, 0L, config);
                        setStatus(out != null ? "H.264 config OK • streaming..." : "H.264 encoder OK • menunggu server...");
                    }
                    return true;
                }
                if (idx < 0) {
                    try { Thread.sleep(1); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
                    return true;
                }

                ByteBuffer b = local.getOutputBuffer(idx);
                try {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) return true;
                    if (b == null || info.size <= 0) return true;

                    int start = Math.max(0, info.offset);
                    int end = Math.min(b.capacity(), info.offset + info.size);
                    if (end <= start) return true;
                    b.position(start);
                    b.limit(end);

                    byte[] raw = new byte[b.remaining()];
                    b.get(raw);
                    byte[] avcc = toAvcc(raw);
                    if (avcc.length == 0) return true;

                    boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                    packetType = (byte)(key ? 1 : 2);
                    payload = avcc;
                    presentationTimeUs = Math.max(0L, info.presentationTimeUs);
                    produced = true;
                } finally {
                    try { local.releaseOutputBuffer(idx, false); } catch (Throwable ignored) {}
                }
            } catch (IllegalStateException e) {
                // If the codec changed between callbacks, simply let the next
                // loop drain the new encoder. Never tear down the TCP socket for
                // an expected portrait/landscape transition.
                if (encoder != local || rebuildingPipeline) return true;
                setStatus("Encoder recovering...");
                return true;
            } catch (Throwable e) {
                if (encoder != local || rebuildingPipeline) return true;
                setStatus("Encoder error: " + shortError(e));
                return true;
            }
        }

        if (!produced || payload == null || out == null) return true;
        try {
            if (packetType == 1 && cachedConfig != null) {
                writePacket(out, (byte)0, 0L, cachedConfig);
            }
            writePacket(out, packetType, presentationTimeUs, payload);
            framesSent++;
            bytesSent += payload.length;
            if ((framesSent % 30) == 0) {
                setStatus("Streaming • " + currentW + "x" + currentH + " • frame " + framesSent);
            }
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    private void writePacket(OutputStream out, byte type, long ptsUs, byte[] payload) throws IOException {
        int n = payload.length + 13;
        byte[] packet = new byte[n];
        packet[0] = (byte)((n >>> 24) & 255);
        packet[1] = (byte)((n >>> 16) & 255);
        packet[2] = (byte)((n >>> 8) & 255);
        packet[3] = (byte)(n & 255);
        packet[4] = type;
        for (int i = 7; i >= 0; i--) packet[12 - i] = (byte)(ptsUs >>> (i * 8));
        System.arraycopy(payload, 0, packet, 13, payload.length);
        sendWebSocketFrame(out, (byte)0x2, packet);
    }

    private synchronized void sendWebSocketFrame(OutputStream out, byte opcode, byte[] payload) throws IOException {
        int len = payload.length;
        out.write(0x80 | (opcode & 0x0f));

        if (len <= 125) {
            out.write(0x80 | len);
        } else if (len <= 65535) {
            out.write(0x80 | 126);
            out.write((len >>> 8) & 255);
            out.write(len & 255);
        } else {
            out.write(0x80 | 127);
            long l = len & 0xffffffffL;
            for (int i = 7; i >= 0; i--) out.write((int)(l >>> (i * 8)) & 255);
        }

        byte[] mask = new byte[4];
        RANDOM.nextBytes(mask);
        out.write(mask);
        byte[] masked = new byte[payload.length];
        for (int i = 0; i < payload.length; i++) masked[i] = (byte)(payload[i] ^ mask[i & 3]);
        out.write(masked);
        out.flush();
    }

    private byte[] makeAvcConfig(MediaFormat f) {
        try {
            byte[] sps = extractFirstNal(f.getByteBuffer("csd-0"), 7);
            byte[] pps = extractFirstNal(f.getByteBuffer("csd-1"), 8);
            if (sps == null || pps == null || sps.length < 4 || pps.length < 1) return new byte[0];
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            out.write(1);
            out.write(sps[1] & 255); out.write(sps[2] & 255); out.write(sps[3] & 255);
            out.write(0xff); // 4-byte NAL lengths
            out.write(0xe1);
            out.write((sps.length >>> 8) & 255); out.write(sps.length & 255); out.write(sps);
            out.write(1);
            out.write((pps.length >>> 8) & 255); out.write(pps.length & 255); out.write(pps);
            return out.toByteArray();
        } catch (Throwable t) { return new byte[0]; }
    }

    private byte[] extractFirstNal(ByteBuffer src, int wantedType) {
        if (src == null) return null;
        ByteBuffer d = src.duplicate(); byte[] data = new byte[d.remaining()]; d.get(data);
        if (data.length >= 7 && (data[0] & 255) == 1) {
            int p = 5, count = data[p++] & 31;
            for (int i=0;i<count && p+2<=data.length;i++) {
                int len=((data[p]&255)<<8)|(data[p+1]&255); p+=2;
                if (len<=0 || p+len>data.length) break;
                int type=data[p]&31; if(type==wantedType){byte[] n=new byte[len];System.arraycopy(data,p,n,0,len);return n;} p+=len;
            }
            if (p<data.length) {
                int countP=data[p++]&255;
                for(int i=0;i<countP&&p+2<=data.length;i++){int len=((data[p]&255)<<8)|(data[p+1]&255);p+=2;if(len<=0||p+len>data.length)break;int type=data[p]&31;if(type==wantedType){byte[] n=new byte[len];System.arraycopy(data,p,n,0,len);return n;}p+=len;}
            }
        }
        int start=findStart(data,0); if(start>=0){
            int p=start; while(p<data.length){int next=findStart(data,p+3);int end=next>=0?next:data.length;int nalStart=skipStart(data,p);if(nalStart<end&&(data[nalStart]&31)==wantedType){byte[]n=new byte[end-nalStart];System.arraycopy(data,nalStart,n,0,n.length);return n;}if(next<0)break;p=next;}
        }
        return ((data.length>0&&(data[0]&31)==wantedType)?data:null);
    }

    private int findStart(byte[] d,int from){for(int i=Math.max(0,from);i+3<d.length;i++){if(d[i]==0&&d[i+1]==0&&(d[i+2]==1||(d[i+2]==0&&d[i+3]==1)))return i;}return -1;}
    private int skipStart(byte[]d,int p){return p+((p+2<d.length&&d[p+2]==1)?3:4);}

    private byte[] toAvcc(byte[] raw) {
        if (raw.length == 0) return raw;
        if (findStart(raw,0) >= 0) {
            ByteArrayOutputStream out=new ByteArrayOutputStream(); int p=findStart(raw,0);
            while(p>=0){int ns=skipStart(raw,p);int next=findStart(raw,ns);int end=next>=0?next:raw.length;if(end>ns){int len=end-ns;out.write((len>>>24)&255);out.write((len>>>16)&255);out.write((len>>>8)&255);out.write(len&255);out.write(raw,ns,len);}if(next<0)break;p=next;}
            return out.toByteArray();
        }
        // Most MediaCodec AVC output is already 4-byte length-prefixed. Validate it.
        int p=0; boolean valid=false;
        while(p+4<=raw.length){int len=((raw[p]&255)<<24)|((raw[p+1]&255)<<16)|((raw[p+2]&255)<<8)|(raw[p+3]&255);if(len<=0||p+4+len>raw.length)break;p+=4+len;valid=true;}
        if(valid&&p==raw.length)return raw;
        // Single raw NAL fallback.
        ByteArrayOutputStream out=new ByteArrayOutputStream();int n=raw.length;out.write((n>>>24)&255);out.write((n>>>16)&255);out.write((n>>>8)&255);out.write(n&255);out.write(raw,0,n);return out.toByteArray();
    }

    private void registerDisplayListener() {
        displayManager = (DisplayManager)getSystemService(DISPLAY_SERVICE);
        displayListener = new DisplayManager.DisplayListener() {
            @Override public void onDisplayAdded(int id) {}
            @Override public void onDisplayRemoved(int id) {}

            @Override public void onDisplayChanged(int id) {
                if (id != Display.DEFAULT_DISPLAY || !running) return;
                if (pendingDisplayRebuild != null) {
                    displayHandler.removeCallbacks(pendingDisplayRebuild);
                }
                // Wait for Android to finish the orientation transition. One
                // rebuild only, instead of racing several callbacks.
                pendingDisplayRebuild = () -> rotatePipeline();
                displayHandler.postDelayed(pendingDisplayRebuild, 300);
            }
        };
        displayManager.registerDisplayListener(displayListener, displayHandler);
    }

    private void rotatePipeline() {
        if (!running || projection == null) return;
        new Thread(() -> {
            int[] target = outputSize();
            synchronized (pipelineLock) {
                if (!running || projection == null) return;
                if (target[0] == currentW && target[1] == currentH) return;
                rebuildingPipeline = true;
                MediaCodec next = null;
                Surface nextSurface = null;
                VirtualDisplay nextDisplay = null;
                MediaCodec old = encoder;
                VirtualDisplay oldDisplay = display;
                Surface oldSurface = inputSurface;
                try {
                    // Build the new pipeline FIRST. The TCP socket stays alive and
                    // the old encoder remains untouched until the new one is ready.
                    MediaFormat fmt = makeFormat(target[0], target[1]);
                    next = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
                    next.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                    nextSurface = next.createInputSurface();
                    next.start();
                    nextDisplay = projection.createVirtualDisplay(
                        "ExcellentMirror", target[0], target[1], metrics().densityDpi,
                        DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                        nextSurface, null, null);
                    if (nextDisplay == null) throw new IllegalStateException("VirtualDisplay gagal dibuat");

                    // Swap only after the complete new pipeline is alive.
                    encoder = next;
                    inputSurface = nextSurface;
                    display = nextDisplay;
                    currentW = target[0];
                    currentH = target[1];
                    cachedConfig = null;
                    setStatus("Rotasi • " + currentW + "x" + currentH + " • reconnect keyframe...");

                    // The old pipeline can now be released safely.
                    try { if (oldDisplay != null) oldDisplay.release(); } catch (Throwable ignored) {}
                    try { if (oldSurface != null) oldSurface.release(); } catch (Throwable ignored) {}
                    try { if (old != null) old.stop(); } catch (Throwable ignored) {}
                    try { if (old != null) old.release(); } catch (Throwable ignored) {}

                    requestKeyFrame();
                    next = null; nextSurface = null; nextDisplay = null;
                } catch (Throwable t) {
                    // Keep the old pipeline alive if creating the rotated pipeline fails.
                    if (nextDisplay != null) try { nextDisplay.release(); } catch (Throwable ignored) {}
                    if (nextSurface != null) try { nextSurface.release(); } catch (Throwable ignored) {}
                    if (next != null) { try { next.stop(); } catch (Throwable ignored) {} try { next.release(); } catch (Throwable ignored) {} }
                    setStatus("Rotasi gagal • stream tetap aktif: " + shortError(t));
                } finally {
                    rebuildingPipeline = false;
                }
            }
        }, "MirrorRotate").start();
    }

    private MediaFormat makeFormat(int w, int h) {
        MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        // Short GOP gives fast recovery after a rotation while keeping CPU cost modest.
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        if (Build.VERSION.SDK_INT >= 21) {
            try { fmt.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR); } catch (Throwable ignored) {}
        }
        if (Build.VERSION.SDK_INT >= 23) {
            try { fmt.setInteger(MediaFormat.KEY_LATENCY, 0); } catch (Throwable ignored) {}
            try { fmt.setInteger(MediaFormat.KEY_PRIORITY, 0); } catch (Throwable ignored) {}
            try { fmt.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1); } catch (Throwable ignored) {}
        }
        return fmt;
    }

    private void stopMirrorNow() {
        running = false;
        if (pendingDisplayRebuild != null) displayHandler.removeCallbacks(pendingDisplayRebuild);
        synchronized (pipelineLock) { stopEncoderLocked(); }
        try { if (projection != null) projection.stop(); } catch (Throwable ignored) {}
        projection = null;
        setStatus("Berhenti");
        stopForeground(true);
        stopSelf();
    }

    private void setStatus(String s) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString("status", s).putLong("frames", framesSent).putLong("bytes", bytesSent).apply();
    }
    private void fail(String s) { running=false; setStatus("ERROR: "+s); stopSelf(); }
    private String shortError(Throwable t){String s=t.getMessage();return s==null?t.getClass().getSimpleName():s;}
    private void closeSocket(Socket s){if(s!=null)try{s.close();}catch(Throwable ignored){}}

    @Override public void onDestroy(){
        running=false;
        if (pendingDisplayRebuild != null) displayHandler.removeCallbacks(pendingDisplayRebuild);
        if(streamThread!=null)streamThread.interrupt();
        try{if(displayManager!=null&&displayListener!=null)displayManager.unregisterDisplayListener(displayListener);}catch(Throwable ignored){}
        synchronized(pipelineLock){stopEncoderLocked();}
        try{if(projection!=null)projection.stop();}catch(Throwable ignored){}
        projection=null;
        setStatus("Berhenti");
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent){return null;}
}
