import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';
import 'favourites_page.dart';
import 'mirror_page.dart';
import 'screen_page.dart';
import 'timers_page.dart';

class RemoteTab extends StatefulWidget {
  const RemoteTab({super.key});

  @override
  State<RemoteTab> createState() => _RemoteTabState();
}

class _RemoteTabState extends State<RemoteTab> {
  final _text = TextEditingController();
  bool _touchpad = false;

  Future<void> _key(String k, {bool long = false}) async {
    HapticFeedback.lightImpact();
    final app = AppScope.read(context);
    final ok = await runTv(context, () => app.sendKey(k, long: long));
    if (ok && const {'volup', 'voldown', 'mute'}.contains(k)) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await app.refreshVolume();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => AppScope.read(context).refreshVolume());
  }

  Future<void> _send() async {
    final t = _text.text;
    if (t.isEmpty) return;
    final ok = await runTv(context, () => AppScope.read(context).typeText(t));
    if (ok) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundKey(icon: Icons.power_settings_new, label: 'Power', color: cs.error, onTap: () => _key('power')),
              _RoundKey(icon: Icons.input, label: 'Input', onTap: () => _key('input')),
              _RoundKey(icon: Icons.settings, label: 'Settings', onTap: () => _key('settings')),
              _RoundKey(icon: Icons.mic_none, label: 'Assistant', onTap: () => _key('assistant')),
            ],
          ),
          const SizedBox(height: 16),
          const _FavouriteApps(),
          const SizedBox(height: 12),
          Center(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.gamepad_outlined), label: Text('Buttons')),
                ButtonSegment(value: true, icon: Icon(Icons.swipe_outlined), label: Text('Touchpad')),
              ],
              selected: {_touchpad},
              onSelectionChanged: (v) => setState(() => _touchpad = v.first),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: _touchpad ? _Touchpad(onKey: _key) : _DPad(onKey: _key),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundKey(icon: Icons.arrow_back, label: 'Back', onTap: () => _key('back')),
              _RoundKey(icon: Icons.home_outlined, label: 'Home', onTap: () => _key('home')),
              _RoundKey(icon: Icons.view_carousel_outlined, label: 'Recent', onTap: () => _key('recents')),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PillKeys(
                label: _volumeLabel(AppScope.of(context).volume),
                minus: () => _key('voldown'),
                plus: () => _key('volup'),
                minusIcon: Icons.volume_down,
                plusIcon: Icons.volume_up,
              ),
              _RoundKey(icon: Icons.volume_off_outlined, label: 'Mute', onTap: () => _key('mute')),
            ],
          ),
          if (AppScope.of(context).volume case (final level, final max, final muted))
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Row(
                children: [
                  Icon(muted ? Icons.volume_off : Icons.volume_up, size: 18, color: cs.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _VolumeSlider(level: level, max: max, muted: muted),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(width: 56, child: Text(muted ? 'Muted' : '$level / $max', textAlign: TextAlign.end)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundKey(icon: Icons.fast_rewind, label: 'Rewind', onTap: () => _key('rewind')),
              _RoundKey(icon: Icons.play_arrow, label: 'Play/Pause', onTap: () => _key('playpause')),
              _RoundKey(icon: Icons.fast_forward, label: 'Forward', onTap: () => _key('forward')),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _text,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              labelText: 'Type or speak on the TV',
              hintText: 'Tap 🎤 on your keyboard to speak',
              prefixIcon: const Icon(Icons.keyboard_voice_outlined),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.backspace_outlined),
                label: const Text('Delete'),
                onPressed: () => _key('del'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.keyboard_return),
                label: const Text('Enter'),
                onPressed: () => _key('enter'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.screenshot_monitor_outlined),
            title: const Text('See the TV screen'),
            subtitle: const Text('A live picture of what\'s on the TV'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScreenPage())),
          ),
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('Mirror this phone'),
            subtitle: const Text('Show your phone\'s screen on the TV'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MirrorPage())),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Open a link on the TV'),
            subtitle: const Text('YouTube, Netflix and other links'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openLinkDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.bedtime_outlined),
            title: const Text('Sleep timer & app bedtime'),
            subtitle: Text(_sleepText(AppScope.of(context).sleepAt)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TimersPage())),
          ),
        ],
      ),
    );
  }
}

/// Drag to a volume level; it is applied when you let go.
class _VolumeSlider extends StatefulWidget {
  final int level, max;
  final bool muted;
  const _VolumeSlider({required this.level, required this.max, required this.muted});

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  double? _dragging;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final value = _dragging ?? (widget.muted ? 0 : widget.level).toDouble();
    return Slider(
      value: value.clamp(0, widget.max.toDouble()),
      max: widget.max.toDouble(),
      divisions: widget.max,
      label: '${value.round()}',
      onChanged: _busy ? null : (v) => setState(() => _dragging = v),
      onChangeEnd: (v) async {
        setState(() => _busy = true);
        await runTv(context, () => AppScope.read(context).setVolume(v.round()));
        if (mounted) {
          setState(() {
            _busy = false;
            _dragging = null;
          });
        }
      },
    );
  }
}

