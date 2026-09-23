import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../widgets/verified_badge.dart';

class CreateGroupPage extends StatefulWidget {
  final Session session;
  const CreateGroupPage({super.key, required this.session});
  @override State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final api = Api();
  final name = TextEditingController();
  final description = TextEditingController();
  final picker = ImagePicker();
  final selected = <String>{};
  XFile? photo;
  List<Map<String, dynamic>> contacts = [];
  bool loading = true, saving = false;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { contacts = (await api.contacts(widget.session.token!)).map((e) => Map<String, dynamic>.from(e)).toList(); } catch (_) {}
    if (mounted) setState(() => loading = false);
  }
  Future<void> _create() async {
    if (name.text.trim().isEmpty || selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Isi nama grup dan pilih minimal satu kontak.')));
      return;
    }
    setState(() => saving = true);
    try {
      var g = await api.createGroup(widget.session.token!, name.text.trim(), description.text.trim(), selected.toList());
      if (photo != null) { try { g = await api.uploadGroupAvatar(widget.session.token!, g['id'].toString(), File(photo!.path)); } catch (_) {} }
      if (mounted) Navigator.pop(context, g);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally { if (mounted) setState(() => saving = false); }
  }
  @override void dispose() { name.dispose(); description.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: AppBar(title: const Text('Grup baru')),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 30),
        children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama grup', prefixIcon: Icon(Icons.groups_rounded))),
          const SizedBox(height: 12),
          Center(child: GestureDetector(
            onTap: () async { final p = await picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1200); if (p != null && mounted) setState(() => photo = p); },
            child: CircleAvatar(radius: 46, backgroundColor: const Color(0xFF2D2039), backgroundImage: photo != null ? FileImage(File(photo!.path)) : null, child: photo == null ? const Icon(Icons.add_a_photo_outlined, size: 28) : null),
          )),
          const SizedBox(height: 8),
          const Center(child: Text('Foto grup opsional', style: TextStyle(color: Colors.white54))),
          const SizedBox(height: 12),
          TextField(controller: description, maxLines: 3, decoration: const InputDecoration(labelText: 'Deskripsi grup (opsional)', prefixIcon: Icon(Icons.notes_rounded))),
          const SizedBox(height: 22),
          const Text('Pilih anggota', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('${selected.length} dipilih', style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          if (contacts.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('Tambahkan kontak dulu.'))),
          ...contacts.map((c) {
            final u = (c['username'] ?? '').toString();
            final display = (c['name'] ?? c['displayName'] ?? u).toString();
            final avatar = (c['avatarUrl'] ?? '').toString();
            final checked = selected.contains(u);
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(color: checked ? const Color(0xFF162B24) : const Color(0xFF10171A), borderRadius: BorderRadius.circular(16)),
              child: CheckboxListTile(
                value: checked,
                onChanged: (_) => setState(() => checked ? selected.remove(u) : selected.add(u)),
                secondary: CircleAvatar(backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null, child: avatar.isEmpty ? Text(display.isEmpty ? '?' : display[0].toUpperCase()) : null),
                title: Row(children: [Flexible(child: Text(display, overflow: TextOverflow.ellipsis)), if (c['verified'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: VerifiedBadge(size: 15))]),
                subtitle: Text('@$u', style: const TextStyle(color: Colors.white54)),
              ),
            );
          }),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: saving ? null : _create, icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_rounded), label: Text(saving ? 'Membuat...' : 'Buat grup')),
        ],
      ),
    );
  }
}

