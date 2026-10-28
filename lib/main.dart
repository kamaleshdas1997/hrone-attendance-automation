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
        // ── Perform punch-in ──────────────────────────────────────────────
        final result = await service.punchIn();
        final loginExpired = result.message.contains('Login expired');
        await notif.show(
          id: 1,
          title: loginExpired
              ? '🔑 HROne Login Expired'
              : result.success
                  ? '✅ Punch-In Done'
                  : '❌ Punch-In Failed',
          body: loginExpired
              ? 'Tap to sign in again — attendance not marked.'
              : result.message,
          isLoginExpired: loginExpired,
        );

        // ── Re-schedule tomorrow's punch-in (one-off → next day) ──────────
        // This is the KEY fix: periodic tasks don't fire at exact times;
        // we chain one-off tasks instead.
        if (prefs.getBool(PrefKeys.automationEnabled) ?? false) {
          await _rescheduleNextDay(
            taskName: AttendanceService.kPunchInTask,
            hourKey: PrefKeys.punchInHour,
            minuteKey: PrefKeys.punchInMinute,
            prefs: prefs,
          );
        }
      } else if (taskName == AttendanceService.kPunchOutTask) {
        // ── Perform punch-out ─────────────────────────────────────────────
        final result = await service.punchOut();
        final loginExpired = result.message.contains('Login expired');
        await notif.show(
          id: 2,
          title: loginExpired
              ? '🔑 HROne Login Expired'
              : result.success
                  ? '✅ Punch-Out Done'
                  : '❌ Punch-Out Failed',
          body: loginExpired
              ? 'Tap to sign in again — attendance not marked.'
              : result.message,
          isLoginExpired: loginExpired,
        );

        // ── Re-schedule tomorrow's punch-out ──────────────────────────────
        if (prefs.getBool(PrefKeys.automationEnabled) ?? false) {
          await _rescheduleNextDay(
            taskName: AttendanceService.kPunchOutTask,
            hourKey: PrefKeys.punchOutHour,
            minuteKey: PrefKeys.punchOutMinute,
            prefs: prefs,
          );
        }
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

/// Re-registers the given task for the same time TOMORROW.
/// Called from within the background callback so the chain never breaks.
Future<void> _rescheduleNextDay({
  required String taskName,
  required String hourKey,
  required String minuteKey,
  required SharedPreferences prefs,
}) async {
  try {
    final hour = prefs.getInt(hourKey) ?? (taskName == AttendanceService.kPunchInTask ? 9 : 18);
    final minute = prefs.getInt(minuteKey) ?? 0;
    final randomize = prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
    final maxJitter = prefs.getInt(PrefKeys.randomizeMinutes) ?? 5;

    // Calculate delay to the same time tomorrow
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute)
        .add(const Duration(days: 1)); // explicitly tomorrow

    if (randomize && maxJitter > 0) {
      // Use dart:math Random — avoid importing services to keep isolate slim
      final seed = now.millisecondsSinceEpoch;
      final jitter = (seed % (maxJitter * 2 + 1)) - maxJitter;
      target = target.add(Duration(minutes: jitter));
    }

    final delay = target.difference(now);

    await Workmanager().registerOneOffTask(
      taskName,
      taskName,
      initialDelay: delay.isNegative ? const Duration(hours: 23) : delay,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  } catch (_) {
    // Don't crash the worker if rescheduling fails — next app open calls applySchedule()
  }
}

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  } catch (_) {}

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
      routes: {
        '/home': (context) => const HomeScreen(),
      },
    );
  }
}
