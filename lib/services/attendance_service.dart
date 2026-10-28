import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:otp/otp.dart';
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

/// Thrown when the server requires an OTP before issuing a token.
class OtpRequiredException implements Exception {
  final String sessionToken;
  const OtpRequiredException(this.sessionToken);
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
  static const domain = 'hrone_domain';
  static const username = 'hrone_username';
  static const password = 'hrone_password';
  static const authToken = 'hrone_auth_token';
  static const punchInHour = 'punch_in_hour';
  static const punchInMinute = 'punch_in_minute';
  static const punchOutHour = 'punch_out_hour';
  static const punchOutMinute = 'punch_out_minute';
  static const automationEnabled = 'automation_enabled';
  static const activeDays = 'active_days'; // comma-separated ints: 1=Mon…7=Sun
  static const randomizeEnabled = 'randomize_enabled';
  static const randomizeMinutes = 'randomize_minutes'; // default 5
  static const totpSecret      = 'hrone_totp_secret';   // base32 secret from authenticator setup
  static const refreshToken    = 'hrone_refresh_token'; // OAuth refresh token from WebView login
  static const tokenExpiry     = 'hrone_token_expiry';  // access token expiry (ms since epoch)
  static const loginMethod     = 'hrone_login_method';  // 'password' | 'sso'
  static const lastPunchInTime = 'last_punch_in_time';
  static const lastPunchOutTime = 'last_punch_out_time';
  static const lastPunchInStatus = 'last_punch_in_status';
  static const lastPunchOutStatus = 'last_punch_out_status';
}

