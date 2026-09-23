import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/session.dart';
import 'home_page.dart';
import 'banned_page.dart';
import '../services/notification_service.dart';


class LoginPage extends StatefulWidget {
  final Session session;
  final bool initialRegister;
  const LoginPage({super.key, required this.session, this.initialRegister = false});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late bool register;
  bool loading = false;
  bool obscure = true;
  final first = TextEditingController();
  final last = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final api = Api();
  String? error;

  @override
  void initState() {
    super.initState();
    register = widget.initialRegister;
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    setState(() { loading = true; error = null; });
    try {
      final data = register
          ? await api.register(first.text.trim(), last.text.trim(), username.text.trim().toLowerCase(), password.text)
          : await api.login(username.text.trim().toLowerCase(), password.text);
      await widget.session.save(data);
      await NotificationService.init();
      await NotificationService.requestPermission();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => HomePage(session: widget.session)),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (e.status == 403) {
        if (mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BannedPage(session: widget.session)), (_) => false);
      } else if (mounted) {
        setState(() => error = e.message);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 30),
                  const _Logo(),
                  const SizedBox(height: 18),
                  Text(
                    register ? 'Buat akun X Chat' : 'Selamat datang kembali',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    register ? 'Pilih username unik untuk ditemukan pengguna lain.' : 'Login untuk melanjutkan chat.',
                    style: const TextStyle(color: Colors.white54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (register)
                    Row(children: [
                      Expanded(child: _field(first, 'Nama depan')),
                      const SizedBox(width: 10),
                      Expanded(child: _field(last, 'Nama belakang')),
                    ]),
                  if (register) const SizedBox(height: 12),
                  _field(username, 'Username', prefix: '@'),
                  const SizedBox(height: 12),
                  _field(
                    password,
                    'Password',
                    obscure: obscure,
                    suffix: IconButton(
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: loading ? null : submit,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: loading
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(register ? 'Buat akun' : 'Login'),
                  ),
                  TextButton(
                    onPressed: loading ? null : () => setState(() { register = !register; error = null; }),
                    child: Text(register ? 'Sudah punya akun? Login' : 'Belum punya akun? Buat akun'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String hint, {String? prefix, bool obscure = false, Widget? suffix}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        prefixText: prefix,
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF171E22),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(colors: [Color(0xFF6B4DFF), Color(0xFF2D6BFF)]),
          ),
          child: const Icon(Icons.chat_bubble_outline, size: 30),
        ),
        const SizedBox(width: 12),
        const Text('X Chat', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
      ],
    );
  }
}
