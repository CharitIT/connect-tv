// TV setup guides per brand and known app names/colours, loaded from assets/devices.json
// (a copy of the project's devices.json; refresh it with tool/sync_assets.sh).

import 'dart:convert';

import 'package:flutter/services.dart';

class TvProfile {
  final String id, brand, label, os;
  final List<String> steps;
  final String? notes;
  TvProfile(this.id, this.brand, this.label, this.os, this.steps, this.notes);
}

class KnownApp {
  final String name;
  final Color color;
  KnownApp(this.name, this.color);
}

class Catalog {
  final List<TvProfile> profiles;
  final Map<String, KnownApp> apps;
  final List<String> defaultChannels;
  Catalog(this.profiles, this.apps, this.defaultChannels);

  static Future<Catalog> load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/devices.json')) as Map<String, dynamic>;
    // The laptop guide says "Click Connect here"; on the phone it's "Tap Connect".
    String phone(String s) => s.replaceAll('Click Connect here', 'Tap Connect').replaceAll('Click', 'Tap');
    final profiles = [
      for (final p in j['profiles'] as List)
        TvProfile(p['id'], p['brand'], p['label'], p['os'] ?? 'Android TV',
            [for (final s in p['steps'] as List) phone(s as String)], p['notes'] == null ? null : phone(p['notes'])),
    ];
    final apps = <String, KnownApp>{
      for (final e in (j['apps'] as Map<String, dynamic>).entries)
        e.key: KnownApp(e.value['name'], _hex(e.value['color'])),
    };
    return Catalog(profiles, apps, List<String>.from(j['defaultChannels'] as List));
  }

  TvProfile profile(String? id) => profiles.firstWhere((p) => p.id == id, orElse: () => profiles.last);

  String appName(String pkg) => apps[pkg]?.name ?? prettyPkg(pkg);
  Color? appColor(String pkg) => apps[pkg]?.color;

  static String prettyPkg(String pkg) {
    const skip = {'com', 'org', 'net', 'tv', 'android', 'app', 'apps', 'google', 'in', 'androidtv', 'atv', 'leanback'};
    final parts = pkg.split('.').where((p) => !skip.contains(p)).toList();
    final name = parts.isEmpty ? pkg : parts.last;
    return name[0].toUpperCase() + name.substring(1);
  }

  static Color _hex(String s) => Color(int.parse(s.replaceFirst('#', ''), radix: 16) | 0xff000000);
}
