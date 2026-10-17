import 'package:flutter/material.dart';

import 'data/reminders.dart';
import 'ui/conversations_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Set up the local-notifications plugin early so a tap on a fired reminder
  // (possibly cold-starting the app) is handled, and scheduling later is cheap.
  await ReminderService().init();
  runApp(const ThreadlyApp());
}

class ThreadlyApp extends StatelessWidget {
  const ThreadlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Threadly',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      // The home: the notification-driven conversation organizer.
      home: const ConversationsScreen(),
    );
  }
}
