import 'package:flutter/material.dart';

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
              1 => const AppsTab(),
              2 => const ScreensaverTab(),
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
