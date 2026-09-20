import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  static const baseUrl = String.fromEnvironment(
    'CHATWITHU_BASE_URL',
    defaultValue: 'https://stock-staining-composure.ngrok-free.dev',
  );

  Uri uri(String path) => Uri.parse('$baseUrl${path.startsWith('/') ? path : '/$path'}');

  Future<dynamic> request(String method, String path, {String? token, Object? body}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (token != null && token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    late http.Response r;
    final u = uri(path);
    switch (method) {
      case 'GET': r = await http.get(u, headers: headers); break;
      case 'POST': r = await http.post(u, headers: headers, body: body == null ? null : jsonEncode(body)); break;
      case 'PATCH': r = await http.patch(u, headers: headers, body: body == null ? null : jsonEncode(body)); break;
      case 'DELETE': r = await http.delete(u, headers: headers); break;
      default: throw ArgumentError(method);
    }
    dynamic data;
    try { data = r.body.isEmpty ? null : jsonDecode(r.body); } catch (_) { data = r.body; }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final msg = data is Map ? (data['message'] ?? data['error'] ?? 'Request gagal') : 'Request gagal (${r.statusCode})';
      throw ApiException(r.statusCode, msg.toString());
    }
    return data;
  }

  Future<Map<String, dynamic>> login(String username, String password) async =>
      Map<String, dynamic>.from(await request('POST', '/api/auth/login', body: {'username': username, 'password': password}));

  Future<Map<String, dynamic>> register(String first, String last, String username, String password) async =>
      Map<String, dynamic>.from(await request('POST', '/api/auth/register', body: {'firstName': first, 'lastName': last, 'username': username, 'password': password}));

  Future<Map<String, dynamic>> me(String token) async =>
      Map<String, dynamic>.from(await request('GET', '/api/auth/me', token: token));

  Future<Map<String, dynamic>> sync(String token) async =>
      Map<String, dynamic>.from(await request('GET', '/api/sync', token: token));

  Future<Map<String, dynamic>> changeUsername(String token, String username) async =>
      Map<String, dynamic>.from(await request('PATCH', '/api/auth/username', token: token, body: {'username': username}));

  Future<Map<String, dynamic>> uploadAvatar(String token, File file) async {
    final req = http.MultipartRequest('POST', uri('/api/profile/avatar'));
    req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await req.send();
    final text = await res.stream.bytesToString();
    dynamic data;
    try { data = jsonDecode(text); } catch (_) { data = {'message': text}; }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, (data is Map ? (data['message'] ?? 'Upload gagal') : 'Upload gagal').toString());
    }
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> findUser(String token, String username) async =>
      Map<String, dynamic>.from(await request('GET', '/api/users/${Uri.encodeComponent(username)}', token: token));

  Future<List<dynamic>> contacts(String token) async => List<dynamic>.from(await request('GET', '/api/contacts', token: token));
  Future<List<dynamic>> inbox(String token) async => List<dynamic>.from(await request('GET', '/api/inbox', token: token));

  Future<void> addContact(String token, String username, String name) async =>
      await request('POST', '/api/contacts', token: token, body: {'username': username, 'name': name});

  Future<void> renameContact(String token, String username, String name) async =>
      await request('PATCH', '/api/contacts/${Uri.encodeComponent(username)}', token: token, body: {'name': name});

  Future<List<dynamic>> messages(String token, String username, {String? since}) async {
    final query = since == null ? '' : '?since=${Uri.encodeQueryComponent(since)}';
    return List<dynamic>.from(await request('GET', '/api/chats/${Uri.encodeComponent(username)}/messages$query', token: token));
  }

  Future<Map<String, dynamic>> sendMessage(String token, String username, String message) async =>
      Map<String, dynamic>.from(await request('POST', '/api/chats/${Uri.encodeComponent(username)}/messages', token: token, body: {'type': 'text', 'message': message}));

  Future<Map<String, dynamic>> uploadMedia(String token, String username, File file, {String type = 'video'}) async {
    final req = http.MultipartRequest('POST', uri('/api/chats/${Uri.encodeComponent(username)}/media'));
    req.headers['Authorization'] = 'Bearer $token';
    req.fields['type'] = type;
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await req.send();
    final text = await res.stream.bytesToString();
    dynamic data;
    try { data = jsonDecode(text); } catch (_) { data = {'message': text}; }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, (data is Map ? (data['message'] ?? 'Upload gagal') : 'Upload gagal').toString());
    }
    return Map<String, dynamic>.from(data as Map);
  }
}
