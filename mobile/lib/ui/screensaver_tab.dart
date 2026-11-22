import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../tv/tv_service.dart';
import 'album_schedule_page.dart';
import 'common.dart';
import 'sync_page.dart';

class ScreensaverTab extends StatefulWidget {
  const ScreensaverTab({super.key});

  @override
  State<ScreensaverTab> createState() => _ScreensaverTabState();
}

class _ScreensaverTabState extends State<ScreensaverTab> {
  ScreensaverStatus? _status;
  String _album = ''; // album shown in the grid ("" = Main)
  Set<String>? _selected; // non-null while choosing photos to remove
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
    final app = AppScope.read(context);
    if (!app.adbConnected) return;
    try {
      var s = await app.service.screensaverStatus(album: _album);
      if (_album.isNotEmpty && !s.albums.contains(_album)) {
        _album = '';
        s = await app.service.screensaverStatus();
      }
      // The TV's config.json is the source of truth (the laptop may have changed it).
      if (s.config != null) {
        app.tv!.config = s.config!;
        app.saveTv();
      }
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
    setState(() {
      _busy = label;
      _progress = null;
    });
    await f();
    if (mounted) setState(() => _busy = null);
    await _refresh();
  }

  /// Write the settings to the TV.
  Future<bool> _saveConfig({String? success}) {
    final app = AppScope.read(context);
    return runTv(context, () async {
      await app.service.pushConfig(app.tv!.config);
      app.saveTv();
    }, success: success);
  }

  // ---------- albums ----------

