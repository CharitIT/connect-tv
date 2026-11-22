// App-wide state: the saved TV, the ADB key, the live connection, and screensaver settings.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'adb/adb_client.dart';
import 'adb/adb_crypto.dart';
import 'tv/catalog.dart';
import 'tv/tv_service.dart';

enum ConnStatus { disconnected, preparingKey, connecting, waitingForAllow, connected }

class SavedTv {
  String address; // "192.168.1.40" (port 5555 implied)
  String? name, profileId, previousScreensaver;
  DeviceInfo? info;
  ScreensaverConfig config;
  int timeoutMin;

  SavedTv(this.address, {this.name, this.profileId, this.previousScreensaver, this.info, ScreensaverConfig? config, this.timeoutMin = 5})
      : config = config ?? ScreensaverConfig();

  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    final i = info;
    if (i != null && i.manufacturer.isNotEmpty) return '${i.manufacturer} ${i.model}'.trim();
    return address;
  }

  Map<String, dynamic> toJson() => {
        'address': address,
        'name': name,
        'profileId': profileId,
        'previousScreensaver': previousScreensaver,
        'info': info?.toJson(),
        'config': config.toJson(),
        'timeoutMin': timeoutMin,
      };

  static SavedTv fromJson(Map<String, dynamic> j) => SavedTv(
        j['address'],
        name: j['name'],
        profileId: j['profileId'],
        previousScreensaver: j['previousScreensaver'],
        info: j['info'] == null ? null : DeviceInfo.fromJson(Map<String, dynamic>.from(j['info'])),
        config: ScreensaverConfig.fromJson(j['config'] == null ? null : Map<String, dynamic>.from(j['config'])),
        timeoutMin: (j['timeoutMin'] as num?)?.toInt() ?? 5,
      );
}

AdbKey _generateKey(int _) => AdbKey.generate();

class AppState extends ChangeNotifier {
  AppState._(this._prefs, this.catalog, this.mediaDir);

  final SharedPreferences _prefs;
  final Catalog catalog;
  final Directory mediaDir; // local copies of uploaded photos (for thumbnails)

  static Future<AppState> load({Directory? docsDir}) async {
    final prefs = await SharedPreferences.getInstance();
    final catalog = await Catalog.load();
    final docs = docsDir ?? await getApplicationDocumentsDirectory();
    final media = Directory('${docs.path}/media')..createSync(recursive: true);
    final s = AppState._(prefs, catalog, media);
    final raw = prefs.getString('tv');
    if (raw != null) s.tv = SavedTv.fromJson(jsonDecode(raw));
    s.selectedProfileId = prefs.getString('profile') ?? s.tv?.profileId;
    return s;
  }

  // ---------- persisted ----------

  SavedTv? tv;
  String? selectedProfileId;

  bool get onboarded => _prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) {
    _prefs.setBool('onboarded', v);
    notifyListeners();
  }

  void saveTv() {
    if (tv == null) {
      _prefs.remove('tv');
    } else {
      _prefs.setString('tv', jsonEncode(tv!.toJson()));
    }
    notifyListeners();
  }

  void selectProfile(String id) {
    selectedProfileId = id;
    _prefs.setString('profile', id);
    notifyListeners();
  }

  // ---------- connection ----------

  ConnStatus status = ConnStatus.disconnected;
  String? lastError;
  AdbClient? _client;
  TvService? _service;
  Future<void>? _connecting;

  bool get connected => status == ConnStatus.connected && _client?.isOpen == true;

  /// The TV service. Throws a friendly error if not connected.
  TvService get service {
    final s = _service;
    if (s == null || !connected) throw AdbException('Not connected to your TV. Tap Reconnect.');
    return s;
  }

  Future<AdbKey> _key() async {
    final raw = _prefs.getString('adb_key');
    if (raw != null) return AdbKey.deserialize(raw);
    status = ConnStatus.preparingKey;
    notifyListeners();
    final key = await compute(_generateKey, 0);
    await _prefs.setString('adb_key', key.serialize());
    return key;
  }

  String get _keyName => 'connect-tv@${Platform.isIOS ? 'iphone' : 'android'}';

  /// Connect to [address] (or the saved TV). Safe to call repeatedly.
  Future<void> connect([String? address]) {
    return _connecting ??= _connect(address).whenComplete(() => _connecting = null);
  }

  Future<void> _connect(String? address) async {
    final host = (address ?? tv?.address ?? '').trim().replaceFirst(RegExp(r':5555$'), '');
    if (host.isEmpty) throw AdbException('Enter your TV\'s IP address.');
    if (!RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host)) throw AdbException('That doesn\'t look like an IP address, e.g. 192.168.1.40');
    disconnect(notify: false);
    lastError = null;
    try {
      final key = await _key();
      status = ConnStatus.connecting;
      notifyListeners();
      final client = await AdbClient.connect(host, key, keyName: _keyName, onAuthPrompt: () {
        status = ConnStatus.waitingForAllow;
        notifyListeners();
      });
      _client = client;
      _service = TvService(client);
      status = ConnStatus.connected;
      client.done.then((_) {
        if (_client == client) {
          status = ConnStatus.disconnected;
          _client = null;
          _service = null;
          notifyListeners();
        }
      });

      // Remember this TV.
      final info = await _service!.deviceInfo();
      if (tv == null || tv!.address != host) {
        tv = SavedTv(host, profileId: selectedProfileId, config: tv?.config);
      }
      tv!.info = info;
      tv!.profileId ??= selectedProfileId;
      saveTv();
    } catch (e) {
      status = ConnStatus.disconnected;
      lastError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Try to reconnect quietly (on app start / resume). Never throws.
  Future<void> autoConnect() async {
    if (tv == null || connected || _connecting != null) return;
    try {
      await connect();
    } catch (_) {}
  }

  void disconnect({bool notify = true}) {
    final c = _client;
    _client = null;
    _service = null;
    c?.close();
    status = ConnStatus.disconnected;
    if (notify) notifyListeners();
  }

  /// Forget the TV and start the setup again.
  void forgetTv() {
    disconnect(notify: false);
    tv = null;
    _prefs.setBool('onboarded', false);
    saveTv();
  }

  // ---------- local thumbnails ----------

  File? localMedia(String name) {
    final f = File('${mediaDir.path}/$name');
    return f.existsSync() ? f : null;
  }
}
