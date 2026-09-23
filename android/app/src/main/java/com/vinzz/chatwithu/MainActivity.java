package com.vinzz.chatwithu;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.os.Vibrator;
import android.os.VibrationEffect;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "xchat/notifications";
    private static final String NOTIFICATION_CHANNEL_ID = "xchat_messages";
    private int nextId = 1000;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("init".equals(call.method)) { createChannel(); result.success(null); return; }
                if ("vibrate500".equals(call.method)) { vibrate500(); result.success(null); return; }
                if ("show".equals(call.method)) {
                    createChannel();
                    String title = call.argument("title");
                    String body = call.argument("body");
                    showNotification(title == null ? "X Chat" : title, body == null ? "Pesan baru" : body);
                    result.success(null);
                    return;
                }
                result.notImplemented();
            });
    }

    private void vibrate500() {
        Vibrator vibrator = (Vibrator) getSystemService(VIBRATOR_SERVICE);
        if (vibrator == null || !vibrator.hasVibrator()) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(500, VibrationEffect.DEFAULT_AMPLITUDE));
        } else {
            vibrator.vibrate(500);
        }
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(NOTIFICATION_CHANNEL_ID, "Pesan X Chat", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("Notifikasi pesan baru");
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) manager.createNotificationChannel(channel);
        }
    }

    private void showNotification(String title, String body) {
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager == null) return;
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, NOTIFICATION_CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        Intent intent = new Intent(this, MainActivity.class);
        intent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pending = PendingIntent.getActivity(this, nextId, intent, flags);
        builder.setSmallIcon(getApplicationInfo().icon)
            .setContentIntent(pending)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(Notification.PRIORITY_HIGH);
        manager.notify(nextId++, builder.build());
    }
}
