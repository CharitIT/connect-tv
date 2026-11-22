// "Mirror this phone": show the phone's screen on the TV. The TV has Chromecast built in, so
// this hands over to the phone's own screen casting (smooth, with sound) instead of streaming
// it ourselves.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

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
          ] else ...[
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('iPhone can\'t mirror to this TV'),
                subtitle: Text(
                  'Google TVs don\'t support AirPlay, and Apple doesn\'t let iPhones cast their whole '
                  'screen with Chromecast.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _Steps(
              title: 'What works instead',
              steps: [
                'Videos: tap the Cast button in YouTube, Netflix, Prime Video and other apps.',
                'Links: share a link to the TV with "Open a link on the TV".',
                'Photos: add them to the screensaver from the Screensaver tab.',
              ],
            ),
          ],
        ],
      ),
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
