import 'package:flutter/material.dart';
import 'services/session.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'utils/navigation.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session();
  await session.load();
  runApp(ChatWithUApp(session: session));
}

class ChatWithUApp extends StatelessWidget {
  final Session session;
  const ChatWithUApp({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorObservers: [chatWithURouteObserver],
      title: 'ChatWithU',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080D10),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C4DFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'sans',
      ),
      home: session.token == null
          ? LoginPage(session: session)
          : HomePage(session: session),
      routes: {
        '/login': (_) => LoginPage(session: session),
      },
    );
  }
}

