import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

class RemoteTab extends StatefulWidget {
  const RemoteTab({super.key});

  @override
  State<RemoteTab> createState() => _RemoteTabState();
}

class _RemoteTabState extends State<RemoteTab> {
  final _text = TextEditingController();

  Future<void> _key(String k, {bool long = false}) async {
    HapticFeedback.lightImpact();
    await runTv(context, () => AppScope.read(context).service.key(k, long: long));
  }

  Future<void> _send() async {
    final t = _text.text;
    if (t.isEmpty) return;
    final ok = await runTv(context, () => AppScope.read(context).service.text(t));
    if (ok) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _RoundKey(icon: Icons.power_settings_new, label: 'Power', color: cs.error, onTap: () => _key('power')),
          _RoundKey(icon: Icons.input, label: 'Input', onTap: () => _key('input')),
          _RoundKey(icon: Icons.settings, label: 'Settings', onTap: () => _key('settings')),
          _RoundKey(icon: Icons.mic_none, label: 'Assistant', onTap: () => _key('assistant')),
        ]),
        const SizedBox(height: 24),
        Center(child: _DPad(onKey: _key)),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _RoundKey(icon: Icons.arrow_back, label: 'Back', onTap: () => _key('back')),
          _RoundKey(icon: Icons.home_outlined, label: 'Home', onTap: () => _key('home')),
          _RoundKey(icon: Icons.view_carousel_outlined, label: 'Recent', onTap: () => _key('recents')),
        ]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _PillKeys(
            label: 'Volume',
            minus: () => _key('voldown'),
            plus: () => _key('volup'),
            minusIcon: Icons.volume_down,
            plusIcon: Icons.volume_up,
          ),
          _RoundKey(icon: Icons.volume_off_outlined, label: 'Mute', onTap: () => _key('mute')),
        ]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _RoundKey(icon: Icons.fast_rewind, label: 'Rewind', onTap: () => _key('rewind')),
          _RoundKey(icon: Icons.play_arrow, label: 'Play/Pause', onTap: () => _key('playpause')),
          _RoundKey(icon: Icons.fast_forward, label: 'Forward', onTap: () => _key('forward')),
        ]),
        const SizedBox(height: 24),
        TextField(
          controller: _text,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(
            labelText: 'Type on the TV',
            hintText: 'For search boxes',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send),
          ),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton.icon(icon: const Icon(Icons.backspace_outlined), label: const Text('Delete'), onPressed: () => _key('del')),
          TextButton.icon(icon: const Icon(Icons.keyboard_return), label: const Text('Enter'), onPressed: () => _key('enter')),
        ]),
      ]),
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
    return Column(mainAxisSize: MainAxisSize.min, children: [
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
    ]);
  }
}

class _PillKeys extends StatelessWidget {
  final String label;
  final VoidCallback minus, plus;
  final IconData minusIcon, plusIcon;
  const _PillKeys({required this.label, required this.minus, required this.plus, required this.minusIcon, required this.plusIcon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(30),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(iconSize: 28, padding: const EdgeInsets.all(16), icon: Icon(minusIcon), onPressed: minus),
          IconButton(iconSize: 28, padding: const EdgeInsets.all(16), icon: Icon(plusIcon), onPressed: plus),
        ]),
      ),
      const SizedBox(height: 4),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ]);
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
          child: IconButton(
            iconSize: 40,
            padding: const EdgeInsets.all(14),
            icon: Icon(icon),
            onPressed: () => onKey(key),
          ),
        );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Container(decoration: BoxDecoration(shape: BoxShape.circle, color: cs.surfaceContainerHighest)),
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
                child: Center(child: Text('OK', style: TextStyle(color: cs.onPrimary, fontSize: 22, fontWeight: FontWeight.bold))),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
