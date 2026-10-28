import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';
import 'qr_scanner_screen.dart';
import 'sso_login_screen.dart';

class CredentialsScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const CredentialsScreen({super.key, required this.prefs});

  @override
  State<CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends State<CredentialsScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _domainCtrl;
  late TextEditingController _userCtrl;
  late TextEditingController _passCtrl;
  late TextEditingController _totpSecretCtrl;
  String _liveTotp = '';          // live 6-digit preview
  bool _obscureSecret = true;

  bool _obscurePass = true;
  bool _saving = false;
  String? _feedback;
  bool _feedbackSuccess = false;

  static const _publicDomains = {
    'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.in', 'yahoo.co.in',
    'hotmail.com', 'outlook.com', 'live.com', 'icloud.com', 'rediffmail.com',
    'protonmail.com', 'zoho.com',
  };

  String _guessDomainFromEmail(String email) {
    final at = email.indexOf('@');
    if (at < 0) return '';
    final host = email.substring(at + 1).toLowerCase().trim();
    if (_publicDomains.contains(host)) return '';
    return host.split('.').first;
  }

  @override
  void initState() {
    super.initState();
    final savedDomain = widget.prefs.getString(PrefKeys.domain) ?? '';
    final savedUsername = widget.prefs.getString(PrefKeys.username) ?? '';
    const knownEmail = 'kamaleshd713@gmail.com';
    final seedEmail = savedUsername.isNotEmpty ? savedUsername : knownEmail;
    final seedDomain = savedDomain.isNotEmpty
        ? savedDomain
        : _guessDomainFromEmail(seedEmail);

    _domainCtrl = TextEditingController(text: seedDomain);
    _userCtrl = TextEditingController(text: seedEmail);
    _passCtrl = TextEditingController(
        text: widget.prefs.getString(PrefKeys.password) ?? '');
    _totpSecretCtrl = TextEditingController(
        text: widget.prefs.getString(PrefKeys.totpSecret) ?? '');
    _totpSecretCtrl.addListener(_updateLiveTotp);
    _updateLiveTotp();
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _totpSecretCtrl.dispose();
    super.dispose();
  }

  void _updateLiveTotp() {
    final secret = _totpSecretCtrl.text.trim().replaceAll(' ', '').toUpperCase();
    if (secret.isEmpty) {
      setState(() => _liveTotp = '');
      return;
    }
    try {
      final code = OTP.generateTOTPCodeString(
        secret,
        DateTime.now().millisecondsSinceEpoch,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
      setState(() => _liveTotp = code);
    } catch (_) {
      setState(() => _liveTotp = 'Invalid secret');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _feedback = null; });

    await AttendanceService(widget.prefs).saveCredentials(
      domain: _domainCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
      totpSecret: _totpSecretCtrl.text,
    );

    setState(() {
      _saving = false;
      _feedbackSuccess = true;
      _feedback = 'Credentials saved. Tap "Test Connection" to verify.';
    });
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _feedback = 'Connecting to HROne…';
      _feedbackSuccess = false;
    });

    final svc = AttendanceService(widget.prefs);
    await svc.saveCredentials(
      domain: _domainCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
      totpSecret: _totpSecretCtrl.text,
    );

    try {
      await svc.testLogin();
      setState(() {
        _saving = false;
        _feedbackSuccess = true;
        _feedback = '✅ Connected! Credentials are valid.';
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _feedbackSuccess = false;
        _feedback = '❌ ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('HROne Account'),
        centerTitle: false,
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: cs.primary, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Enter your HROne login credentials.\nStored locally on your device only.',
                        style: TextStyle(color: cs.onPrimaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Domain
              Text('Company Domain',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              TextFormField(
                controller: _domainCtrl,
                decoration: const InputDecoration(
                  hintText: 'e.g. mycompany',
                  prefixText: 'https://',
                  suffixText: '.hrone.cloud',
                  prefixIcon: Icon(Icons.business_outlined),
                ),
                keyboardType: TextInputType.url,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Detect domain from email'),
                  onPressed: () {
                    final guessed = _guessDomainFromEmail(_userCtrl.text);
                    if (guessed.isNotEmpty) {
                      setState(() => _domainCtrl.text = guessed);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Could not detect domain — please enter it manually.'),
                        ),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),

              // Username
              Text('Username / Email',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(
                  hintText: 'john.doe@company.com',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                keyboardType: TextInputType.emailAddress,
                onChanged: (v) {
                  final guessed = _guessDomainFromEmail(v);
                  if (guessed.isNotEmpty && _domainCtrl.text.isEmpty) {
                    setState(() => _domainCtrl.text = guessed);
                  }
                },
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              // Password
              Text('Password', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              TextFormField(
                controller: _passCtrl,
                obscureText: _obscurePass,
                decoration: InputDecoration(
                  hintText: '••••••••',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 20),

              // ── TOTP Secret section ───────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.secondary.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.security, color: cs.secondary, size: 20),
                        const SizedBox(width: 8),
                        Text('Authenticator App (MFA)',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Paste your TOTP secret key once — the app generates '
                      'the 6-digit code automatically at every punch. '
                      'Find it in Google Authenticator → Transfer accounts → Export, '
                      'or use the QR-code scanner below.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSecondaryContainer),
                    ),
                    const SizedBox(height: 12),
                    // QR scan button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan QR Code from HROne MFA Setup'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: cs.secondary),
                          foregroundColor: cs.secondary,
                        ),
                        onPressed: () async {
                          final secret = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                                builder: (_) => const QrScannerScreen()),
                          );
                          if (secret != null && secret.isNotEmpty) {
                            _totpSecretCtrl.text = secret;
                            _updateLiveTotp();
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _totpSecretCtrl,
                      obscureText: _obscureSecret,
                      decoration: InputDecoration(
                        labelText: 'TOTP Secret Key (optional)',
                        hintText: 'e.g. JBSWY3DPEHPK3PXP',
                        prefixIcon: const Icon(Icons.vpn_key_outlined),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureSecret
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscureSecret = !_obscureSecret),
                        ),
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z2-7= ]')),
                      ],
                    ),
                    // Live TOTP preview
                    if (_liveTotp.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: _liveTotp == 'Invalid secret'
                              ? Colors.red.shade50
                              : Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _liveTotp == 'Invalid secret'
                                ? Colors.red.shade300
                                : Colors.green.shade300,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _liveTotp == 'Invalid secret'
                                  ? Icons.error_outline
                                  : Icons.check_circle_outline,
                              color: _liveTotp == 'Invalid secret'
                                  ? Colors.red
                                  : Colors.green,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _liveTotp == 'Invalid secret'
                                  ? const Text('Invalid secret key',
                                      style: TextStyle(color: Colors.red))
                                  : RichText(
                                      text: TextSpan(
                                        style: DefaultTextStyle.of(context).style,
                                        children: [
                                          const TextSpan(
                                              text: 'Current code: ',
                                              style: TextStyle(fontSize: 12)),
                                          TextSpan(
                                            text: _liveTotp,
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 4,
                                              color: Colors.green,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                            if (_liveTotp != 'Invalid secret')
                              IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: 'Copy',
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: _liveTotp));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Code copied'),
                                        duration: Duration(seconds: 1)),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '✓ Compare this with your authenticator app to verify the secret is correct.',
                        style: TextStyle(
                            fontSize: 11, color: cs.outline),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Microsoft SSO login ───────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0078D4).withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFF0078D4).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.login,
                            color: Color(0xFF0078D4), size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Microsoft SSO (Recommended)',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF0078D4)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'If your company uses Microsoft login for HROne, '
                      'sign in here once. The app will automatically renew '
                      'the session — you only need to sign in again when '
                      'the refresh token expires (~90 days).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0078D4),
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.open_in_browser, size: 20),
                        label: const Text(
                          'Sign in with Microsoft',
                          style: TextStyle(fontSize: 15),
                        ),
                        onPressed: _saving
                            ? null
                            : () async {
                                // Save domain/username first so SSO screen
                                // knows which tenant URL to open
                                if (_domainCtrl.text.trim().isEmpty) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text(
                                        'Enter your Company Domain first.'),
                                  ));
                                  return;
                                }
                                await AttendanceService(widget.prefs)
                                    .saveCredentials(
                                  domain: _domainCtrl.text,
                                  username: _userCtrl.text,
                                  password: _passCtrl.text,
                                  totpSecret: _totpSecretCtrl.text,
                                );
                                if (!context.mounted) return;
                                final ok =
                                    await Navigator.of(context).push<bool>(
                                  MaterialPageRoute(
                                    builder: (_) => SsoLoginScreen(
                                        prefs: widget.prefs),
                                  ),
                                );
                                if (ok == true && context.mounted) {
                                  setState(() {
                                    _feedbackSuccess = true;
                                    _feedback =
                                        '✅ Microsoft login successful! '
                                        'Session saved — punches will use '
                                        'this session automatically.';
                                  });
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _testConnection,
                      icon: const Icon(Icons.wifi_find_outlined),
                      label: const Text('Test Connection'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ),
                ],
              ),

              // Feedback
              if (_feedback != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _feedbackSuccess
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    border: Border.all(
                        color: _feedbackSuccess
                            ? Colors.green.shade300
                            : Colors.red.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _feedback!,
                    style: TextStyle(
                      color: _feedbackSuccess
                          ? Colors.green.shade800
                          : Colors.red.shade800,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 32),
              _infoTile(
                context,
                icon: Icons.security_outlined,
                title: 'Security Note',
                body:
                    'Credentials are stored in your device\'s local storage. '
                    'They are never sent anywhere except the HROne API.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoTile(BuildContext context,
      {required IconData icon,
      required String title,
      required String body}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.onSurface),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withOpacity(0.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
