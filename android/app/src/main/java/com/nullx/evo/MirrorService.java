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
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;

/**
 * Excellent Mirror sender.
 *
 * Transport is intentionally fixed to 127.0.0.1:27183. With a USB-connected
 * Android device, the Chromebook runs `adb reverse tcp:27183 tcp:27183`.
 *
 * Wire format:
 *   uint32 BE payload length
 *   uint8  type: 0=config(AVCDecoderConfigurationRecord), 1=key, 2=delta
 *   bytes  payload (H.264 AVCC)
 */
public class MirrorService extends Service {
    private static final int NOTIF_ID = 77;
    private static final String CHANNEL_ID = "mirror";
    private static final String HOST = "127.0.0.1";
    private static final int PORT = 27183;
    private static final String PREFS = "mirror_state";

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
        if (running) return START_STICKY;

        int resultCode = intent != null ? intent.getIntExtra("resultCode", -1) : -1;
        Intent data = getProjectionIntent(intent);
        maxEdge = intent != null ? intent.getIntExtra("width", 720) : 720;
        bitrate = intent != null ? intent.getIntExtra("bitrate", 4_000_000) : 4_000_000;
        fps = intent != null ? intent.getIntExtra("fps", 60) : 60;

        startForegroundNow();
        setStatus("Izin screen capture diterima • memulai encoder...");

        new Thread(() -> startMirror(resultCode, data), "MirrorStart").start();
        return START_STICKY;
    }

    private void startForegroundNow() {
        Notification n;
        if (Build.VERSION.SDK_INT >= 26) {
            n = new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Excellent Mirror")
                .setContentText("USB/ADB mirroring aktif")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true).build();
        } else {
            n = new Notification.Builder(this)
                .setContentTitle("Excellent Mirror")
                .setContentText("USB/ADB mirroring aktif")
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
            setStatus("Encoder aktif • menunggu ADB reverse...");

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
            MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, currentW, currentH);
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        if (Build.VERSION.SDK_INT >= 23) {
            try { fmt.setInteger(MediaFormat.KEY_PRIORITY, 0); } catch (Throwable ignored) {}
            try { fmt.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1); } catch (Throwable ignored) {}
        }
        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        encoder.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = encoder.createInputSurface();
            encoder.start();
            cachedConfig = null;
            display = projection.createVirtualDisplay(
                "ExcellentMirror", currentW, currentH, metrics().densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface, null, null);
            requestKeyFrame();
            setStatus("Encoder aktif • " + currentW + "x" + currentH + " • " + fps + " FPS");
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
        long lastConnectAttempt = 0;
        while (running) {
            try {
                if (socket == null || socket.isClosed() || !socket.isConnected()) {
                    long now = System.currentTimeMillis();
                    if (now - lastConnectAttempt < 150) { drainOnce(null); continue; }
                    lastConnectAttempt = now;
                    try {
                        Socket s = new Socket();
                        s.setTcpNoDelay(true); s.setKeepAlive(true); s.setSendBufferSize(64 * 1024);
                        s.connect(new InetSocketAddress(HOST, PORT), 350);
                        socket = s; out = s.getOutputStream();
                        if (cachedConfig != null) writePacket(out, (byte)0, cachedConfig);
                        requestKeyFrame();
                        setStatus("ADB reverse CONNECTED • streaming...");
                    } catch (IOException e) {
                        closeSocket(socket); socket = null; out = null;
                        setStatus("Menunggu ADB reverse / server Chromebook...");
                        drainOnce(null);
                        continue;
                    }
                }
                boolean ok = drainOnce(out);
                if (!ok) {
                    closeSocket(socket); socket = null; out = null;
                    setStatus("ADB reverse terputus • reconnect...");
                }
            } catch (Throwable t) {
                closeSocket(socket); socket = null; out = null;
                setStatus("Stream error: " + shortError(t));
            }
        }
        closeSocket(socket);
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
        synchronized (pipelineLock) { local = encoder; }
        if (local == null) return true;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            int idx = local.dequeueOutputBuffer(info, 5_000);
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat f = local.getOutputFormat();
                byte[] config = makeAvcConfig(f);
                if (config.length > 0) {
                    cachedConfig = config;
                    if (out != null) writePacket(out, (byte)0, config);
                    setStatus(out != null ? "H.264 config OK • streaming..." : "H.264 encoder OK • menunggu server...");
                }
                return true;
            }
            if (idx < 0) return true;
            ByteBuffer b = local.getOutputBuffer(idx);
            try {
                if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) return true;
                if (b == null || info.size <= 0) return true;
                int start = Math.max(0, info.offset);
                int end = Math.min(b.capacity(), info.offset + info.size);
                if (end <= start) return true;
                b.position(start); b.limit(end);
                byte[] raw = new byte[b.remaining()]; b.get(raw);
                byte[] avcc = toAvcc(raw);
                if (avcc.length == 0) return true;
                boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                if (out != null) {
                    if (cachedConfig != null && key) writePacket(out, (byte)0, cachedConfig);
                    writePacket(out, (byte)(key ? 1 : 2), avcc);
                    framesSent++; bytesSent += avcc.length;
                    if ((framesSent % 30) == 0) setStatus("Streaming • " + currentW + "x" + currentH + " • frame " + framesSent);
                }
                return true;
            } finally { try { local.releaseOutputBuffer(idx, false); } catch (Throwable ignored) {} }
        } catch (IOException e) { return false; }
          catch (IllegalStateException e) {
              // Rotation swaps the MediaCodec. Do not interpret the expected
              // old-codec transition as a dead TCP/ADB connection.
              return rebuildingPipeline || running;
          }
    }

    private void writePacket(OutputStream out, byte type, byte[] payload) throws IOException {
        int n = payload.length + 1;
        out.write((n >>> 24) & 255); out.write((n >>> 16) & 255); out.write((n >>> 8) & 255); out.write(n & 255);
        out.write(type); out.write(payload); out.flush();
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
        displayManager=(DisplayManager)getSystemService(DISPLAY_SERVICE);
        displayListener=new DisplayManager.DisplayListener(){
            @Override public void onDisplayAdded(int id){}
            @Override public void onDisplayRemoved(int id){}
            @Override public void onDisplayChanged(int id){
                if(id!=Display.DEFAULT_DISPLAY||!running)return;
                // Android may emit several display-change callbacks during one
                // rotation. Rebuilding for every callback races MediaCodec and
                // can make the stream look disconnected. Debounce them.
                if (pendingDisplayRebuild != null) {
                    displayHandler.removeCallbacks(pendingDisplayRebuild);
                }
                pendingDisplayRebuild = () -> new Thread(() -> {
                    try {
                        synchronized(pipelineLock) {
                            if (!running) return;
                            int[] n = outputSize();
                            if(n[0] != currentW || n[1] != currentH) rebuildPipelineLocked();
                        }
                    } catch(Throwable t) {
                        setStatus("Rotate error: "+shortError(t));
                    }
                },"MirrorRotate").start();
                displayHandler.postDelayed(pendingDisplayRebuild, 350);
            }
        };
        displayManager.registerDisplayListener(displayListener,null);
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
        projection=null; setStatus("Berhenti"); super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent){return null;}
}
