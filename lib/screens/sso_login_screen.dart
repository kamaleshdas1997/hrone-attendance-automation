import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

/// Opens a WebView that loads the HROne Microsoft login page.
///
/// Extended behaviour (v2):
///   • Intercepts every XHR / fetch the page makes via JS monkey-patching
///   • Captures the real punch endpoint URL + auth headers automatically
///   • Saves captured endpoint + token to SharedPreferences so the background
///     worker can call the exact same URL with the exact same headers
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
  bool _tokenCaptured = false;
  String _statusMsg = '';

  @override
  void initState() {
    super.initState();
    _setupWebView();
  }

  String get _domain =>
      widget.prefs.getString(PrefKeys.domain)?.trim() ?? '';

  String get _startUrl {
    final d = _domain;
    if (d.isEmpty) return 'https://app.hrone.cloud/login';
    if (d.startsWith('http://') || d.startsWith('https://')) return d;
    if (d.contains('hrone.cloud')) return 'https://$d/login';
    if (d.contains('.')) return 'https://$d';
    return 'https://app.hrone.cloud/login?domain=$d&company=$d';
  }

  void _setupWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (url) async {
            setState(() => _loading = false);
            // Inject network interceptor on every page load
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
              final isHardFail = code == -6 || code == -7 ||
                  code == -105 || code == -106;
              if (isHardFail) {
                setState(() {
                  _loading = false;
                  _error =
                      'Cannot reach HROne login page (${err.description}).\n\n'
                      'Check your internet connection or verify your domain in Account settings.';
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
  // Monkey-patches XMLHttpRequest and fetch so we can see every API call the
  // HROne web app makes. We look for attendance/punch calls and capture the
  // URL + Authorization header automatically.

  Future<void> _injectNetworkInterceptor() async {
    const js = r'''
(function() {
  if (window.__flutterInterceptorInstalled) return;
  window.__flutterInterceptorInstalled = true;

  // ── XHR interceptor ──────────────────────────────────────────────────────
  const OrigXHR = window.XMLHttpRequest;
  function PatchedXHR() {
    const xhr = new OrigXHR();
    const capturedHeaders = {};
    let capturedMethod = '';
    let capturedUrl = '';

    const origOpen = xhr.open.bind(xhr);
    xhr.open = function(method, url) {
      capturedMethod = method;
      capturedUrl = url;
      return origOpen(method, url);
    };

    const origSetHeader = xhr.setRequestHeader.bind(xhr);
    xhr.setRequestHeader = function(name, value) {
      capturedHeaders[name] = value;
      return origSetHeader(name, value);
    };

    const origSend = xhr.send.bind(xhr);
    xhr.send = function(body) {
      // Report ALL API calls so Flutter can see them
      try {
        FlutterBridge.postMessage(JSON.stringify({
          type: 'xhr',
          method: capturedMethod,
          url: capturedUrl,
          headers: capturedHeaders,
          body: (typeof body === 'string') ? body : '',
          status: 0
        }));
      } catch(_) {}

      // Hook into load to capture response status
      xhr.addEventListener('load', function() {
        try {
          if (capturedUrl && (
            capturedUrl.includes('attend') ||
            capturedUrl.includes('punch') ||
            capturedUrl.includes('mark')
          )) {
            FlutterBridge.postMessage(JSON.stringify({
              type: 'xhr_response',
              method: capturedMethod,
              url: capturedUrl,
              headers: capturedHeaders,
              body: (typeof body === 'string') ? body : '',
              status: xhr.status,
              responseText: xhr.responseText ? xhr.responseText.substring(0, 500) : ''
            }));
          }
        } catch(_) {}
      });

      return origSend(body);
    };

    return xhr;
  }
  PatchedXHR.prototype = OrigXHR.prototype;
  window.XMLHttpRequest = PatchedXHR;

  // ── Fetch interceptor ─────────────────────────────────────────────────────
  const origFetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    const url = (typeof input === 'string') ? input : (input && input.url) || '';
    const method = (init && init.method) || 'GET';
    const headers = (init && init.headers) || {};

    // Report ALL fetch calls
    try {
      FlutterBridge.postMessage(JSON.stringify({
        type: 'fetch',
        method: method,
        url: url,
        headers: headers,
        body: (init && typeof init.body === 'string') ? init.body : ''
      }));
    } catch(_) {}

    const response = await origFetch(input, init);

    // Clone and report attendance-related responses
    try {
      if (url && (url.includes('attend') || url.includes('punch') || url.includes('mark'))) {
        const clone = response.clone();
        clone.text().then(text => {
          try {
            FlutterBridge.postMessage(JSON.stringify({
              type: 'fetch_response',
              method: method,
              url: url,
              headers: headers,
              body: (init && typeof init.body === 'string') ? init.body : '',
              status: response.status,
              responseText: text.substring(0, 500)
            }));
          } catch(_) {}
        });
      }
    } catch(_) {}

    return response;
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

      // ── Handle all API call captures ─────────────────────────────────────
      if (type == 'xhr' || type == 'fetch') {
        final url = map['url'] as String? ?? '';
        final headers = map['headers'];
        final method = (map['method'] as String? ?? '').toUpperCase();

        // Save API base URL (first non-microsoft, non-login API call)
        if (url.isNotEmpty &&
            url.startsWith('https://') &&
            !url.contains('microsoft') &&
            !url.contains('microsoftonline') &&
            !url.contains('login.') &&
            url.contains('/api/')) {
          // Extract base URL (scheme + host)
          final uri = Uri.tryParse(url);
          if (uri != null) {
            final base = '${uri.scheme}://${uri.host}';
            widget.prefs.setString(PrefKeys.discoveredApiBase, base);
            setState(() => _statusMsg = 'API discovered: ${uri.host}');
          }
        }

        // Extract auth token from headers
        if (!_tokenCaptured && headers is Map) {
          final auth = headers['Authorization'] as String? ??
              headers['authorization'] as String? ??
              headers['x-auth-token'] as String? ??
              headers['X-Auth-Token'] as String?;

          if (auth != null && auth.isNotEmpty) {
            final token = auth.startsWith('Bearer ')
                ? auth.substring(7)
                : auth;
            if (token.length > 20) {
              _captureToken(token);
            }
          }
        }

        // Save attendance endpoint when we see one (any method: POST, PUT, PATCH)
        final isAttendanceCall = (url.contains('attend') ||
            url.contains('punch') ||
            url.contains('mark-attendance') ||
            url.contains('mark_attendance'));
        final isWriteMethod = method == 'POST' || method == 'PUT' || method == 'PATCH';

        if (isWriteMethod && isAttendanceCall) {
          widget.prefs.setString(PrefKeys.discoveredPunchUrl, url);
          widget.prefs.setString(PrefKeys.discoveredPunchMethod, method);

          // Save headers map as JSON for the background worker to reuse
          if (headers is Map) {
            final headersJson = jsonEncode(headers);
            widget.prefs.setString(PrefKeys.discoveredPunchHeaders, headersJson);
          }

          // Save request body template
          final body = map['body'] as String? ?? '';
          if (body.isNotEmpty) {
            widget.prefs.setString(PrefKeys.discoveredPunchBody, body);
          }

          setState(() => _statusMsg = '✅ Punch endpoint captured! ($method)');
        }
        return;
      }

      // ── Handle xhr_response / fetch_response (attendance calls) ──────────
      if (type == 'xhr_response' || type == 'fetch_response') {
        final url = map['url'] as String? ?? '';
        final status = map['status'] as int? ?? 0;
        if (url.isNotEmpty) {
          widget.prefs.setString(PrefKeys.discoveredPunchUrl, url);
          setState(() =>
              _statusMsg = '📡 Punch API: ${Uri.parse(url).path} ($status)');
        }
        return;
      }

      // ── Handle token value messages ───────────────────────────────────────
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

      _captureToken(token);
    } catch (_) {}
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
      final expiresIn =
          int.tryParse(p['expires_in'] ?? p['expiresIn'] ?? '');
      if (token != null && token.isNotEmpty) {
        _captureToken(token, refreshToken: refreshToken, expiresIn: expiresIn);
      }
    } catch (_) {}
  }

  // ── Token extraction from localStorage ────────────────────────────────────

  Future<void> _tryExtractTokenFromPage(String url) async {
    if (_tokenCaptured) return;
    if (!url.contains('hrone.cloud')) return;

    const js = r'''
(function() {
  const keys = [
    'token', 'access_token', 'accessToken', 'authToken', 'jwt',
    'hrone_token', 'hrone_access_token', 'Bearer',
    'msal.idtoken', 'msal.access.token.keys'
  ];
  for (const k of keys) {
    const v = localStorage.getItem(k) || sessionStorage.getItem(k);
    if (v && v.length > 20) {
      FlutterBridge.postMessage(JSON.stringify({source:'storage', key:k, value:v}));
      return;
    }
  }
  const jwtRegex = /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/;
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    const v = localStorage.getItem(k);
    if (v && jwtRegex.test(v)) {
      FlutterBridge.postMessage(JSON.stringify({source:'localStorage-scan', key:k, value:v}));
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
          FlutterBridge.postMessage(JSON.stringify({source:'msal', key:k, value:secret}));
          return;
        }
      } catch(_) {}
    }
  }
  const g = window.__HRONE_TOKEN__ || window.hroneToken || window.authToken;
  if (g) FlutterBridge.postMessage(JSON.stringify({source:'global', key:'window', value:String(g)}));
})();
''';
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  // ── Capture token + close ──────────────────────────────────────────────────

  Future<void> _captureToken(
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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Signed in successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop(true);
    }
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
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload page',
            onPressed: () {
              setState(() {
                _error = null;
                _tokenCaptured = false;
                _statusMsg = '';
              });
              _controller.loadRequest(Uri.parse(_startUrl));
            },
          ),
        ],
      ),
      body: Stack(
        children: [
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
                          _tokenCaptured = false;
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

          if (_loading && _error == null)
            Container(
              color: Colors.white.withOpacity(0.6),
              child: const Center(child: CircularProgressIndicator()),
            ),

          if (_tokenCaptured)
            Container(
              color: Colors.green.withOpacity(0.85),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 64, color: Colors.white),
                    SizedBox(height: 12),
                    Text('Login successful!',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 6),
                    Text('Returning to app…',
                        style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),

          // Status bar showing interceptor activity
          if (_statusMsg.isNotEmpty && !_tokenCaptured && _error == null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black87,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  _statusMsg,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