// ---------------------------------------------------------------------------
// AttendanceService
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
    String totpSecret = '',
  }) async {
    await _prefs.setString(PrefKeys.domain, domain.trim());
    await _prefs.setString(PrefKeys.username, username.trim());
    await _prefs.setString(PrefKeys.password, password);
    if (totpSecret.isNotEmpty) {
      // Normalize: strip spaces, uppercase (base32 is case-insensitive)
      await _prefs.setString(
          PrefKeys.totpSecret, totpSecret.trim().replaceAll(' ', '').toUpperCase());
    } else {
      await _prefs.remove(PrefKeys.totpSecret);
    }
    await _prefs.remove(PrefKeys.authToken);
  }

  /// Generates the current 6-digit TOTP code from the stored secret.
  /// Returns empty string if no secret is saved.
  String _currentTotp() {
    final secret = _prefs.getString(PrefKeys.totpSecret) ?? '';
    if (secret.isEmpty) return '';
    try {
      return OTP.generateTOTPCodeString(
        secret,
        DateTime.now().millisecondsSinceEpoch,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
    } catch (_) {
      return '';
    }
  }

  // ---- Active days helpers -------------------------------------------------

  /// Returns active weekdays as a Set<int> where 1=Monday … 7=Sunday
  static Set<int> activeDaysFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(PrefKeys.activeDays);
    if (raw == null || raw.isEmpty) {
      // Default: Mon–Fri
      return {1, 2, 3, 4, 5};
    }
    return raw.split(',').map((s) => int.tryParse(s.trim()) ?? 0).where((d) => d >= 1 && d <= 7).toSet();
  }

  static Future<void> saveActiveDays(SharedPreferences prefs, Set<int> days) async {
    await prefs.setString(PrefKeys.activeDays, days.join(','));
  }

  /// Returns true if today is an active day
  bool get isActiveToday {
    final today = DateTime.now().weekday; // 1=Mon … 7=Sun
    return activeDaysFromPrefs(_prefs).contains(today);
  }

  // ---- Auth ----------------------------------------------------------------

  /// Returns a bearer token.
  /// Throws [OtpRequiredException] if the server requires a 2FA OTP first.
  /// Throws [Exception] on credential failure or network error.
  // ── Token helpers ────────────────────────────────────────────────────────

  bool get _accessTokenValid {
    final expiry = _prefs.getInt(PrefKeys.tokenExpiry) ?? 0;
    // Consider expired 2 min early to avoid edge cases
    return expiry > DateTime.now().millisecondsSinceEpoch + 120000;
  }

  /// Saves an SSO access token + optional refresh token received from WebView.
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

  /// Tries to get a fresh access token using the stored refresh token.
  /// Returns null if no refresh token or refresh fails.
  Future<String?> _tryRefreshToken() async {
    final rt = _prefs.getString(PrefKeys.refreshToken);
    if (rt == null || rt.isEmpty) return null;

    // Try HROne's token refresh endpoint
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/api/v1/auth/refresh-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': rt}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = json['data']?['token'] ??
            json['data']?['accessToken'] ??
            json['token'] ??
            json['accessToken'];
        final newRt = json['data']?['refreshToken'] ??
            json['refreshToken'];
        final expiresIn = json['data']?['expiresIn'] ??
            json['expiresIn'] ?? 3600;
        if (token != null) {
          await saveSsoTokens(
            accessToken: token as String,
            refreshToken: newRt as String?,
            expiresInSeconds: expiresIn as int?,
          );
          return token;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _getToken({bool forceRefresh = false}) async {
    final loginMethod = _prefs.getString(PrefKeys.loginMethod) ?? 'password';

    // ── SSO path ─────────────────────────────────────────────────────────
    if (loginMethod == 'sso') {
      final cached = _prefs.getString(PrefKeys.authToken) ?? '';

      // Use cached token if still valid
      if (!forceRefresh && cached.isNotEmpty && _accessTokenValid) {
        return cached;
      }

      // Try silent refresh
      final refreshed = await _tryRefreshToken();
      if (refreshed != null) return refreshed;

      // Refresh token also expired → signal login required
      throw LoginExpiredException();
    }

    // ── Password path ─────────────────────────────────────────────────────
    final cached = _prefs.getString(PrefKeys.authToken);
    if (cached != null && cached.isNotEmpty && !forceRefresh) return cached;

    final totp = _currentTotp();
    final body = <String, dynamic>{
      'domain': domain,
      'username': username,
      'password': password,
    };
    if (totp.isNotEmpty) {
      body['mfaCode'] = totp;
      body['totpCode'] = totp;
      body['otp'] = totp;
    }

    final resp = await http
        .post(
          Uri.parse('$_baseUrl/api/v1/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = json['data']?['token'] ??
          json['data']?['accessToken'] ??
          json['token'] ??
          json['accessToken'];
      if (token == null) {
        throw Exception('Login response did not contain a token.\n${resp.body}');
      }
      await _prefs.setString(PrefKeys.authToken, token as String);
      return token as String;
    } else {
      throw Exception('Login failed (${resp.statusCode}): ${resp.body}');
    }
  }

  // ---- Attendance API ------------------------------------------------------

  /// Attempts login only (no punch). Used by credentials screen to verify.
  /// Throws [OtpRequiredException] if 2FA is needed.
  /// Throws [Exception] on bad credentials or network failure.
  Future<void> testLogin() async {
    await _prefs.remove(PrefKeys.authToken); // force fresh login
    await _getToken();
  }

  Future<AttendanceResult> punchIn() => _punch('IN');
  Future<AttendanceResult> punchOut() => _punch('OUT');

  Future<AttendanceResult> _punch(String type) async {
    // Skip if today is not an active day
    if (!isActiveToday) {
      final msg = 'Skipped — today (${_weekdayName(DateTime.now().weekday)}) is not an active day.';
      await _saveStatus(type, true, msg);
      return AttendanceResult(success: true, message: msg);
    }

    try {
      final token = await _getToken();

      // Apply ±N min randomness if enabled
      final randomize = _prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
      final maxJitter = _prefs.getInt(PrefKeys.randomizeMinutes) ?? 5;
      DateTime now = DateTime.now();
      if (randomize) {
        final jitter = Random().nextInt(maxJitter * 2 + 1) - maxJitter; // -5..+5
        now = now.add(Duration(minutes: jitter));
      }
      final iso = now.toIso8601String().substring(0, 19);

      final uri = Uri.parse('$_baseUrl/api/v1/attendance/mark-attendance');
      Future<http.Response> doPost(String token) => http.post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'punchType': type, 'punchTime': iso}),
          ).timeout(const Duration(seconds: 15));

      var resp = await doPost(token);

      // 401 → refresh token and retry once
      if (resp.statusCode == 401) {
        final fresh = await _getToken(forceRefresh: true);
        resp = await doPost(fresh);
      }

      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      final msg = ok
          ? 'Punch $type at $iso${randomize ? ' (±${maxJitter}m jitter)' : ''}'
          : 'Error ${resp.statusCode}: ${resp.body}';
      await _saveStatus(type, ok, msg);
      return AttendanceResult(success: ok, message: msg);
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
      await _prefs.setString(PrefKeys.lastPunchInStatus, ok ? 'success: $msg' : 'error: $msg');
    } else {
      await _prefs.setString(PrefKeys.lastPunchOutTime, now);
      await _prefs.setString(PrefKeys.lastPunchOutStatus, ok ? 'success: $msg' : 'error: $msg');
    }
  }

  // ---- Schedule ------------------------------------------------------------

  Future<void> applySchedule() async {
    try {
      await Workmanager().cancelAll();
    } catch (_) {
      // cancelAll can throw if WorkManager isn't initialized — safe to ignore
    }
    if (!(_prefs.getBool(PrefKeys.automationEnabled) ?? false)) return;

    final inH = _prefs.getInt(PrefKeys.punchInHour) ?? 9;
    final inM = _prefs.getInt(PrefKeys.punchInMinute) ?? 0;
    final outH = _prefs.getInt(PrefKeys.punchOutHour) ?? 18;
    final outM = _prefs.getInt(PrefKeys.punchOutMinute) ?? 0;

    // Schedule daily tasks — weekday & jitter checks happen inside _punch()
    try {
      await Workmanager().registerPeriodicTask(
        kPunchInTask,
        kPunchInTask,
        frequency: const Duration(hours: 24),
        initialDelay: _delayUntil(inH, inM),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}

    try {
      await Workmanager().registerPeriodicTask(
        kPunchOutTask,
        kPunchOutTask,
        frequency: const Duration(hours: 24),
        initialDelay: _delayUntil(outH, outM),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}
  }

  Duration _delayUntil(int hour, int minute) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);
    if (target.isBefore(now)) target = target.add(const Duration(days: 1));
    return target.difference(now);
  }

  // ---- Helpers -------------------------------------------------------------

  static String _weekdayName(int d) =>
      ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d];

  String get lastPunchInTime => _prefs.getString(PrefKeys.lastPunchInTime) ?? '';
  String get lastPunchOutTime => _prefs.getString(PrefKeys.lastPunchOutTime) ?? '';
  String get lastPunchInStatus => _prefs.getString(PrefKeys.lastPunchInStatus) ?? '—';
  String get lastPunchOutStatus => _prefs.getString(PrefKeys.lastPunchOutStatus) ?? '—';
}
