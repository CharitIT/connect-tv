import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final tv = app.tv;
    final profile = app.catalog.profile(tv?.profileId ?? app.selectedProfileId);
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      const _Header('Your TV'),
      ListTile(
        leading: const Icon(Icons.tv),
        title: Text(tv?.displayName ?? 'No TV'),
        subtitle: Text([
          if (tv != null) tv.address,
          if (tv?.info?.android.isNotEmpty == true) 'Android ${tv!.info!.android}',
          profile.label,
        ].join(' · ')),
      ),
      ListTile(
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Rename'),
        onTap: tv == null ? null : () => _rename(context, app),
      ),
      ListTile(
        leading: const Icon(Icons.refresh),
        title: Text(app.connected ? 'Reconnect' : 'Connect'),
        subtitle: app.connected ? null : const Text('Switch the TV on first'),
        onTap: () => runTv(context, () => app.connect(), success: 'Connected'),
      ),
      if (app.connected)
        ListTile(leading: const Icon(Icons.link_off), title: const Text('Disconnect'), onTap: app.userDisconnect),

      _Header(app.tvs.length > 1 ? 'Other TVs' : 'More TVs'),
      for (final t in app.tvs)
        if (!identical(t, tv))
          ListTile(
            leading: const Icon(Icons.tv_outlined),
            title: Text(t.displayName),
            subtitle: Text(t.address),
            trailing: const Text('Switch'),
            onTap: () => switchTvTo(context, t),
          ),
      ListTile(
        leading: const Icon(Icons.add),
        title: const Text('Add another TV'),
        subtitle: const Text('Save it here and switch between your TVs'),
        onTap: () => runTv(context, () async => app.addTv()),
      ),

      const _Header('Connections'),
      ListTile(
        leading: Icon(Icons.pin_outlined, color: app.remoteConnected ? Colors.green : null),
        title: Text(tv?.remotePaired == true ? 'Remote: paired' : 'Pair as remote'),
        subtitle: Text(app.remoteConnected
            ? 'Connected. Keys and apps work without Developer mode.'
            : tv?.remotePaired == true
                ? 'Not connected right now. Tap to pair again if the TV forgot this phone.'
                : 'Pair with a code shown on the TV. No Developer mode needed.'),
        onTap: tv == null ? null : () => _pair(context, app),
      ),
      ListTile(
        leading: Icon(Icons.developer_mode, color: app.adbConnected ? Colors.green : null),
        title: const Text('Developer mode'),
        subtitle: Text(app.adbConnected
            ? 'Connected. Screensaver, typing and the full app list are available.'
            : app.adbWaitingForAllow
                ? 'Look at your TV: tick "Always allow", then choose Allow.'
                : app.adbError ?? 'Not connected. Needed for the screensaver. Tap to connect.'),
        onTap: app.adbConnected || app.adbWaitingForAllow
            ? null
            : () => runTv(context, app.connectDeveloperMode, success: 'Developer mode connected'),
      ),

      const _Header('Help'),
      ExpansionTile(
        leading: const Icon(Icons.developer_mode),
        title: const Text('How to turn on Developer mode'),
        subtitle: Text(profile.label),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (var i = 0; i < profile.steps.length; i++)
            ListTile(dense: true, leading: CircleAvatar(radius: 12, child: Text('${i + 1}')), title: Text(profile.steps[i])),
        ],
      ),
      const ExpansionTile(
        leading: Icon(Icons.wifi_off),
        title: Text('The app can\'t connect'),
        childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Text('• Switch the TV on. Most TVs turn their Wi-Fi off in standby.\n'
              '• Make sure the phone and the TV are on the same Wi-Fi network (not a guest network).\n'
              '• Check the TV\'s IP address hasn\'t changed: Settings → Network & Internet → your Wi-Fi.\n'
              '• If pairing worked before, tap "Pair as remote" above to pair again.\n'
              '• Turn USB debugging off and on again on the TV, or restart the TV.\n'
              '• iPhone: Settings → Privacy & Security → Local Network → turn on Connect TV.'),
        ],
      ),

      const _Header('Start over'),
      ListTile(
        leading: const Icon(Icons.restart_alt),
        title: const Text('Run the setup guide again'),
        onTap: () => app.onboarded = false,
      ),
      ListTile(
        leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
        title: const Text('Forget this TV'),
        subtitle: Text(app.tvs.length > 1 ? 'Remove it from this phone' : 'Connect a different TV'),
        onTap: () => _forget(context, app),
      ),
      const SizedBox(height: 24),
      const Center(child: Text('Connect TV · works with Android TV and Google TV')),
      const SizedBox(height: 24),
    ]);
  }

  Future<void> _pair(BuildContext context, AppState app) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pair as remote'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Switch the TV on. It will show a code for you to type here.'),
              const SizedBox(height: 16),
              PairPanel(address: () => app.tv!.address, onPaired: () => Navigator.pop(ctx)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );

  Future<void> _rename(BuildContext context, AppState app) async {
    final c = TextEditingController(text: app.tv!.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TV name'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      app.tv!.name = name;
      app.saveTv();
    }
  }

  Future<void> _forget(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this TV?'),
        content: const Text('The screensaver stays on the TV. You can add it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Forget')),
        ],
      ),
    );
    if (ok == true && context.mounted) await runTv(context, () async => app.forgetTv());
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
