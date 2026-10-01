package com.nullx.evo;

import android.app.Activity;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "excellent.mirror/control";
    private static final int REQUEST_CAPTURE = 4201;

    // Transport is intentionally fixed to the device-side ADB reverse endpoint.
    // Chromebook runs: adb reverse tcp:27183 tcp:27183
    private int pendingLongEdge = 720;
    private int pendingBitrate = 4_000_000;
    private int pendingFps = 60;

    @Override
    public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);

        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("startProjection".equals(call.method)) {
                    Number edge = call.argument("width");
                    Number br = call.argument("bitrate");
                    Number frame = call.argument("fps");

                    pendingLongEdge = edge != null ? edge.intValue() : 720;
                    pendingBitrate = br != null ? br.intValue() : 4_000_000;
                    pendingFps = frame != null ? frame.intValue() : 60;

                    MediaProjectionManager mgr =
                        (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
                    startActivityForResult(
                        mgr.createScreenCaptureIntent(), REQUEST_CAPTURE);
                    result.success("Menunggu izin screen capture...");
                } else if ("stopProjection".equals(call.method)) {
                    stopService(new Intent(this, MirrorService.class));
                    result.success(null);
                } else {
                    result.notImplemented();
                }
            });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        if (requestCode == REQUEST_CAPTURE &&
            resultCode == Activity.RESULT_OK && data != null) {

            Intent i = new Intent(this, MirrorService.class);
            i.putExtra("resultCode", resultCode);
            i.putExtra("data", data);
            i.putExtra("width", pendingLongEdge);
            i.putExtra("bitrate", pendingBitrate);
            i.putExtra("fps", pendingFps);
            startForegroundService(i);
        }
    }
}
