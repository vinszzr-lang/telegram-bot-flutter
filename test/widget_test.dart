import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatwithu/pages/login_page.dart';
import 'package:chatwithu/services/session.dart';

void main() {
  testWidgets('ChatWithU login screen renders', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(session: Session())));
    expect(find.text('ChatWithU'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Belum punya akun? Buat akun'), findsOneWidget);
  });
}
