import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

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
  late TextEditingController _mfaCtrl;

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
    _mfaCtrl = TextEditingController(
        text: widget.prefs.getString(PrefKeys.mfaCode) ?? '');
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _mfaCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _feedback = null; });

    await AttendanceService(widget.prefs).saveCredentials(
      domain: _domainCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
      mfaCode: _mfaCtrl.text.trim(),
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
      mfaCode: _mfaCtrl.text.trim(),
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

              // ── MFA / Authenticator section ──────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: cs.secondary.withOpacity(0.3)),
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
                      'If your HROne account uses Google Authenticator / Authy, '
                      'enter the current 6-digit code here before tapping Test Connection. '
                      'The app will use this code for background punches too — '
                      'update it here if your session token ever expires.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSecondaryContainer),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _mfaCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      decoration: const InputDecoration(
                        labelText: 'MFA Code (optional)',
                        hintText: '6-digit code from your authenticator',
                        prefixIcon: Icon(Icons.pin_outlined),
                        counterText: '',
                        border: OutlineInputBorder(),
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
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
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
                        color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
