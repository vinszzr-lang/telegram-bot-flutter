import 'package:flutter/material.dart';
import 'login_page.dart';
import '../services/session.dart';

class BannedPage extends StatelessWidget {
  final Session session;
  const BannedPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Akun Anda Di Banned', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () async {
                  await session.clear();
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => LoginPage(session: session, initialRegister: true)),
                    (_) => false,
                  );
                },
                child: const Text('Buat akun baru'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
