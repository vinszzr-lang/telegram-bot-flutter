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
import android.view.Display;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.view.Surface;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.ByteBuffer;

/**
 * Low-latency screen sender.
 *
 * Design goals:
 * - Hardware H.264 through a Surface encoder.
 * - Outbound TCP to a separate receiver server; USB/ADB can be used with adb reverse.
 * - Bounded output: if the receiver falls behind, the socket is dropped
 *   instead of allowing old video frames to pile up.
 * - Rebuild the encoder/display when the phone rotates so the stream follows
 *   the physical screen orientation.
 */
public class MirrorService extends Service {
    private static final int NOTIF_ID = 77;
    private static final String CHANNEL_ID = "mirror";

    private final Object pipelineLock = new Object();

    private MediaProjection projection;
    private VirtualDisplay display;
    private MediaCodec encoder;
    private Surface inputSurface;
    private volatile boolean running;
    private Thread connectThread;
    private String serverHost = "192.168.1.100";

    private int maxEdge = 720;
    private int bitrate = 2_000_000;
    private int fps = 30;
    private int port = 27183;

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
        bitrate = intent.getIntExtra("bitrate", 2_000_000);
        fps = intent.getIntExtra("fps", 30);
        port = intent.getIntExtra("port", 27183);
        serverHost = intent.getStringExtra("host");
        if (serverHost == null || serverHost.trim().isEmpty()) serverHost = "192.168.1.100";

        Notification n;
        if (Build.VERSION.SDK_INT >= 26) {
            n = new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Excellent Mirror")
                .setContentText("Mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true)
                .build();
        } else {
            n = new Notification.Builder(this)
                .setContentTitle("Excellent Mirror")
                .setContentText("Mirroring aktif")
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

        // Long edge is capped; short edge follows the phone's aspect ratio.
        // Both dimensions are even for H.264.
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

        fmt.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);

        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);

