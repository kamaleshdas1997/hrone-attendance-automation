import 'dart:convert';
import 'dart:math';
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


/// Thrown when SSO session has expired and silent refresh failed.
/// The user must log in again via WebView.
class LoginExpiredException implements Exception {
  const LoginExpiredException();
}

// ---------------------------------------------------------------------------
// Pref keys
// ---------------------------------------------------------------------------
class PrefKeys {
  static const authToken = 'hrone_auth_token';
  static const punchInHour = 'punch_in_hour';
  static const punchInMinute = 'punch_in_minute';
  static const punchOutHour = 'punch_out_hour';
  static const punchOutMinute = 'punch_out_minute';
  static const automationEnabled = 'automation_enabled';
  static const activeDays = 'active_days'; // comma-separated ints: 1=Mon…7=Sun
  static const randomizeEnabled = 'randomize_enabled';
  static const randomizeMinutes = 'randomize_minutes'; // default 5
  static const refreshToken = 'hrone_refresh_token';
  static const tokenExpiry = 'hrone_token_expiry'; // ms since epoch
  static const loginMethod = 'hrone_login_method'; // 'sso'
  static const lastPunchInTime = 'last_punch_in_time';
  static const lastPunchOutTime = 'last_punch_out_time';
  static const lastPunchInStatus = 'last_punch_in_status';
  static const lastPunchOutStatus = 'last_punch_out_status';

  // Employee profile (fetched after SSO login)
  static const employeeId = 'hrone_employee_id';       // int, e.g. 4306
  static const employeeCode = 'hrone_employee_code';   // string, e.g. "KD001"
  static const employeeName = 'hrone_employee_name';
  static const employeeEmail = 'hrone_employee_email';

  // Kept for potential future use (no longer written by interceptor)
  static const discoveredApiBase = 'discovered_api_base';
  static const discoveredPunchUrl = 'discovered_punch_url';
  static const discoveredPunchMethod = 'discovered_punch_method';
  static const discoveredPunchHeaders = 'discovered_punch_headers';
  static const discoveredPunchBody = 'discovered_punch_body';
}

// ---------------------------------------------------------------------------
// AttendanceService
// ---------------------------------------------------------------------------
class AttendanceService {
  static const kPunchInTask = 'hrone_punch_in';
  static const kPunchOutTask = 'hrone_punch_out';

  // HROne web-app base URL — all API calls go here, not api.hrone.cloud
  static const String _baseUrl = 'https://app.hrone.cloud';

  final SharedPreferences _prefs;
  AttendanceService(this._prefs);

  // ---- Active days helpers -------------------------------------------------

