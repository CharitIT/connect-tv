// Sleep timer (turn the TV off later) and app bedtime (no chosen apps during set hours).

import 'dart:async';

import 'package:flutter/material.dart';

import '../tv/tv_service.dart';
import 'common.dart';

class TimersPage extends StatefulWidget {
  const TimersPage({super.key});

  @override
  State<TimersPage> createState() => _TimersPageState();
}

class _TimersPageState extends State<TimersPage> {
  Timer? _tick;
  List<String>? _apps;
  late AppLimits _limits;
  bool? _running;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    final l = app.tv?.limits ?? AppLimits();
    _limits = AppLimits(enabled: l.enabled, apps: [...l.apps], fromMin: l.fromMin, toMin: l.toMin);
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    if (!app.adbConnected) return;
    try {
      await app.refreshSleepTimer();
      final apps = await app.service.listApps();
      final running = await app.service.appLimitsRunning();
      apps.sort((a, b) => app.catalog.appName(a).toLowerCase().compareTo(app.catalog.appName(b).toLowerCase()));
      if (mounted) setState(() { _apps = apps; _running = running; });
    } catch (_) {}
  }

  Future<void> _setSleep(int? minutes) async {
    final app = AppScope.read(context);
    await runTv(context, () => app.setSleepTimer(minutes),
        success: minutes == null ? 'Sleep timer cancelled' : 'The TV will turn off in $minutes minutes');
  }

  Future<void> _saveLimits() async {
    final app = AppScope.read(context);
    setState(() => _busy = true);
    final ok = await runTv(context, () => app.saveAppLimits(_limits),
        success: _limits.enabled ? 'App bedtime is on' : 'App bedtime is off');
    if (ok) _running = await app.service.appLimitsRunning().catchError((_) => false);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickTime(bool from) async {
    final m = from ? _limits.fromMin : _limits.toMin;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (t == null) return;
    setState(() {
      if (from) {
        _limits.fromMin = t.hour * 60 + t.minute;
      } else {
        _limits.toMin = t.hour * 60 + t.minute;
      }
    });
  }

  String _fmt(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final at = app.sleepAt;
    final left = at?.difference(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Timers')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Sleep timer', style: t.titleLarge),
        const SizedBox(height: 4),
        Text(left == null || left.isNegative
            ? 'Turn the TV off after a while.'
            : 'The TV turns off in ${left.inMinutes + 1} min (at ${TimeOfDay.fromDateTime(at!).format(context)}).'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in [15, 30, 45, 60, 90, 120]) ActionChip(label: Text('$m min'), onPressed: () => _setSleep(m)),
          if (at != null)
            ActionChip(avatar: const Icon(Icons.close, size: 18), label: const Text('Cancel'), onPressed: () => _setSleep(null)),
        ]),
        const SizedBox(height: 8),
        if (!app.adbConnected)
          const Text('Without Developer mode the timer runs in this app, so keep Connect TV open '
              '(the phone may stop it in the background). With Developer mode it runs on the TV itself.')
        else if (app.sleepTimerOnPhone)
          const Text('This timer runs in this app. Keep Connect TV open.'),
        const Divider(height: 40),

        Text('App bedtime', style: t.titleLarge),
        const SizedBox(height: 4),
        const Text('During these hours the TV goes back to the home screen if one of the chosen apps is opened. '
            'It runs on the TV, so it works even when this phone is off.'),
        const SizedBox(height: 12),
        if (!app.adbConnected)
          Card(
            child: ListTile(
              leading: const Icon(Icons.developer_mode),
              title: const Text('Needs Developer mode'),
              subtitle: Text(app.adbError ?? 'Connect Developer mode in the Settings tab.'),
              onTap: () => runTv(context, app.connectDeveloperMode, success: 'Developer mode connected').then((_) => _load()),
            ),
          )
        else ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('App bedtime'),
            subtitle: Text(_running == null
                ? ''
                : _running!
                    ? 'Running on the TV'
                    : app.tv?.limits.enabled == true
                        ? 'Not running (the TV restarted). Tap Save to start it again.'
                        : 'Off'),
            value: _limits.enabled,
            onChanged: (v) => setState(() => _limits.enabled = v),
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.nightlight_outlined),
                label: Text('From ${_fmt(_limits.fromMin)}'),
                onPressed: () => _pickTime(true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.wb_sunny_outlined),
                label: Text('Until ${_fmt(_limits.toMin)}'),
                onPressed: () => _pickTime(false),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('Apps to block:'),
          const SizedBox(height: 8),
          if (_apps == null)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final p in _apps!)
                FilterChip(
                  label: Text(app.catalog.appName(p)),
                  selected: _limits.apps.contains(p),
                  onSelected: (on) => setState(() => on ? _limits.apps.add(p) : _limits.apps.remove(p)),
                ),
            ]),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || (_limits.enabled && _limits.apps.isEmpty) ? null : _saveLimits,
            child: Text(_limits.enabled && _limits.apps.isEmpty ? 'Choose at least one app' : 'Save'),
          ),
          const SizedBox(height: 8),
          const Text('Uses the TV\'s clock. It stops if the TV restarts; Connect TV starts it again the next time it connects.'),
        ],
      ]),
    );
  }
}
