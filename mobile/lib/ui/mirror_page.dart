// "Mirror this phone": show the phone's screen on the TV. The TV has Chromecast built in, so
// this hands over to the phone's own screen casting (smooth, with sound) instead of streaming
// it ourselves.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

/// AirScreen, a free AirPlay receiver for Android TV (by another company), so iPhones can mirror.
const airScreenPackage = 'com.ionitech.airscreen';

class MirrorPage extends StatelessWidget {
  const MirrorPage({super.key});

  static const _cast = MethodChannel('connecttv/cast');

  Future<void> _start(BuildContext context) async {
    String? opened;
    try {
      opened = await _cast.invokeMethod<String>('castScreen');
    } catch (_) {}
    if (!context.mounted) return;
    switch (opened) {
      case 'settings':
        showMessage(context, 'Choose your TV in the list. To stop, tap Disconnect there.');
      case 'home':
        showMessage(context, 'In Google Home, tap your TV, then "Cast my screen".');
      case 'store':
        showMessage(context, 'Install Google Home, then open it, tap your TV and choose "Cast my screen".');
      default:
        showMessage(
          context,
          'Couldn\'t open screen casting. Swipe down twice from the top of the phone and tap '
          'Cast or Smart View.',
          error: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final android = Platform.isAndroid;
    return Scaffold(
      appBar: AppBar(title: const Text('Mirror this phone')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Show everything on your phone\'s screen on the TV, with sound. '
            'It uses Chromecast, which is built into the TV.',
          ),
          const SizedBox(height: 8),
          const Text('The phone and the TV must be on the same Wi-Fi, and the TV must be switched on.'),
          const SizedBox(height: 20),
          if (android) ...[
            FilledButton.icon(
              icon: const Icon(Icons.cast),
              label: const Text('Start mirroring'),
              onPressed: () => _start(context),
            ),
            const SizedBox(height: 20),
            const _Steps(
              title: 'If your TV isn\'t listed',
              steps: [
                'Samsung phones: swipe down twice from the top and tap Smart View. If the TV isn\'t there, use Google Home.',
                'Google Home app: tap your TV, then "Cast my screen".',
                'To stop: tap the Cast notification on the phone and choose Disconnect.',
              ],
            ),
          ] else
            const IphoneMirrorSetup(),
        ],
      ),
    );
  }
}

/// iPhone: how to mirror to a Google TV (an AirPlay receiver app on the TV, then the iPhone's own
/// Screen Mirroring). Used on the Mirror page and as a step in the setup guide.
class IphoneMirrorSetup extends StatefulWidget {
  const IphoneMirrorSetup({super.key});

  @override
  State<IphoneMirrorSetup> createState() => _IphoneMirrorSetupState();
}

class _IphoneMirrorSetupState extends State<IphoneMirrorSetup> {
  bool? _installed; // known only with Developer mode

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final app = AppScope.read(context);
    if (!app.adbConnected) return;
    try {
      final yes = await app.service.isInstalled(airScreenPackage);
      if (mounted) setState(() => _installed = yes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Google TVs don\'t understand AirPlay, the iPhone\'s screen mirroring. A free AirPlay app on the TV '
          'fixes that: afterwards the iPhone\'s own Screen Mirroring shows the TV, with sound.',
        ),
        const SizedBox(height: 16),
        const _Steps(
          title: 'Once: put AirPlay on the TV',
          steps: [
            'Tap the button below. The TV opens AirScreen in its Play Store.',
            'On the TV, choose Install, then open AirScreen once and leave its settings as they are.',
          ],
        ),
        if (_installed == true)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle, color: Colors.green),
            title: Text('AirScreen is on the TV'),
          )
        else
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Open AirScreen on the TV'),
            onPressed: () async {
              await runTv(
                context,
                () => AppScope.read(context).openStorePage(airScreenPackage),
                success: 'Look at your TV',
              );
            },
          ),
        const SizedBox(height: 20),
        const _Steps(
          title: 'Each time: mirror the iPhone',
          steps: [
            'Swipe down from the top-right corner of the iPhone to open Control Center.',
            'Tap Screen Mirroring (two overlapping rectangles) and choose your TV.',
            'To stop: open Control Center, tap Screen Mirroring, then Stop Mirroring.',
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'AirScreen is made by another company and is free with an optional paid version. '
          'Other AirPlay receiver apps in the TV\'s Play Store work the same way.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

class _Steps extends StatelessWidget {
  final String title;
  final List<String> steps;
  const _Steps({required this.title, required this.steps});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(s)),
              ],
            ),
          ),
      ],
    );
  }
}