class GroupInfoPage extends StatefulWidget {
  final Session session;
  final String groupId;
  const GroupInfoPage({super.key, required this.session, required this.groupId});
  @override State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  final api = Api();
  Map<String, dynamic>? group;
  bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final g = await api.group(widget.session.token!, widget.groupId); if (mounted) setState(() => group = g); } catch (_) {}
    if (mounted) setState(() => loading = false);
  }
  Future<void> _toggleSetting() async {
    final g = group!;
    if (g['role'] != 'owner') return;
    await showDialog(context: context, builder: (c) => AlertDialog(
      title: const Text('Pengaturan anggota'),
      content: SwitchListTile(
        value: g['onlyAdminsManage'] != false,
        onChanged: (v) async {
          Navigator.pop(c);
          try { final next = await api.updateGroupSettings(widget.session.token!, widget.groupId, onlyAdminsManage: v); if (mounted) setState(() => group = next); }
          catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
        },
        title: const Text('Hanya admin yang dapat menambah atau mengeluarkan anggota.'),
      ),
    ));
  }
  Future<void> _addMembers() async {
    final contacts = await api.contacts(widget.session.token!);
    final current = List<dynamic>.from(group?['members'] ?? const []);
    final existing = current.map((e) => e['username'].toString()).toSet();
    final picked = <String>{};
    if (!mounted) return;
    await showDialog(context: context, builder: (c) => StatefulBuilder(builder: (c, setLocal) => AlertDialog(
      title: const Text('Tambah anggota'),
      content: SizedBox(width: 420, height: 360, child: ListView(children: contacts.where((x) => !existing.contains(x['username'])).map((x) {
        final u = x['username'].toString();
        return CheckboxListTile(value: picked.contains(u), onChanged: (_) => setLocal(() {
              if (picked.contains(u)) {
                picked.remove(u);
              } else {
                picked.add(u);
              }
            }), title: Text((x['name'] ?? u).toString()), subtitle: Text('@$u'));
      }).toList())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(c);
            try {
              final next = await api.addGroupMembers(widget.session.token!, widget.groupId, picked.toList());
              if (!context.mounted) return;
              setState(() => group = next);
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
            }
          },
          child: const Text('Tambah'),
        ),
      ],
    )));
  }
  Future<void> _memberActions(Map<String, dynamic> m) async {
    final role = group?['role']?.toString();
    if (m['role'] == 'owner') return;
    final onlyAdmins = group?['onlyAdminsManage'] != false;
    if (onlyAdmins && role != 'owner' && role != 'admin') return;
    final target = m['username'].toString();
    await showModalBottomSheet(context: context, backgroundColor: const Color(0xFF10171A), builder: (c) => SafeArea(child: Wrap(children: [
      if (role == 'owner') ListTile(leading: const Icon(Icons.admin_panel_settings), title: Text(m['role'] == 'admin' ? 'Turunkan jadi anggota' : 'Jadikan admin'), onTap: () async {
        Navigator.pop(c);
        try { await api.setGroupRole(widget.session.token!, widget.groupId, target, m['role'] == 'admin' ? 'member' : 'admin'); await _load(); }
        catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
      }),
      ListTile(leading: const Icon(Icons.person_remove_outlined), title: const Text('Keluarkan dari grup'), onTap: () async {
        Navigator.pop(c);
        try { await api.removeGroupMember(widget.session.token!, widget.groupId, target); await _load(); }
        catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
      }),
    ])));
  }
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(backgroundColor: Color(0xFF080D10), body: Center(child: CircularProgressIndicator()));
    final g = group!;
    final members = List<Map<String, dynamic>>.from((g['members'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e)));
    final avatar = (g['avatarUrl'] ?? '').toString();
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: AppBar(title: const Text('Info grup'), actions: [IconButton(onPressed: _toggleSetting, icon: const Icon(Icons.tune_rounded))]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 40),
        children: [
          Center(child: CircleAvatar(radius: 54, backgroundColor: const Color(0xFF2D2039), backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null, child: avatar.isEmpty ? Text(g['name'].toString().isEmpty ? '?' : g['name'].toString()[0].toUpperCase(), style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800)) : null)),
          const SizedBox(height: 14),
          Center(child: Text(g['name'].toString(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800))),
          const SizedBox(height: 5),
          Center(child: Text('${members.length} anggota', style: const TextStyle(color: Colors.white54))),
          if ((g['description'] ?? '').toString().trim().isNotEmpty) ...[
            const SizedBox(height: 20),
            Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF10171A), borderRadius: BorderRadius.circular(18)), child: Text(g['description'].toString(), style: const TextStyle(color: Colors.white70, height: 1.4))),
          ],
          const SizedBox(height: 24),
          Row(children: [const Text('Anggota', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)), const Spacer(), if (g['role'] == 'owner' || g['role'] == 'admin' || g['onlyAdminsManage'] == false) IconButton(onPressed: _addMembers, icon: const Icon(Icons.person_add_alt_1_rounded))]),
          ...members.map((m) {
            final a = (m['avatarUrl'] ?? '').toString();
            final n = m['name'].toString();
            return ListTile(
              onTap: () => _memberActions(m),
              leading: CircleAvatar(backgroundImage: a.isNotEmpty ? NetworkImage(a) : null, child: a.isEmpty ? Text(n.isEmpty ? '?' : n[0].toUpperCase()) : null),
              title: Row(children: [Flexible(child: Text(n, overflow: TextOverflow.ellipsis)), if (m['verified'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: VerifiedBadge(size: 15))]),
              subtitle: Text(m['role'] == 'owner' ? 'Pembuat grup' : m['role'] == 'admin' ? 'Admin' : '@${m['username']}'),
            );
          }),
          const SizedBox(height: 20),
          if (g['role'] != 'owner')
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await api.leaveGroup(widget.session.token!, widget.groupId);
                  if (!context.mounted) return;
                  Navigator.pop(context, true);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Keluar dari grup'),
            ),
        ],
      ),
    );
  }
}
