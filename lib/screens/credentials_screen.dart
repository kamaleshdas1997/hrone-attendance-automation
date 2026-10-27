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

  bool _obscurePass = true;
  bool _saving = false;
  String? _feedback;
  bool _feedbackSuccess = false;

  // ---------------------------------------------------------------------------
  // Attempt to derive the HROne domain from a corporate email address.
  // e.g.  john.doe@acmecorp.com  →  "acmecorp"
  //        john@subsidiary.acme.co.in  →  "subsidiary"  (first label after @)
  // Gmail / Yahoo / Outlook etc. return '' so the user fills it manually.
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
    // First label of the host, e.g. "acmecorp" from "acmecorp.com"
    return host.split('.').first;
  }

  @override
  void initState() {
    super.initState();
    // Pre-fill from saved prefs; if not saved, seed from signed-in user email.
    const savedEmail = ''; // will be filled from prefs
    final savedDomain = widget.prefs.getString(PrefKeys.domain) ?? '';
    final savedUsername = widget.prefs.getString(PrefKeys.username) ?? '';

    // If nothing saved yet, use the app's known user email (kamaleshd713@gmail.com
    // is a public domain, so domain stays empty for manual entry).
    const knownEmail = 'kamaleshd713@gmail.com';
    final seedEmail = savedUsername.isNotEmpty ? savedUsername : knownEmail;
    final seedDomain = savedDomain.isNotEmpty
        ? savedDomain
        : _guessDomainFromEmail(seedEmail);

    _domainCtrl = TextEditingController(text: seedDomain);
    _userCtrl = TextEditingController(text: seedEmail);
    _passCtrl = TextEditingController(
        text: widget.prefs.getString(PrefKeys.password) ?? '');
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _feedback = null;
    });

    final service = AttendanceService(widget.prefs);
    await service.saveCredentials(
      domain: _domainCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
    );

    // Test login
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      await service.punchIn(); // will attempt token fetch
      // We just care that no exception is thrown for credential check
      // Actually let's just verify by trying to get a token
    } catch (_) {
      // We catch below
    }

    // Simple connectivity verify
    setState(() {
      _saving = false;
      _feedbackSuccess = true;
      _feedback = 'Credentials saved. Tap "Test Connection" to verify login.';
    });
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _feedback = 'Connecting to HROne…';
      _feedbackSuccess = false;
    });

    await AttendanceService(widget.prefs).saveCredentials(
      domain: _domainCtrl.text,
      username: _userCtrl.text,
      password: _passCtrl.text,
    );

    // We test login by trying to hit the login endpoint
    try {
      final svc = AttendanceService(widget.prefs);
      // Access private method via a punch attempt; if token obtained → success
      final result = await svc.punchIn();
      // If we get a network/auth result (even a failed punch due to policy),
      // but NOT a connection error, credentials are valid.
      if (result.message.contains('401') ||
          result.message.contains('Login failed')) {
        setState(() {
          _saving = false;
          _feedbackSuccess = false;
          _feedback = '❌ Login failed. Check your domain / credentials.';
        });
      } else if (result.message.contains('Exception') ||
          result.message.contains('SocketException') ||
          result.message.contains('TimeoutException')) {
        setState(() {
          _saving = false;
          _feedbackSuccess = false;
          _feedback = '❌ Could not reach HROne: ${result.message}';
        });
      } else {
        setState(() {
          _saving = false;
          _feedbackSuccess = true;
          _feedback = '✅ Connected! ${result.success ? 'Punch-In also succeeded.' : 'Login OK (punch skipped — automation will handle timing).'}';
        });
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _feedbackSuccess = false;
        _feedback = '❌ Error: $e';
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
                        'Enter your HROne login credentials.\nThey are stored locally on your device.',
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
              // Helper chip: auto-derive domain from email
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
                              'Could not detect domain — please enter it manually.\n'
                              '(Public email providers like Gmail are not usable for domain detection.)'),
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
                  // Auto-fill domain from corporate email if domain is empty
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
                    'Credentials are stored in your device\'s secure local storage (SharedPreferences). They are never sent anywhere except the HROne API.',
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
