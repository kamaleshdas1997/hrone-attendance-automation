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
  static const totpSecret = 'hrone_totp_secret';
  static const refreshToken = 'hrone_refresh_token';
  static const tokenExpiry = 'hrone_token_expiry'; // ms since epoch
  static const loginMethod = 'hrone_login_method'; // 'password' | 'sso'
  static const lastPunchInTime = 'last_punch_in_time';
  static const lastPunchOutTime = 'last_punch_out_time';
  static const lastPunchInStatus = 'last_punch_in_status';
  static const lastPunchOutStatus = 'last_punch_out_status';

  // Auto-discovered from WebView network interceptor
  static const discoveredApiBase = 'discovered_api_base';
  static const discoveredPunchUrl = 'discovered_punch_url';
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
      await _prefs.setString(
          PrefKeys.totpSecret,
          totpSecret.trim().replaceAll(' ', '').toUpperCase());
    } else {
      await _prefs.remove(PrefKeys.totpSecret);
    }
    // Clear cached token so next punch re-authenticates
    await _prefs.remove(PrefKeys.authToken);
  }

  /// Generates the current 6-digit TOTP code from the stored secret.
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
    final loginMethod = _prefs.getString(PrefKeys.loginMethod) ?? 'password';

    // ── SSO path ─────────────────────────────────────────────────────────
    if (loginMethod == 'sso') {
      final cached = _prefs.getString(PrefKeys.authToken) ?? '';
      if (!forceRefresh && cached.isNotEmpty && _accessTokenValid) {
        return cached;
      }
      final refreshed = await _tryRefreshToken();
      if (refreshed != null) return refreshed;
      throw const LoginExpiredException();
    }

    // ── Password path ─────────────────────────────────────────────────────
    final cached = _prefs.getString(PrefKeys.authToken);
    if (cached != null && cached.isNotEmpty && !forceRefresh) return cached;

    final totp = _currentTotp();

    // Try multiple known HROne login endpoint patterns
    final loginEndpoints = [
      '$_baseUrl/api/auth/login',
      '$_baseUrl/api/v1/auth/login',
      '$_baseUrl/api/v2/auth/login',
    ];

    final body = <String, dynamic>{
      'domain': domain,
      'username': username,
      'password': password,
      'companyCode': domain,
    };
    if (totp.isNotEmpty) {
      body['mfaCode'] = totp;
      body['totpCode'] = totp;
      body['otp'] = totp;
    }

    for (final endpoint in loginEndpoints) {
      try {
        final resp = await http.post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Origin': _baseUrl,
            'Referer': '$_baseUrl/login',
          },
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 15));

        if (resp.statusCode == 200) {
          final json = jsonDecode(resp.body) as Map<String, dynamic>;
          final token = _extractToken(json);
          if (token != null) {
            await _prefs.setString(PrefKeys.authToken, token);
            // Cache login method and expiry
            await _prefs.setString(PrefKeys.loginMethod, 'password');
            final expiry = DateTime.now().millisecondsSinceEpoch + 3600000;
            await _prefs.setInt(PrefKeys.tokenExpiry, expiry);
            return token;
          }
        }
        // 404 = wrong endpoint, try next; other errors = stop
        if (resp.statusCode != 404) {
          throw Exception(
              'Login failed (${resp.statusCode}): ${resp.body}');
        }
      } catch (e) {
        if (e is Exception && e.toString().contains('Login failed')) rethrow;
        // Network error on this endpoint — try next
      }
    }

    throw Exception(
        'Could not reach HROne login API. Check your domain and internet connection.');
  }

  /// Extracts token from any known HROne response shape.
  String? _extractToken(Map<String, dynamic> json) {
    return json['data']?['token'] as String? ??
        json['data']?['accessToken'] as String? ??
        json['data']?['access_token'] as String? ??
        json['token'] as String? ??
        json['accessToken'] as String? ??
        json['access_token'] as String?;
  }

  // ---- Attendance API ------------------------------------------------------

  Future<void> testLogin() async {
    await _prefs.remove(PrefKeys.authToken);
    await _getToken();
  }

  Future<AttendanceResult> punchIn() => _punch('IN');
  Future<AttendanceResult> punchOut() => _punch('OUT');

  Future<AttendanceResult> _punch(String type) async {
    if (!isActiveToday) {
      final msg =
          'Skipped — today (${_weekdayName(DateTime.now().weekday)}) is not an active day.';
      await _saveStatus(type, true, msg);
      return AttendanceResult(success: true, message: msg);
    }

    try {
      final token = await _getToken();

      final randomize = _prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
      final maxJitter = _prefs.getInt(PrefKeys.randomizeMinutes) ?? 5;
      DateTime now = DateTime.now();
      if (randomize) {
        final jitter = Random().nextInt(maxJitter * 2 + 1) - maxJitter;
        now = now.add(Duration(minutes: jitter));
      }
      final iso = now.toIso8601String().substring(0, 19);

      // ── Strategy 1: Use auto-discovered endpoint from WebView interceptor ──
      // When the user logs in via SSO WebView, we capture the real punch URL.
      // Use it first — it's the only one guaranteed to work.
      final discoveredUrl = _prefs.getString(PrefKeys.discoveredPunchUrl);
      final discoveredHeadersJson = _prefs.getString(PrefKeys.discoveredPunchHeaders);
      final discoveredBase = _prefs.getString(PrefKeys.discoveredApiBase) ?? _baseUrl;

      if (discoveredUrl != null && discoveredUrl.isNotEmpty) {
        try {
          // Rebuild headers: use discovered headers + override Authorization with fresh token
          final Map<String, String> headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
            'Origin': discoveredBase,
            'Referer': '$discoveredBase/',
          };

          if (discoveredHeadersJson != null) {
            try {
              final discovered = jsonDecode(discoveredHeadersJson) as Map<String, dynamic>;
              for (final entry in discovered.entries) {
                final k = entry.key as String;
                final v = entry.value as String? ?? '';
                // Keep all discovered headers EXCEPT Authorization (we use fresh token)
                if (k.toLowerCase() != 'authorization') {
                  headers[k] = v;
                }
              }
            } catch (_) {}
          }

          // Build body — replace punchType value with current type
          Map<String, dynamic> body;
          final discoveredBody = _prefs.getString(PrefKeys.discoveredPunchBody);
          if (discoveredBody != null && discoveredBody.isNotEmpty) {
            try {
              final template = jsonDecode(discoveredBody) as Map<String, dynamic>;
              body = Map<String, dynamic>.from(template);
              // Replace punch type values
              for (final k in body.keys.toList()) {
                final v = body[k]?.toString() ?? '';
                if (v == 'IN' || v == 'OUT' || v == 'PUNCH_IN' || v == 'PUNCH_OUT' ||
                    v == 'in' || v == 'out' || v == 'punch_in' || v == 'punch_out') {
                  if (type == 'IN') {
                    if (v.contains('_')) {
                      body[k] = 'PUNCH_IN';
                    } else {
                      body[k] = v == v.toUpperCase() ? 'IN' : 'in';
                    }
                  } else {
                    if (v.contains('_')) {
                      body[k] = 'PUNCH_OUT';
                    } else {
                      body[k] = v == v.toUpperCase() ? 'OUT' : 'out';
                    }
                  }
                }
                // Update time fields
                if (k.toLowerCase().contains('time') || k.toLowerCase().contains('date')) {
                  body[k] = k.toLowerCase().contains('date') ? iso.substring(0, 10) : iso;
                }
              }
            } catch (_) {
              body = {'punchType': type, 'punchTime': iso};
            }
          } else {
            body = {'punchType': type, 'punchTime': iso};
          }

          var resp = await http.post(
            Uri.parse(discoveredUrl),
            headers: headers,
            body: jsonEncode(body),
          ).timeout(const Duration(seconds: 15));

          if (resp.statusCode == 401) {
            final fresh = await _getToken(forceRefresh: true);
            headers['Authorization'] = 'Bearer $fresh';
            resp = await http.post(
              Uri.parse(discoveredUrl),
              headers: headers,
              body: jsonEncode(body),
            ).timeout(const Duration(seconds: 15));
          }

          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final msg = 'Punch $type at $iso${randomize ? ' (±${maxJitter}m)' : ''}';
            await _saveStatus(type, true, msg);
            return AttendanceResult(success: true, message: msg);
          }
          // Non-2xx but not 404 → real error, don't probe further
          if (resp.statusCode != 404) {
            final errMsg = 'Punch failed (${resp.statusCode}). '
                'Open app and punch manually once to re-capture the API endpoint.';
            await _saveStatus(type, false, errMsg);
            return AttendanceResult(success: false, message: errMsg);
          }
          // 404 on discovered URL → URL stale, clear it and fall through to probing
          await _prefs.remove(PrefKeys.discoveredPunchUrl);
        } catch (_) {
          // Network error → fall through to probing
        }
      }

      // ── Strategy 2: Probe known endpoint patterns ─────────────────────────
      // Used as fallback when no discovered URL exists yet.
      // Tell user to punch manually once to discover the real endpoint.
      final punchEndpoints = [
        '$discoveredBase/api/attendance/punch',
        '$discoveredBase/api/v1/attendance/punch',
        '$discoveredBase/api/attendance/mark-attendance',
        '$discoveredBase/api/v1/attendance/mark-attendance',
        '$_baseUrl/api/attendance/punch',
        '$_baseUrl/api/v1/attendance/punch',
        '$_baseUrl/api/attendance/mark-attendance',
        '$_baseUrl/api/v1/attendance/mark-attendance',
      ];

      final bodies = [
        {'punchType': type, 'punchTime': iso, 'punchDate': iso.substring(0, 10)},
        {'type': type, 'time': iso, 'date': iso.substring(0, 10)},
        {'attendanceType': type == 'IN' ? 'PUNCH_IN' : 'PUNCH_OUT', 'punchTime': iso},
        {'punch_type': type.toLowerCase(), 'punch_time': iso},
      ];

      Future<http.Response> doPost(String url, Map<String, dynamic> body,
              String tkn) =>
          http.post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $tkn',
              'Origin': discoveredBase,
              'Referer': '$discoveredBase/',
            },
            body: jsonEncode(body),
          ).timeout(const Duration(seconds: 15));

      String? lastError;

      for (final endpoint in punchEndpoints) {
        for (final body in bodies) {
          try {
            var resp = await doPost(endpoint, body, token);
            if (resp.statusCode == 401) {
              final fresh = await _getToken(forceRefresh: true);
              resp = await doPost(endpoint, body, fresh);
            }
            if (resp.statusCode == 404) continue;
            final ok = resp.statusCode >= 200 && resp.statusCode < 300;
            if (ok) {
              // Save this working endpoint for next time
              await _prefs.setString(PrefKeys.discoveredPunchUrl, endpoint);
              await _prefs.setString(PrefKeys.discoveredPunchBody, jsonEncode(body));
              final msg = 'Punch $type at $iso${randomize ? ' (±${maxJitter}m)' : ''}';
              await _saveStatus(type, true, msg);
              return AttendanceResult(success: true, message: msg);
            } else {
              lastError = 'Error ${resp.statusCode}: ${resp.body}';
              break;
            }
          } catch (_) {}
        }
        if (lastError != null && !lastError.startsWith('Error 404')) break;
      }

      // All probes failed — tell user to punch from the web app once so
      // the WebView interceptor can capture the real endpoint.
      const guidance = 'Endpoint not yet discovered.\n\n'
          '👉 Open the app → Account → "Sign in with Microsoft"\n'
          '→ log in → go to HROne Attendance page → tap Punch In/Out once.\n'
          'The app will auto-capture the real API endpoint for future background punches.';
      await _saveStatus(type, false, guidance);
      return AttendanceResult(success: false, message: guidance);
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
