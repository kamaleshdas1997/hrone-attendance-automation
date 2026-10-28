import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Call once at app start (or in background isolate).
  /// Does NOT ask for permissions — safe to call from main() before runApp().
  Future<void> init() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      const settings = InitializationSettings(android: android, iOS: ios);
      await _plugin.initialize(settings);
      _initialized = true;
    } catch (_) {
      // Non-fatal — notifications just won't show
    }
  }

  /// Request OS permission. Call this AFTER the first frame is rendered
  /// (e.g. from HomeScreen.initState via WidgetsBinding.addPostFrameCallback).
  Future<void> requestPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
      // Permission denied or unavailable — continue without notifications
    }
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
    bool isLoginExpired = false,
  }) async {
    if (!_initialized) await init();
    try {
      final androidDetails = AndroidNotificationDetails(
        isLoginExpired
            ? 'hrone_login_expired'
            : 'hrone_attendance_channel',
        isLoginExpired ? 'Login Alerts' : 'Attendance Automation',
        channelDescription: isLoginExpired
            ? 'Alerts when your HROne login session expires'
            : 'Notifications for automated attendance punches',
        importance: isLoginExpired ? Importance.max : Importance.high,
        priority: isLoginExpired ? Priority.max : Priority.high,
        icon: '@mipmap/ic_launcher',
        autoCancel: true,
        // Expand full help text for login-expired notifications
        styleInformation: isLoginExpired
            ? const BigTextStyleInformation(
                'Your HROne login session has expired and attendance was NOT marked.\n\n'
                'Open the app → Account tab → tap "Sign in with Microsoft" to renew your session. '
                'Scheduled punches will resume automatically.',
                htmlFormatBigText: false,
                contentTitle: '🔑 Action required',
                summaryText: 'Tap to open the app',
              )
            : null,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _plugin.show(id, title, body, details);
    } catch (_) {
      // Silent fail — punch already happened, notification is non-critical
    }
  }
}
