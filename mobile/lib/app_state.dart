// App-wide state: the saved TV, the phone's keys, the live connections, and screensaver settings.
//
// There are two ways to talk to the TV:
//   • the Android TV Remote protocol (atv/): pairs with a code on the TV, no Developer mode.
//     Used for keys and opening apps.
//   • ADB (adb/): needs Developer mode + USB debugging. Used for the screensaver, typing,
//     the full app list, and as a fallback for keys.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'adb/adb_client.dart';
import 'adb/adb_crypto.dart';
import 'atv/atv_cert.dart';
import 'atv/atv_remote.dart';
import 'sync/album_sync.dart';
import 'tv/catalog.dart';
import 'tv/tv_service.dart';

enum ConnStatus { disconnected, preparingKey, connecting, waitingForAllow, connected }

class SavedTv {
  String address; // "192.168.1.40" (port 5555 implied)
  String? name, profileId, previousScreensaver;
  DeviceInfo? info;
  ScreensaverConfig config;
  int timeoutMin;
  bool remotePaired; // paired with the Android TV Remote protocol
  AppLimits limits;
  List<SyncLink> syncs; // phone albums mirrored to TV albums
  List<String>? favourites; // app packages on the Remote tab, in order (null = the default list)

  SavedTv(this.address, {this.name, this.profileId, this.previousScreensaver, this.info, ScreensaverConfig? config, this.timeoutMin = 5, this.remotePaired = false, AppLimits? limits, List<SyncLink>? syncs, this.favourites})
      : config = config ?? ScreensaverConfig(),
        limits = limits ?? AppLimits(),
        syncs = syncs ?? [];

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
        'remotePaired': remotePaired,
        'limits': limits.toJson(),
        'syncs': [for (final s in syncs) s.toJson()],
        'favourites': favourites,
      };

  static SavedTv fromJson(Map<String, dynamic> j) => SavedTv(
        j['address'],
        name: j['name'],
        profileId: j['profileId'],
        previousScreensaver: j['previousScreensaver'],
        info: j['info'] == null ? null : DeviceInfo.fromJson(Map<String, dynamic>.from(j['info'])),
        config: ScreensaverConfig.fromJson(j['config'] == null ? null : Map<String, dynamic>.from(j['config'])),
        timeoutMin: (j['timeoutMin'] as num?)?.toInt() ?? 5,
        remotePaired: j['remotePaired'] == true,
        limits: AppLimits.fromJson(j['limits'] == null ? null : Map<String, dynamic>.from(j['limits'])),
        syncs: [
          for (final s in (j['syncs'] as List? ?? const []))
            if (s is Map) SyncLink.fromJson(Map<String, dynamic>.from(s)),
        ],
        favourites: (j['favourites'] as List?)?.whereType<String>().toList(),
      );
}

