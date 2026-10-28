import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

/// Opens a WebView for HROne Microsoft SSO login.
///
/// Flow:
///   1. User taps "Sign in with Microsoft" → WebView loads HROne login
///   2. User completes Microsoft MFA in the WebView
///   3. JS interceptor patches XHR + fetch — every API call is reported to Flutter
///   4. Token is captured from API request headers (Authorization: Bearer ...)
///   5. WebView stays open — banner asks user to go to Attendance and tap Punch
///   6. When user taps Punch in the web app, the interceptor captures the real
///      punch endpoint URL + HTTP method + headers + body
///   7. "Punch endpoint captured!" banner shows → user taps Done → screen closes
///
/// This one-time setup lets background punches work forever without any API guessing.
class SsoLoginScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const SsoLoginScreen({super.key, required this.prefs});

  @override
  State<SsoLoginScreen> createState() => _SsoLoginScreenState();
}

class _SsoLoginScreenState extends State<SsoLoginScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  // Login state
  bool _tokenCaptured = false;       // Auth token captured from API headers
  bool _punchCaptured = false;       // Punch endpoint captured
  bool _autoPunchAttempted = false;  // Auto-punch JS fired once
  String _statusMsg = '';

  @override
  void initState() {
    super.initState();
    // Check if punch endpoint was already captured in a previous session
    _punchCaptured = (widget.prefs.getString(PrefKeys.discoveredPunchUrl) ?? '').isNotEmpty;
    _setupWebView();
  }

  // Always start at the HROne SSO login page
  static const _startUrl = 'https://app.hrone.cloud/login';

  void _setupWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            setState(() => _loading = false);
            await _injectNetworkInterceptor();
            if (!_tokenCaptured) {
              await _tryExtractTokenFromPage(url);
            }
          },
          onNavigationRequest: (req) {
            _tryExtractTokenFromUrl(req.url);
            return NavigationDecision.navigate;
          },
          onWebResourceError: (err) {
            if (err.isForMainFrame == true) {
              final code = err.errorCode;
              final isHardFail =
                  code == -6 || code == -7 || code == -105 || code == -106;
              if (isHardFail) {
                setState(() {
                  _loading = false;
                  _error =
                      'Cannot reach HROne login page (${err.description}).\n\n'
                      'Check your internet connection or verify the domain in Account settings.';
                });
              }
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: (msg) => _handleBridgeMessage(msg.message),
      )
      ..loadRequest(Uri.parse(_startUrl));
  }

  // ── Network interceptor ────────────────────────────────────────────────────

  Future<void> _injectNetworkInterceptor() async {
    const js = r'''
(function() {
  if (window.__flutterInterceptorInstalled) return;
  window.__flutterInterceptorInstalled = true;

  // XHR interceptor
  const OrigXHR = window.XMLHttpRequest;
  function PatchedXHR() {
    const xhr = new OrigXHR();
    const capturedHeaders = {};
    let capturedMethod = '';
    let capturedUrl = '';

    const origOpen = xhr.open.bind(xhr);
    xhr.open = function(method, url) {
      capturedMethod = method ? method.toUpperCase() : '';
      capturedUrl = url || '';
      return origOpen(method, url);
    };

    const origSetHeader = xhr.setRequestHeader.bind(xhr);
    xhr.setRequestHeader = function(name, value) {
      capturedHeaders[name] = value;
      return origSetHeader(name, value);
    };

    const origSend = xhr.send.bind(xhr);
    xhr.send = function(body) {
      try {
        FlutterBridge.postMessage(JSON.stringify({
          type: 'xhr',
          method: capturedMethod,
          url: capturedUrl,
          headers: capturedHeaders,
          body: (typeof body === 'string') ? body : ''
        }));
      } catch(_) {}
      return origSend(body);
    };
    return xhr;
  }
  PatchedXHR.prototype = OrigXHR.prototype;
  window.XMLHttpRequest = PatchedXHR;

  // Fetch interceptor
  const origFetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    const url = (typeof input === 'string') ? input : (input && input.url) || '';
    const method = ((init && init.method) || 'GET').toUpperCase();
    let headers = {};
    if (init && init.headers) {
      if (typeof init.headers.forEach === 'function') {
        init.headers.forEach((v, k) => { headers[k] = v; });
      } else {
        headers = Object.assign({}, init.headers);
      }
    }
    try {
      FlutterBridge.postMessage(JSON.stringify({
        type: 'fetch',
        method: method,
        url: url,
        headers: headers,
        body: (init && typeof init.body === 'string') ? init.body : ''
      }));
    } catch(_) {}
    return origFetch(input, init);
  };
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  // ── Bridge message handler ─────────────────────────────────────────────────

  void _handleBridgeMessage(String message) {
    try {
      final map = jsonDecode(message) as Map<String, dynamic>;
      final type = map['type'] as String? ?? '';

      if (type == 'xhr' || type == 'fetch') {
        final url = (map['url'] as String? ?? '').trim();
        final method = (map['method'] as String? ?? 'POST').toUpperCase();
        final headers = map['headers'];
        final body = map['body'] as String? ?? '';

        // ── Capture auth token from any API call header ───────────────────
        if (!_tokenCaptured && headers is Map) {
          final auth = _findHeader(headers, [
            'Authorization', 'authorization',
            'x-auth-token', 'X-Auth-Token',
            'x-access-token', 'X-Access-Token',
          ]);
          if (auth != null && auth.isNotEmpty) {
            final token = auth.startsWith('Bearer ') ? auth.substring(7) : auth;
            if (token.length > 20) {
              _captureTokenSilently(token);
            }
          }
        }

        // ── Save API base URL ─────────────────────────────────────────────
        if (url.isNotEmpty &&
            url.startsWith('https://') &&
            !url.contains('microsoft') &&
            !url.contains('microsoftonline') &&
            !url.contains('login.') &&
            url.contains('/api')) {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            final base = '${uri.scheme}://${uri.host}';
            widget.prefs.setString(PrefKeys.discoveredApiBase, base);
          }
        }

        // ── Capture punch endpoint ────────────────────────────────────────
        final isAttendanceCall = url.contains('attend') ||
            url.contains('punch') ||
            url.contains('mark-attendance') ||
            url.contains('mark_attendance');
        final isWriteMethod =
            method == 'POST' || method == 'PUT' || method == 'PATCH';

        if (isWriteMethod && isAttendanceCall && url.isNotEmpty) {
          widget.prefs.setString(PrefKeys.discoveredPunchUrl, url);
          widget.prefs.setString(PrefKeys.discoveredPunchMethod, method);

          if (headers is Map) {
            widget.prefs.setString(
                PrefKeys.discoveredPunchHeaders, jsonEncode(headers));
          }
          if (body.isNotEmpty) {
            widget.prefs.setString(PrefKeys.discoveredPunchBody, body);
          }

          setState(() {
            _punchCaptured = true;
            _statusMsg = '✅ Punch endpoint captured! ($method)\nTap Done — background punches will now work.';
          });
        }
        return;
      }

      // ── localStorage / global token messages ─────────────────────────────
      if (_tokenCaptured) return;
      final value = map['value'] as String? ?? '';
      if (value.isEmpty) return;
      String token = value;
      try {
        final inner = jsonDecode(value) as Map<String, dynamic>;
        token = inner['token'] as String? ??
            inner['access_token'] as String? ??
            inner['secret'] as String? ??
            value;
      } catch (_) {}
      _captureTokenSilently(token);
    } catch (_) {}
  }

  String? _findHeader(Map headers, List<String> names) {
    for (final name in names) {
      final v = headers[name];
      if (v != null && (v as String).isNotEmpty) return v;
    }
    return null;
  }

  // ── Token extraction from URL ──────────────────────────────────────────────

  void _tryExtractTokenFromUrl(String url) {
    if (_tokenCaptured) return;
    try {
      final uri = Uri.parse(url);
      final p = uri.queryParameters;
      final token = p['token'] ?? p['access_token'] ?? p['accessToken'] ??
          p['jwt'] ?? p['id_token'];
      final refreshToken = p['refresh_token'] ?? p['refreshToken'];
      final expiresIn = int.tryParse(p['expires_in'] ?? p['expiresIn'] ?? '');
      if (token != null && token.isNotEmpty) {
        _captureTokenSilently(token, refreshToken: refreshToken, expiresIn: expiresIn);
      }
    } catch (_) {}
  }

  // ── Token extraction from localStorage ────────────────────────────────────

  Future<void> _tryExtractTokenFromPage(String url) async {
    if (_tokenCaptured) return;
    if (!url.contains('hrone.cloud')) return;

    const js = r'''
(function() {
  const keys = ['token','access_token','accessToken','authToken','jwt',
    'hrone_token','hrone_access_token','Bearer','msal.idtoken'];
  for (const k of keys) {
    const v = localStorage.getItem(k) || sessionStorage.getItem(k);
    if (v && v.length > 20) {
      FlutterBridge.postMessage(JSON.stringify({source:'storage',key:k,value:v}));
      return;
    }
  }
  const jwtRegex = /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/;
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    const v = localStorage.getItem(k);
    if (v && jwtRegex.test(v)) {
      FlutterBridge.postMessage(JSON.stringify({source:'localStorage-scan',key:k,value:v}));
      return;
    }
  }
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.includes('accesstoken')) {
      try {
        const obj = JSON.parse(localStorage.getItem(k));
        const secret = obj.secret || obj.access_token || obj.token;
        if (secret && secret.length > 20) {
          FlutterBridge.postMessage(JSON.stringify({source:'msal',key:k,value:secret}));
          return;
        }
      } catch(_) {}
    }
  }
  const g = window.__HRONE_TOKEN__ || window.hroneToken || window.authToken;
  if (g) FlutterBridge.postMessage(JSON.stringify({source:'global',key:'window',value:String(g)}));
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  // ── Capture token + close screen immediately ──────────────────────────────

  Future<void> _captureTokenSilently(
    String token, {
    String? refreshToken,
    int? expiresIn,
  }) async {
    if (_tokenCaptured || token.isEmpty) return;
    _tokenCaptured = true;

    final svc = AttendanceService(widget.prefs);
    await svc.saveSsoTokens(
      accessToken: token,
      refreshToken: refreshToken,
      expiresInSeconds: expiresIn ?? 3600,
    );

    // Fetch employee profile in background; don't wait — close first
    svc.fetchAndSaveEmployeeProfile(token).catchError((_) {});

    // Return to the main app immediately — no need to stay on HROne web
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  void _closeScreen() {
    Navigator.of(context).pop(_tokenCaptured);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in with Microsoft'),
        centerTitle: false,
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        actions: [
          if (_tokenCaptured)
            TextButton(
              onPressed: _closeScreen,
              child: const Text('Done',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload page',
              onPressed: () {
                setState(() {
                  _error = null;
                  _statusMsg = '';
                });
                _controller.loadRequest(Uri.parse(_startUrl));
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          // Error state
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off, size: 56, color: cs.error),
                    const SizedBox(height: 16),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.error)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _statusMsg = '';
                        });
                        _controller.loadRequest(Uri.parse(_startUrl));
                      },
                    ),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),

          // Loading spinner
          if (_loading && _error == null)
            Container(
              color: Colors.white.withOpacity(0.6),
              child: const Center(child: CircularProgressIndicator()),
            ),

          // Status banner — shown after login and after punch capture
          if (_statusMsg.isNotEmpty && _error == null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Material(
                color: _punchCaptured ? Colors.green.shade800 : Colors.blue.shade800,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        _punchCaptured ? Icons.check_circle : Icons.info_outline,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _statusMsg,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              height: 1.4),
                        ),
                      ),
                      if (_tokenCaptured)
                        TextButton(
                          onPressed: _closeScreen,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.white24,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                          ),
                          child: const Text('Done',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
