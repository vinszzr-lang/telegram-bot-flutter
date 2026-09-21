import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api.dart';
import '../services/session.dart';
import 'banned_page.dart';
import 'login_page.dart';

class ProfilePage extends StatefulWidget {
  final Session session;
  const ProfilePage({super.key, required this.session});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final api = Api();
  final picker = ImagePicker();
  bool uploading = false;
  bool changingUsername = false;

  void _showBanned() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => BannedPage(session: widget.session)),
      (_) => false,
    );
  }

  Future<void> _pickAvatar() async {
    // image_picker uses Android's native Photo Picker on supported Android
    // versions. Do not request READ_MEDIA_* first; doing so can send users
    // through the permission/file flow instead of opening the gallery picker.
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1200,
    );
    if (picked == null) return;
    final file = File(picked.path);
    try {
      final length = await file.length();
      if (length <= 0) throw Exception('Foto tidak dapat dibaca.');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Foto tidak valid: $e')));
      return;
    }
    setState(() => uploading = true);
    try {
      final data = await api.uploadAvatar(widget.session.token!, file);
      await widget.session.updateUser(Map<String, dynamic>.from(data['user']));
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      if (e.status == 403) return _showBanned();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengganti foto: $e')));
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> _changeUsername() async {
    final controller = TextEditingController(text: widget.session.username ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ganti username'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(prefixText: '@', hintText: 'username baru'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim().toLowerCase()), child: const Text('Simpan')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == widget.session.username) return;
    setState(() => changingUsername = true);
    try {
      final data = await api.changeUsername(widget.session.token!, value);
      await widget.session.save(data);
      if (mounted) setState(() {});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username berhasil diganti. Chat dan kontak tetap tersimpan.')));
    } on ApiException catch (e) {
      if (e.status == 403) return _showBanned();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengganti username: $e')));
    } finally {
      if (mounted) setState(() => changingUsername = false);
    }
  }

  Future<void> _logout() async {
    await widget.session.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => LoginPage(session: widget.session)), (_) => false);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = widget.session.avatarUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 58,
                  backgroundColor: const Color(0xFF51418B),
                  backgroundImage: avatar != null && avatar.isNotEmpty ? NetworkImage(avatar) : null,
                  child: avatar == null || avatar.isEmpty ? Text(widget.session.displayName.isEmpty ? '?' : widget.session.displayName[0].toUpperCase(), style: const TextStyle(fontSize: 40)) : null,
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: FloatingActionButton.small(
                    heroTag: 'avatar',
                    onPressed: uploading ? null : _pickAvatar,
                    child: uploading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.camera_alt),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Center(child: Text(widget.session.displayName, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold))),
          const SizedBox(height: 4),
          Center(child: Text('@${widget.session.username ?? ''}', style: const TextStyle(color: Colors.white54))),
          if (widget.session.verified)
            const Center(child: Padding(padding: EdgeInsets.only(top: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.verified, color: Color(0xFF3EA6FF)), SizedBox(width: 5), Text('Terverifikasi', style: TextStyle(color: Color(0xFF3EA6FF)))]))),
          const SizedBox(height: 28),
          ListTile(leading: const Icon(Icons.alternate_email), title: const Text('Ganti username'), subtitle: const Text('Chat dan kontak tidak dihapus'), trailing: changingUsername ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null, onTap: changingUsername ? null : _changeUsername),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Keluar'), onTap: _logout),
        ],
      ),
    );
  }
}
