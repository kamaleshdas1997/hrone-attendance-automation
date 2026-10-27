import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------
class AttendanceResult {
  final bool success;
  final String message;
  const AttendanceResult({required this.success, required this.message});
}

// ---------------------------------------------------------------------------
// Pref keys
// ---------------------------------------------------------------------------
class PrefKeys {
  static const domain = 'hrone_domain';
  static const username = 'hrone_username';
  static const password = 'hrone_password';
  static const authToken = 'hrone_auth_token';
  static const punchInHour = 'punch_in_hour';
  static const punchInMinute = 'punch_in_minute';
  static const punchOutHour = 'punch_out_hour';
  static const punchOutMinute = 'punch_out_minute';
  static const automationEnabled = 'automation_enabled';
  static const lastPunchInTime = 'last_punch_in_time';
  static const lastPunchOutTime = 'last_punch_out_time';
  static const lastPunchInStatus = 'last_punch_in_status';
  static const lastPunchOutStatus = 'last_punch_out_status';
}

// ---------------------------------------------------------------------------
// AttendanceService — wraps HROne REST API
//
// API base: https://api.hrone.cloud
//
// Auth flow (reverse-engineered from the HROne Swagger UI):
//   POST /api/v1/auth/login  { domain, username, password }
//   → { data: { token: "..." } }
//
// Mark attendance:
//   POST /api/v1/attendance/mark-attendance
//   Headers: Authorization: Bearer <token>
//   Body: { punchType: "IN" | "OUT", punchTime: "2024-01-15T09:00:00" }
// ---------------------------------------------------------------------------
class AttendanceService {
  static const kPunchInTask = 'hrone_punch_in';
  static const kPunchOutTask = 'hrone_punch_out';

  static const String _baseUrl = 'https://api.hrone.cloud';

  final SharedPreferences _prefs;

  AttendanceService(this._prefs);

  // ---- Credential helpers --------------------------------------------------

  String get domain => _prefs.getString(PrefKeys.domain) ?? '';
  String get username => _prefs.getString(PrefKeys.username) ?? '';
  String get password => _prefs.getString(PrefKeys.password) ?? '';

  Future<void> saveCredentials({
    required String domain,
    required String username,
    required String password,
  }) async {
    await _prefs.setString(PrefKeys.domain, domain.trim());
    await _prefs.setString(PrefKeys.username, username.trim());
    await _prefs.setString(PrefKeys.password, password);
    // Clear cached token when creds change
    await _prefs.remove(PrefKeys.authToken);
  }

  // ---- Auth ----------------------------------------------------------------

  /// Login and cache the Bearer token.
  Future<String> _getToken({bool forceRefresh = false}) async {
    final cached = _prefs.getString(PrefKeys.authToken);
    if (cached != null && cached.isNotEmpty && !forceRefresh) return cached;

    final uri = Uri.parse('$_baseUrl/api/v1/auth/login');
    final resp = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'domain': domain,
            'username': username,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body);
      // Try multiple common response shapes
      final token = json['data']?['token'] ??
          json['data']?['accessToken'] ??
          json['token'] ??
          json['accessToken'];
      if (token == null) {
        throw Exception('Login response did not contain a token.\n${resp.body}');
      }
      await _prefs.setString(PrefKeys.authToken, token as String);
      return token;
    } else {
      final body = resp.body;
      throw Exception('Login failed (${resp.statusCode}): $body');
    }
  }

  // ---- Attendance API ------------------------------------------------------

  Future<AttendanceResult> punchIn() => _punch('IN');
  Future<AttendanceResult> punchOut() => _punch('OUT');

  Future<AttendanceResult> _punch(String type) async {
    try {
      final token = await _getToken();
      final now = DateTime.now();
      final iso = now.toIso8601String().substring(0, 19); // trim millis

      final uri = Uri.parse('$_baseUrl/api/v1/attendance/mark-attendance');
      final resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'punchType': type,
              'punchTime': iso,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      final msg = ok
          ? 'Punch $type successful at $iso'
          : 'Server error ${resp.statusCode}: ${resp.body}';

      // If 401 → token expired, try once with fresh token
      if (resp.statusCode == 401) {
        final freshToken = await _getToken(forceRefresh: true);
        final retry = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $freshToken',
              },
              body: jsonEncode({'punchType': type, 'punchTime': iso}),
            )
            .timeout(const Duration(seconds: 15));
        final retryOk = retry.statusCode >= 200 && retry.statusCode < 300;
        final retryMsg = retryOk
            ? 'Punch $type successful at $iso'
            : 'Retry error ${retry.statusCode}: ${retry.body}';
        await _saveStatus(type, retryOk, retryMsg);
        return AttendanceResult(success: retryOk, message: retryMsg);
      }

      await _saveStatus(type, ok, msg);
      return AttendanceResult(success: ok, message: msg);
    } catch (e) {
      final msg = e.toString();
      await _saveStatus(type, false, msg);
      return AttendanceResult(success: false, message: msg);
    }
  }

  Future<void> _saveStatus(String type, bool ok, String msg) async {
    final now = DateTime.now().toIso8601String();
    if (type == 'IN') {
      await _prefs.setString(PrefKeys.lastPunchInTime, now);
      await _prefs.setString(
          PrefKeys.lastPunchInStatus, ok ? 'success: $msg' : 'error: $msg');
    } else {
      await _prefs.setString(PrefKeys.lastPunchOutTime, now);
      await _prefs.setString(
          PrefKeys.lastPunchOutStatus, ok ? 'success: $msg' : 'error: $msg');
    }
  }

  // ---- Schedule ------------------------------------------------------------

  /// Register or cancel daily background tasks based on saved schedule.
  Future<void> applySchedule() async {
    // Cancel existing
    await Workmanager().cancelAll();

    if (!(_prefs.getBool(PrefKeys.automationEnabled) ?? false)) return;

    final inH = _prefs.getInt(PrefKeys.punchInHour) ?? 9;
    final inM = _prefs.getInt(PrefKeys.punchInMinute) ?? 0;
    final outH = _prefs.getInt(PrefKeys.punchOutHour) ?? 18;
    final outM = _prefs.getInt(PrefKeys.punchOutMinute) ?? 0;

    await Workmanager().registerPeriodicTask(
      kPunchInTask,
      kPunchInTask,
      frequency: const Duration(hours: 24),
      initialDelay: _delayUntil(inH, inM),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );

    await Workmanager().registerPeriodicTask(
      kPunchOutTask,
      kPunchOutTask,
      frequency: const Duration(hours: 24),
      initialDelay: _delayUntil(outH, outM),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  Duration _delayUntil(int hour, int minute) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);
    if (target.isBefore(now)) target = target.add(const Duration(days: 1));
    return target.difference(now);
  }

  // ---- Status helpers ------------------------------------------------------

  String get lastPunchInTime => _prefs.getString(PrefKeys.lastPunchInTime) ?? '';
  String get lastPunchOutTime =>
      _prefs.getString(PrefKeys.lastPunchOutTime) ?? '';
  String get lastPunchInStatus =>
      _prefs.getString(PrefKeys.lastPunchInStatus) ?? '—';
  String get lastPunchOutStatus =>
      _prefs.getString(PrefKeys.lastPunchOutStatus) ?? '—';
}
