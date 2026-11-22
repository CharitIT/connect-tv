// A live picture of what's on the TV (refreshed every few seconds). Needs Developer mode.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'common.dart';

class ScreenPage extends StatefulWidget {
  const ScreenPage({super.key});

  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends State<ScreenPage> {
  Uint8List? _png;
  String? _error;
  bool _live = true, _loading = false;
  DateTime? _at;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _grab());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_live) _grab();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _grab() async {
    final app = AppScope.read(context);
    if (_loading || !app.adbConnected) return;
    _loading = true;
    try {
      final png = await app.service.screenshot();
      if (mounted) setState(() { _png = png; _error = null; _at = DateTime.now(); });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TV screen'),
        actions: [
          if (app.adbConnected) ...[
            IconButton(
              tooltip: _live ? 'Pause' : 'Live',
              icon: Icon(_live ? Icons.pause : Icons.play_arrow),
              onPressed: () => setState(() => _live = !_live),
            ),
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _grab),
          ],
        ],
      ),
      body: !app.adbConnected
          ? const DevModeNeeded(feature: 'Seeing the TV screen')
          : ListView(padding: const EdgeInsets.all(16), children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: Colors.black,
                    child: _png == null
                        ? Center(
                            child: _error == null
                                ? const CircularProgressIndicator()
                                : const Icon(Icons.hide_image_outlined, color: Colors.white54, size: 48),
                          )
                        : InteractiveViewer(maxScale: 4, child: Image.memory(_png!, gaplessPlayback: true, fit: BoxFit.contain)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
              else if (_at != null)
                Text(_live ? 'Live: updates every 3 seconds. Pinch to zoom.' : 'Paused.'),
              const SizedBox(height: 16),
              const Text('Streaming apps such as Netflix and Prime Video block screenshots, '
                  'so they show as black or not at all.'),
            ]),
    );
  }
}