/// One-tap buttons for the favourite apps, plus an edit button.
class _FavouriteApps extends StatelessWidget {
  const _FavouriteApps();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final p in app.favourites)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Builder(
                builder: (context) {
                  final color = app.catalog.appColor(p) ?? Theme.of(context).colorScheme.secondaryContainer;
                  final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                      ? Colors.white
                      : Colors.black;
                  return ActionChip(
                    backgroundColor: color,
                    side: BorderSide.none,
                    label: Text(
                      app.catalog.appName(p),
                      style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      runTv(context, () => app.launchApp(p), success: 'Opening ${app.catalog.appName(p)}…');
                    },
                  );
                },
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.edit_outlined, size: 18),
            label: Text(app.favourites.isEmpty ? 'Add favourite apps' : 'Edit'),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FavouritesPage())),
          ),
        ],
      ),
    );
  }
}

String _volumeLabel((int, int, bool)? v) {
  if (v == null) return 'Volume';
  final (level, _, muted) = v;
  return muted ? 'Volume · muted' : 'Volume $level';
}

String _sleepText(DateTime? at) {
  if (at == null) return 'Turn the TV off later, or limit apps at night';
  final left = at.difference(DateTime.now());
  return left.isNegative ? 'Turning off now' : 'TV turns off in ${left.inMinutes + 1} min';
}

/// Swipe to move (one arrow key per step), tap for OK.
class _Touchpad extends StatefulWidget {
  final void Function(String key) onKey;
  const _Touchpad({required this.onKey});

  @override
  State<_Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<_Touchpad> {
  static const _step = 40.0;
  Offset _acc = Offset.zero, _total = Offset.zero;
  DateTime _down = DateTime.now();
  bool _moved = false;

  void _move(Offset d) {
    _acc += d;
    _total += d;
    while (_acc.dx.abs() >= _step || _acc.dy.abs() >= _step) {
      _moved = true;
      if (_acc.dx.abs() > _acc.dy.abs()) {
        widget.onKey(_acc.dx > 0 ? 'right' : 'left');
        _acc = Offset(_acc.dx - _step * _acc.dx.sign, 0);
      } else {
        widget.onKey(_acc.dy > 0 ? 'down' : 'up');
        _acc = Offset(0, _acc.dy - _step * _acc.dy.sign);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The eager recognizer claims the touch, so swiping here doesn't scroll the page.
    return RawGestureDetector(
      gestures: {
        EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
          EagerGestureRecognizer.new,
          (_) {},
        ),
      },
      child: Listener(
        onPointerDown: (_) {
          _acc = Offset.zero;
          _total = Offset.zero;
          _moved = false;
          _down = DateTime.now();
        },
        onPointerMove: (e) => _move(e.delta),
        onPointerUp: (_) {
          final quick = DateTime.now().difference(_down) < const Duration(milliseconds: 350);
          if (!_moved && _total.distance < 12 && quick) widget.onKey('ok');
        },
        child: Container(
          width: 260,
          height: 260,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swipe_outlined, size: 40, color: cs.outline),
                const SizedBox(height: 8),
                Text(
                  'Swipe to move\nTap for OK',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundKey extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  const _RoundKey({required this.icon, required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: cs.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 60, height: 60, child: Icon(icon, color: color ?? cs.onSurface)),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _PillKeys extends StatelessWidget {
  final String label;
  final VoidCallback minus, plus;
  final IconData minusIcon, plusIcon;
  const _PillKeys({
    required this.label,
    required this.minus,
    required this.plus,
    required this.minusIcon,
    required this.plusIcon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(30),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(iconSize: 28, padding: const EdgeInsets.all(16), icon: Icon(minusIcon), onPressed: minus),
              IconButton(iconSize: 28, padding: const EdgeInsets.all(16), icon: Icon(plusIcon), onPressed: plus),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

/// Circular D-pad with an OK button in the middle.
class _DPad extends StatelessWidget {
  final void Function(String key) onKey;
  const _DPad({required this.onKey});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const size = 240.0;
    Widget arrow(String key, IconData icon, Alignment a) => Align(
      alignment: a,
      child: IconButton(iconSize: 40, padding: const EdgeInsets.all(14), icon: Icon(icon), onPressed: () => onKey(key)),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: cs.surfaceContainerHighest),
          ),
          arrow('up', Icons.keyboard_arrow_up, Alignment.topCenter),
          arrow('down', Icons.keyboard_arrow_down, Alignment.bottomCenter),
          arrow('left', Icons.keyboard_arrow_left, Alignment.centerLeft),
          arrow('right', Icons.keyboard_arrow_right, Alignment.centerRight),
          Center(
            child: Material(
              color: cs.primary,
              shape: const CircleBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onKey('ok'),
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: Center(
                    child: Text(
                      'OK',
                      style: TextStyle(color: cs.onPrimary, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
