import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'services/attendance_service.dart';
import 'services/notification_service.dart';

// ---------------------------------------------------------------------------
// Background task callback (top-level, required by Workmanager)
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final prefs = await SharedPreferences.getInstance();
    final service = AttendanceService(prefs);
    final notif = NotificationService();
    await notif.init();

    try {
      if (taskName == AttendanceService.kPunchInTask) {
        final result = await service.punchIn();
        await notif.show(
          id: 1,
          title: result.success ? '✅ Punch-In Done' : '❌ Punch-In Failed',
          body: result.message,
        );
      } else if (taskName == AttendanceService.kPunchOutTask) {
        final result = await service.punchOut();
        await notif.show(
          id: 2,
          title: result.success ? '✅ Punch-Out Done' : '❌ Punch-Out Failed',
          body: result.message,
        );
      }
    } catch (e) {
      await notif.show(
        id: 99,
        title: '⚠️ Attendance Error',
        body: e.toString(),
      );
    }

    return Future.value(true);
  });
}

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Workmanager for background tasks.
  // Must complete before runApp so the callback dispatcher is registered.
  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  } catch (_) {
    // Workmanager init failure is non-fatal — app still opens, background
    // tasks won't fire until the user saves the schedule again.
  }

  runApp(const HROneApp());
}

class HROneApp extends StatelessWidget {
  const HROneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HROne Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
