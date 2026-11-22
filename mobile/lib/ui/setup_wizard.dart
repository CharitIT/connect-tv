// First-run guide: welcome → choose TV brand → turn on Developer mode → find & connect →
// set up the screensaver → feature tour.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../tv/tv_service.dart';
import 'common.dart';

class SetupWizard extends StatefulWidget {
  const SetupWizard({super.key});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  final _pages = PageController();
  int _page = 0;
  static const _count = 6;

  void _go(int p) {
    setState(() => _page = p);
    _pages.animateToPage(p, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final canNext = switch (_page) {
      1 => app.selectedProfileId != null,
      3 => app.connected,
      _ => true,
    };
    final last = _page == _count - 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up Connect TV'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_page + 1) / _count),
        ),
      ),
      body: PageView(
        controller: _pages,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const _Welcome(),
          const _ChooseBrand(),
          const _DeveloperMode(),
          _Connect(onConnected: () => _go(4)),
          const _ScreensaverSetup(),
          const _Done(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            if (_page > 0) TextButton(onPressed: () => _go(_page - 1), child: const Text('Back')),
            const Spacer(),
            if (_page == 4)
              TextButton(onPressed: () => _go(5), child: const Text('Skip for now'))
            else
              FilledButton(
                onPressed: !canNext
                    ? null
                    : last
                        ? () => app.onboarded = true
                        : () => _go(_page + 1),
                child: Text(switch (_page) {
                  0 => 'Get started',
                  2 => 'I\'ve done this',
                  _ when last => 'Start using Connect TV',
                  _ => 'Next',
                }),
              ),
            if (_page == 4) ...[
              const SizedBox(width: 8),
              FilledButton(onPressed: () => _go(5), child: const Text('Next')),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _Step({required this.icon, required this.title, this.subtitle, this.children = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 24), children: [
      Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 12),
      Text(title, style: t.headlineSmall),
      if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!, style: t.bodyLarge)],
      const SizedBox(height: 20),
      ...children,
    ]);
  }
}

// ---------- 0. Welcome ----------

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    return const _Step(
      icon: Icons.tv,
      title: 'Welcome to Connect TV',
      subtitle: 'Control your Android TV or Google TV from this phone, and show your own photos as the TV screensaver.',
      children: [
        _Feature(Icons.gamepad_outlined, 'Remote control', 'Arrows, OK, volume, power, play/pause, and typing.'),
        _Feature(Icons.apps, 'Switch apps', 'One tap for Netflix, Prime Video, YouTube and more.'),
        _Feature(Icons.photo_library_outlined, 'Your screensaver', 'Your photos and videos when the TV is idle.'),
        SizedBox(height: 16),
        Text('Setup takes about 3 minutes. You\'ll need your TV remote and this phone on the same Wi-Fi as the TV.'),
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String title, text;
  const _Feature(this.icon, this.title, this.text);

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(text),
      );
}

// ---------- 1. Choose brand ----------

class _ChooseBrand extends StatelessWidget {
  const _ChooseBrand();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return _Step(
      icon: Icons.tv_outlined,
      title: 'Which TV do you have?',
      subtitle: 'This shows the right setup steps for your TV.',
      children: [
        RadioGroup<String>(
          groupValue: app.selectedProfileId,
          onChanged: (v) => app.selectProfile(v!),
          child: Column(children: [
            for (final p in app.catalog.profiles)
              RadioListTile<String>(value: p.id, title: Text(p.label), subtitle: Text(p.os), contentPadding: EdgeInsets.zero),
          ]),
        ),
      ],
    );
  }
}

// ---------- 2. Developer mode ----------