  static Set<int> activeDaysFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(PrefKeys.activeDays);
    if (raw == null || raw.isEmpty) return {1, 2, 3, 4, 5};
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .where((d) => d >= 1 && d <= 7)
        .toSet();
  }

  static Future<void> saveActiveDays(
      SharedPreferences prefs, Set<int> days) async {
    await prefs.setString(PrefKeys.activeDays, days.join(','));
  }

  bool get isActiveToday {
    final today = DateTime.now().weekday;
    return activeDaysFromPrefs(_prefs).contains(today);
  }

  // ---- Token helpers -------------------------------------------------------

  bool get _accessTokenValid {
    final expiry = _prefs.getInt(PrefKeys.tokenExpiry) ?? 0;
    return expiry > DateTime.now().millisecondsSinceEpoch + 120000;
  }

  Future<void> saveSsoTokens({
    required String accessToken,
    String? refreshToken,
    int? expiresInSeconds,
  }) async {
    await _prefs.setString(PrefKeys.authToken, accessToken);
    await _prefs.setString(PrefKeys.loginMethod, 'sso');
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _prefs.setString(PrefKeys.refreshToken, refreshToken);
    }
    final expiry = DateTime.now().millisecondsSinceEpoch +
        ((expiresInSeconds ?? 3600) * 1000);
    await _prefs.setInt(PrefKeys.tokenExpiry, expiry);
  }

  // ---- Employee profile ----------------------------------------------------

  /// Called once after SSO login to load the employee profile into prefs.
  /// Endpoint: GET /api/timeOffice/employee/markattendance/alarm/details/{employeeCode}
  /// We first try to extract employeeCode from the JWT payload; if that fails
  /// we try the generic profile endpoint and parse whatever we get.
  Future<void> fetchAndSaveEmployeeProfile(String token) async {
    // Try to extract employeeCode from the JWT claims
    String guessedCode = _extractEmployeeCodeFromJwt(token);

    // If JWT has a code, hit the alarm/details endpoint
    if (guessedCode.isNotEmpty) {
      final saved = await _fetchAlarmDetails(token, guessedCode);
      if (saved) return;
    }

    // Fallback: try generic profile endpoints to get at least name + email
    await _fetchGenericProfile(token);
  }

  String _extractEmployeeCodeFromJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return '';
      final payload = parts[1];
      // Base64url decode with padding
      final padded = payload.padRight(
          payload.length + (4 - payload.length % 4) % 4, '=');
      final decoded = utf8.decode(base64Url.decode(padded));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      return (map['employeeCode'] ??
              map['employee_code'] ??
              map['EmployeeCode'] ??
              map['sub'] ??
              '') as String;
    } catch (_) {
      return '';
    }
  }

  Future<bool> _fetchAlarmDetails(String token, String code) async {
    final url = '$_baseUrl/api/timeOffice/employee/markattendance/alarm/details/$code';
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'Origin': _baseUrl,
          'Referer': '$_baseUrl/',
        },
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        final data = (body is Map) ? (body['data'] ?? body) : body;
        if (data is Map) {
          final name = _firstNonEmpty(data, [
            'employeeName', 'EmployeeName', 'name', 'Name',
            'displayName', 'fullName', 'FirstName',
          ]);
          final email = _firstNonEmpty(data, [
            'emailId', 'email', 'Email', 'emailAddress',
            'officialEmail', 'workEmail',
          ]);
          final empId = _firstNonEmpty(data, [
            'employeeId', 'EmployeeId', 'id', 'Id',
            'employeeID', 'EmpId',
          ]);
          final empCode = _firstNonEmpty(data, [
            'employeeCode', 'EmployeeCode', 'empCode', 'code',
          ]);
          if (name.isNotEmpty) await _prefs.setString(PrefKeys.employeeName, name);
          if (email.isNotEmpty) await _prefs.setString(PrefKeys.employeeEmail, email);
          if (empId.isNotEmpty) {
            await _prefs.setString(PrefKeys.employeeId, empId);
          }
          if (empCode.isNotEmpty) {
            await _prefs.setString(PrefKeys.employeeCode, empCode);
          } else {
            await _prefs.setString(PrefKeys.employeeCode, code);
          }
          return name.isNotEmpty || empId.isNotEmpty;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _fetchGenericProfile(String token) async {
    final endpoints = [
      '$_baseUrl/api/employee/profile',
      '$_baseUrl/api/v1/employee/profile',
      '$_baseUrl/api/employee/me',
    ];
    for (final url in endpoints) {
      try {
        final resp = await http.get(
          Uri.parse(url),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body);
          final data = (body is Map) ? (body['data'] ?? body) : body;
          if (data is Map) {
            final name = _firstNonEmpty(data, ['employeeName', 'name', 'displayName', 'fullName']);
            final email = _firstNonEmpty(data, ['emailId', 'email', 'emailAddress']);
            final empId = _firstNonEmpty(data, ['employeeId', 'id', 'empId']);
            final empCode = _firstNonEmpty(data, ['employeeCode', 'empCode', 'code']);
            if (name.isNotEmpty) await _prefs.setString(PrefKeys.employeeName, name);
            if (email.isNotEmpty) await _prefs.setString(PrefKeys.employeeEmail, email);
            if (empId.isNotEmpty) await _prefs.setString(PrefKeys.employeeId, empId);
            if (empCode.isNotEmpty) await _prefs.setString(PrefKeys.employeeCode, empCode);
            if (name.isNotEmpty) return; // Got what we need
          }
        }
      } catch (_) {}
    }
  }

  String _firstNonEmpty(Map data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  // ---- Employee profile getters (for UI) -----------------------------------

  String get employeeId => _prefs.getString(PrefKeys.employeeId) ?? '';
  String get employeeCode => _prefs.getString(PrefKeys.employeeCode) ?? '';
  String get employeeName => _prefs.getString(PrefKeys.employeeName) ?? '';
  String get employeeEmail => _prefs.getString(PrefKeys.employeeEmail) ?? '';

  /// Extracts bearer token from any known HROne response shape.
  String? _extractToken(Map<String, dynamic> json) {
    return json['data']?['token'] as String? ??
        json['data']?['accessToken'] as String? ??
        json['data']?['access_token'] as String? ??
        json['token'] as String? ??
        json['accessToken'] as String? ??
        json['access_token'] as String?;
  }

  Future<String?> _tryRefreshToken() async {
    final rt = _prefs.getString(PrefKeys.refreshToken);
    if (rt == null || rt.isEmpty) return null;
    try {
      // HROne refresh token endpoint (app.hrone.cloud)
      final resp = await http.post(
        Uri.parse('$_baseUrl/api/auth/refresh-token'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Origin': _baseUrl,
          'Referer': '$_baseUrl/',
        },
        body: jsonEncode({'refreshToken': rt}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = _extractToken(json);
        final newRt = json['data']?['refreshToken'] ?? json['refreshToken'];
        final expiresIn =
            json['data']?['expiresIn'] ?? json['expiresIn'] ?? 3600;
        if (token != null) {
          await saveSsoTokens(
            accessToken: token,
            refreshToken: newRt as String?,
            expiresInSeconds: (expiresIn as num).toInt(),
          );
          return token;
        }
      }
    } catch (_) {}
    return null;
  }

  // ---- Auth ----------------------------------------------------------------

  Future<String> _getToken({bool forceRefresh = false}) async {
    final cached = _prefs.getString(PrefKeys.authToken) ?? '';
    if (!forceRefresh && cached.isNotEmpty && _accessTokenValid) {
      return cached;
    }
    final refreshed = await _tryRefreshToken();
    if (refreshed != null) return refreshed;
    throw const LoginExpiredException();
  }

  // ---- Attendance API ------------------------------------------------------

  Future<AttendanceResult> punchIn() => _punch('IN');
  Future<AttendanceResult> punchOut() => _punch('OUT');

  // Real HROne punch endpoint (discovered from the app network traffic).
  static const _punchUrl =
      '$_baseUrl/api/timeoffice/mobile/checkin/Attendance/Request';

  Future<AttendanceResult> _punch(String type) async {
    if (!isActiveToday) {
      final msg =
          'Skipped — today (${_weekdayName(DateTime.now().weekday)}) is not an active day.';
      await _saveStatus(type, true, msg);
      return AttendanceResult(success: true, message: msg);
    }

    try {
      var token = await _getToken();

      final randomize = _prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
      final maxJitter = _prefs.getInt(PrefKeys.randomizeMinutes) ?? 5;
      DateTime now = DateTime.now();
      if (randomize) {
        final jitter = Random().nextInt(maxJitter * 2 + 1) - maxJitter;
        now = now.add(Duration(minutes: jitter));
      }
      // HROne expects "yyyy-MM-ddTHH:mm" (no seconds)
      final punchTime =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}T${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      // employeeId saved after login; fall back to 0 (API will reject with a
      // clear error rather than silently succeeding for wrong employee)
      final empIdStr = _prefs.getString(PrefKeys.employeeId) ?? '';
      final empId = int.tryParse(empIdStr) ?? 0;

      final body = <String, dynamic>{
        'requestType': 'A',
        'applyRequestSource': 10,
        'employeeId': empId,
        'latitude': '',
        'longitude': '',
        'geoAccuracy': '',
        'geoLocation': '',
        'punchTime': punchTime,
        'remarks': '',
        'uploadedPhotoOneName': '',
        'uploadedPhotoOnePath': '',
        'uploadedPhotoTwoName': '',
        'uploadedPhotoTwoPath': '',
        'attendanceSource': 'W',
        'attendanceType': 'Online',
        'punchType': null,
      };

      Map<String, String> _headers(String tkn) => {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $tkn',
            'Origin': _baseUrl,
            'Referer': '$_baseUrl/',
          };

      var resp = await http
          .post(
            Uri.parse(_punchUrl),
            headers: _headers(token),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));

      // 401 → try refresh once
      if (resp.statusCode == 401) {
        token = await _getToken(forceRefresh: true);
        resp = await http
            .post(
              Uri.parse(_punchUrl),
              headers: _headers(token),
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 20));
      }

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final msg =
            'Punch $type at $punchTime${randomize ? ' (±${maxJitter}m)' : ''}';
        await _saveStatus(type, true, msg);
        return AttendanceResult(success: true, message: msg);
      }

      // Parse HROne error message if available
      String errDetail = '';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        errDetail = (j['message'] ?? j['Message'] ?? j['error'] ?? '')
            .toString();
      } catch (_) {
        errDetail = resp.body.length > 200
            ? resp.body.substring(0, 200)
            : resp.body;
      }
      final errMsg = 'Punch failed (${resp.statusCode})'
          '${errDetail.isNotEmpty ? ': $errDetail' : ''}';
      await _saveStatus(type, false, errMsg);
      return AttendanceResult(success: false, message: errMsg);
    } on LoginExpiredException {
      const msg = 'Login expired — open the app to sign in again.';
      await _saveStatus(type, false, msg);
      return AttendanceResult(success: false, message: msg);
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
      await _prefs.setString(PrefKeys.lastPunchInStatus,
          ok ? 'success: $msg' : 'error: $msg');
    } else {
      await _prefs.setString(PrefKeys.lastPunchOutTime, now);
      await _prefs.setString(PrefKeys.lastPunchOutStatus,
          ok ? 'success: $msg' : 'error: $msg');
    }
  }

  // ---- Schedule ------------------------------------------------------------
  //
  // IMPORTANT: Android WorkManager's minimum periodic interval is 15 minutes.
  // Using registerPeriodicTask with 24h frequency + a long initialDelay means
  // the task fires at most once per 24h cycle BUT Android may defer it
  // significantly in Doze mode.
  //
  // Better approach: registerOneOffTask that fires at the target time and
  // re-schedules itself for the next day inside the callback (main.dart).

  Future<void> applySchedule() async {
    try {
      await Workmanager().cancelAll();
    } catch (_) {}

    if (!(_prefs.getBool(PrefKeys.automationEnabled) ?? false)) return;

    final inH = _prefs.getInt(PrefKeys.punchInHour) ?? 9;
    final inM = _prefs.getInt(PrefKeys.punchInMinute) ?? 0;
    final outH = _prefs.getInt(PrefKeys.punchOutHour) ?? 18;
    final outM = _prefs.getInt(PrefKeys.punchOutMinute) ?? 0;
    final randomize = _prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
    final maxJitter = _prefs.getInt(PrefKeys.randomizeMinutes) ?? 5;

    // Use one-off tasks — each fires once at the right time,
    // then the callback in main.dart re-schedules for tomorrow.
    final inDelay = _delayUntilWithJitter(inH, inM, randomize, maxJitter);
    final outDelay = _delayUntilWithJitter(outH, outM, randomize, maxJitter);

    try {
      await Workmanager().registerOneOffTask(
        kPunchInTask,
        kPunchInTask,
        initialDelay: inDelay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}

    try {
      await Workmanager().registerOneOffTask(
        kPunchOutTask,
        kPunchOutTask,
        initialDelay: outDelay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}
  }

  Duration _delayUntilWithJitter(
      int hour, int minute, bool randomize, int maxJitter) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);

    // Apply jitter before scheduling so the task fires at jittered time
    if (randomize && maxJitter > 0) {
      final jitter = Random().nextInt(maxJitter * 2 + 1) - maxJitter;
      target = target.add(Duration(minutes: jitter));
    }

    // If target is already past for today, schedule for tomorrow
    if (target.isBefore(now)) {
      target = target.add(const Duration(days: 1));
    }

    return target.difference(now);
  }

  // ---- Helpers -------------------------------------------------------------

  static String _weekdayName(int d) =>
      ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d];

  String get lastPunchInTime =>
      _prefs.getString(PrefKeys.lastPunchInTime) ?? '';
  String get lastPunchOutTime =>
      _prefs.getString(PrefKeys.lastPunchOutTime) ?? '';
  String get lastPunchInStatus =>
      _prefs.getString(PrefKeys.lastPunchInStatus) ?? '—';
  String get lastPunchOutStatus =>
      _prefs.getString(PrefKeys.lastPunchOutStatus) ?? '—';
}
