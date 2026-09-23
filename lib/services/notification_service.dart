import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static const _channel = MethodChannel('xchat/notifications');
  static Future<void> init() async { try { await _channel.invokeMethod('init'); } catch (_) {} }
  static Future<void> requestPermission() async { try { final status=await Permission.notification.status; if(!status.isGranted) await Permission.notification.request(); } catch (_) {} }
  static Future<void> show({required String title, required String body}) async { try { await _channel.invokeMethod('show', {'title':title,'body':body}); } catch (_) {} }
}
