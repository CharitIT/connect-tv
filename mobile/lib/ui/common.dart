import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../tv/tv_service.dart';

/// Gives every screen access to the AppState.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

void showMessage(BuildContext context, String msg, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    behavior: SnackBarBehavior.floating,
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

/// Run a TV action and show any error as a message. Returns true on success.
Future<bool> runTv(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showMessage(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showMessage(context, e.toString(), error: true);
    return false;
  }
}

/// Connection status pill shown in the app bar. Tap to reconnect.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final (Color color, String label) = switch (app.status) {
      ConnStatus.connected => (Colors.green, 'Connected'),
      ConnStatus.waitingForAllow => (Colors.orange, 'Allow on TV'),
      ConnStatus.connecting || ConnStatus.preparingKey => (Colors.orange, 'Connecting…'),
      ConnStatus.disconnected => (cs.error, 'Reconnect'),
    };
    return ActionChip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label),
      onPressed: app.connected
          ? null
          : () => runTv(context, () => app.connect(), success: 'Connected to ${app.tv?.displayName ?? 'your TV'}'),
    );
  }
}

/// Shown in place of a tab's content while the TV isn't connected.
class NotConnected extends StatelessWidget {
  const NotConnected({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final busy = app.status != ConnStatus.disconnected;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.tv_off_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(busy ? 'Connecting to your TV…' : 'Your TV isn\'t connected',
              style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            app.status == ConnStatus.waitingForAllow
                ? 'Look at your TV: tick "Always allow" and choose Allow.'
                : 'Make sure the TV is switched on (not in standby) and on the same Wi-Fi as this phone.',
            textAlign: TextAlign.center,
          ),
          if (app.lastError != null && !busy) ...[
            const SizedBox(height: 8),
            Text(app.lastError!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          busy
              ? const CircularProgressIndicator()
              : FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                  onPressed: () => runTv(context, () => app.connect()),
                ),
        ]),
      ),
    );
  }
}

// ---------- screensaver actions shared by the setup wizard and the Screensaver tab ----------

class ScreensaverActions {
  static Future<bool> install(BuildContext context, {void Function(String step)? onStep}) {
    final app = AppScope.read(context);
    return runTv(context, () async {
      final apk = await rootBundle.load('assets/tv-screensaver.apk');
      await app.service.installScreensaver(apk.buffer.asUint8List(), app.tv!.config, onStep: onStep);
    }, success: 'Screensaver app installed on the TV');
  }

  /// Pick photos/videos and send them to the TV. Returns how many were added.
  static Future<int> addMedia(BuildContext context,
      {String album = '', void Function(String status, double? progress)? onProgress}) async {
    final app = AppScope.read(context);
    final List<XFile> picked;
    try {
      // Resizing also converts iPhone HEIC photos to JPEG.
      picked = await ImagePicker().pickMultipleMedia(maxWidth: 3840, maxHeight: 2160, imageQuality: 90);
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not open your photos: $e', error: true);
      return 0;
    }
    if (picked.isEmpty) return 0;

    var added = 0;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < picked.length; i++) {
      final x = picked[i];
      final ext = x.name.contains('.') ? x.name.split('.').last.toLowerCase() : 'jpg';
      final name = 'CTV_${stamp}_$i.$ext';
      onProgress?.call('Sending ${i + 1} of ${picked.length}…', i / picked.length);
      try {
        if (!mediaExt.hasMatch(name)) throw Exception('${x.name}: this file type isn\'t supported');
        final local = await File(x.path).copy('${app.mediaDir.path}/$name');
        await app.service.uploadMedia(local, name, album: album, onProgress: (sent, total) {
          onProgress?.call('Sending ${i + 1} of ${picked.length}…', (i + sent / (total == 0 ? 1 : total)) / picked.length);
        });
        added++;
      } catch (e) {
        if (context.mounted) showMessage(context, e.toString(), error: true);
      }
    }
    onProgress?.call('Added $added of ${picked.length}', null);
    return added;
  }

  static Future<bool> activate(BuildContext context, int minutes) {
    final app = AppScope.read(context);
    return runTv(context, () async {
      final prev = await app.service.activate(timeoutMin: minutes);
      if (prev != null) app.tv!.previousScreensaver = prev;
      app.tv!.timeoutMin = minutes;
      app.saveTv();
    }, success: 'Your photos are now the TV screensaver');
  }
}

// ---------- pairing with a code (no Developer mode needed) ----------

/// "Show code on TV" → type the code → paired. Used by the setup guide and Settings.
class PairPanel extends StatefulWidget {
  final String Function() address;
  final VoidCallback? onPaired;
  const PairPanel({super.key, required this.address, this.onPaired});

  @override
  State<PairPanel> createState() => _PairPanelState();
}

