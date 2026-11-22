// Choose and order the favourite apps shown on the Remote tab (and as Quick switch on Apps).

import 'package:flutter/material.dart';

import 'common.dart';

class FavouritesPage extends StatefulWidget {
  const FavouritesPage({super.key});

  @override
  State<FavouritesPage> createState() => _FavouritesPageState();
}

class _FavouritesPageState extends State<FavouritesPage> {
  late List<String> _fav;
  List<String>? _all; // every app we can offer
  bool _fromTv = false;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _fav = List.of(app.favourites);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    var all = <String>[...app.catalog.apps.keys];
    var fromTv = false;
    if (app.adbConnected) {
      try {
        all = await app.service.listApps();
        fromTv = true;
      } catch (_) {}
    }
    all.sort((a, b) => app.catalog.appName(a).toLowerCase().compareTo(app.catalog.appName(b).toLowerCase()));
    if (mounted) setState(() { _all = all; _fromTv = fromTv; });
  }

  void _save() {
    AppScope.read(context).setFavourites(_fav);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final others = (_all ?? const <String>[]).where((p) => !_fav.contains(p)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favourite apps'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('On the Remote tab', style: t.titleMedium),
        const Text('Drag to reorder. Tap − to remove.'),
        const SizedBox(height: 8),
        if (_fav.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No favourites. Add some below.')),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (a, b) => setState(() => _fav.insert(b, _fav.removeAt(a))),
          children: [
            for (var i = 0; i < _fav.length; i++)
              ListTile(
                key: ValueKey(_fav[i]),
                contentPadding: EdgeInsets.zero,
                leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                title: Text(app.catalog.appName(_fav[i])),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => _fav.removeAt(i)),
                ),
              ),
          ],
        ),
        const Divider(height: 32),
        Text(_fromTv ? 'Apps on your TV' : 'Known apps', style: t.titleMedium),
        if (!_fromTv)
          const Text('Connect Developer mode to see every app on your TV.'),
        const SizedBox(height: 8),
        if (_all == null)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
        else
          for (final p in others)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(backgroundColor: app.catalog.appColor(p), radius: 10),
              title: Text(app.catalog.appName(p)),
              trailing: IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => _fav.add(p)),
              ),
            ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ]),
    );
  }
}
