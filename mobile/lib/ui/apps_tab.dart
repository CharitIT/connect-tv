import 'package:flutter/material.dart';

import 'common.dart';

class AppsTab extends StatefulWidget {
  const AppsTab({super.key});

  @override
  State<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<AppsTab> {
  List<String>? _apps;
  String? _current;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    try {
      final apps = await app.service.listApps();
      apps.sort((a, b) {
        final ka = app.catalog.apps.containsKey(a), kb = app.catalog.apps.containsKey(b);
        if (ka != kb) return ka ? -1 : 1;
        return app.catalog.appName(a).toLowerCase().compareTo(app.catalog.appName(b).toLowerCase());
      });
      if (mounted) setState(() { _apps = apps; _error = null; });
      _loadCurrent();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadCurrent() async {
    try {
      final c = await AppScope.read(context).service.currentApp();
      if (mounted) setState(() => _current = c);
    } catch (_) {}
  }

  Future<void> _launch(String pkg) async {
    final app = AppScope.read(context);
    final ok = await runTv(context, () => app.service.launch(pkg), success: 'Opening ${app.catalog.appName(pkg)}…');
    if (ok) Future.delayed(const Duration(seconds: 3), _loadCurrent);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: _load, child: const Text('Try again')),
      ])));
    }
    final apps = _apps;
    if (apps == null) return const Center(child: CircularProgressIndicator());
    final installed = apps.toSet();
    final quick = app.catalog.defaultChannels.where(installed.contains).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(slivers: [
        if (_current != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('On screen now: ${app.catalog.appName(_current!)}', style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
        if (quick.isNotEmpty) ...[
          _header(context, 'Quick switch'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.9,
              children: [for (final p in quick) _AppTile(pkg: p, big: true, onTap: () => _launch(p))],
            ),
          ),
        ],
        _header(context, 'All apps on your TV'),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverGrid.count(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.5,
            children: [for (final p in apps) _AppTile(pkg: p, onTap: () => _launch(p))],
          ),
        ),
      ]),
    );
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
}

class _AppTile extends StatelessWidget {
  final String pkg;
  final bool big;
  final VoidCallback onTap;
  const _AppTile({required this.pkg, required this.onTap, this.big = false});

  @override
  Widget build(BuildContext context) {
    final cat = AppScope.of(context).catalog;
    final color = cat.appColor(pkg) ?? const Color(0xFF3A3F4F);
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              cat.appName(pkg),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: big ? 18 : 13),
            ),
          ),
        ),
      ),
    );
  }
}