AdbKey _generateKey(int _) => AdbKey.generate();
AtvIdentity _makeIdentity(AdbKey key) => AtvIdentity.create(key);

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
    final list = prefs.getString('tvs');
    if (list != null) {
      s.tvs.addAll((jsonDecode(list) as List).map((j) => SavedTv.fromJson(j as Map<String, dynamic>)));
    } else {
      final raw = prefs.getString('tv'); // before several TVs could be saved
      if (raw != null) s.tvs.add(SavedTv.fromJson(jsonDecode(raw)));
    }
    final current = prefs.getString('currentTv');
    s.tv = s.tvs.where((t) => t.address == current).firstOrNull ?? s.tvs.firstOrNull;
    s.selectedProfileId = prefs.getString('profile') ?? s.tv?.profileId;
    return s;
  }

  // ---------- persisted ----------

  /// All saved TVs. [tv] is the one being controlled (one of these, or null while adding a TV).
  final List<SavedTv> tvs = [];
  SavedTv? tv;
  String? selectedProfileId;

  /// While adding another TV: the TV to go back to if the user cancels.
  SavedTv? _addingFrom;
  bool get addingTv => _addingFrom != null;

  /// Bumped whenever the app switches TV, so a connection to the old TV finishing late is dropped.
  int _gen = 0;

  bool get onboarded => _prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) {
    _prefs.setBool('onboarded', v);
    notifyListeners();
  }

  void saveTv() {
    final t = tv;
    if (t != null && !tvs.contains(t)) tvs.add(t);
    _prefs.setString('tvs', jsonEncode([for (final x in tvs) x.toJson()]));
    _prefs.remove('tv');
    if (t != null) _prefs.setString('currentTv', t.address);
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

  /// Why the Developer-mode (ADB) link isn't available, when the remote link is.
  String? adbError;

  /// The TV is showing "Allow USB debugging?" for this phone.
  bool adbWaitingForAllow = false;
  AdbClient? _client;
  TvService? _service;
  AtvRemote? _remote;
  AtvPairing? _pairing;
  String? _pairingHost;
  Future<void>? _connecting;

  bool get adbConnected => _client?.isOpen == true && _service != null;
  bool get remoteConnected => _remote?.isOpen == true;
  bool get connected => adbConnected || remoteConnected;

  /// The Developer-mode TV service. Throws a friendly error if it isn't connected.
  TvService get service {
    final s = _service;
    if (s != null && adbConnected) return s;
    if (remoteConnected) throw AdbException(needsDevModeMessage);
    throw AdbException('Not connected to your TV. Tap Reconnect.');
  }

  String get needsDevModeMessage => 'This needs Developer mode on the TV (Settings tab → Developer mode).'
      '${adbError == null ? '' : '\n\n$adbError'}';

  Future<AdbKey> _key() async {
    final raw = _prefs.getString('adb_key');
    if (raw != null) return AdbKey.deserialize(raw);
    status = ConnStatus.preparingKey;
    notifyListeners();
    final key = await compute(_generateKey, 0);
    await _prefs.setString('adb_key', key.serialize());
    return key;
  }

  Future<AtvIdentity> _identity() async {
    final raw = _prefs.getString('atv_identity');
    if (raw != null) return AtvIdentity.deserialize(raw);
    final key = await _key();
    final id = await compute(_makeIdentity, key);
    await _prefs.setString('atv_identity', id.serialize());
    return id;
  }

  String get _keyName => 'connect-tv@${Platform.isIOS ? 'iphone' : 'android'}';

  static String _cleanHost(String? address) {
    final host = (address ?? '').trim().replaceFirst(RegExp(r':\d+$'), '');
    if (host.isEmpty) throw AdbException('Enter your TV\'s IP address.');
    if (!RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host)) throw AdbException('That doesn\'t look like an IP address, e.g. 192.168.1.40');
    return host;
  }

  void _rememberHost(String host) {
    if (tv == null || tv!.address != host) {
      tv = tvs.where((t) => t.address == host).firstOrNull ?? SavedTv(host, profileId: selectedProfileId);
    }
    tv!.profileId ??= selectedProfileId;
  }

  void _refreshStatus() {
    if (_connecting == null) status = connected ? ConnStatus.connected : ConnStatus.disconnected;
    notifyListeners();
  }

  /// Connect to [address] (or the saved TV). Safe to call repeatedly.
  /// [developerMode] false skips the ADB link (used right after pairing).
  Future<void> connect([String? address, bool developerMode = true]) {
    _userDisconnected = false;
    return _connecting ??= _connect(address, developerMode).whenComplete(() {
      _connecting = null;
      _refreshStatus();
    });
  }

  Future<void> _connect(String? address, bool developerMode) async {
    final host = _cleanHost(address ?? tv?.address);
    disconnect(notify: false);
    lastError = null;
    adbError = null;
    try {
      final key = await _key();
      status = ConnStatus.connecting;
      notifyListeners();

      // 1. The remote link, if this phone was paired. Fast, and needs no Developer mode.
      if (tv?.address == host && tv!.remotePaired) {
        try {
          await _connectRemote(host);
          status = ConnStatus.connected;
          notifyListeners();
        } on AtvNotPaired {
          tv!.remotePaired = false; // the TV forgot this phone
          saveTv();
        } catch (_) {}
      }

      // 2. The Developer-mode link. If the remote already works, finish this in the background.
      final adb = _connectAdb(host, key, developerMode);
      if (remoteConnected) {
        unawaited(adb.catchError((Object e) {
          adbError = e.toString();
          notifyListeners();
        }));
        return;
      }
      await adb;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Connect only the Developer-mode link, keeping the remote link. Waits for "Allow" on the TV.
  Future<void> connectDeveloperMode() async {
    if (adbConnected) return;
    if (!remoteConnected) return connect();
    final host = _cleanHost(tv?.address);
    _client?.close();
    try {
      await _connectAdb(host, await _key(), true);
    } catch (e) {
      adbError = e.toString();
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _connectAdb(String host, AdbKey key, bool enabled) async {
    if (!enabled) throw AdbException('Developer mode isn\'t set up yet.');
    final gen = _gen;
    final AdbClient client;
    try {
      client = await AdbClient.connect(host, key, keyName: _keyName, onAuthPrompt: () {
        adbWaitingForAllow = true;
        if (!remoteConnected) status = ConnStatus.waitingForAllow;
        notifyListeners();
      });
    } finally {
      adbWaitingForAllow = false;
    }
    if (gen != _gen) {
      client.close(); // the user switched to another TV meanwhile
      return;
    }
    _client = client;
    _service = TvService(client);
    adbError = null;
    client.done.then((_) {
      if (_client == client) {
        _client = null;
        _service = null;
        _refreshStatus();
      }
    });
    final info = await _service!.deviceInfo();
    _rememberHost(host);
    tv!.info = info;
    saveTv();
    // Bring synced phone albums up to date, quietly (only if photo access was already given).
    if (tv!.syncs.isNotEmpty) unawaited(syncAlbums(quiet: true).catchError((_) {}));
    // The bedtime script stops when the TV restarts: start it again if it's switched on.
    if (tv!.limits.enabled) {
      unawaited(_service!.appLimitsRunning().then((running) {
        if (!running) return _service?.applyAppLimits(tv!.limits);
      }).catchError((_) {}));
    }
  }

  Future<void> _connectRemote(String host) async {
    final gen = _gen;
    final r = await AtvRemote.connect(host, await _identity());
    if (gen != _gen) {
      r.close();
      return;
    }
    _remote = r;
    r.onChange = notifyListeners;
    r.done.then((_) {
      if (_remote == r) {
        _remote = null;
        _refreshStatus();
      }
    });
  }

  // ---------- pairing (Android TV Remote protocol) ----------

  /// Ask the TV at [address] to show a pairing code. Returns the TV's name, if it says.
  Future<String?> startPairing(String address) async {
    final host = _cleanHost(address);
    final id = await _identity();
    cancelPairing();
    final p = await AtvPairing.start(host, id, clientName: 'Connect TV (${Platform.isIOS ? 'iPhone' : 'Android'})');
    _pairing = p;
    _pairingHost = host;
    return p.tvName;
  }

  /// Send the code shown on the TV, then connect.
  Future<void> finishPairing(String code) async {
    final p = _pairing, host = _pairingHost;
    if (p == null || host == null) throw AdbException('Tap "Show code on TV" first.');
    await p.finish(code);
    cancelPairing();
    _rememberHost(host);
    tv!.remotePaired = true;
    if ((tv!.name ?? '').isEmpty && (p.tvName ?? '').isNotEmpty) tv!.name = p.tvName;
    saveTv();
    await connect(host);
  }

  void cancelPairing() {
    _pairing?.close();
    _pairing = null;
    _pairingHost = null;
  }

  // ---------- actions that work over either link ----------

  /// Press a key ("up", "ok", "volup", …). Uses the remote link when available.
  Future<void> sendKey(String name, {bool long = false}) async {
    final r = _remote;
    final code = keyNumbers[name];
    if (r != null && r.isOpen && code != null) return r.key(code, long: long);
    return service.key(name, long: long);
  }

  // ---------- favourite apps ----------

  /// Apps shown on the Remote tab and as Quick switch, in order.
  List<String> get favourites => tv?.favourites ?? catalog.defaultChannels;

  void setFavourites(List<String> pkgs) {
    if (tv == null) return;
    tv!.favourites = List.of(pkgs);
    saveTv();
  }

  // ---------- volume ----------

  /// The TV's volume (level, max, muted), from the remote link or Developer mode.
  (int, int, bool)? get volume {
    final r = _remote;
    if (r != null && r.isOpen && r.volume != null && (r.volumeMax ?? 0) > 0) return (r.volume!, r.volumeMax!, r.muted ?? false);
    return _adbVolume;
  }

  (int, int, bool)? _adbVolume;

  /// Read the volume again (after a volume key). The remote link reports it by itself;
  /// with only Developer mode it has to be asked.
  Future<void> refreshVolume() async {
    if (!adbConnected) return;
    final r = _remote;
    if (r != null && r.isOpen && r.volume != null) return;
    try {
      _adbVolume = await service.volume();
      notifyListeners();
    } catch (_) {}
  }

  /// Move the volume to [target] by pressing volume up/down the right number of times,
  /// then checking. (Android 11 TVs can't set a volume number directly.)
  Future<void> setVolume(int target) async {
    for (var pass = 0; pass < 3; pass++) {
      final v = volume;
      if (v == null) return;
      final diff = target.clamp(0, v.$2) - v.$1;
      if (diff == 0) return;
      final key = diff > 0 ? 'volup' : 'voldown';
      final r = _remote;
      if (r != null && r.isOpen && r.volume != null) {
        for (var i = 0; i < diff.abs(); i++) {
          await r.key(keyNumbers[key]!);
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500)); // the TV reports the new level
      } else if (adbConnected) {
        await service.keyRepeat(key, diff.abs());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _adbVolume = await service.volume();
      } else {
        return;
      }
      notifyListeners();
      // If one press moves more than one step, stop once we've passed the target.
      final now = volume;
      if (now == null || (target - now.$1).sign != diff.sign) return;
    }
  }

  /// Open an app by package name.
  Future<void> launchApp(String pkg) async {
    if (adbConnected) return service.launch(pkg);
    final r = _remote;
    if (r != null && r.isOpen) return r.openLink('market://launch?id=$pkg');
    throw AdbException('Not connected to your TV. Tap Reconnect.');
  }

  /// Type text on the TV. Uses Developer mode if connected, otherwise key presses over
  /// the remote link (letters arrive lower-case, which search boxes don't mind).
  Future<void> typeText(String text) async {
    if (adbConnected) return service.text(text);
    final r = _remote;
    if (r == null || !r.isOpen) throw AdbException('Not connected to your TV. Tap Reconnect.');
    final skipped = <String>{};
    for (final ch in text.split('')) {
      final code = charKeyCode(ch);
      if (code == null) {
        skipped.add(ch);
        continue;
      }
      await r.key(code);
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    if (skipped.isNotEmpty) {
      throw AdbException('Some characters can\'t be typed without Developer mode: ${skipped.join(' ')}');
    }
  }

  /// Open a web link on the TV (YouTube, Netflix… links open in their apps).
  Future<void> openUrl(String url) async {
    url = url.trim();
    if (!webLink.hasMatch(url)) throw AdbException('That isn\'t a web link. Links start with https://');
    final r = _remote;
    if (r != null && r.isOpen) return r.openLink(url);
    return service.openUrl(url);
  }

  // ---------- sleep timer ----------

  /// When the TV will go to sleep, if a timer is set.
  DateTime? sleepAt;

  /// True when the timer runs on the phone (no Developer mode), so the app must stay open.
  bool sleepTimerOnPhone = false;
  Timer? _phoneSleepTimer;

  /// Put the TV to sleep after [minutes]; null cancels. Runs on the TV when Developer mode
  /// is connected (the phone can then be switched off), otherwise in this app.
  Future<void> setSleepTimer(int? minutes) async {
    _phoneSleepTimer?.cancel();
    _phoneSleepTimer = null;
    // A timer on the TV keeps working when the phone locks; one in this app doesn't (the phone pauses
    // apps in the background). So if Developer mode has dropped, reconnect it first when it worked before.
    if (!adbConnected && remoteConnected && tv?.info != null && !adbWaitingForAllow) {
      try {
        await connectDeveloperMode().timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    var onTv = false;
    if (adbConnected) {
      try {
        await service.setSleepTimer(minutes);
        onTv = true;
      } catch (_) {
        // The link may be stale: reconnect once and try again.
        _client?.close();
        try {
          await connectDeveloperMode().timeout(const Duration(seconds: 10));
          await service.setSleepTimer(minutes);
          onTv = true;
        } catch (_) {
          if (!remoteConnected) rethrow;
        }
      }
    }
    if (onTv) {
      sleepTimerOnPhone = false;
    } else if (minutes != null && minutes > 0) {
      if (!remoteConnected) throw AdbException('Not connected to your TV. Tap Reconnect.');
      _phoneSleepTimer = Timer(Duration(minutes: minutes), () async {
        sleepAt = null;
        notifyListeners();
        try {
          await sendKey('sleep');
        } catch (_) {}
      });
      sleepTimerOnPhone = true;
    }
    sleepAt = (minutes == null || minutes <= 0) ? null : DateTime.now().add(Duration(minutes: minutes));
    notifyListeners();
  }

  /// Read the timer back from the TV (e.g. after the app restarts).
  Future<void> refreshSleepTimer() async {
    if (!adbConnected || _phoneSleepTimer != null) return;
    final left = await service.sleepTimerLeft();
    sleepAt = left == null ? null : DateTime.now().add(Duration(seconds: left));
    sleepTimerOnPhone = false;
    notifyListeners();
  }

  // ---------- phone album sync ----------

  /// What the sync is doing right now (null when idle), and its progress 0–1.
  String? syncStatus;
  double? syncProgress;
  Future<void>? _syncing;

  /// Sync every linked phone album (or just [only]). [quiet] skips it if photo access
  /// hasn't been given yet, so no prompt appears by surprise.
  Future<void> syncAlbums({SyncLink? only, bool quiet = false}) {
    return _syncing ??= _syncAlbums(only, quiet).then((_) => lastSyncError = null, onError: (Object e) {
      lastSyncError = e.toString();
      if (!quiet) throw e;
    }).whenComplete(() {
      _syncing = null;
      syncStatus = null;
      syncProgress = null;
      notifyListeners();
    });
  }

  Future<void> _syncAlbums(SyncLink? only, bool quiet) async {
    final links = only == null ? [...?tv?.syncs] : [only];
    if (links.isEmpty) return;
    if (!adbConnected) {
      if (quiet) return;
      throw AdbException('Syncing sends photos with Developer mode, which isn\'t connected. $needsDevModeMessage');
    }
    if (!(quiet ? await AlbumSync.hasPermission() : await AlbumSync.requestPermission())) {
      if (quiet) return;
      throw AdbException('Connect TV needs access to your photos to sync albums. Allow it in the phone\'s Settings.');
    }
    if (await AlbumSync.isLimited()) {
      if (quiet) return;
      throw AdbException('Connect TV can only see the photos you picked, so it can\'t sync albums. '
          'Allow access to all photos: Settings → Apps → Connect TV → Permissions → Photos and videos → Allow all.');
    }
    final results = <String>[];
    final dates = <String, String>{};
    final removed = <String>[];
    for (final link in links) {
      final r = await AlbumSync.run(service, link, mediaDir, onProgress: (s, p) {
        syncStatus = s;
        syncProgress = p;
        notifyListeners();
      });
      saveTv();
      dates.addAll(r.dates);
      removed.addAll(r.removedKeys);
      results.add('${link.phoneAlbumName}: $r');
    }
    // Tell the TV when the new photos were taken (for "On this day"), keeping its other settings.
    if (dates.isNotEmpty || removed.isNotEmpty) {
      final cfg = await service.readConfig() ?? tv!.config;
      cfg.dates.addAll(dates);
      for (final k in removed) {
        cfg.dates.remove(k);
        cfg.captions.remove(k);
        cfg.soundOn.remove(k);
      }
      await service.pushConfig(cfg);
      tv!.config = cfg;
      saveTv();
    }
    lastSyncResult = results.join('\n');
  }

  String? lastSyncResult;

  /// Why the last sync failed (also for the automatic one), shown on the sync page.
  String? lastSyncError;

  /// Save and apply the app bedtime settings on the TV.
  Future<void> saveAppLimits(AppLimits limits) async {
    await service.applyAppLimits(limits);
    tv!.limits = limits;
    saveTv();
  }

  /// The app on screen, if known.
  Future<String?> currentApp() async {
    final fromRemote = _remote?.currentApp;
    if (fromRemote != null) return fromRemote;
    return adbConnected ? service.currentApp() : null;
  }

  // ---------- auto-reconnect ----------

  Timer? _watch;
  bool _userDisconnected = false; // the user tapped Disconnect: don't reconnect by ourselves
  DateTime _lastAdbRetry = DateTime(2000);

  /// While the app is open, check every few seconds and reconnect as soon as the TV is back
  /// (e.g. after standby). Also brings Developer mode back if only the remote reconnected.
  void startWatching() {
    _watch ??= Timer.periodic(const Duration(seconds: 8), (_) => _watchTick());
  }

  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  Future<void> _watchTick() async {
    final t = tv;
    if (t == null || _userDisconnected || _connecting != null || _syncing != null || _pairing != null) return;
    if (!connected) {
      if (await tvLooksOn(t.address)) await autoConnect();
      return;
    }
    // The remote is back but Developer mode isn't: retry now and then, but only if it worked before
    // (so no surprise "Allow" prompt) and the TV isn't asking right now.
    final now = DateTime.now();
    if (remoteConnected && !adbConnected && t.info != null && !adbWaitingForAllow &&
        now.difference(_lastAdbRetry) > const Duration(minutes: 1)) {
      _lastAdbRetry = now;
      try {
        await connectDeveloperMode();
      } catch (_) {}
    }
  }

  /// Try to reconnect quietly (on app start / resume). Never throws.
  Future<void> autoConnect() async {
    if (tv == null || connected || _connecting != null || _userDisconnected) return;
    try {
      await connect();
    } catch (_) {}
  }

  /// The user chose to disconnect: stay disconnected until they connect again.
  void userDisconnect() {
    _userDisconnected = true;
    disconnect();
  }

  void disconnect({bool notify = true}) {
    final c = _client, r = _remote;
    _client = null;
    _service = null;
    _remote = null;
    c?.close();
    r?.close();
    status = ConnStatus.disconnected;
    if (notify) notifyListeners();
  }

  /// Stop everything that belongs to the current TV before controlling another one.
  void _leaveTv() {
    if (_syncing != null) throw AdbException('Wait for the album sync to finish, then try again.');
    _gen++;
    _userDisconnected = false;
    cancelPairing();
    disconnect(notify: false);
    _phoneSleepTimer?.cancel();
    _phoneSleepTimer = null;
    sleepAt = null;
    sleepTimerOnPhone = false;
    lastError = null;
    adbError = null;
    adbWaitingForAllow = false;
    lastSyncResult = null;
    lastSyncError = null;
  }

  /// Control another saved TV.
  Future<void> switchTv(SavedTv t) async {
    if (identical(t, tv) && connected) return;
    _leaveTv();
    _addingFrom = null;
    tv = t;
    if (t.profileId != null) selectedProfileId = t.profileId;
    saveTv();
    await connect();
  }

  /// Start the setup guide for another TV, keeping the saved ones.
  void addTv() {
    _addingFrom = tv;
    _leaveTv();
    tv = null;
    onboarded = false;
  }

  /// Leave the setup guide without adding a TV, and go back to the previous one.
  void cancelAddTv() {
    final back = _addingFrom;
    if (back == null) return;
    _leaveTv();
    _addingFrom = null;
    tv = back;
    saveTv();
    onboarded = true;
    unawaited(autoConnect());
  }

  /// Setup finished: the TV just set up is now saved alongside the others.
  void finishSetup() {
    _addingFrom = null;
    saveTv();
    onboarded = true;
  }

  /// Forget the current TV. Switches to another saved TV, or starts the setup when none is left.
  void forgetTv() {
    final gone = tv;
    _leaveTv();
    tvs.remove(gone);
    tv = tvs.firstOrNull;
    if (tv == null) {
      _prefs.remove('currentTv');
      _prefs.setBool('onboarded', false);
    }
    saveTv();
    if (tv != null) unawaited(autoConnect());
  }

  // ---------- local thumbnails ----------

  File? localMedia(String name) {
    final f = File('${mediaDir.path}/$name');
    return f.existsSync() ? f : null;
  }
}
