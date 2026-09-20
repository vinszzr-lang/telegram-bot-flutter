import 'package:socket_io_client/socket_io_client.dart' as io;
import 'api.dart';

class SocketService {
  io.Socket? socket;
  final String token;
  final void Function(Map<String, dynamic>) onMessage;
  final void Function(Map<String, dynamic>) onStatus;
  final void Function()? onBanned;
  final void Function(Map<String, dynamic>)? onProfileUpdated;

  SocketService(
    this.token,
    this.onMessage,
    this.onStatus, {
    this.onBanned,
    this.onProfileUpdated,
  });

  void connect() {
    socket = io.io(Api.baseUrl, io.OptionBuilder()
      .setTransports(['websocket'])
      .enableAutoConnect()
      .enableReconnection()
      .setAuth({'token': token})
      .build());
    socket!.onConnect((_) => onStatus({'state': 'connected'}));
    socket!.onDisconnect((_) => onStatus({'state': 'disconnected'}));
    socket!.onConnectError((e) {
      final text = e.toString();
      if (text.toLowerCase().contains('diblokir') || text.toLowerCase().contains('banned')) {
        onBanned?.call();
      }
      onStatus({'state': 'error', 'error': text});
    });
    socket!.on('message', (data) {
      if (data is Map) onMessage(Map<String, dynamic>.from(data));
    });
    socket!.on('profile_updated', (data) {
      if (data is Map) onProfileUpdated?.call(Map<String, dynamic>.from(data));
    });
    socket!.on('banned', (_) => onBanned?.call());
    socket!.on('message_deleted', (data) {
      if (data is Map) onMessage({'_event': 'deleted', 'id': data['id']});
    });
    socket!.connect();
  }

  void sendTyping(String username, bool typing) => socket?.emit('typing', {'username': username, 'typing': typing});
  void markRead(String username) => socket?.emit('read', {'username': username});
  void dispose() => socket?.dispose();
}