class _DeveloperMode extends StatelessWidget {
  const _DeveloperMode();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = app.catalog.profile(app.selectedProfileId);
    // The last step is about connecting, which happens on the next page.
    final steps = p.steps.where((s) => !s.startsWith('Tap Connect')).toList();
    return _Step(
      icon: Icons.developer_mode,
      title: 'Turn on Developer mode',
      subtitle: 'A one-time setting on the TV that lets this phone control it. Use your TV remote:',
      children: [
        for (var i = 0; i < steps.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
            title: Text(steps[i]),
          ),
        if (p.notes != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [const Icon(Icons.info_outline), const SizedBox(width: 12), Expanded(child: Text(p.notes!))]),
            ),
          ),
        const SizedBox(height: 8),
        const Text('Tip: write down the IP address. You\'ll need it on the next screen.'),
      ],
    );
  }
}

// ---------- 3. Connect ----------

class _Connect extends StatefulWidget {
  final VoidCallback onConnected;
  const _Connect({required this.onConnected});

  @override
  State<_Connect> createState() => _ConnectState();
}

class _ConnectState extends State<_Connect> {
  final _ip = TextEditingController();
  List<String>? _found;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    final tv = AppScope.read(context).tv;
    if (tv != null) _ip.text = tv.address;
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = null;
    });
    try {
      final found = await discoverTvs();
      if (mounted) setState(() => _found = found);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not scan the Wi-Fi: $e', error: true);
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(String ip) async {
    _ip.text = ip;
    final app = AppScope.read(context);
    final ok = await runTv(context, () => app.connect(ip));
    if (ok && mounted) {
      showMessage(context, 'Connected to ${app.tv?.displayName}');
      widget.onConnected();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final busy = app.status != ConnStatus.disconnected && !app.connected;
    return _Step(
      icon: Icons.wifi_tethering,
      title: 'Connect to your TV',
      subtitle: 'Make sure this phone is on the same Wi-Fi as the TV.',
      children: [
        TextField(
          controller: _ip,
          enabled: !busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'TV IP address',
            hintText: 'e.g. 192.168.1.40',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.router_outlined),
          ),
          onSubmitted: busy ? null : _connect,
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('Connect'),
              onPressed: busy ? null : () => _connect(_ip.text),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            icon: _scanning
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: const Text('Find my TV'),
            onPressed: busy || _scanning ? null : _scan,
          ),
        ]),
        if (_found != null) ...[
          const SizedBox(height: 12),
          if (_found!.isEmpty)
            const Text('No TVs found. Check that USB debugging is on and the TV is on this Wi-Fi, or type the IP address.')
          else
            for (final ip in _found!)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tv),
                  title: Text(ip),
                  subtitle: const Text('TV with debugging turned on'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy ? null : () => _connect(ip),
                ),
              ),
        ],
        const SizedBox(height: 20),
        if (app.status == ConnStatus.preparingKey)
          const _Progress('Creating a secure key for this phone (first time only)…'),
        if (app.status == ConnStatus.connecting) const _Progress('Connecting…'),
        if (app.status == ConnStatus.waitingForAllow)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(Icons.touch_app), SizedBox(width: 8), Text('Look at your TV now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))]),
                SizedBox(height: 8),
                Text('It shows "Allow USB debugging?".\n1. Tick "Always allow from this computer".\n2. Choose Allow.'),
              ]),
            ),
          ),
        if (app.connected)
          Card(
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('Connected to ${app.tv?.displayName}'),
              subtitle: Text('Android ${app.tv?.info?.android ?? ''}'),
            ),
          ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  final String text;
  const _Progress(this.text);

  @override
  Widget build(BuildContext context) => Row(children: [
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ]);
}

// ---------- 4. Screensaver ----------

class _ScreensaverSetup extends StatefulWidget {
  const _ScreensaverSetup();

  @override
  State<_ScreensaverSetup> createState() => _ScreensaverSetupState();
}

