import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tv/tv_service.dart';

import 'apps_tab.dart';
import 'common.dart';
import 'remote_tab.dart';
import 'screensaver_tab.dart';
import 'settings_tab.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// Links shared to the app from Android's Share menu.
  static const _share = MethodChannel('connecttv/share');

  @override
  void initState() {
    super.initState();
    _share.setMethodCallHandler((call) async {
      if (call.method == 'shared') await _takeShared();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeShared());
  }

  Future<void> _takeShared() async {
    String? text;
    try {
      text = await _share.invokeMethod<String>('takeShared');
    } on MissingPluginException {
      return; // iPhone: no share hook (yet)
    } on PlatformException {
      return;
    }
    final link = findLink(text ?? '');
    if (link == null || !mounted) return;
    final app = AppScope.read(context);
    if (!app.connected) await app.autoConnect();
    if (mounted) await openLinkDialog(context, initial: link);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    const titles = ['Remote', 'Apps', 'Screensaver', 'Settings'];
    final needsTv = _tab != 3;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titles[_tab]),
          Text(app.tv?.displayName ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: const [StatusChip(), SizedBox(width: 12)],
      ),
      body: needsTv && !app.connected
          ? const NotConnected()
          : switch (_tab) {
              0 => const RemoteTab(),
              1 => AppsTab(key: ValueKey(app.adbConnected)),
              2 => ScreensaverTab(key: ValueKey(app.adbConnected)),
              _ => const SettingsTab(),
            },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.gamepad_outlined), selectedIcon: Icon(Icons.gamepad), label: 'Remote'),
          NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: 'Apps'),
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Screensaver'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
