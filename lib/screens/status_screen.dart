import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

class StatusScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const StatusScreen({super.key, required this.prefs});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  bool _manualLoading = false;
  String? _manualResult;
  bool _manualSuccess = false;

  AttendanceService get _svc => AttendanceService(widget.prefs);

  Future<void> _manualPunch(String type) async {
    setState(() {
      _manualLoading = true;
      _manualResult = null;
    });
    final result =
        type == 'IN' ? await _svc.punchIn() : await _svc.punchOut();
    setState(() {
      _manualLoading = false;
      _manualSuccess = result.success;
      _manualResult = result.message;
    });
  }

  String _formatTime(String iso) {
    if (iso.isEmpty) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final m = dt.minute.toString().padLeft(2, '0');
      final p = dt.hour >= 12 ? 'PM' : 'AM';
      final day = '${dt.day}/${dt.month}/${dt.year}';
      return '$day  $h:$m $p';
    } catch (_) {
      return iso;
    }
  }

  bool _isStatusSuccess(String status) => status.startsWith('success:');
  String _statusLabel(String status) {
    if (status == '—') return 'Not yet punched';
    if (status.startsWith('success:')) return '✅ Success';
    return '❌ Failed';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Pull fresh prefs
    final inH = widget.prefs.getInt(PrefKeys.punchInHour) ?? 9;
    final inM = widget.prefs.getInt(PrefKeys.punchInMinute) ?? 0;
    final outH = widget.prefs.getInt(PrefKeys.punchOutHour) ?? 18;
    final outM = widget.prefs.getInt(PrefKeys.punchOutMinute) ?? 0;
    final enabled = widget.prefs.getBool(PrefKeys.automationEnabled) ?? false;

    final domain = widget.prefs.getString(PrefKeys.domain) ?? '';
    final username = widget.prefs.getString(PrefKeys.username) ?? '';
    final configured = domain.isNotEmpty && username.isNotEmpty;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Automation status banner
            _banner(
              context: context,
              active: enabled && configured,
              domain: domain,
              username: username,
              inH: inH,
              inM: inM,
              outH: outH,
              outM: outM,
            ),
            const SizedBox(height: 20),

            Text('Last Punches',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),

            _punchCard(
              context: context,
              type: 'Punch-In',
              icon: Icons.login,
              color: Colors.green,
              time: _formatTime(_svc.lastPunchInTime),
              status: _svc.lastPunchInStatus,
            ),
            const SizedBox(height: 10),
            _punchCard(
              context: context,
              type: 'Punch-Out',
              icon: Icons.logout,
              color: Colors.orange,
              time: _formatTime(_svc.lastPunchOutTime),
              status: _svc.lastPunchOutStatus,
            ),

            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 16),

            Text('Manual Override',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Tap to punch immediately, regardless of schedule.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _manualLoading
                        ? null
                        : () => _manualPunch('IN'),
                    icon: const Icon(Icons.login, color: Colors.green),
                    label: const Text('Punch In Now'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Colors.green),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _manualLoading
                        ? null
                        : () => _manualPunch('OUT'),
                    icon: const Icon(Icons.logout, color: Colors.orange),
                    label: const Text('Punch Out Now'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ),
              ],
            ),

            if (_manualLoading) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],

            if (_manualResult != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _manualSuccess
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  border: Border.all(
                    color: _manualSuccess
                        ? Colors.green.shade300
                        : Colors.red.shade300,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _manualResult!,
                  style: TextStyle(
                    color: _manualSuccess
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 32),
            _notesCard(context),
          ],
        ),
      ),
    );
  }

  Widget _banner({
    required BuildContext context,
    required bool active,
    required String domain,
    required String username,
    required int inH,
    required int inM,
    required int outH,
    required int outM,
  }) {
    final cs = Theme.of(context).colorScheme;
    String t(int h, int m) {
      final hr = h > 12 ? h - 12 : (h == 0 ? 12 : h);
      final min = m.toString().padLeft(2, '0');
      final p = h >= 12 ? 'PM' : 'AM';
      return '$hr:$min $p';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: active
              ? [const Color(0xFF1565C0), const Color(0xFF0288D1)]
              : [cs.surfaceContainerHighest, cs.surfaceContainerHighest],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                active ? Icons.check_circle : Icons.info_outline,
                color: active ? Colors.white : cs.onSurface.withOpacity(0.7),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                active ? 'Automation Active' : 'Automation Inactive',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: active ? Colors.white : cs.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 10),
            Text('Account:  $username @ $domain.hrone.cloud',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Punch-In:   ${t(inH, inM)}',
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            Text('Punch-Out: ${t(outH, outM)}',
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              domain.isEmpty
                  ? 'Go to Account tab to add credentials.'
                  : 'Go to Schedule tab and enable automation.',
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _punchCard({
    required BuildContext context,
    required String type,
    required IconData icon,
    required Color color,
    required String time,
    required String status,
  }) {
    final ok = _isStatusSuccess(status);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(time,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color:
                                Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
          Chip(
            label: Text(_statusLabel(status),
                style: TextStyle(
                  color: status == '—'
                      ? null
                      : ok
                          ? Colors.green.shade800
                          : Colors.red.shade800,
                  fontSize: 12,
                )),
            backgroundColor: status == '—'
                ? null
                : ok
                    ? Colors.green.shade50
                    : Colors.red.shade50,
          ),
        ],
      ),
    );
  }

  Widget _notesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notes',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...[
            '• Background tasks fire once per 24 hours.',
            '• Android may delay tasks when in battery-saver mode.',
            '  → Disable battery optimization for this app.',
            '• Background execution is not 100% guaranteed on all devices.',
            '• Manual punches are immediate and reliable.',
          ].map((t) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(t,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurface.withOpacity(0.7))),
              )),
        ],
      ),
    );
  }
}
