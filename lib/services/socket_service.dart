import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  io.Socket? _socket;
  String? _token;

  bool get connected => _socket?.connected == true;

  void connect(String baseUrl, String token) {
    if (_token == token && _socket != null) return;
    disconnect();
    _token = token;
    _socket = io.io(baseUrl, io.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .setAuth({'token': token})
      .enableReconnection()
      .setReconnectionAttempts(999999)
      .setReconnectionDelay(500)
      .setReconnectionDelayMax(5000)
      .build());
    _socket!.connect();
  }

  void on(String event, Function(dynamic) handler) => _socket?.on(event, handler);
  void off(String event, [Function(dynamic)? handler]) => _socket?.off(event, handler);
  void emit(String event, [dynamic data]) => _socket?.emit(event, data);

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _token = null;
  }
}
