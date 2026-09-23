import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_chat/pages/login_page.dart';
import 'package:x_chat/services/session.dart';

void main() {
  testWidgets('X Chat login screen renders', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(session: Session())));
    expect(find.text('X Chat'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Belum punya akun? Buat akun'), findsOneWidget);
  });
}
