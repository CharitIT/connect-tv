// Everything the app does on the TV, built on AdbClient. This is the phone version of
// the laptop server.js; keep the two in sync when changing TV behaviour.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../adb/adb_client.dart';

const ssPkg = 'com.connecttv.screensaver';
const ssDream = '$ssPkg/.PhotoDream';
const ssPreview = '$ssPkg/.PreviewActivity';
const ssDirApp = '/sdcard/Android/data/$ssPkg/files/screensaver';
const ssDirPublic = '/sdcard/Pictures/TVScreensaver';

final mediaExt = RegExp(r'\.(jpe?g|png|webp|gif|bmp|mp4|m4v|webm|mkv|mov)$', caseSensitive: false);
final videoExt = RegExp(r'\.(mp4|m4v|webm|mkv|mov)$', caseSensitive: false);

/// Quote a value for the TV's shell.
String q(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Make a file name safe for the TV (same rules as server.js safeName).
String safeName(String name) {
  var base = name.split(RegExp(r'[/\\]')).last;
  base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceFirst(RegExp(r'^\.+'), '');
  if (base.isEmpty || !mediaExt.hasMatch(base)) {
    throw AdbException('Only photos (JPG, PNG, WEBP, GIF, BMP) and videos (MP4, MOV, MKV, WEBM) are supported.');
  }
  return base;
}

const keyCodes = <String, String>{
  'up': 'KEYCODE_DPAD_UP', 'down': 'KEYCODE_DPAD_DOWN', 'left': 'KEYCODE_DPAD_LEFT', 'right': 'KEYCODE_DPAD_RIGHT',
  'ok': 'KEYCODE_DPAD_CENTER', 'back': 'KEYCODE_BACK', 'home': 'KEYCODE_HOME', 'menu': 'KEYCODE_MENU',
  'volup': 'KEYCODE_VOLUME_UP', 'voldown': 'KEYCODE_VOLUME_DOWN', 'mute': 'KEYCODE_VOLUME_MUTE',
  'power': 'KEYCODE_POWER', 'wake': 'KEYCODE_WAKEUP', 'sleep': 'KEYCODE_SLEEP',
  'playpause': 'KEYCODE_MEDIA_PLAY_PAUSE', 'rewind': 'KEYCODE_MEDIA_REWIND', 'forward': 'KEYCODE_MEDIA_FAST_FORWARD',
  'next': 'KEYCODE_MEDIA_NEXT', 'prev': 'KEYCODE_MEDIA_PREVIOUS', 'stop': 'KEYCODE_MEDIA_STOP',
  'input': 'KEYCODE_TV_INPUT', 'search': 'KEYCODE_SEARCH', 'assistant': 'KEYCODE_ASSIST',
  'settings': 'KEYCODE_SETTINGS', 'recents': 'KEYCODE_APP_SWITCH', 'del': 'KEYCODE_DEL', 'enter': 'KEYCODE_ENTER',
};

class DeviceInfo {
  final String manufacturer, model, android, device;
  final int? sdk;
  DeviceInfo(this.manufacturer, this.model, this.android, this.sdk, this.device);

  Map<String, dynamic> toJson() =>
      {'manufacturer': manufacturer, 'model': model, 'android': android, 'sdk': sdk, 'device': device};
  static DeviceInfo fromJson(Map<String, dynamic> j) => DeviceInfo(j['manufacturer'] ?? '', j['model'] ?? '',
      j['android'] ?? '', j['sdk'] as int?, j['device'] ?? '');
}

class ScreensaverConfig {
  int intervalSec;
  bool shuffle, showClock, motion, muteVideo;
  String fit; // "cover" | "contain"

  ScreensaverConfig({
    this.intervalSec = 12,
    this.shuffle = true,
    this.showClock = true,
    this.motion = true,
    this.muteVideo = true,
    this.fit = 'cover',
  });

  Map<String, dynamic> toJson() => {
        'intervalSec': intervalSec,
        'shuffle': shuffle,
        'showClock': showClock,
        'fit': fit,
        'motion': motion,
        'muteVideo': muteVideo,
      };

  static ScreensaverConfig fromJson(Map<String, dynamic>? j) {
    if (j == null) return ScreensaverConfig();
    return ScreensaverConfig(
      intervalSec: (j['intervalSec'] as num?)?.toInt() ?? 12,
      shuffle: j['shuffle'] ?? true,
      showClock: j['showClock'] ?? true,
      motion: j['motion'] ?? true,
      muteVideo: j['muteVideo'] ?? true,
      fit: j['fit'] == 'contain' ? 'contain' : 'cover',
    );
  }
}

class ScreensaverStatus {
  final bool installed, active;
  final String components;
  final int? timeoutMin;
  final List<String> files;
  ScreensaverStatus(this.installed, this.active, this.components, this.timeoutMin, this.files);
}

class TvApp {
  final String pkg;
  TvApp(this.pkg);
}

class TvService {
  final AdbClient adb;
  String? _ssDir;
  TvService(this.adb);

  Future<String> sh(String cmd, {Duration timeout = const Duration(seconds: 20)}) => adb.shell(cmd, timeout: timeout);

  Future<DeviceInfo> deviceInfo() async {
    final out = await sh('getprop ro.product.manufacturer; getprop ro.product.model; '
        'getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.device');
    final l = out.split('\n').map((s) => s.trim()).toList();
    String at(int i) => i < l.length ? l[i] : '';
    return DeviceInfo(at(0), at(1), at(2), int.tryParse(at(3)), at(4));
  }

  // ---------- remote ----------

  Future<void> key(String name, {bool long = false}) async {
    final code = keyCodes[name] ?? name;
    if (!RegExp(r'^(KEYCODE_[A-Z0-9_]+|\d{1,3})$').hasMatch(code)) throw AdbException('Unknown key');
    await sh('input keyevent ${long ? '--longpress ' : ''}$code');
  }

  Future<void> text(String text) async {
    if (text.isEmpty) return;
    await sh('input text ${q(text.replaceAll('%', r'\%').replaceAll(' ', '%s'))}');
  }

  // ---------- apps ----------

  Future<List<String>> listApps() async {
    final pkgs = <String>{};
    for (final cat in ['android.intent.category.LEANBACK_LAUNCHER', 'android.intent.category.LAUNCHER']) {
      final out = await sh('cmd package query-activities -a android.intent.action.MAIN -c $cat');
      for (final m in RegExp(r'packageName=([A-Za-z0-9_.]+)').allMatches(out)) {
        pkgs.add(m.group(1)!);
      }
      if (cat.contains('LEANBACK') && pkgs.length > 5) break;
    }
    if (pkgs.isEmpty) {
      final out = await sh('pm list packages -3');
      for (final m in RegExp(r'package:([A-Za-z0-9_.]+)').allMatches(out)) {
        pkgs.add(m.group(1)!);
      }
    }
    return pkgs.toList();
  }

  Future<void> launch(String pkg) async {
    if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(pkg)) throw AdbException('Bad app name');
    var out = await sh('monkey -p ${q(pkg)} -c android.intent.category.LEANBACK_LAUNCHER 1');
    if (RegExp('No activities found|aborted', caseSensitive: false).hasMatch(out)) {
      out = await sh('monkey -p ${q(pkg)} -c android.intent.category.LAUNCHER 1');
    }
    if (RegExp('No activities found|aborted', caseSensitive: false).hasMatch(out)) {
      throw AdbException('That app is not installed on this TV, or it can\'t be opened.');
    }
  }

  Future<String?> currentApp() async {
    final out = await sh("dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity:' | head -n 1");
    return RegExp(r' ([A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+').firstMatch(out)?.group(1);
  }

  // ---------- screensaver ----------

  Future<bool> isInstalled(String pkg) async => (await sh('pm path ${q(pkg)}')).contains('package:');

  Future<String> screensaverDir() async {
    if (_ssDir != null) return _ssDir!;
    final out = await sh('mkdir -p ${q(ssDirApp)} && touch ${q('$ssDirApp/.probe')} && echo OK');
    if (out.contains('OK')) return _ssDir = ssDirApp;
    await sh('mkdir -p ${q(ssDirPublic)}');
    await _grantMediaPermissions();
    return _ssDir = ssDirPublic;
  }

  Future<void> _grantMediaPermissions() async {
    for (final p in ['READ_EXTERNAL_STORAGE', 'READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO']) {
      await sh('pm grant $ssPkg android.permission.$p 2>/dev/null');
    }
  }

  Future<ScreensaverStatus> screensaverStatus() async {
    final installed = await isInstalled(ssPkg);
    final comp = (await sh('settings get secure screensaver_components')).trim();
    final timeoutMs = int.tryParse((await sh('settings get system screen_off_timeout')).trim());
    final files = installed ? await listScreensaverFiles() : <String>[];
    return ScreensaverStatus(installed, comp.contains(ssPkg), comp,
        timeoutMs == null ? null : (timeoutMs / 60000).round(), files);
  }

  Future<List<String>> listScreensaverFiles() async {
    final dir = await screensaverDir();
    final out = await sh('ls -1 ${q(dir)} 2>/dev/null');
    return out.split('\n').map((s) => s.trim()).where((s) => mediaExt.hasMatch(s)).toList()..sort();
  }

  /// Install (or update) the screensaver app from the APK bundled in the phone app.
  Future<void> installScreensaver(Uint8List apk, ScreensaverConfig cfg,
      {void Function(String step)? onStep}) async {
    const tmp = '/data/local/tmp/connecttv-screensaver.apk';
    onStep?.call('Sending the screensaver app to the TV…');
    await adb.push(apk, tmp);
    onStep?.call('Installing…');
    final out = await sh('pm install -r -g $tmp', timeout: const Duration(minutes: 3));
    await sh('rm -f $tmp');
    if (!out.contains('Success')) throw AdbException('Install failed: ${out.trim()}');
    _ssDir = null;
    await _grantMediaPermissions();
    onStep?.call('Preparing the photo folder…');
    // Launch once so Android creates the app's storage folder, then go back home.
    await sh('am start -n $ssPreview');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await sh('input keyevent KEYCODE_HOME');
    await pushConfig(cfg);
  }

  Future<void> pushConfig(ScreensaverConfig cfg) async {
    final dir = await screensaverDir();
    final json = const JsonEncoder.withIndent('  ').convert(cfg.toJson());
    await adb.push(Uint8List.fromList(utf8.encode(json)), '$dir/config.json');
  }

  Future<String> uploadMedia(File file, String name, {void Function(int sent, int total)? onProgress}) async {
    final safe = safeName(name);
    final dir = await screensaverDir();
    await adb.pushFile(file, '$dir/$safe', onProgress: onProgress);
    return safe;
  }

  Future<void> deleteMedia(String name) async {
    final dir = await screensaverDir();
    await sh('rm -f ${q('$dir/${safeName(name)}')}');
  }

  /// Make our screensaver the TV's screensaver. Returns the previous one (for restore).
  Future<String?> activate({int? timeoutMin}) async {
    final prev = (await sh('settings get secure screensaver_components')).trim();
    await sh('settings put secure screensaver_components $ssDream');
    await sh('settings put secure screensaver_enabled 1');
    await sh('settings put secure screensaver_activate_on_sleep 1');
    if (timeoutMin != null) {
      final mins = timeoutMin.clamp(1, 120);
      await sh('settings put system screen_off_timeout ${mins * 60000}');
    }
    return (prev.isEmpty || prev == 'null' || prev.contains(ssPkg)) ? null : prev;
  }

  Future<void> restore(String? previous) async {
    if (previous != null && previous.isNotEmpty) {
      await sh('settings put secure screensaver_components ${q(previous)}');
    } else {
      await sh('settings delete secure screensaver_components');
    }
  }

  Future<void> preview() async {
    final out = await sh('am start -n $ssPreview');
    if (out.contains('Error')) throw AdbException(out.trim());
  }
}

/// Find devices on the phone's Wi-Fi with network debugging on (port 5555 open).
Future<List<String>> discoverTvs({Duration probeTimeout = const Duration(milliseconds: 500)}) async {
  final subnets = <String>{};
  for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in iface.addresses) {
      final ip = a.address;
      if (a.isLoopback) continue;
      if (RegExp(r'^(10|172|192)\.').hasMatch(ip)) subnets.add(ip.split('.').take(3).join('.'));
    }
  }
  final ips = [for (final s in subnets) for (var i = 1; i < 255; i++) '$s.$i'];
  final found = <String>[];
  var idx = 0;
  Future<void> worker() async {
    while (idx < ips.length) {
      final ip = ips[idx++];
      try {
        final s = await Socket.connect(ip, 5555, timeout: probeTimeout);
        s.destroy();
        found.add(ip);
      } catch (_) {}
    }
  }

  await Future.wait(List.generate(64, (_) => worker()));
  found.sort((a, b) => int.parse(a.split('.').last).compareTo(int.parse(b.split('.').last)));
  return found;
}
