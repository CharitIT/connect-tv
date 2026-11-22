// Which album the screensaver plays: a default album, plus schedule rules such as
// "Diwali album from 25 Oct to 5 Nov" or "Night album from 22:00 to 06:00".
// The first rule that matches wins; the TV checks before every photo.

import 'package:flutter/material.dart';

import '../tv/tv_service.dart';
import 'common.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String albumLabel(String a) => a.isEmpty ? 'Main' : a;

/// "10-25" → "25 Oct".
String dayLabel(String mmdd) {
  final p = mmdd.split('-').map(int.tryParse).toList();
  if (p.length != 2 || p[0] == null || p[1] == null || p[0]! < 1 || p[0]! > 12) return mmdd;
  return '${p[1]} ${_months[p[0]! - 1]}';
}

String _mmdd(DateTime d) => '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String ruleLabel(BuildContext context, ScheduleRule r) {
  String time(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);
  return [
    if (r.hasDates) '${dayLabel(r.from!)} – ${dayLabel(r.to!)}',
    if (r.hasTimes) '${time(r.fromMin!)} – ${time(r.toMin!)}',
  ].join(', ');
}

class AlbumSchedulePage extends StatefulWidget {
  final List<String> albums;
  const AlbumSchedulePage({super.key, required this.albums});

  @override
  State<AlbumSchedulePage> createState() => _AlbumSchedulePageState();
}

class _AlbumSchedulePageState extends State<AlbumSchedulePage> {
  late ScreensaverConfig _cfg;
  bool _saving = false;

  List<String> get _all => ['', ...widget.albums];

  @override
  void initState() {
    super.initState();
    _cfg = AppScope.read(context).tv!.config.copy();
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    setState(() => _saving = true);
    final ok = await runTv(context, () async {
      await app.service.pushConfig(_cfg);
      app.tv!.config = _cfg;
      app.saveTv();
    }, success: 'Saved to the TV');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _editRule([int? index]) async {
    final rule = await showDialog<ScheduleRule>(
      context: context,
      builder: (_) => _RuleDialog(albums: _all, rule: index == null ? null : _cfg.schedule[index]),
    );
    if (rule == null) return;
    setState(() => index == null ? _cfg.schedule.add(rule) : _cfg.schedule[index] = rule);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Which album plays')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Normally', style: t.titleMedium),
        const SizedBox(height: 4),
        RadioGroup<String>(
          groupValue: _cfg.album,
          onChanged: (v) => setState(() => _cfg.album = v ?? ''),
          child: Column(children: [
            for (final a in _all)
              RadioListTile<String>(value: a, title: Text(albumLabel(a)), contentPadding: EdgeInsets.zero),
          ]),
        ),
        const Divider(height: 32),
        Text('Schedule', style: t.titleMedium),
        const SizedBox(height: 4),
        const Text('Play a different album on some dates or at some times. The first rule that matches wins. '
            'If an album is empty, the Main album plays.'),
        const SizedBox(height: 8),
        if (_cfg.schedule.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No rules yet.')),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (a, b) => setState(() => _cfg.schedule.insert(b, _cfg.schedule.removeAt(a))),
          children: [
            for (var i = 0; i < _cfg.schedule.length; i++)
              Card(
                key: ValueKey('rule$i${_cfg.schedule[i].hashCode}'),
                child: ListTile(
                  leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                  title: Text(albumLabel(_cfg.schedule[i].album)),
                  subtitle: Text(ruleLabel(context, _cfg.schedule[i])),
                  onTap: () => _editRule(i),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _cfg.schedule.removeAt(i)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add a rule'),
          onPressed: widget.albums.isEmpty ? null : () => _editRule(),
        ),
        if (widget.albums.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Create an album first (Screensaver tab → the folder icon next to Album).'),
          ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ]),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  final List<String> albums;
  final ScheduleRule? rule;
  const _RuleDialog({required this.albums, this.rule});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late String _album = widget.rule?.album ?? widget.albums.firstWhere((a) => a.isNotEmpty, orElse: () => '');
  late bool _useDates = widget.rule?.hasDates ?? true;
  late bool _useTimes = widget.rule?.hasTimes ?? false;
  late String _from = widget.rule?.from ?? _mmdd(DateTime.now());
  late String _to = widget.rule?.to ?? _mmdd(DateTime.now().add(const Duration(days: 7)));
  late int _fromMin = widget.rule?.fromMin ?? 22 * 60;
  late int _toMin = widget.rule?.toMin ?? 6 * 60;

  Future<void> _pickDay(bool from) async {
    final p = (from ? _from : _to).split('-').map(int.parse).toList();
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, p[0], p[1]),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'Every year on this day',
    );
    if (d != null) setState(() => from ? _from = _mmdd(d) : _to = _mmdd(d));
  }

  Future<void> _pickTime(bool from) async {
    final m = from ? _fromMin : _toMin;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (t != null) setState(() => from ? _fromMin = t.hour * 60 + t.minute : _toMin = t.hour * 60 + t.minute);
  }

  @override
  Widget build(BuildContext context) {
    String time(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);
    return AlertDialog(
      title: Text(widget.rule == null ? 'New rule' : 'Edit rule'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            initialValue: _album,
            decoration: const InputDecoration(labelText: 'Play this album', border: OutlineInputBorder()),
            items: [for (final a in widget.albums) DropdownMenuItem(value: a, child: Text(albumLabel(a)))],
            onChanged: (v) => setState(() => _album = v ?? ''),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Between these dates (every year)'),
            value: _useDates,
            onChanged: (v) => setState(() => _useDates = v ?? false),
          ),
          if (_useDates)
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _pickDay(true), child: Text(dayLabel(_from)))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('to')),
              Expanded(child: OutlinedButton(onPressed: () => _pickDay(false), child: Text(dayLabel(_to)))),
            ]),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Between these times'),
            value: _useTimes,
            onChanged: (v) => setState(() => _useTimes = v ?? false),
          ),
          if (_useTimes)
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _pickTime(true), child: Text(time(_fromMin)))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('to')),
              Expanded(child: OutlinedButton(onPressed: () => _pickTime(false), child: Text(time(_toMin)))),
            ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: !_useDates && !_useTimes
              ? null
              : () => Navigator.pop(
                    context,
                    ScheduleRule(
                      album: _album,
                      from: _useDates ? _from : null,
                      to: _useDates ? _to : null,
                      fromMin: _useTimes ? _fromMin : null,
                      toMin: _useTimes ? _toMin : null,
                    ),
                  ),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
