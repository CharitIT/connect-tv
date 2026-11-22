import 'package:flutter/material.dart';

import '../tv/tv_service.dart';
import 'common.dart';

class ScreensaverTab extends StatefulWidget {
  const ScreensaverTab({super.key});

  @override
  State<ScreensaverTab> createState() => _ScreensaverTabState();
}

class _ScreensaverTabState extends State<ScreensaverTab> {
  ScreensaverStatus? _status;
  String? _busy;
  double? _progress;
  int _minutes = 5;

  @override
  void initState() {
    super.initState();
    _minutes = AppScope.read(context).tv?.timeoutMin ?? 5;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final s = await AppScope.read(context).service.screensaverStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        if (s.timeoutMin != null) _minutes = s.timeoutMin!.clamp(1, 60);
      });
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    }
  }

  Future<void> _do(String label, Future<void> Function() f) async {
    setState(() { _busy = label; _progress = null; });
    await f();
    if (mounted) setState(() => _busy = null);
    await _refresh();
  }

  Future<void> _delete(String name) async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove from TV?'),
        content: const Text('This removes the photo from the TV screensaver. It stays on your phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _do('Removing…', () => runTv(context, () async {
          await app.service.deleteMedia(name);
          app.localMedia(name)?.deleteSync();
        }));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = _status;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final busy = _busy != null;
    final cfg = app.tv!.config;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        // ----- status -----
        Card(
          child: ListTile(
            leading: Icon(s.active ? Icons.check_circle : Icons.info_outline, color: s.active ? Colors.green : null),
            title: Text(!s.installed
                ? 'Screensaver app not installed'
                : s.active
                    ? 'Your photos are the TV screensaver'
                    : 'Installed, but not turned on'),
            subtitle: Text(s.installed ? '${s.files.length} photos and videos · starts after ${s.timeoutMin ?? '?'} min idle' : 'Install it to show your own photos.'),
          ),
        ),
        if (!s.installed)
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Install on TV'),
            onPressed: busy ? null : () => _do('Installing…', () => ScreensaverActions.install(context, onStep: (t) => setState(() => _busy = t))),
          ),
        if (busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 6),
          Text(_busy!),
        ],
        if (s.installed) ...[
          // ----- photos -----
          const SizedBox(height: 16),
          Row(children: [
            Text('Photos & videos', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add'),
              onPressed: busy
                  ? null
                  : () => _do('Sending…', () => ScreensaverActions.addMedia(context, onProgress: (t, p) {
                        if (mounted) setState(() { _busy = t; _progress = p; });
                      })),
            ),
          ]),
          const SizedBox(height: 10),
          if (s.files.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No photos on the TV yet. Tap Add to choose some from your phone.'))
          else
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [for (final f in s.files) _Thumb(name: f, onDelete: busy ? null : () => _delete(f))],
            ),

          // ----- settings -----
          const SizedBox(height: 24),
          Text('Settings', style: Theme.of(context).textTheme.titleMedium),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Seconds per photo'),
                subtitle: Slider(
                  value: cfg.intervalSec.clamp(3, 60).toDouble(),
                  min: 3,
                  max: 60,
                  divisions: 57,
                  label: '${cfg.intervalSec} s',
                  onChanged: (v) => setState(() => cfg.intervalSec = v.round()),
                ),
                trailing: Text('${cfg.intervalSec} s'),
              ),
              ListTile(
                title: const Text('Fit'),
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'cover', label: Text('Fill')),
                    ButtonSegment(value: 'contain', label: Text('Whole')),
                  ],
                  selected: {cfg.fit},
                  onSelectionChanged: (v) => setState(() => cfg.fit = v.first),
                ),
              ),
              SwitchListTile(title: const Text('Shuffle'), value: cfg.shuffle, onChanged: (v) => setState(() => cfg.shuffle = v)),
              SwitchListTile(title: const Text('Show clock'), value: cfg.showClock, onChanged: (v) => setState(() => cfg.showClock = v)),
              SwitchListTile(title: const Text('Slow zoom motion'), value: cfg.motion, onChanged: (v) => setState(() => cfg.motion = v)),
              SwitchListTile(title: const Text('Mute videos'), value: cfg.muteVideo, onChanged: (v) => setState(() => cfg.muteVideo = v)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: busy
                        ? null
                        : () => _do('Saving…', () => runTv(context, () async {
                              await app.service.pushConfig(cfg);
                              app.saveTv();
                            }, success: 'Settings saved to the TV')),
                    child: const Text('Save settings'),
                  ),
                ),
              ),
            ]),
          ),

          // ----- activate -----
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Start after the TV is idle for')),
                  DropdownButton<int>(
                    value: _minutes,
                    items: [for (final m in {1, 2, 3, 5, 10, 15, 30, 60, _minutes}.toList()..sort()) DropdownMenuItem(value: m, child: Text('$m min'))],
                    onChanged: busy ? null : (v) => setState(() => _minutes = v!),
                  ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text(s.active ? 'Update' : 'Set as screensaver'),
                    onPressed: busy ? null : () => _do('Saving…', () => ScreensaverActions.activate(context, _minutes)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Preview on TV'),
                    onPressed: busy ? null : () => runTv(context, () => app.service.preview(), success: 'Playing on the TV. Press Back on the TV remote to stop.'),
                  ),
                  if (s.active)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _do('Restoring…', () => runTv(context, () => app.service.restore(app.tv!.previousScreensaver),
                              success: 'The TV\'s own screensaver is back')),
                      child: const Text('Restore original'),
                    ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            TextButton.icon(
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Reinstall screensaver app'),
              onPressed: busy ? null : () => _do('Installing…', () => ScreensaverActions.install(context, onStep: (t) => setState(() => _busy = t))),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String name;
  final VoidCallback? onDelete;
  const _Thumb({required this.name, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final local = app.localMedia(name);
    final isVideo = videoExt.hasMatch(name);
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(fit: StackFit.expand, children: [
        if (local != null && !isVideo)
          Image.file(local, fit: BoxFit.cover, cacheWidth: 300)
        else
          Container(
            color: cs.surfaceContainerHighest,
            child: Center(child: Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined, size: 32)),
          ),
        if (isVideo)
          const Positioned(left: 6, bottom: 6, child: Icon(Icons.play_circle, color: Colors.white, size: 20)),
        Positioned(
          top: 2,
          right: 2,
          child: IconButton.filledTonal(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ),
      ]),
    );
  }
}
