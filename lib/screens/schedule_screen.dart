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
  late Set<int> _activeDays; // 1=Mon … 7=Sun
  late bool _randomize;
  bool _saving = false;
  String? _feedback;

  // Day labels Mon–Sun (index 0 = Mon = weekday 1)
  static const _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _dayFull = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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
    _activeDays = AttendanceService.activeDaysFromPrefs(widget.prefs);
    _randomize = widget.prefs.getBool(PrefKeys.randomizeEnabled) ?? true;
  }

  Future<void> _pickTime(bool isIn) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isIn ? _punchIn : _punchOut,
      helpText: isIn ? 'Set Punch-In Time' : 'Set Punch-Out Time',
    );
    if (picked != null) {
      setState(() => isIn ? _punchIn = picked : _punchOut = picked);
    }
  }

  Future<void> _saveSchedule() async {
    if (_activeDays.isEmpty) {
      setState(() {
        _feedback = '⚠️ Select at least one active day.';
      });
      return;
    }

    setState(() { _saving = true; _feedback = null; });

    await widget.prefs.setInt(PrefKeys.punchInHour, _punchIn.hour);
    await widget.prefs.setInt(PrefKeys.punchInMinute, _punchIn.minute);
    await widget.prefs.setInt(PrefKeys.punchOutHour, _punchOut.hour);
    await widget.prefs.setInt(PrefKeys.punchOutMinute, _punchOut.minute);
    await widget.prefs.setBool(PrefKeys.automationEnabled, _enabled);
    await widget.prefs.setBool(PrefKeys.randomizeEnabled, _randomize);
    await AttendanceService.saveActiveDays(widget.prefs, _activeDays);

    await AttendanceService(widget.prefs).applySchedule();

    final dayStr = _activeDays.toList()
      ..sort();
    final daysLabel = dayStr.map((d) => _dayFull[d - 1]).join(', ');

    setState(() {
      _saving = false;
      _feedback = _enabled
          ? '✅ Automation active!\n'
              '• Punch-In:  ${_fmt(_punchIn)}${_randomize ? ' ±5 min' : ''}\n'
              '• Punch-Out: ${_fmt(_punchOut)}${_randomize ? ' ±5 min' : ''}\n'
              '• Days: $daysLabel'
          : '⏸ Automation disabled.';
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Enable toggle ──────────────────────────────────────────────
            Card(
              elevation: 0,
              color: _enabled ? cs.primaryContainer : cs.surfaceContainerHighest,
              child: SwitchListTile(
                title: Text(
                  _enabled ? 'Automation ON' : 'Automation OFF',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(_enabled
                    ? 'Punches will fire automatically on active days'
                    : 'Toggle on to enable auto-punch'),
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

            // ── Active days ────────────────────────────────────────────────
            Text('Active Days',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _dayPicker(cs),
            const SizedBox(height: 24),

            // ── Punch-In ───────────────────────────────────────────────────
            Text('Punch-In Time',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
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

            // ── Punch-Out ──────────────────────────────────────────────────
            Text('Punch-Out Time',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _timeCard(
              context: context,
              time: _punchOut,
              icon: Icons.logout,
              color: Colors.orange,
              label: 'Exit / Check-Out',
              onTap: () => _pickTime(false),
            ),
            const SizedBox(height: 20),

            // ── Working hours ──────────────────────────────────────────────
            _workingHoursBanner(context),
            const SizedBox(height: 20),

            // ── Randomness toggle ──────────────────────────────────────────
            _randomnessCard(cs),
            const SizedBox(height: 28),

            // ── Save button ────────────────────────────────────────────────
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

            // ── Feedback ───────────────────────────────────────────────────
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

  // ── Day picker widget ──────────────────────────────────────────────────────
  Widget _dayPicker(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(7, (i) {
        final day = i + 1; // 1=Mon … 7=Sun
        final selected = _activeDays.contains(day);
        final isWeekend = day >= 6;
        return GestureDetector(
          onTap: () {
            setState(() {
              if (selected) {
                _activeDays.remove(day);
              } else {
                _activeDays.add(day);
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: selected
                  ? (isWeekend ? Colors.orange : cs.primary)
                  : cs.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : cs.outline.withOpacity(0.4),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _dayLabels[i],
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: selected
                        ? Colors.white
                        : (isWeekend ? Colors.orange : cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  // ── Randomness card ────────────────────────────────────────────────────────
  Widget _randomnessCard(ColorScheme cs) {
    return Card(
      elevation: 0,
      color: _randomize ? cs.secondaryContainer.withOpacity(0.6) : cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.shuffle,
                color: _randomize ? cs.secondary : cs.outline, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Random ±5 min jitter',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    _randomize
                        ? 'Each punch fires within ±5 min of set time — looks natural'
                        : 'Punches fire at exact scheduled times',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurface.withOpacity(0.7)),
                  ),
                ],
              ),
            ),
            Switch(
              value: _randomize,
              onChanged: (v) => setState(() => _randomize = v),
            ),
          ],
        ),
      ),
    );
  }

  // ── Time card ──────────────────────────────────────────────────────────────
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
                        ?.copyWith(
                            fontWeight: FontWeight.bold, color: color),
                  ),
                  if (_randomize)
                    Text('±5 min randomness',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline)),
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

  // ── Working hours banner ───────────────────────────────────────────────────
  Widget _workingHoursBanner(BuildContext context) {
    final inMins = _punchIn.hour * 60 + _punchIn.minute;
    final outMins = _punchOut.hour * 60 + _punchOut.minute;
    final diff = outMins - inMins;
    if (diff <= 0) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(8)),
        child: const Row(children: [
          Icon(Icons.warning_amber_outlined, color: Colors.red),
          SizedBox(width: 8),
          Text('Punch-Out is before Punch-In!',
              style: TextStyle(color: Colors.red)),
        ]),
      );
    }
    final h = diff ~/ 60;
    final m = diff % 60;
    final label = m == 0 ? '$h hr' : '$h hr $m min';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .secondaryContainer
            .withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.timelapse_outlined),
        const SizedBox(width: 10),
        Text('Working hours: $label',
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );
  }

  // ── How it works ───────────────────────────────────────────────────────────
  Widget _howItWorks(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10)),
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
            '📅 Tap day circles to choose which days to punch.',
            '🎲 Jitter adds a random ±5 min offset — looks human.',
            '⏰ At Punch-In time → HROne entry is marked.',
            '⏰ At Punch-Out time → HROne exit is marked.',
            '🔔 You get a notification on success or failure.',
            '🔋 Keep the app installed (doesn\'t need to be open).',
          ].map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(s,
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
