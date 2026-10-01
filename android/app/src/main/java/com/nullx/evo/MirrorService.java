package com.nullx.evo;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
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
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.view.Surface;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;

/**
 * USB/ADB-only low-latency H.264 sender.
 *
 * The APK has no IP/port settings. It always connects to 127.0.0.1:27183.
 * On a Chromebook this endpoint is exposed to the host by:
 *   adb reverse tcp:27183 tcp:27183
 *
 * Wire format:
 *   4-byte big-endian packet length
 *   1-byte type: 0=config, 1=key frame, 2=delta frame
 *   N bytes Annex-B H.264
 *
 * There is deliberately no frame queue. A slow receiver causes the socket to
 * be dropped instead of allowing old frames to accumulate.
 */
public class MirrorService extends Service {
    private static final int NOTIF_ID = 77;
    private static final String CHANNEL_ID = "mirror";
    private static final String HOST = "127.0.0.1";
    private static final int PORT = 27183;

    private final Object pipelineLock = new Object();

    private MediaProjection projection;
    private VirtualDisplay display;
    private MediaCodec encoder;
    private Surface inputSurface;
    private volatile boolean running;
    private Thread connectThread;

    private int maxEdge = 720;
    private int bitrate = 4_000_000;
    private int fps = 60;

    private int currentW;
    private int currentH;
    private DisplayManager displayManager;
    private DisplayManager.DisplayListener displayListener;

    @Override
    public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel c = new NotificationChannel(
                CHANNEL_ID, "Mirroring", NotificationManager.IMPORTANCE_LOW);
            getSystemService(NotificationManager.class).createNotificationChannel(c);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (running) return START_STICKY;

        int resultCode = intent.getIntExtra("resultCode", -1);
        Intent data = getProjectionIntent(intent);
        maxEdge = intent.getIntExtra("width", 720);
        bitrate = intent.getIntExtra("bitrate", 4_000_000);
        fps = intent.getIntExtra("fps", 60);

        Notification n;
        if (Build.VERSION.SDK_INT >= 26) {
            n = new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Excellent Mirror")
                .setContentText("USB/ADB mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true)
                .build();
        } else {
            n = new Notification.Builder(this)
                .setContentTitle("Excellent Mirror")
                .setContentText("USB/ADB mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true)
                .build();
        }

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIF_ID, n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIF_ID, n);
        }

