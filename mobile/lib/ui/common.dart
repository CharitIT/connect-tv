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
  static Future<int> addMedia(BuildContext context, {void Function(String status, double? progress)? onProgress}) async {
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
        await app.service.uploadMedia(local, name, onProgress: (sent, total) {
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