        // Frequent keyframes make rotation/reconnect recover quickly without
        // making the bitrate explode.
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);

        if (Build.VERSION.SDK_INT >= 23) {
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);
            try {
                fmt.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1);
            } catch (Throwable ignored) {}
        }

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        encoder.configure(
            fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = encoder.createInputSurface();
        encoder.start();

        display = projection.createVirtualDisplay(
            "ExcellentMirror",
            currentW,
            currentH,
            metrics().densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            null);

    }

    private void stopEncoderLocked() {
        MediaCodec oldEncoder = encoder;
        encoder = null;

        try {
            if (display != null) display.release();
        } catch (Throwable ignored) {}
        display = null;

        try {
            if (inputSurface != null) inputSurface.release();
        } catch (Throwable ignored) {}
        inputSurface = null;

        if (oldEncoder != null) {
            try { oldEncoder.stop(); } catch (Throwable ignored) {}
            try { oldEncoder.release(); } catch (Throwable ignored) {}
        }
    }

    /**
     * Connect outbound to the separate receiver server.
     *
     * There is intentionally no producer queue between MediaCodec and the
     * socket. If the network/server cannot keep up, the TCP connection is
     * dropped and retried rather than accumulating seconds of stale video.
     */
    private void connectLoop() {
        while (running) {
            try (Socket socket = new Socket()) {
                socket.setTcpNoDelay(true);
                socket.setKeepAlive(true);
                socket.setSendBufferSize(64 * 1024);
                socket.connect(new java.net.InetSocketAddress(serverHost, port), 1500);
                streamSocket(socket);
            } catch (IOException ignored) {
                if (!running) break;
            }

            if (running) {
                try {
                    Thread.sleep(500);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
    }

    private void streamSocket(Socket socket) {
        try {
            OutputStream out =
                new BufferedOutputStream(socket.getOutputStream(), 8 * 1024);

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();

            while (running && !socket.isClosed()) {
                MediaCodec localEncoder;
                synchronized (pipelineLock) {
                    localEncoder = encoder;
                }
                if (localEncoder == null) break;

                int idx = localEncoder.dequeueOutputBuffer(info, 5_000);

                if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat f = localEncoder.getOutputFormat();
                    writeCsdAsAnnexB(out, f);
                    out.flush();
                    continue;
                }

                if (idx < 0) continue;

                ByteBuffer b = localEncoder.getOutputBuffer(idx);
                try {
                    if (b != null && info.size > 0) {
                        int start = info.offset;
                        int end = info.offset + info.size;
                        if (start < 0 || end > b.capacity()) continue;

                        b.position(start);
                        b.limit(end);

                        // Copy only one encoded frame. There is deliberately no
                        // queue: a slow receiver causes the connection to end.
                        byte[] frame = new byte[b.remaining()];
                        b.get(frame);
                        out.write(frame);
                        out.flush();
                    }
                } finally {
                    try { localEncoder.releaseOutputBuffer(idx, false); }
                    catch (Throwable ignored) {}
                }
            }
        } catch (IOException ignored) {
            // Receiver disconnected or ADB tunnel closed.
        }
    }

    private void writeCsdAsAnnexB(OutputStream out, MediaFormat f) throws IOException {
        ByteBuffer csd0 = f.getByteBuffer("csd-0");
        ByteBuffer csd1 = f.getByteBuffer("csd-1");

        if (csd0 != null) writeAvcCOrAnnexB(out, csd0);
        if (csd1 != null) writeAvcCOrAnnexB(out, csd1);
    }

    private void writeAvcCOrAnnexB(OutputStream out, ByteBuffer source) throws IOException {
        ByteBuffer b = source.duplicate();
        byte[] data = new byte[b.remaining()];
        b.get(data);

        // Annex-B already: pass through.
        if (containsStartCode(data)) {
            out.write(data);
            return;
        }

        // AVCDecoderConfigurationRecord (avcC): SPS/PPS are length-prefixed.
        if (data.length >= 7 && (data[0] & 0xFF) == 1) {
            int p = 5;
            int spsCount = data[p++] & 0x1F;

            for (int i = 0; i < spsCount && p + 2 <= data.length; i++) {
                int len = ((data[p] & 0xFF) << 8) | (data[p + 1] & 0xFF);
                p += 2;
                if (len <= 0 || p + len > data.length) return;
                out.write(new byte[]{0,0,0,1});
                out.write(data, p, len);
                p += len;
            }

            if (p >= data.length) return;
            int ppsCount = data[p++] & 0xFF;
            for (int i = 0; i < ppsCount && p + 2 <= data.length; i++) {
                int len = ((data[p] & 0xFF) << 8) | (data[p + 1] & 0xFF);
                p += 2;
                if (len <= 0 || p + len > data.length) return;
                out.write(new byte[]{0,0,0,1});
                out.write(data, p, len);
                p += len;
            }
        }
    }

    private boolean containsStartCode(byte[] data) {
        for (int i = 0; i + 3 < data.length; i++) {
            if (data[i] == 0 && data[i + 1] == 0 &&
                ((data[i + 2] == 1) ||
                 (data[i + 2] == 0 && data[i + 3] == 1))) {
                return true;
            }
        }
        return false;
    }


    private void registerDisplayListener() {
        displayManager = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        if (displayManager == null) return;

        displayListener = new DisplayManager.DisplayListener() {
            @Override public void onDisplayAdded(int displayId) {}

            @Override public void onDisplayRemoved(int displayId) {}

            @Override public void onDisplayChanged(int displayId) {
                if (displayId != Display.DEFAULT_DISPLAY || !running) return;

                int[] next = outputSize();
                if (next[0] == currentW && next[1] == currentH) return;

                new Thread(() -> {
                    synchronized (pipelineLock) {
                        if (!running) return;
                        try {
                            rebuildPipelineLocked();
                        } catch (Throwable t) {
                            stopSelf();
                        }
                    }
                }, "MirrorDisplayRefresh").start();
            }
        };

        displayManager.registerDisplayListener(displayListener, null);
    }

    private void unregisterDisplayListener() {
        try {
            if (displayManager != null && displayListener != null) {
                displayManager.unregisterDisplayListener(displayListener);
            }
        } catch (Throwable ignored) {}
        displayListener = null;
        displayManager = null;
    }

    /**
     * Public helper used by the activity if a future UI wants to force a
     * pipeline refresh. The normal path refreshes when the service restarts.
     */
    public void refreshForRotation() {
        if (!running) return;
        new Thread(() -> {
            synchronized (pipelineLock) {
                try {
                    rebuildPipelineLocked();
                } catch (Throwable ignored) {
                    stopSelf();
                }
            }
        }, "MirrorRotation").start();
    }

    @Override
    public void onDestroy() {
        running = false;
        unregisterDisplayListener();

        synchronized (pipelineLock) {
            stopEncoderLocked();
        }

        try {
            if (projection != null) projection.stop();
        } catch (Throwable ignored) {}
        projection = null;

        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