        new Thread(() -> startMirror(resultCode, data), "MirrorStart").start();
        return START_STICKY;
    }

    @SuppressWarnings("deprecation")
    private Intent getProjectionIntent(Intent intent) {
        if (Build.VERSION.SDK_INT >= 33) {
            return intent.getParcelableExtra("data", Intent.class);
        }
        return intent.getParcelableExtra("data");
    }

    private void startMirror(int resultCode, Intent data) {
        try {
            MediaProjectionManager mgr =
                (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
            projection = mgr.getMediaProjection(resultCode, data);
            if (projection == null) throw new IllegalStateException("MediaProjection gagal");

            running = true;
            registerDisplayListener();

            synchronized (pipelineLock) {
                rebuildPipelineLocked();
            }

            connectThread = new Thread(this::connectLoop, "MirrorConnect");
            connectThread.start();
        } catch (Throwable t) {
            stopSelf();
        }
    }

    @SuppressWarnings("deprecation")
    private DisplayMetrics metrics() {
        DisplayMetrics d = new DisplayMetrics();
        android.view.WindowManager wm =
            (android.view.WindowManager) getSystemService(WINDOW_SERVICE);
        if (wm != null && wm.getDefaultDisplay() != null) {
            wm.getDefaultDisplay().getRealMetrics(d);
        } else {
            d.setTo(getResources().getDisplayMetrics());
        }
        return d;
    }

    private int[] outputSize() {
        DisplayMetrics d = metrics();
        int sw = Math.max(2, d.widthPixels);
        int sh = Math.max(2, d.heightPixels);
        float scale = Math.min(1f, maxEdge / (float)Math.max(sw, sh));
        int w = Math.max(2, ((int)(sw * scale)) & ~1);
        int h = Math.max(2, ((int)(sh * scale)) & ~1);
        return new int[] {w, h};
    }

    private void rebuildPipelineLocked() throws Exception {
        stopEncoderLocked();

        int[] size = outputSize();
        currentW = size[0];
        currentH = size[1];

        MediaFormat fmt = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, currentW, currentH);
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);

        if (Build.VERSION.SDK_INT >= 23) {
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);
            try {
                fmt.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1);
            } catch (Throwable ignored) {}
        }

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        encoder.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = encoder.createInputSurface();
        encoder.start();

        display = projection.createVirtualDisplay(
            "ExcellentMirror",
            currentW,
            currentH,
            metrics().densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface, null, null);
    }

    private void stopEncoderLocked() {
        MediaCodec old = encoder;
        encoder = null;

        try { if (display != null) display.release(); } catch (Throwable ignored) {}
        display = null;
        try { if (inputSurface != null) inputSurface.release(); } catch (Throwable ignored) {}
        inputSurface = null;

        if (old != null) {
            try { old.stop(); } catch (Throwable ignored) {}
            try { old.release(); } catch (Throwable ignored) {}
        }
    }

    private void connectLoop() {
        while (running) {
            try (Socket socket = new Socket()) {
                socket.setTcpNoDelay(true);
                socket.setKeepAlive(true);
                socket.setSendBufferSize(64 * 1024);
                socket.connect(new InetSocketAddress(HOST, PORT), 800);
                streamSocket(socket);
            } catch (IOException ignored) {
                if (!running) break;
            }

            if (running) {
                try { Thread.sleep(150); }
                catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
    }

    private void streamSocket(Socket socket) {
        try {
            OutputStream out = socket.getOutputStream();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();

            while (running && !socket.isClosed()) {
                MediaCodec local;
                synchronized (pipelineLock) { local = encoder; }
                if (local == null) break;

                int idx = local.dequeueOutputBuffer(info, 5_000);

                if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat f = local.getOutputFormat();
                    byte[] config = makeConfigAnnexB(f);
                    if (config.length > 0) {
                        writePacket(out, (byte)0, config);
                    }
                    continue;
                }

                if (idx < 0) continue;

                ByteBuffer b = local.getOutputBuffer(idx);
                try {
                    if (b != null && info.size > 0) {
                        int start = Math.max(0, info.offset);
                        int end = Math.min(b.capacity(), info.offset + info.size);
                        if (end > start) {
                            b.position(start);
                            b.limit(end);
                            byte[] raw = new byte[b.remaining()];
                            b.get(raw);
                            byte[] annexB = toAnnexB(raw);

                            boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                            if (annexB.length > 0) {
                                writePacket(out, (byte)(key ? 1 : 2), annexB);
                            }
                        }
                    }
                } finally {
                    try { local.releaseOutputBuffer(idx, false); } catch (Throwable ignored) {}
                }
            }
        } catch (IOException ignored) {
            // Receiver disconnected or ADB tunnel was closed.
        }
    }

    private void writePacket(OutputStream out, byte type, byte[] payload) throws IOException {
        int n = payload.length + 1;
        out.write((n >>> 24) & 0xff);
        out.write((n >>> 16) & 0xff);
        out.write((n >>> 8) & 0xff);
        out.write(n & 0xff);
        out.write(type);
        out.write(payload);
        out.flush();
    }

    private byte[] makeConfigAnnexB(MediaFormat f) {
        try {
            ByteArrayOutput out = new ByteArrayOutput();
            ByteBuffer csd0 = f.getByteBuffer("csd-0");
            ByteBuffer csd1 = f.getByteBuffer("csd-1");
            if (csd0 != null) appendAvcCOrAnnexB(out, csd0);
            if (csd1 != null) appendAvcCOrAnnexB(out, csd1);
            return out.toByteArray();
        } catch (Throwable t) {
            return new byte[0];
        }
    }

    private static class ByteArrayOutput {
        byte[] data = new byte[8192];
        int size = 0;
        void ensure(int n) {
            if (size + n <= data.length) return;
            int cap = data.length;
            while (cap < size + n) cap *= 2;
            byte[] x = new byte[cap];
            System.arraycopy(data, 0, x, 0, size);
            data = x;
        }
        void write(byte[] x) {
            ensure(x.length);
            System.arraycopy(x, 0, data, size, x.length);
            size += x.length;
        }
        byte[] toByteArray() {
            byte[] x = new byte[size];
            System.arraycopy(data, 0, x, 0, size);
            return x;
        }
    }

    private void appendAvcCOrAnnexB(ByteArrayOutput out, ByteBuffer source) {
        ByteBuffer b = source.duplicate();
        byte[] data = new byte[b.remaining()];
        b.get(data);

        if (containsStartCode(data)) {
            out.write(data);
            return;
        }

        if (data.length >= 7 && (data[0] & 0xff) == 1) {
            int p = 5;
            int spsCount = data[p++] & 0x1f;
            for (int i = 0; i < spsCount && p + 2 <= data.length; i++) {
                int len = ((data[p] & 0xff) << 8) | (data[p + 1] & 0xff);
                p += 2;
                if (len <= 0 || p + len > data.length) break;
                writeStartCode(out);
                byte[] nal = new byte[len];
                System.arraycopy(data, p, nal, 0, len);
                out.write(nal);
                p += len;
            }
            if (p < data.length) {
                int ppsCount = data[p++] & 0xff;
                for (int i = 0; i < ppsCount && p + 2 <= data.length; i++) {
                    int len = ((data[p] & 0xff) << 8) | (data[p + 1] & 0xff);
                    p += 2;
                    if (len <= 0 || p + len > data.length) break;
                    writeStartCode(out);
                    byte[] nal = new byte[len];
                    System.arraycopy(data, p, nal, 0, len);
                    out.write(nal);
                    p += len;
                }
            }
            return;
        }

        out.write(data);
    }

    private static boolean containsStartCode(byte[] d) {
        for (int i = 0; i + 3 < d.length; i++) {
            if (d[i] == 0 && d[i+1] == 0 &&
                ((d[i+2] == 1) || (d[i+2] == 0 && d[i+3] == 1))) return true;
        }
        return false;
    }

    private static void writeStartCode(ByteArrayOutput out) {
        out.write(new byte[] {0, 0, 0, 1});
    }

    private static byte[] toAnnexB(byte[] raw) {
        if (containsStartCode(raw)) return raw;

        // Most AVC MediaCodec outputs are length-prefixed NAL units.
        ByteArrayOutput out = new ByteArrayOutput();
        int p = 0;
        boolean parsed = false;
        while (p + 4 <= raw.length) {
            int len = ((raw[p] & 0xff) << 24) |
                      ((raw[p+1] & 0xff) << 16) |
                      ((raw[p+2] & 0xff) << 8) |
                      (raw[p+3] & 0xff);
            p += 4;
            if (len <= 0 || p + len > raw.length) {
                parsed = false;
                break;
            }
            writeStartCode(out);
            byte[] nal = new byte[len];
            System.arraycopy(raw, p, nal, 0, len);
            out.write(nal);
            p += len;
            parsed = true;
        }
        return parsed && p == raw.length ? out.toByteArray() : raw;
    }

    private void registerDisplayListener() {
        displayManager = (DisplayManager)getSystemService(DISPLAY_SERVICE);
        displayListener = new DisplayManager.DisplayListener() {
            @Override public void onDisplayAdded(int displayId) {}
            @Override public void onDisplayRemoved(int displayId) {}
            @Override public void onDisplayChanged(int displayId) {
                if (displayId != Display.DEFAULT_DISPLAY || !running) return;
                new Thread(() -> {
                    try {
                        synchronized (pipelineLock) {
                            int[] next = outputSize();
                            if (next[0] != currentW || next[1] != currentH) {
                                rebuildPipelineLocked();
                            }
                        }
                    } catch (Throwable ignored) {}
                }, "MirrorRotate").start();
            }
        };
        displayManager.registerDisplayListener(displayListener, null);
    }

    @Override
    public void onDestroy() {
        running = false;
        if (connectThread != null) connectThread.interrupt();

        try {
            if (displayManager != null && displayListener != null) {
                displayManager.unregisterDisplayListener(displayListener);
            }
        } catch (Throwable ignored) {}

        synchronized (pipelineLock) {
            stopEncoderLocked();
        }

        try { if (projection != null) projection.stop(); } catch (Throwable ignored) {}
        projection = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