class _PairPanelState extends State<PairPanel> {
  final _code = TextEditingController();
  late final AppState _app;
  bool _shown = false, _busy = false;
  String? _tvName;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    final ok = await runTv(context, () async => _tvName = await _app.startPairing(widget.address()));
    if (mounted) setState(() { _busy = false; _shown = ok; _code.clear(); });
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final ok = await runTv(context, () => _app.finishPairing(_code.text), success: 'Paired with ${_tvName ?? 'your TV'}');
    if (!mounted) return;
    setState(() { _busy = false; if (ok) _shown = false; });
    if (ok) widget.onPaired?.call();
  }

  @override
  void dispose() {
    _app.cancelPairing();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) {
      return FilledButton.icon(
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.pin_outlined),
        label: const Text('Show code on TV'),
        onPressed: _busy ? null : _start,
      );
    }
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.tv),
            SizedBox(width: 8),
            Text('Look at your TV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 8),
          Text('${_tvName ?? 'The TV'} is showing a 6-character code. Type it here:'),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            maxLength: 6,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9A-Fa-f]'))],
            style: const TextStyle(fontSize: 28, letterSpacing: 8, fontFamily: 'monospace'),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(border: OutlineInputBorder(), counterText: '', hintText: 'A1B2C3'),
            onSubmitted: _busy ? null : (_) => _finish(),
          ),
          const SizedBox(height: 12),
          Row(children: [
            TextButton(onPressed: _busy ? null : _start, child: const Text('New code')),
            const Spacer(),
            FilledButton(onPressed: _busy ? null : _finish, child: const Text('Pair')),
          ]),
        ]),
      ),
    );
  }
}

// ---------- shown where Developer mode is needed ----------

/// Explains that a feature needs Developer mode, with the steps for this TV and a Connect button.
class DevModeNeeded extends StatelessWidget {
  final String feature;
  const DevModeNeeded({super.key, required this.feature});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final profile = app.catalog.profile(app.tv?.profileId ?? app.selectedProfileId);
    final steps = profile.steps.where((s) => !s.startsWith('Tap Connect')).toList();
    final busy = app.status == ConnStatus.connecting || app.adbWaitingForAllow;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Icon(Icons.developer_mode, size: 48, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 12),
      Text('$feature needs Developer mode', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('The remote and switching apps work without it. Turn it on once with your TV remote:'),
      const SizedBox(height: 8),
      for (var i = 0; i < steps.length; i++)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(radius: 12, child: Text('${i + 1}')),
          title: Text(steps[i]),
        ),
      if (app.adbError != null) ...[
        const SizedBox(height: 8),
        Text(app.adbError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      if (app.adbWaitingForAllow)
        Card(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: const ListTile(
            leading: Icon(Icons.touch_app),
            title: Text('Look at your TV now'),
            subtitle: Text('Tick "Always allow from this computer", then choose Allow.'),
          ),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        icon: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.link),
        label: const Text('I\'ve done this — connect'),
        onPressed: busy ? null : () => runTv(context, app.connectDeveloperMode, success: 'Developer mode connected'),
      ),
    ]);
  }
}

// ---------- open a link on the TV ----------

/// Ask for a link (pre-filled from [initial] or the clipboard) and open it on the TV.
Future<void> openLinkDialog(BuildContext context, {String? initial}) async {
  final app = AppScope.read(context);
  var text = initial ?? '';
  if (text.isEmpty) {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    text = findLink(clip?.text ?? '') ?? '';
  }
  if (!context.mounted) return;
  final c = TextEditingController(text: text);
  final url = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Open on the TV'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Paste a YouTube, Netflix or other web link. It opens in the matching app on the TV.'),
        const SizedBox(height: 12),
        TextField(
          controller: c,
          autofocus: text.isEmpty,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'https://…'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, findLink(c.text) ?? c.text.trim()), child: const Text('Open')),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  await runTv(context, () => app.openUrl(url), success: 'Opening on the TV…');
}

/// Switch to another saved TV and connect to it.
Future<void> switchTvTo(BuildContext context, SavedTv t) =>
    runTv(context, () => AppScope.read(context).switchTv(t), success: 'Connected to ${t.displayName}');

/// Pick which saved TV to control (or add another).
Future<void> showTvPicker(BuildContext context) async {
  final app = AppScope.read(context);
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final t in app.tvs)
          ListTile(
            leading: Icon(identical(t, app.tv) ? Icons.tv : Icons.tv_outlined),
            title: Text(t.displayName),
            subtitle: Text(t.address),
            trailing: identical(t, app.tv) ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, t),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Add another TV'),
          onTap: () => Navigator.pop(ctx, 'add'),
        ),
      ]),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'add') {
    await runTv(context, () async => app.addTv());
  } else if (choice is SavedTv && !identical(choice, app.tv)) {
    await switchTvTo(context, choice);
  }
}