  Future<void> _newAlbum() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New album'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. Family, Travel, Diwali'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    if (!albumNameRe.hasMatch(name)) {
      showMessage(context, 'Album names can use letters, numbers, spaces, - and _.', error: true);
      return;
    }
    final app = AppScope.read(context);
    await _do('Creating album…', () async {
      if (await runTv(context, () => app.service.createAlbum(name), success: 'Album "$name" created')) _album = name;
    });
  }

  Future<void> _deleteAlbum() async {
    final name = _album;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete the album "$name"?'),
        content: const Text('Its photos and videos are removed from the TV. They stay on your phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final app = AppScope.read(context);
    await _do('Deleting album…', () async {
      final done = await runTv(context, () => app.service.deleteAlbum(name), success: 'Album deleted');
      if (!done) return;
      final cfg = app.tv!.config;
      if (cfg.album == name) cfg.album = '';
      cfg.schedule.removeWhere((r) => r.album == name);
      cfg.captions.removeWhere((k, _) => k.startsWith('albums/$name/'));
      cfg.soundOn.removeWhere((k) => k.startsWith('albums/$name/'));
      _album = '';
      if (mounted) await _saveConfig();
    });
  }

  // ---------- one photo / video ----------

  Future<void> _editItem(String name) async {
    final app = AppScope.read(context);
    final cfg = app.tv!.config;
    final key = mediaKey(_album, name);
    final isVideo = videoExt.hasMatch(name);
    final caption = TextEditingController(text: cfg.captions[key] ?? '');
    var sound = cfg.soundOn.contains(key);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(isVideo ? 'Video' : 'Photo', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: caption,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Caption on the TV',
                  hintText: 'e.g. Goa, December 2025',
                  border: OutlineInputBorder(),
                ),
              ),
              if (isVideo)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Play with sound'),
                  subtitle: Text(cfg.muteVideo ? 'Other videos stay muted' : 'All videos already play with sound'),
                  value: sound || !cfg.muteVideo,
                  onChanged: cfg.muteVideo ? (v) => setSheet(() => sound = v) : null,
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    icon: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                    label: Text('Remove from TV', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                    onPressed: () => Navigator.pop(ctx, 'delete'),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') return _delete(name);
    if (action != 'save') return;
    final text = caption.text.trim();
    if (text.isEmpty) {
      cfg.captions.remove(key);
    } else {
      cfg.captions[key] = text;
    }
    cfg.soundOn.remove(key);
    if (sound) cfg.soundOn.add(key);
    await _do('Saving…', () => _saveConfig(success: 'Saved'));
  }

  /// Remove the selected photos and videos from the TV in one go.
  Future<void> _deleteSelected() async {
    final names = _selected?.toList() ?? const <String>[];
    if (names.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${names.length} from the TV?'),
        content: const Text('They are removed from the TV screensaver. They stay on your phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final app = AppScope.read(context);
    final album = _album;
    await _do(
      'Removing…',
      () => runTv(context, () async {
        final cfg = app.tv!.config;
        var changed = false;
        for (var i = 0; i < names.length; i++) {
          if (mounted) {
            setState(() {
              _busy = 'Removing ${i + 1} of ${names.length}…';
              _progress = i / names.length;
            });
          }
          await app.service.deleteMedia(names[i], album: album);
          app.localMedia(names[i])?.deleteSync();
          final key = mediaKey(album, names[i]);
          changed = (cfg.captions.remove(key) != null) | cfg.soundOn.remove(key) | changed;
        }
        if (changed) {
          await app.service.pushConfig(cfg);
          app.saveTv();
        }
        _selected = null;
      }, success: 'Removed ${names.length} from the TV'),
    );
  }

  void _toggle(String name) => setState(() {
    final sel = _selected ??= {};
    if (!sel.remove(name)) sel.add(name);
    if (sel.isEmpty) _selected = null;
  });

  Future<void> _delete(String name) async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove from TV?'),
        content: const Text('This removes it from the TV screensaver. It stays on your phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final album = _album;
    await _do(
      'Removing…',
      () => runTv(context, () async {
        await app.service.deleteMedia(name, album: album);
        app.localMedia(name)?.deleteSync();
        final cfg = app.tv!.config, key = mediaKey(album, name);
        if (cfg.captions.remove(key) != null || cfg.soundOn.remove(key)) {
          await app.service.pushConfig(cfg);
          app.saveTv();
        }
      }),
    );
  }

  // ---------- weather ----------

  Future<void> _setWeather() async {
    final app = AppScope.read(context);
    final cfg = app.tv!.config;
    final place = await showDialog<Object>(
      context: context,
      builder: (_) => _WeatherDialog(current: cfg.weather),
    );
    if (place == null || !mounted) return;
    setState(() => cfg.weather = place is WeatherPlace ? place : null);
    await _do(
      'Saving…',
      () => _saveConfig(success: cfg.weather == null ? 'Weather turned off' : 'Weather for ${cfg.weather!.place}'),
    );
  }

  // ---------- build ----------

  String _playingText(ScreensaverConfig cfg) {
    final main = cfg.album.isEmpty ? 'Main' : cfg.album;
    if (cfg.schedule.isEmpty) return 'Plays the $main album';
    return 'Plays $main, with ${cfg.schedule.length} schedule rule${cfg.schedule.length == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.adbConnected) return const DevModeNeeded(feature: 'The screensaver');
    final s = _status;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final busy = _busy != null;
    final cfg = app.tv!.config;
    final t = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ----- status -----
          Card(
            child: ListTile(
              leading: Icon(s.active ? Icons.check_circle : Icons.info_outline, color: s.active ? Colors.green : null),
              title: Text(
                !s.installed
                    ? 'Screensaver app not installed'
                    : s.active
                    ? 'Your photos are the TV screensaver'
                    : 'Installed, but not turned on',
              ),
              subtitle: Text(
                s.installed ? 'Starts after ${s.timeoutMin ?? '?'} min idle' : 'Install it to show your own photos.',
              ),
            ),
          ),
          if (!s.installed)
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('Install on TV'),
              onPressed: busy
                  ? null
                  : () => _do(
                      'Installing…',
                      () => ScreensaverActions.install(context, onStep: (t) => setState(() => _busy = t)),
                    ),
            ),
          if (busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 6),
            Text(_busy!),
          ],
          if (s.installed) ...[
            // ----- which album plays -----
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_note_outlined),
                title: const Text('Which album plays'),
                subtitle: Text(_playingText(cfg)),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => AlbumSchedulePage(albums: s.albums)),
                        );
                        if (mounted) setState(() {});
                      },
              ),
            ),

            Card(
              child: ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Sync from phone albums'),
                subtitle: Text(
                  app.syncStatus ??
                      (app.tv!.syncs.isEmpty
                          ? 'Keep a TV album in step with an album on this phone'
                          : app.tv!.syncs.map((x) => x.phoneAlbumName).join(', ')),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => SyncPage(tvAlbums: s.albums)));
                        if (mounted) _refresh();
                      },
              ),
            ),

            // ----- photos in an album -----
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Album', style: t.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _album,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Main')),
                      for (final a in s.albums) DropdownMenuItem(value: a, child: Text(a)),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() {
                              _album = v ?? '';
                              _status = null;
                              _selected = null;
                            });
                            _refresh();
                          },
                  ),
                ),
                IconButton(
                  tooltip: 'New album',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: busy ? null : _newAlbum,
                ),
                if (_album.isNotEmpty)
                  IconButton(
                    tooltip: 'Delete album',
                    icon: const Icon(Icons.folder_delete_outlined),
                    onPressed: busy ? null : _deleteAlbum,
                  ),
              ],
            ),
            if (_selected != null)
              Row(
                children: [
                  Expanded(child: Text('${_selected!.length} selected', style: t.titleSmall)),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() => _selected = _selected!.length == s.files.length ? {} : {...s.files}),
                    child: Text(_selected!.length == s.files.length ? 'None' : 'All'),
                  ),
                  TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Cancel')),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                    onPressed: busy || _selected!.isEmpty ? null : _deleteSelected,
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${s.files.length} photos and videos. Tap one for a caption or sound; press and hold to select.',
                    ),
                  ),
                  if (s.files.isNotEmpty)
                    TextButton(
                      onPressed: busy ? null : () => setState(() => _selected = {}),
                      child: const Text('Select'),
                    ),
                  FilledButton.icon(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Add'),
                    onPressed: busy
                        ? null
                        : () => _do(
                            'Sending…',
                            () => ScreensaverActions.addMedia(
                              context,
                              album: _album,
                              onProgress: (t, p) {
                                if (mounted) {
                                  setState(() {
                                    _busy = t;
                                    _progress = p;
                                  });
                                }
                              },
                            ),
                          ),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            if (s.files.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No photos in this album yet. Tap Add to choose some from your phone.'),
              )
            else
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final f in s.files)
                    _Thumb(
                      name: f,
                      hasCaption: cfg.captions.containsKey(mediaKey(_album, f)),
                      hasSound: cfg.soundOn.contains(mediaKey(_album, f)),
                      selected: _selected?.contains(f),
                      onTap: busy ? null : () => _selected != null ? _toggle(f) : _editItem(f),
                      onLongPress: busy ? null : () => _toggle(f),
                    ),
                ],
              ),

            // ----- settings -----
            const SizedBox(height: 24),
            Text('Settings', style: t.titleMedium),
            Card(
              child: Column(
                children: [
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
                    title: const Text('Change photos with'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'fade', label: Text('Fade')),
                          ButtonSegment(value: 'slide', label: Text('Slide')),
                          ButtonSegment(value: 'none', label: Text('Cut')),
                        ],
                        selected: {cfg.transition},
                        onSelectionChanged: (v) => setState(() => cfg.transition = v.first),
                      ),
                    ),
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
                  SwitchListTile(
                    title: const Text('Shuffle'),
                    value: cfg.shuffle,
                    onChanged: (v) => setState(() => cfg.shuffle = v),
                  ),
                  SwitchListTile(
                    title: const Text('Slow zoom motion'),
                    value: cfg.motion,
                    onChanged: (v) => setState(() => cfg.motion = v),
                  ),
                  SwitchListTile(
                    title: const Text('Show clock'),
                    value: cfg.showClock,
                    onChanged: (v) => setState(() => cfg.showClock = v),
                  ),
                  SwitchListTile(
                    title: const Text('Show date'),
                    value: cfg.showDate,
                    onChanged: (v) => setState(() => cfg.showDate = v),
                  ),
                  SwitchListTile(
                    title: const Text('On this day'),
                    subtitle: const Text(
                      'On days with old photos, show photos taken on this date in earlier years, '
                      'with "3 years ago today" on screen',
                    ),
                    value: cfg.onThisDay,
                    onChanged: (v) => setState(() => cfg.onThisDay = v),
                  ),
                  ListTile(
                    title: const Text('Weather'),
                    subtitle: Text(
                      cfg.weather == null ? 'Off' : '${cfg.weather!.place} · °${cfg.weather!.unit.toUpperCase()}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: busy ? null : _setWeather,
                  ),
                  SwitchListTile(
                    title: const Text('Mute videos'),
                    subtitle: const Text('Tap a video above to give just that one sound'),
                    value: cfg.muteVideo,
                    onChanged: (v) => setState(() => cfg.muteVideo = v),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonal(
                        onPressed: busy
                            ? null
                            : () => _do('Saving…', () => _saveConfig(success: 'Settings saved to the TV')),
                        child: const Text('Save settings'),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ----- activate -----
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('Start after the TV is idle for')),
                        DropdownButton<int>(
                          value: _minutes,
                          items: [
                            for (final m in {1, 2, 3, 5, 10, 15, 30, 60, _minutes}.toList()..sort())
                              DropdownMenuItem(value: m, child: Text('$m min')),
                          ],
                          onChanged: busy ? null : (v) => setState(() => _minutes = v!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.check),
                          label: Text(s.active ? 'Update' : 'Set as screensaver'),
                          onPressed: busy
                              ? null
                              : () => _do('Saving…', () => ScreensaverActions.activate(context, _minutes)),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Preview on TV'),
                          onPressed: busy
                              ? null
                              : () => runTv(
                                  context,
                                  () => app.service.preview(),
                                  success: 'Playing on the TV. Press Back on the TV remote to stop.',
                                ),
                        ),
                        if (s.active)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _do(
                                    'Restoring…',
                                    () => runTv(
                                      context,
                                      () => app.service.restore(app.tv!.previousScreensaver),
                                      success: 'The TV\'s own screensaver is back',
                                    ),
                                  ),
                            child: const Text('Restore original'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.system_update_alt),
                  label: const Text('Reinstall screensaver app'),
                  onPressed: busy
                      ? null
                      : () => _do(
                          'Installing…',
                          () => ScreensaverActions.install(context, onStep: (t) => setState(() => _busy = t)),
                        ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String name;
  final bool hasCaption, hasSound;
  final VoidCallback? onTap, onLongPress;
  final bool? selected; // null when not selecting
  const _Thumb({
    required this.name,
    this.hasCaption = false,
    this.hasSound = false,
    this.onTap,
    this.onLongPress,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final local = app.localMedia(name);
    final isVideo = videoExt.hasMatch(name);
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (local != null && !isVideo)
                Image.file(local, fit: BoxFit.cover, cacheWidth: 300)
              else
                Container(
                  color: cs.surfaceContainerHighest,
                  child: Center(child: Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined, size: 32)),
                ),
              Positioned(
                left: 6,
                bottom: 6,
                child: Row(
                  children: [
                    if (isVideo) const Icon(Icons.play_circle, color: Colors.white, size: 20),
                    if (hasSound) const Icon(Icons.volume_up, color: Colors.white, size: 20),
                    if (hasCaption) const Icon(Icons.short_text, color: Colors.white, size: 20),
                  ],
                ),
              ),
              if (selected != null) ...[
                if (selected!) ColoredBox(color: cs.primary.withValues(alpha: 0.35)),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    selected! ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected! ? cs.primary : Colors.white,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Find a town with Open-Meteo's free geocoding (no account). Pops a WeatherPlace, or false for "off".
class _WeatherDialog extends StatefulWidget {
  final WeatherPlace? current;
  const _WeatherDialog({this.current});

  @override
  State<_WeatherDialog> createState() => _WeatherDialogState();
}

class _WeatherDialogState extends State<_WeatherDialog> {
  late final _q = TextEditingController(text: widget.current?.place.split(',').first ?? '');
  late String _unit = widget.current?.unit ?? 'c';
  List<WeatherPlace>? _results;
  bool _searching = false;
  String? _error;

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {'name': q, 'count': '6', 'format': 'json'});
      final res = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 10));
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final list = (body['results'] as List? ?? const []).whereType<Map>().map((r) {
        final name = [r['name'], r['admin1'], r['country']].whereType<String>().where((s) => s.isNotEmpty).join(', ');
        return WeatherPlace((r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble(), name, unit: _unit);
      }).toList();
      if (!mounted) return;
      setState(() {
        _results = list;
        if (list.isEmpty) _error = 'No town found with that name.';
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not search. Check this phone is online.');
    } finally {
      client.close();
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Weather on the TV'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Type your town. The TV shows its weather next to the clock, from Open-Meteo (free, no account).',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'Town or city',
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : IconButton(icon: const Icon(Icons.search), onPressed: _search),
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'c', label: Text('°C')),
                  ButtonSegment(value: 'f', label: Text('°F')),
                ],
                selected: {_unit},
                onSelectionChanged: (v) => setState(() => _unit = v.first),
              ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
              for (final p in _results ?? const <WeatherPlace>[])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(p.place),
                  onTap: () => Navigator.pop(context, WeatherPlace(p.lat, p.lon, p.place, unit: _unit)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Turn off')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
