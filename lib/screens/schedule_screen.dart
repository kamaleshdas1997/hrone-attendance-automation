import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_service.dart';

class ScheduleScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const ScheduleScreen({super.key, required this.prefs});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  late TimeOfDay _punchIn;
  late TimeOfDay _punchOut;
  late bool _enabled;
  bool _saving = false;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _punchIn = TimeOfDay(
      hour: widget.prefs.getInt(PrefKeys.punchInHour) ?? 9,
      minute: widget.prefs.getInt(PrefKeys.punchInMinute) ?? 0,
    );
    _punchOut = TimeOfDay(
      hour: widget.prefs.getInt(PrefKeys.punchOutHour) ?? 18,
      minute: widget.prefs.getInt(PrefKeys.punchOutMinute) ?? 0,
    );
    _enabled = widget.prefs.getBool(PrefKeys.automationEnabled) ?? false;
  }

  Future<void> _pickTime(bool isIn) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isIn ? _punchIn : _punchOut,
      helpText: isIn ? 'Set Punch-In Time' : 'Set Punch-Out Time',
    );
    if (picked != null) {
      setState(() {
        if (isIn) {
          _punchIn = picked;
        } else {
          _punchOut = picked;
        }
      });
    }
  }

  Future<void> _saveSchedule() async {
    // Validate credentials exist
    final domain = widget.prefs.getString(PrefKeys.domain) ?? '';
    final username = widget.prefs.getString(PrefKeys.username) ?? '';
    if (domain.isEmpty || username.isEmpty) {
      setState(() {
        _feedback = '⚠️ Please save your HROne credentials first (Account tab).';
      });
      return;
    }

    setState(() {
      _saving = true;
      _feedback = null;
    });

    await widget.prefs.setInt(PrefKeys.punchInHour, _punchIn.hour);
    await widget.prefs.setInt(PrefKeys.punchInMinute, _punchIn.minute);
    await widget.prefs.setInt(PrefKeys.punchOutHour, _punchOut.hour);
    await widget.prefs.setInt(PrefKeys.punchOutMinute, _punchOut.minute);
    await widget.prefs.setBool(PrefKeys.automationEnabled, _enabled);

    await AttendanceService(widget.prefs).applySchedule();

    setState(() {
      _saving = false;
      _feedback = _enabled
          ? '✅ Automation active!\n'
              '• Punch-In:  ${_fmt(_punchIn)} daily\n'
              '• Punch-Out: ${_fmt(_punchOut)} daily'
          : '⏸ Automation disabled. No punches will be sent.';
    });
  }

  String _fmt(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $p';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Schedule'),
        centerTitle: false,
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Enable toggle
            Card(
              elevation: 0,
              color: _enabled
                  ? cs.primaryContainer
                  : cs.surfaceContainerHighest,
              child: SwitchListTile(
                title: Text(
                  _enabled ? 'Automation ON' : 'Automation OFF',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  _enabled
                      ? 'Punches will fire automatically every day'
                      : 'Toggle on to enable daily auto-punch',
                ),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                secondary: Icon(
                  _enabled ? Icons.play_circle : Icons.pause_circle_outline,
                  color: _enabled ? cs.primary : cs.outline,
                  size: 32,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text('Punch-In Time',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _timeCard(
              context: context,
              time: _punchIn,
              icon: Icons.login,
              color: Colors.green,
              label: 'Entry / Check-In',
              onTap: () => _pickTime(true),
            ),
            const SizedBox(height: 16),

            Text('Punch-Out Time',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _timeCard(
              context: context,
              time: _punchOut,
              icon: Icons.logout,
              color: Colors.orange,
              label: 'Exit / Check-Out',
              onTap: () => _pickTime(false),
            ),
            const SizedBox(height: 28),

            // Working hours summary
            if (true) ...[
              _workingHoursBanner(context),
              const SizedBox(height: 24),
            ],

            // Save button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveSchedule,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.save_alt_outlined),
                label: Text(_saving ? 'Applying…' : 'Save & Apply Schedule'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),

            // Feedback
            if (_feedback != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _feedback!.startsWith('✅')
                      ? Colors.green.shade50
                      : _feedback!.startsWith('⏸')
                          ? Colors.blue.shade50
                          : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _feedback!.startsWith('✅')
                        ? Colors.green.shade300
                        : _feedback!.startsWith('⏸')
                            ? Colors.blue.shade300
                            : Colors.amber.shade400,
                  ),
                ),
                child: Text(_feedback!),
              ),
            ],

            const SizedBox(height: 32),
            _howItWorks(context),
          ],
        ),
      ),
    );
  }

  Widget _timeCard({
    required BuildContext context,
    required TimeOfDay time,
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline)),
                  Text(
                    _fmt(time),
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold, color: color),
                  ),
                ],
              ),
            ),
            Icon(Icons.edit_outlined,
                color: Theme.of(context).colorScheme.outline),
          ],
        ),
      ),
    );
  }

  Widget _workingHoursBanner(BuildContext context) {
    // Calculate duration
    final inMins = _punchIn.hour * 60 + _punchIn.minute;
    final outMins = _punchOut.hour * 60 + _punchOut.minute;
    final diff = outMins - inMins;
    if (diff <= 0) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_outlined, color: Colors.red),
            SizedBox(width: 8),
            Text('Punch-Out is before Punch-In!',
                style: TextStyle(color: Colors.red)),
          ],
        ),
      );
    }
    final h = diff ~/ 60;
    final m = diff % 60;
    final label = m == 0 ? '$h hr' : '$h hr $m min';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color:
            Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.timelapse_outlined),
          const SizedBox(width: 10),
          Text('Working hours: $label',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _howItWorks(BuildContext context) {
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
          Text('How it works',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...[
            '📱 The app schedules two daily background tasks.',
            '⏰ At Punch-In time → API call to HROne marks your entry.',
            '⏰ At Punch-Out time → API call to HROne marks your exit.',
            '🔔 You get a notification on success or failure.',
            '📶 Requires an internet connection at punch time.',
            '🔋 Keep the app installed (doesn\'t need to be open).',
          ].map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(s,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              )),
        ],
      ),
    );
  }
}
