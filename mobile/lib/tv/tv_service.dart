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

/// The same keys as Android key-code numbers, for the Android TV Remote protocol.
const keyNumbers = <String, int>{
  'up': 19, 'down': 20, 'left': 21, 'right': 22, 'ok': 23, 'back': 4, 'home': 3, 'menu': 82,
  'volup': 24, 'voldown': 25, 'mute': 164, 'power': 26, 'wake': 224, 'sleep': 223,
  'playpause': 85, 'rewind': 89, 'forward': 90, 'next': 87, 'prev': 88, 'stop': 86,
  'input': 178, 'search': 84, 'assistant': 219, 'settings': 176, 'recents': 187, 'del': 67, 'enter': 66,
};

/// Android key code for a typed character, or null if it can't be typed as a key.
/// Used to type over the remote link (letters are sent lower-case; search boxes don't mind).
int? charKeyCode(String ch) {
  final c = ch.toLowerCase().codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7a) return 29 + c - 0x61; // a–z
  if (c >= 0x30 && c <= 0x39) return 7 + c - 0x30; // 0–9
  return const {
    ' ': 62, '.': 56, ',': 55, '-': 69, '=': 70, '/': 76, '@': 77, "'": 75, ';': 74,
    '[': 71, ']': 72, r'\': 73, '`': 68, '+': 81, '#': 18, '*': 17, '\n': 66,
  }[ch];
}

/// Only plain web links can be opened on the TV.
final webLink = RegExp(r'''^https?://[^\s'"<>]+$''');

/// First web link in a piece of shared text (e.g. "Watch this! https://youtu.be/…").
String? findLink(String text) => RegExp(r'''https?://[^\s'"<>]+''').firstMatch(text)?.group(0);

const _sleepPid = '/data/local/tmp/connecttv-sleep.pid';
const _limitsPid = '/data/local/tmp/connecttv-limits.pid';
const _limitsScript = '/data/local/tmp/connecttv-limits.sh';

/// "Bedtime" for apps: between [fromMin] and [toMin] (minutes after midnight, TV's clock),
/// the TV goes back to the home screen if one of [apps] is open.
class AppLimits {
  bool enabled;
  List<String> apps;
  int fromMin, toMin;
  AppLimits({this.enabled = false, List<String>? apps, this.fromMin = 22 * 60, this.toMin = 6 * 60})
      : apps = apps ?? [];

  Map<String, dynamic> toJson() => {'enabled': enabled, 'apps': apps, 'from': fromMin, 'to': toMin};
  static AppLimits fromJson(Map<String, dynamic>? j) => j == null
      ? AppLimits()
      : AppLimits(
          enabled: j['enabled'] == true,
          apps: List<String>.from(j['apps'] ?? const []),
          fromMin: (j['from'] as num?)?.toInt() ?? 22 * 60,
          toMin: (j['to'] as num?)?.toInt() ?? 6 * 60,
        );
}

class DeviceInfo {
  final String manufacturer, model, android, device;
  final int? sdk;
  DeviceInfo(this.manufacturer, this.model, this.android, this.sdk, this.device);

  Map<String, dynamic> toJson() =>
      {'manufacturer': manufacturer, 'model': model, 'android': android, 'sdk': sdk, 'device': device};
  static DeviceInfo fromJson(Map<String, dynamic> j) => DeviceInfo(j['manufacturer'] ?? '', j['model'] ?? '',
      j['android'] ?? '', j['sdk'] as int?, j['device'] ?? '');
}

/// A schedule rule: play [album] between two dates ("MM-DD", every year) and/or between two
/// times of day (minutes after midnight). Ranges may wrap (Dec→Jan, 22:00→06:00).
class ScheduleRule {
  String album;
  String? from, to; // "10-25"
  int? fromMin, toMin;
  ScheduleRule({this.album = '', this.from, this.to, this.fromMin, this.toMin});

  bool get hasDates => from != null && to != null;
  bool get hasTimes => fromMin != null && toMin != null;

  Map<String, dynamic> toJson() => {
        'album': album,
        if (hasDates) 'from': from,
        if (hasDates) 'to': to,
        if (hasTimes) 'fromMin': fromMin,
        if (hasTimes) 'toMin': toMin,
      };

  static ScheduleRule fromJson(Map<String, dynamic> j) => ScheduleRule(
        album: j['album'] as String? ?? '',
        from: j['from'] as String?,
        to: j['to'] as String?,
        fromMin: (j['fromMin'] as num?)?.toInt(),
        toMin: (j['toMin'] as num?)?.toInt(),
      );
}

/// Where to show weather from (Open-Meteo; the TV fetches it).
class WeatherPlace {
  final double lat, lon;
  final String place;
  final String unit; // "c" | "f"
  WeatherPlace(this.lat, this.lon, this.place, {this.unit = 'c'});

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'place': place, 'unit': unit};
  static WeatherPlace? fromJson(Object? j) {
    if (j is! Map || j['lat'] is! num || j['lon'] is! num) return null;
    return WeatherPlace((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble(), j['place'] as String? ?? '',
        unit: j['unit'] == 'f' ? 'f' : 'c');
  }
}

/// The screensaver's config.json on the TV. The TV's file is the source of truth: read it,
/// change it, write it back (the laptop server does the same), so neither side loses settings.
class ScreensaverConfig {
  int intervalSec;
  bool shuffle, showClock, motion, muteVideo, showDate, onThisDay;
  String fit; // "cover" | "contain"
  String transition; // "fade" | "slide" | "none"
  String album; // "" = Main
  List<ScheduleRule> schedule;
  List<String> soundOn; // videos that play with sound (paths relative to the screensaver folder)
  Map<String, String> captions; // same keys
  Map<String, String> dates; // same keys → "YYYY-MM-DD" taken date, when the photo has no EXIF date
  WeatherPlace? weather;
  Map<String, dynamic> extra; // keys this version doesn't know, kept as they are

  ScreensaverConfig({
    this.intervalSec = 12,
    this.shuffle = true,
    this.showClock = true,
    this.motion = true,
    this.muteVideo = true,
    this.showDate = false,
    this.onThisDay = false,
    this.fit = 'cover',
    this.transition = 'fade',
    this.album = '',
    List<ScheduleRule>? schedule,
    List<String>? soundOn,
    Map<String, String>? captions,
    Map<String, String>? dates,
    this.weather,
    Map<String, dynamic>? extra,
  })  : schedule = schedule ?? [],
        soundOn = soundOn ?? [],
        captions = captions ?? {},
        dates = dates ?? {},
        extra = extra ?? {};

  static const known = {
    'intervalSec', 'shuffle', 'showClock', 'fit', 'motion', 'muteVideo', 'showDate', 'transition', 'album',
    'schedule', 'soundOn', 'captions', 'weather', 'onThisDay', 'dates',
  };

  Map<String, dynamic> toJson() => {
        ...extra,
        'intervalSec': intervalSec,
        'shuffle': shuffle,
        'showClock': showClock,
        'fit': fit,
        'motion': motion,
        'muteVideo': muteVideo,
        'showDate': showDate,
        'onThisDay': onThisDay,
        'transition': transition,
        'album': album,
        'schedule': [for (final r in schedule) r.toJson()],
        'soundOn': soundOn,
        'captions': captions,
        'dates': dates,
        'weather': weather?.toJson(),
      };

  static ScreensaverConfig fromJson(Map<String, dynamic>? j) {
    if (j == null) return ScreensaverConfig();
    return ScreensaverConfig(
      intervalSec: (j['intervalSec'] as num?)?.toInt() ?? 12,
      shuffle: j['shuffle'] ?? true,
      showClock: j['showClock'] ?? true,
      motion: j['motion'] ?? true,
      muteVideo: j['muteVideo'] ?? true,
      showDate: j['showDate'] ?? false,
      onThisDay: j['onThisDay'] ?? false,
      fit: j['fit'] == 'contain' ? 'contain' : 'cover',
      transition: const ['fade', 'slide', 'none'].contains(j['transition']) ? j['transition'] : 'fade',
      album: j['album'] is String ? j['album'] : '',
      schedule: [
        for (final r in (j['schedule'] as List? ?? const []))
          if (r is Map) ScheduleRule.fromJson(Map<String, dynamic>.from(r)),
      ],
      soundOn: [for (final s in (j['soundOn'] as List? ?? const [])) if (s is String) s],
      captions: {
        for (final e in (j['captions'] as Map? ?? const {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      dates: {
        for (final e in (j['dates'] as Map? ?? const {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      weather: WeatherPlace.fromJson(j['weather']),
      extra: {for (final e in j.entries) if (!known.contains(e.key)) e.key: e.value},
    );
  }

  ScreensaverConfig copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// Album names: letters, digits, spaces, "_" and "-". "" is the Main album.
final albumNameRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$');

/// Path of a media file relative to the screensaver folder (used for captions and sound).
String mediaKey(String album, String name) => album.isEmpty ? name : 'albums/$album/$name';

class ScreensaverStatus {
  final bool installed, active;
  final String components;
  final int? timeoutMin;
  final List<String> files; // in the album that was asked for
  final List<String> albums; // other than Main
  final ScreensaverConfig? config; // null if the TV has no config.json yet
  ScreensaverStatus(this.installed, this.active, this.components, this.timeoutMin, this.files,
      {this.albums = const [], this.config});
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

  /// The TV's volume: (level, max, muted), or null if it can't be read.
  Future<(int, int, bool)?> volume() async {
    final out = await sh("dumpsys audio | grep -A7 '^- STREAM_MUSIC'");
    final level = int.tryParse(RegExp(r'streamVolume:\s*(\d+)').firstMatch(out)?.group(1) ?? '');
    final max = int.tryParse(RegExp(r'Max:\s*(\d+)').firstMatch(out)?.group(1) ?? '');
    if (level == null || max == null || max <= 0) return null;
    return (level, max, RegExp(r'Muted:\s*true').hasMatch(out));
  }

  /// Press a key [count] times in one command (much faster than one command per press).
  Future<void> keyRepeat(String name, int count) async {
    final code = keyCodes[name] ?? name;
    if (!RegExp(r'^KEYCODE_[A-Z0-9_]+$').hasMatch(code)) throw AdbException('Unknown key');
    if (count <= 0) return;
    await sh('input keyevent ${List.filled(count.clamp(1, 100), code).join(' ')}');
  }

  Future<void> text(String text) async {
    if (text.isEmpty) return;
    await sh('input text ${q(text.replaceAll('%', r'\%').replaceAll(' ', '%s'))}');
  }

  /// Open a web link on the TV (YouTube, Netflix… links open in their apps).
  Future<void> openUrl(String url) async {
    if (!webLink.hasMatch(url)) throw AdbException('That isn\'t a web link.');
    final out = await sh('am start -a android.intent.action.VIEW -d ${q(url)}');
    if (RegExp(r'Error|unable to resolve', caseSensitive: false).hasMatch(out)) {
      throw AdbException('The TV has no app that can open this link.');
    }
  }

  /// Show an app's page in the TV's Play Store (to install it).
  Future<void> openStorePage(String pkg) async {
    if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(pkg)) throw AdbException('Bad app name');
    final out = await sh('am start -a android.intent.action.VIEW -d ${q('market://details?id=$pkg')}');
    if (RegExp(r'Error|unable to resolve', caseSensitive: false).hasMatch(out)) {
      throw AdbException('The TV has no Play Store. Install the app from the TV\'s app store instead.');
    }
  }

  /// A PNG picture of what's on the TV screen.
  Future<Uint8List> screenshot() async {
    final png = await adb.execBytes('screencap -p');
    if (png.length < 8 || png[0] != 0x89 || png[1] != 0x50) {
      throw AdbException('The TV didn\'t allow a picture of this screen. '
          'Streaming apps like Netflix and Prime Video block screenshots. Try it on the home screen.');
    }
    return png;
  }

  // ---------- timers (they run on the TV, so the phone can be switched off) ----------

  /// Put the TV to sleep after [minutes]. Null or 0 cancels the timer.
  /// The timer file holds "pid seconds"; its modification time is the start time.
  Future<void> setSleepTimer(int? minutes) async {
    await sh('[ -f $_sleepPid ] && kill \$(cut -d" " -f1 $_sleepPid) 2>/dev/null; rm -f $_sleepPid');
    if (minutes == null || minutes <= 0) return;
    final secs = minutes.clamp(1, 600) * 60;
    await sh("nohup sh -c 'echo \$\$ $secs > $_sleepPid; sleep $secs; rm -f $_sleepPid; input keyevent KEYCODE_SLEEP' "
        '>/dev/null 2>&1 &');
  }

  /// Seconds until the sleep timer fires, or null if none is running.
  Future<int?> sleepTimerLeft() async {
    final out = await sh('[ -f $_sleepPid ] && kill -0 \$(cut -d" " -f1 $_sleepPid) 2>/dev/null && '
        'echo \$(cut -d" " -f2 $_sleepPid) \$(stat -c %Y $_sleepPid) \$(date +%s)');
    final n = out.trim().split(RegExp(r'\s+')).map(int.tryParse).toList();
    if (n.length != 3 || n.contains(null)) return null;
    final left = n[0]! + n[1]! - n[2]!;
    return left > 0 ? left : null;
  }

  /// Start, update or stop the app bedtime script on the TV.
  Future<void> applyAppLimits(AppLimits l) async {
    await sh('[ -f $_limitsPid ] && kill \$(cat $_limitsPid) 2>/dev/null; rm -f $_limitsPid');
    if (!l.enabled || l.apps.isEmpty) return;
    for (final p in l.apps) {
      if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(p)) throw AdbException('Bad app name');
    }
    final from = l.fromMin.clamp(0, 1439), to = l.toMin.clamp(0, 1439);
    final inWindow = from <= to ? '[ \$t -ge $from ] && [ \$t -lt $to ]' : '[ \$t -ge $from ] || [ \$t -lt $to ]';
    final cases = l.apps.map((p) => '*" $p/"*').join('|');
    final script = '''#!/system/bin/sh
# Connect TV app bedtime: go home if a blocked app is open during the set hours.
echo \$\$ > $_limitsPid
while true; do
  h=\$(date +%H); m=\$(date +%M); t=\$((10#\$h*60+10#\$m))
  if $inWindow; then
    top=\$(dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -n 1)
    case "\$top" in $cases) input keyevent KEYCODE_HOME ;; esac
  fi
  sleep 20
done
''';
    await adb.push(Uint8List.fromList(utf8.encode(script)), _limitsScript, mode: 493 /* 0755 */);
    await sh('nohup sh $_limitsScript >/dev/null 2>&1 &');
  }

  /// True if the app bedtime script is running on the TV (it stops when the TV restarts).
  Future<bool> appLimitsRunning() async =>
      (await sh('[ -f $_limitsPid ] && kill -0 \$(cat $_limitsPid) 2>/dev/null && echo RUN')).contains('RUN');

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

  Future<ScreensaverStatus> screensaverStatus({String album = ''}) async {
    final installed = await isInstalled(ssPkg);
    final comp = (await sh('settings get secure screensaver_components')).trim();
    final timeoutMs = int.tryParse((await sh('settings get system screen_off_timeout')).trim());
    final files = installed ? await listScreensaverFiles(album: album) : <String>[];
    final albums = installed ? await listAlbums() : <String>[];
    final config = installed ? await readConfig() : null;
    return ScreensaverStatus(installed, comp.contains(ssPkg), comp, timeoutMs == null ? null : (timeoutMs / 60000).round(), files,
        albums: albums, config: config);
  }

  String _albumDir(String dir, String album) {
    if (album.isEmpty) return dir;
    if (!albumNameRe.hasMatch(album)) throw AdbException('Album names can use letters, numbers, spaces, - and _.');
    return '$dir/albums/$album';
  }

  Future<List<String>> listScreensaverFiles({String album = ''}) async {
    final dir = _albumDir(await screensaverDir(), album);
    final out = await sh('ls -1 ${q(dir)} 2>/dev/null');
    return out.split('\n').map((s) => s.trim()).where((s) => mediaExt.hasMatch(s)).toList()..sort();
  }

  Future<List<String>> listAlbums() async {
    final dir = await screensaverDir();
    final out = await sh('ls -1p ${q('$dir/albums')} 2>/dev/null');
    return out
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.endsWith('/'))
        .map((s) => s.substring(0, s.length - 1))
        .where(albumNameRe.hasMatch)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<void> createAlbum(String name) async {
    final dir = _albumDir(await screensaverDir(), name.trim());
    await sh('mkdir -p ${q(dir)}');
  }

  /// Delete an album and every photo in it.
  Future<void> deleteAlbum(String name) async {
    if (name.isEmpty) throw AdbException('The Main album can\'t be deleted.');
    final dir = _albumDir(await screensaverDir(), name);
    await sh('rm -rf ${q(dir)}');
  }

  /// The config.json on the TV, or null if there isn't one yet.
  Future<ScreensaverConfig?> readConfig() async {
    final dir = await screensaverDir();
    final out = await sh('cat ${q('$dir/config.json')} 2>/dev/null');
    try {
      final j = jsonDecode(out);
      return j is Map ? ScreensaverConfig.fromJson(Map<String, dynamic>.from(j)) : null;
    } catch (_) {
      return null;
    }
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
    // Keep the settings already on the TV (e.g. after a reinstall), otherwise use the phone's.
    await pushConfig(await readConfig() ?? cfg);
  }

  Future<void> pushConfig(ScreensaverConfig cfg) async {
    final dir = await screensaverDir();
    final json = const JsonEncoder.withIndent('  ').convert(cfg.toJson());
    await adb.push(Uint8List.fromList(utf8.encode(json)), '$dir/config.json');
  }

  Future<String> uploadMedia(File file, String name,
      {String album = '', void Function(int sent, int total)? onProgress}) async {
    final safe = safeName(name);
    final dir = _albumDir(await screensaverDir(), album);
    if (album.isNotEmpty) await sh('mkdir -p ${q(dir)}');
    await adb.pushFile(file, '$dir/$safe', onProgress: onProgress);
    return safe;
  }

  Future<void> deleteMedia(String name, {String album = ''}) async {
    final dir = _albumDir(await screensaverDir(), album);
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

/// Find Android/Google TVs on the phone's Wi-Fi: anything answering on the TV remote
/// port (6466, no Developer mode needed) or the debugging port (5555).
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
      for (final port in const [6466, 5555]) {
        try {
          final s = await Socket.connect(ip, port, timeout: probeTimeout);
          s.destroy();
          found.add(ip);
          break;
        } catch (_) {}
      }
    }
  }

  await Future.wait(List.generate(64, (_) => worker()));
  found.sort((a, b) => int.parse(a.split('.').last).compareTo(int.parse(b.split('.').last)));
  return found;
}
