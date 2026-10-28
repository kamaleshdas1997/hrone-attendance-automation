import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

/// Opens a WebView that loads the HROne Microsoft login page.
///
/// Flow:
///   1. User taps "Sign in with Microsoft"
///   2. WebView loads `https://<domain>.hrone.cloud`
///   3. HROne redirects to Microsoft login — user signs in with MFA in the WebView
///   4. After successful auth, HROne redirects back to its own URL
///   5. We intercept the redirect, extract the Bearer token from:
///      - URL query params (token= / access_token= / jwt=)
///      - Or from the page's localStorage via JavaScript injection
///      - Or from the navigation request headers (Authorization)
///   6. Call [AttendanceService.saveSsoTokens()] and pop with success=true
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

  @override
  void initState() {
    super.initState();
    _setupWebView();
  }

  String get _domain =>
      widget.prefs.getString(PrefKeys.domain)?.trim() ?? '';

  /// The HROne tenant URL.
  String get _startUrl {
    final d = _domain;
    if (d.isEmpty) return 'https://app.hrone.cloud';
    // Handle domains that already contain .hrone.cloud
    if (d.contains('.')) return 'https://$d';
    return 'https://$d.hrone.cloud';
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
            if (!_tokenCaptured) {
              await _tryExtractTokenFromPage(url);
            }
          },
          onNavigationRequest: (req) {
            _tryExtractTokenFromUrl(req.url);
            return NavigationDecision.navigate;
          },
          onWebResourceError: (err) {
            // Ignore subresource errors; only flag main-frame failures
            if (err.isForMainFrame == true) {
              setState(() {
                _loading = false;
                _error = 'Page load error: ${err.description}';
              });
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

  // ── Token extraction ───────────────────────────────────────────────────────

  /// Checks URL query parameters for a token.
  void _tryExtractTokenFromUrl(String url) {
    if (_tokenCaptured) return;
    try {
      final uri = Uri.parse(url);
      final params = uri.queryParameters;
      final token = params['token'] ??
          params['access_token'] ??
          params['accessToken'] ??
          params['jwt'] ??
          params['id_token'];
      final refreshToken = params['refresh_token'] ?? params['refreshToken'];
      final expiresIn = int.tryParse(params['expires_in'] ?? params['expiresIn'] ?? '');

      if (token != null && token.isNotEmpty) {
        _captureToken(token, refreshToken: refreshToken, expiresIn: expiresIn);
      }
    } catch (_) {}
  }

  /// Injects JS to read localStorage / sessionStorage / cookies for the token.
  Future<void> _tryExtractTokenFromPage(String url) async {
    if (_tokenCaptured) return;
    // Only inject on HROne pages, not Microsoft login pages
    if (!url.contains('hrone.cloud')) return;

    const js = r'''
(function() {
  // Common key names used by HROne / MSAL
  const keys = [
    'token', 'access_token', 'accessToken', 'authToken', 'jwt',
    'hrone_token', 'hrone_access_token', 'Bearer',
    'msal.idtoken', 'msal.access.token.keys'
  ];

  // Search localStorage
  for (const k of keys) {
    const v = localStorage.getItem(k);
    if (v && v.length > 20) {
      FlutterBridge.postMessage(JSON.stringify({source:'localStorage', key:k, value:v}));
      return;
    }
  }

  // Search sessionStorage
  for (const k of keys) {
    const v = sessionStorage.getItem(k);
    if (v && v.length > 20) {
      FlutterBridge.postMessage(JSON.stringify({source:'sessionStorage', key:k, value:v}));
      return;
    }
  }

  // Scan ALL localStorage keys for JWT-shaped values (three base64 parts)
  const jwtRegex = /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/;
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    const v = localStorage.getItem(k);
    if (v && jwtRegex.test(v)) {
      FlutterBridge.postMessage(JSON.stringify({source:'localStorage-scan', key:k, value:v}));
      return;
    }
  }

  // MSAL stores access token inside a JSON blob keyed by account
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.includes('accesstoken')) {
      const v = localStorage.getItem(k);
      try {
        const obj = JSON.parse(v);
        const secret = obj.secret || obj.access_token || obj.token;
        if (secret && secret.length > 20) {
          FlutterBridge.postMessage(JSON.stringify({source:'msal', key:k, value:secret}));
          return;
        }
      } catch(_) {}
    }
  }

  // Also check window.__HRONE_TOKEN__ or similar globals
  const globalToken = window.__HRONE_TOKEN__ || window.hroneToken || window.authToken;
  if (globalToken) {
    FlutterBridge.postMessage(JSON.stringify({source:'global', key:'window', value: String(globalToken)}));
  }
})();
''';

    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  void _handleBridgeMessage(String message) {
    if (_tokenCaptured) return;
    try {
      final map = jsonDecode(message) as Map<String, dynamic>;
      final value = map['value'] as String? ?? '';
      if (value.isEmpty) return;

      // If the value itself is a JSON string (MSAL pattern), parse it
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
              setState(() { _error = null; _tokenCaptured = false; });
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
                        setState(() { _error = null; _tokenCaptured = false; });
                        _controller.loadRequest(Uri.parse(_startUrl));
                      },
                    ),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),

          // Loading overlay
          if (_loading && _error == null)
            Container(
              color: Colors.white.withOpacity(0.6),
              child: const Center(child: CircularProgressIndicator()),
            ),

          // Token captured banner
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
        ],
      ),
    );
  }
}