class _ScreensaverSetupState extends State<_ScreensaverSetup> {
  bool? _installed;
  int _photos = 0;
  bool _active = false;
  String? _busy;
  double? _progress;
  int _minutes = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    if (!app.connected) return;
    try {
      final s = await app.service.screensaverStatus();
      if (!mounted) return;
      setState(() {
        _installed = s.installed;
        _photos = s.files.length;
        _active = s.active;
        if (s.timeoutMin != null) _minutes = s.timeoutMin!.clamp(1, 60);
      });
    } catch (_) {}
  }

  Future<void> _do(String label, Future<void> Function() f) async {
    setState(() => _busy = label);
    await f();
    if (mounted) setState(() => _busy = null);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null;
    return _Step(
      icon: Icons.photo_library_outlined,
      title: 'Your photo screensaver',
      subtitle: 'Show your own photos and videos when the TV is idle. You can also do this later.',
      children: [
        _TaskTile(
          n: 1,
          done: _installed == true,
          title: 'Install the screensaver on the TV',
          subtitle: _installed == true ? 'Installed' : 'A small app that plays your photos. Takes about a minute.',
          action: FilledButton(
            onPressed: busy ? null : () => _do('Installing…', () => ScreensaverActions.install(context, onStep: (s) => setState(() => _busy = s))),
            child: Text(_installed == true ? 'Reinstall' : 'Install'),
          ),
        ),
        _TaskTile(
          n: 2,
          done: _photos > 0,
          title: 'Add photos or videos',
          subtitle: _photos > 0 ? '$_photos on the TV' : 'Choose from this phone\'s gallery.',
          action: FilledButton(
            onPressed: busy || _installed != true
                ? null
                : () => _do('Sending…', () => ScreensaverActions.addMedia(context, onProgress: (s, p) {
                      if (mounted) setState(() { _busy = s; _progress = p; });
                    })),
            child: const Text('Add'),
          ),
        ),
        _TaskTile(
          n: 3,
          done: _active,
          title: 'Use it as the TV\'s screensaver',
          subtitle: 'Starts after the TV is idle for:',
          extra: DropdownButton<int>(
            value: _minutes,
            items: [for (final m in [1, 2, 3, 5, 10, 15, 30, 60]) DropdownMenuItem(value: m, child: Text('$m min'))],
            onChanged: busy ? null : (v) => setState(() => _minutes = v!),
          ),
          action: FilledButton(
            onPressed: busy || _installed != true ? null : () => _do('Saving…', () => ScreensaverActions.activate(context, _minutes)),
            child: Text(_active ? 'Update' : 'Turn on'),
          ),
        ),
        if (_installed == true && _photos > 0)
          OutlinedButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Preview on TV'),
            onPressed: busy ? null : () => runTv(context, () => AppScope.read(context).service.preview(), success: 'Playing on the TV. Press Back on the TV remote to stop.'),
          ),
        if (busy) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(_busy!),
        ],
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  final int n;
  final bool done;
  final String title, subtitle;
  final Widget action;
  final Widget? extra;
  const _TaskTile({required this.n, required this.done, required this.title, required this.subtitle, required this.action, this.extra});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: done ? Colors.green : null,
              child: done ? const Icon(Icons.check, color: Colors.white) : Text('$n'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle),
                ?extra,
              ]),
            ),
            const SizedBox(width: 8),
            action,
          ]),
        ),
      );
}

// ---------- 5. Done ----------

class _Done extends StatelessWidget {
  const _Done();

  @override
  Widget build(BuildContext context) {
    return const _Step(
      icon: Icons.celebration_outlined,
      title: 'You\'re all set!',
      subtitle: 'Here\'s what you can do:',
      children: [
        _Feature(Icons.gamepad_outlined, 'Remote', 'Use the arrows, OK, Back and Home. Volume and play/pause are there too, and you can type into search boxes.'),
        _Feature(Icons.apps, 'Apps', 'Tap Netflix, Prime Video, YouTube or any app on the TV to open it.'),
        _Feature(Icons.photo_library_outlined, 'Screensaver', 'Add or remove photos, change the timing and clock, preview, or go back to the TV\'s own screensaver.'),
        _Feature(Icons.settings_outlined, 'Settings', 'Reconnect, see the setup steps again, or connect a different TV.'),
        SizedBox(height: 12),
        Text('Tip: if the app says "Reconnect", switch the TV on first. Most TVs turn their Wi-Fi off in standby.'),
      ],
    );
  }
}
