// Link phone albums to TV albums and keep them in step.

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../app_state.dart';
import '../sync/album_sync.dart';
import '../tv/tv_service.dart';
import 'common.dart';

class SyncPage extends StatefulWidget {
  final List<String> tvAlbums;
  const SyncPage({super.key, required this.tvAlbums});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> with WidgetsBindingObserver {
  bool _limited = false;

  List<String> get tvAlbums => widget.tvAlbums;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLimited();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the phone's Settings: check again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _checkLimited();
  }

  Future<void> _checkLimited() async {
    try {
      final l = await AlbumSync.isLimited();
      if (mounted) setState(() => _limited = l);
    } catch (_) {}
  }

  String _ago(DateTime? t) {
    if (t == null) return 'not synced yet';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'synced just now';
    if (d.inHours < 1) return 'synced ${d.inMinutes} min ago';
    if (d.inDays < 1) return 'synced ${d.inHours} h ago';
    return 'synced ${d.inDays} days ago';
  }

  Future<void> _add(BuildContext context, AppState app) async {
    final allowed = await AlbumSync.requestPermission();
    await _checkLimited();
    if (_limited) return;
    if (!allowed) {
      if (context.mounted) {
        showMessage(context, 'Connect TV needs access to your photos. Allow it in the phone\'s Settings, then try again.', error: true);
      }
      return;
    }
    final List<(AssetPathEntity, int)> albums;
    try {
      albums = await AlbumSync.phoneAlbums();
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not read your albums: $e', error: true);
      return;
    }
    if (!context.mounted) return;
    if (albums.isEmpty) {
      showMessage(
          context,
          'No albums found on this phone. If you allowed only some photos, allow all photos for Connect TV '
          'in the phone\'s Settings → Apps → Connect TV → Permissions → Photos and videos.',
          error: true);
      return;
    }
    final linked = {for (final s in app.tv!.syncs) s.phoneAlbumId};
    if (albums.every((a) => linked.contains(a.$1.id))) {
      showMessage(context, 'All your phone albums are already linked.');
      return;
    }
    final picked = await showDialog<(AssetPathEntity, int)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose a phone album'),
        children: [
          for (final a in albums)
            if (!linked.contains(a.$1.id))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, a),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(a.$1.isAll ? Icons.photo_library : Icons.photo_album_outlined),
                  title: Text(a.$1.isAll ? 'All photos (${a.$1.name})' : a.$1.name),
                  subtitle: Text('${a.$2} items'),
                ),
              ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    final (path, count) = picked;

    // Which TV album: a new one named after the phone album, or an existing one.
    var suggested = path.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    if (suggested.isEmpty || !albumNameRe.hasMatch(suggested)) suggested = 'Phone';
    if (suggested.length > 40) suggested = suggested.substring(0, 40).trim();
    final tvAlbum = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Put the photos in which TV album?'),
        children: [
          if (!tvAlbums.contains(suggested))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, suggested),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text('New album "$suggested"'),
                subtitle: const Text('Recommended'),
              ),
            ),
          for (final a in tvAlbums)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, a),
              child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.folder_outlined), title: Text(a)),
            ),
        ],
      ),
    );
    if (tvAlbum == null || !context.mounted) return;

    final link = SyncLink(path.id, path.name, tvAlbum);
    app.tv!.syncs.add(link);
    app.saveTv();
    if (count > AlbumSync.maxPerRun) {
      showMessage(context, 'This album has $count items. ${AlbumSync.maxPerRun} are sent now; the rest on the next syncs.');
    }
    await _sync(context, app, link);
  }

  Future<void> _sync(BuildContext context, AppState app, [SyncLink? link]) async {
    final ok = await runTv(context, () => app.syncAlbums(only: link));
    if (ok && context.mounted && app.lastSyncResult != null) showMessage(context, app.lastSyncResult!);
  }

  Future<void> _remove(BuildContext context, AppState app, SyncLink link) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stop syncing "${link.phoneAlbumName}"?'),
        content: Text('The ${link.files.length} photos already on the TV can stay in the "${link.tvAlbum.isEmpty ? 'Main' : link.tvAlbum}" album, or be removed from the TV.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Remove from TV')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep on TV')),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    await runTv(context, () async {
      if (choice == 'delete') {
        for (final name in link.files.values) {
          await app.service.deleteMedia(name, album: link.tvAlbum);
          app.localMedia(name)?.deleteSync();
        }
      }
      app.tv!.syncs.remove(link);
      app.saveTv();
    }, success: 'Stopped syncing');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final syncs = app.tv?.syncs ?? const <SyncLink>[];
    final busy = app.syncStatus != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync from phone albums')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Choose an album on this phone and Connect TV keeps a TV album in step with it: new photos are sent '
            'to the TV, and photos you remove from the phone album are removed from the TV. '
            'Google Photos and iCloud albums work if they are on this phone.'),
        const SizedBox(height: 8),
        const Text('It syncs each time the app connects to the TV, or when you tap Sync now.'),
        const SizedBox(height: 16),
        if (!app.adbConnected)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.developer_mode),
              title: const Text('Developer mode isn\'t connected'),
              subtitle: Text('Syncing sends photos to the TV with Developer mode. Tap to connect.'
                  '${app.adbError == null ? '' : '\n\n${app.adbError}'}'),
              onTap: app.adbWaitingForAllow
                  ? null
                  : () => runTv(context, app.connectDeveloperMode, success: 'Developer mode connected'),
            ),
          ),
        if (app.adbWaitingForAllow)
          const Card(
            child: ListTile(
              leading: Icon(Icons.touch_app),
              title: Text('Look at your TV now'),
              subtitle: Text('Tick "Always allow", then choose Allow.'),
            ),
          ),
        if (_limited)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Allow all photos'),
              subtitle: const Text('Connect TV can only see the photos you picked, so new photos never reach the TV. '
                  'In Settings choose Photos and videos → Allow all (iPhone: Photos → Full Access).'),
              trailing: FilledButton(onPressed: AlbumSync.openSettings, child: const Text('Open Settings')),
            ),
          ),
        if (app.lastSyncError != null && !busy)
          Card(
            child: ListTile(
              leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('The last sync didn\'t finish'),
              subtitle: Text(app.lastSyncError!),
            ),
          ),
        if (busy) ...[
          LinearProgressIndicator(value: app.syncProgress),
          const SizedBox(height: 6),
          Text(app.syncStatus!),
          const SizedBox(height: 16),
        ],
        for (final s in syncs)
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync),
              title: Text('${s.phoneAlbumName} → ${s.tvAlbum.isEmpty ? 'Main' : s.tvAlbum}'),
              subtitle: Text('${s.files.length} on the TV · ${_ago(s.lastSync)}'),
              trailing: IconButton(
                tooltip: 'Stop syncing',
                icon: const Icon(Icons.link_off),
                onPressed: busy ? null : () => _remove(context, app, s),
              ),
            ),
          ),
        if (syncs.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No albums linked yet.')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Link a phone album'),
            onPressed: busy || !app.adbConnected ? null : () => _add(context, app),
          ),
          if (syncs.isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
              onPressed: busy || !app.adbConnected ? null : () => _sync(context, app),
            ),
        ]),
      ]),
    );
  }
}
