import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';
import '../services/notification_service.dart';
import 'schedule_screen.dart';
import 'status_screen.dart';
import 'sso_login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<SharedPreferences> _prefsFuture;
  int _tab = 0; // 0 = Schedule, 1 = Status

  @override
  void initState() {
    super.initState();
    _prefsFuture = SharedPreferences.getInstance();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await NotificationService().init();
      await NotificationService().requestPermission();
    });
  }

  bool _isLoggedIn(SharedPreferences prefs) {
    final token = prefs.getString(PrefKeys.authToken) ?? '';
    final loginMethod = prefs.getString(PrefKeys.loginMethod) ?? '';
    // Logged in = has a non-empty token from SSO
    return token.isNotEmpty && loginMethod == 'sso';
  }

  Future<void> _logout(SharedPreferences prefs) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'You will need to sign in again with Microsoft to use automation.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // Clear all auth + profile data
    await prefs.remove(PrefKeys.authToken);
    await prefs.remove(PrefKeys.refreshToken);
    await prefs.remove(PrefKeys.tokenExpiry);
    await prefs.remove(PrefKeys.loginMethod);
    await prefs.remove(PrefKeys.employeeId);
    await prefs.remove(PrefKeys.employeeCode);
    await prefs.remove(PrefKeys.employeeName);
    await prefs.remove(PrefKeys.employeeEmail);
    await prefs.remove(PrefKeys.discoveredPunchUrl);
    await prefs.remove(PrefKeys.discoveredPunchMethod);
    await prefs.remove(PrefKeys.discoveredPunchHeaders);
    await prefs.remove(PrefKeys.discoveredPunchBody);
    await prefs.remove(PrefKeys.discoveredApiBase);
    // Disable automation
    await prefs.setBool(PrefKeys.automationEnabled, false);
    try { await AttendanceService(prefs).applySchedule(); } catch (_) {}

    if (!mounted) return;
    setState(() {
      _prefsFuture = SharedPreferences.getInstance();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: _prefsFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 12),
                  Text(snap.error.toString()),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => setState(
                        () => _prefsFuture = SharedPreferences.getInstance()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final prefs = snap.data!;

        // ── Not logged in → show login screen ────────────────────────────
        if (!_isLoggedIn(prefs)) {
          return _LoginGate(
            prefs: prefs,
            onLoggedIn: () => setState(
                () => _prefsFuture = SharedPreferences.getInstance()),
          );
        }

        // ── Logged in → show main app ─────────────────────────────────────
        final cs = Theme.of(context).colorScheme;

        return Scaffold(
          appBar: AppBar(
            title: const Text('HROne Attendance'),
            centerTitle: false,
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
            actions: [
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Sign out',
                onPressed: () => _logout(prefs),
              ),
            ],
          ),
          body: IndexedStack(
            index: _tab,
            children: [
              ScheduleScreen(prefs: prefs),
              StatusScreen(prefs: prefs),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.schedule_outlined),
                selectedIcon: Icon(Icons.schedule),
                label: 'Schedule',
              ),
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Status',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Wraps LoginScreen so it can trigger a rebuild of HomeScreen on success.
class _LoginGate extends StatelessWidget {
  final SharedPreferences prefs;
  final VoidCallback onLoggedIn;
  const _LoginGate({required this.prefs, required this.onLoggedIn});

  @override
  Widget build(BuildContext context) {
    return _DirectLoginScreen(prefs: prefs, onLoggedIn: onLoggedIn);
  }
}

class _DirectLoginScreen extends StatefulWidget {
  final SharedPreferences prefs;
  final VoidCallback onLoggedIn;
  const _DirectLoginScreen({required this.prefs, required this.onLoggedIn});

  @override
  State<_DirectLoginScreen> createState() => _DirectLoginScreenState();
}

class _DirectLoginScreenState extends State<_DirectLoginScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() { _loading = true; _error = null; });

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SsoLoginScreen(prefs: widget.prefs),
      ),
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result == true) {
      widget.onLoggedIn();
    } else {
      setState(() => _error = 'Sign-in was cancelled. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 60),

                // Logo
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(Icons.fingerprint, size: 48, color: cs.primary),
                ),
                const SizedBox(height: 24),

                Text(
                  'HROne Attendance',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Auto punch-in & out, on schedule.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface.withOpacity(0.6),
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 60),

                // Microsoft sign-in button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : OutlinedButton(
                          onPressed: _signIn,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: cs.outline),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _MicrosoftLogo(size: 20),
                              const SizedBox(width: 12),
                              Text(
                                'Sign in with Microsoft',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: cs.onErrorContainer, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_error!,
                              style: TextStyle(
                                  color: cs.onErrorContainer, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 40),
                Text(
                  'Uses your company Microsoft account.\nNo passwords stored.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withOpacity(0.4),
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Microsoft logo — four coloured squares.
class _MicrosoftLogo extends StatelessWidget {
  final double size;
  const _MicrosoftLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    final half = size / 2 - 1;
    return SizedBox(
      width: size,
      height: size,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: half, height: half, color: const Color(0xFFF25022)),
            const SizedBox(width: 2),
            Container(width: half, height: half, color: const Color(0xFF7FBA00)),
          ]),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: half, height: half, color: const Color(0xFF00A4EF)),
            const SizedBox(width: 2),
            Container(width: half, height: half, color: const Color(0xFFFFB900)),
          ]),
        ],
      ),
    );
  }
}
