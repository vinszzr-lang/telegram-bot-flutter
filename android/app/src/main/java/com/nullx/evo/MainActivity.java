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
    private int pendingLongEdge = 720;
    private int pendingBitrate = 4_000_000;
    private int pendingFps = 60;

    @Override public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "startProjection":
                        Number edge=call.argument("width"), br=call.argument("bitrate"), frame=call.argument("fps");
                        pendingLongEdge=edge!=null?edge.intValue():720;
                        pendingBitrate=br!=null?br.intValue():4_000_000;
                        pendingFps=frame!=null?frame.intValue():60;
                        MediaProjectionManager mgr=(MediaProjectionManager)getSystemService(MEDIA_PROJECTION_SERVICE);
                        startActivityForResult(mgr.createScreenCaptureIntent(),REQUEST_CAPTURE);
                        result.success("Meminta izin screen capture...");
                        break;
                    case "stopProjection":
                        stopService(new Intent(this,MirrorService.class)); result.success(null); break;
                    case "status":
                        result.success(getSharedPreferences("mirror_state",MODE_PRIVATE).getString("status","Siap — sambungkan USB + ADB"));
                        break;
                    case "stats":
                        android.content.SharedPreferences p=getSharedPreferences("mirror_state",MODE_PRIVATE);
                        java.util.Map<String,Object> m=new java.util.HashMap<>();
                        m.put("status",p.getString("status","—"));m.put("frames",p.getLong("frames",0));m.put("bytes",p.getLong("bytes",0));result.success(m); break;
                    default: result.notImplemented();
                }
            });
    }

    @Override protected void onActivityResult(int requestCode,int resultCode,Intent data){
        super.onActivityResult(requestCode,resultCode,data);
        if(requestCode!=REQUEST_CAPTURE)return;
        if(resultCode!=Activity.RESULT_OK||data==null){
            getSharedPreferences("mirror_state",MODE_PRIVATE).edit().putString("status","Izin screen capture dibatalkan").apply();
            return;
        }
        Intent i=new Intent(this,MirrorService.class);
        i.putExtra("resultCode",resultCode);i.putExtra("data",data);
        i.putExtra("width",pendingLongEdge);i.putExtra("bitrate",pendingBitrate);i.putExtra("fps",pendingFps);
        try { startForegroundService(i); }
        catch(Throwable t){ startService(i); }
    }
}
