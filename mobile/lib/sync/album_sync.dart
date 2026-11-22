// Keep a TV album in step with an album on the phone (which can include Google Photos or
// iCloud photos synced to the phone). New photos are sent to the TV; photos removed from the
// phone album are removed from the TV album. Runs when asked, and quietly after connecting.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';
import 'package:pointycastle/export.dart' show SHA1Digest;

import '../adb/adb_client.dart' show AdbException;
import '../tv/tv_service.dart';

/// One link: phone album → TV album, with what has been sent so far.
class SyncLink {
  final String phoneAlbumId;
  String phoneAlbumName;
  String tvAlbum;
  Map<String, String> files; // phone asset id → file name on the TV
  DateTime? lastSync;

  SyncLink(this.phoneAlbumId, this.phoneAlbumName, this.tvAlbum, {Map<String, String>? files, this.lastSync})
      : files = files ?? {};

  Map<String, dynamic> toJson() => {
        'phoneAlbumId': phoneAlbumId,
        'phoneAlbumName': phoneAlbumName,
        'tvAlbum': tvAlbum,
        'files': files,
        'lastSync': lastSync?.toIso8601String(),
      };

  static SyncLink fromJson(Map<String, dynamic> j) => SyncLink(
        j['phoneAlbumId'] as String,
        j['phoneAlbumName'] as String? ?? '',
        j['tvAlbum'] as String? ?? '',
        files: Map<String, String>.from(j['files'] as Map? ?? const {}),
        lastSync: DateTime.tryParse(j['lastSync'] as String? ?? ''),
      );
}

class SyncResult {
  int added = 0, removed = 0, skipped = 0, left = 0;
  String? firstProblem; // why the first skipped item was skipped
  final Map<String, String> dates = {}; // media key → "YYYY-MM-DD" taken date, for "On this day"
  final List<String> removedKeys = [];
  @override
  String toString() {
    final parts = [
      if (added > 0) '$added added',
      if (removed > 0) '$removed removed',
      if (skipped > 0) '$skipped skipped',
    ];
    final s = parts.isEmpty ? 'Already up to date' : parts.join(', ');
    final why = skipped > 0 && firstProblem != null ? ' (first problem: $firstProblem)' : '';
    return (left > 0 ? '$s. $left more next time.' : s) + why;
  }
}

class AlbumSync {
  /// Most new items sent in one go, so a huge album doesn't block the app for an hour.
  static const maxPerRun = 150;

  /// Videos bigger than this are skipped (the TV has limited space).
  static const maxVideoBytes = 500 * 1024 * 1024;

  static const _perm = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: false),
  );

  /// Ask for access to the phone's photos. True if allowed (fully or for selected photos).
  static Future<bool> requestPermission() async => (await PhotoManager.requestPermissionExtend(requestOption: _perm)).hasAccess;

  /// True if access was already given (never shows a prompt).
  static Future<bool> hasPermission() async =>
      (await PhotoManager.getPermissionState(requestOption: _perm)).hasAccess;

  /// True if the phone gave access to only some photos ("Allow limited access" / "Selected photos").
  /// Then new photos are invisible to the app, so syncing can't work.
  static Future<bool> isLimited() async =>
      (await PhotoManager.getPermissionState(requestOption: _perm)) == PermissionState.limited;

  /// Open this app's page in the phone's Settings (to allow all photos).
  static Future<void> openSettings() => PhotoManager.openSetting();

  /// Albums on the phone, with how many photos and videos each has.
  static Future<List<(AssetPathEntity, int)>> phoneAlbums() async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common);
    final out = <(AssetPathEntity, int)>[];
    for (final p in paths) {
      final n = await p.assetCountAsync;
      if (n > 0) out.add((p, n));
    }
    return out;
  }

  /// Bring the TV album up to date with the phone album.
  static Future<SyncResult> run(TvService tv, SyncLink link, Directory mediaDir,
      {void Function(String status, double? progress)? onProgress}) async {
    final r = SyncResult();
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common);
    AssetPathEntity? path;
    for (final p in paths) {
      if (p.id == link.phoneAlbumId) path = p;
    }
    if (path == null) throw AdbException('The phone album "${link.phoneAlbumName}" isn\'t on this phone any more.');
    link.phoneAlbumName = path.name;

    final count = await path.assetCountAsync;
    final assets = count == 0 ? <AssetEntity>[] : await path.getAssetListRange(start: 0, end: count);
    final ids = {for (final a in assets) a.id};

    // Removed from the phone album → remove from the TV album.
    for (final e in link.files.entries.toList()) {
      if (ids.contains(e.key)) continue;
      try {
        await tv.deleteMedia(e.value, album: link.tvAlbum);
      } catch (_) {}
      final local = File('${mediaDir.path}/${e.value}');
      if (local.existsSync()) local.deleteSync();
      r.removedKeys.add(mediaKey(link.tvAlbum, e.value));
      link.files.remove(e.key);
      r.removed++;
    }

    // New on the phone → send to the TV.
    final fresh = assets.where((a) => !link.files.containsKey(a.id) && a.type != AssetType.audio).toList();
    r.left = fresh.length > maxPerRun ? fresh.length - maxPerRun : 0;
    final todo = fresh.take(maxPerRun).toList();
    if (link.tvAlbum.isNotEmpty) await tv.createAlbum(link.tvAlbum);
    for (var i = 0; i < todo.length; i++) {
      final a = todo[i];
      onProgress?.call('Sending ${i + 1} of ${todo.length} from "${path.name}"…', i / todo.length);
      try {
        final file = await _export(a, mediaDir);
        if (file == null) {
          r.skipped++;
          r.firstProblem ??= 'the phone couldn\'t give the file (an iCloud/Google Photos item not downloaded, or an unsupported type)';
          continue;
        }
        final name = file.uri.pathSegments.last;
        await tv.uploadMedia(file, name, album: link.tvAlbum, onProgress: (sent, total) {
          onProgress?.call('Sending ${i + 1} of ${todo.length} from "${path!.name}"…',
              (i + sent / (total == 0 ? 1 : total)) / todo.length);
        });
        if (a.type == AssetType.video) file.deleteSync(); // only photos are kept for thumbnails
        link.files[a.id] = name;
        final t = a.createDateTime;
        if (t.year > 1970) {
          r.dates[mediaKey(link.tvAlbum, name)] =
              '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
        }
        r.added++;
      } on AdbException {
        rethrow; // the TV went away: stop
      } catch (e) {
        r.skipped++;
        r.firstProblem ??= e.toString();
      }
    }
    link.lastSync = DateTime.now();
    onProgress?.call(r.toString(), null);
    return r;
  }

  /// A file ready for the TV: photos as JPEG/PNG/WEBP (HEIC converted, at most 4K),
  /// videos as they are. Null if it can't be used.
  static Future<File?> _export(AssetEntity a, Directory mediaDir) async {
    final base = 'CTV_S_${_shortHash(a.id)}';
    if (a.type == AssetType.video) {
      final f = await a.loadFile(isOrigin: true);
      if (f == null || await f.length() > maxVideoBytes) return null;
      final ext = f.path.split('.').last.toLowerCase();
      if (!videoExt.hasMatch('x.$ext')) return null;
      return f.copy('${mediaDir.path}/$base.$ext');
    }
    if (a.type != AssetType.image) return null;

    final orig = await a.originFile;
    final ext = (orig?.path.split('.').last ?? '').toLowerCase();
    if (orig != null && const ['jpg', 'jpeg', 'png', 'webp'].contains(ext) && await orig.length() <= 12 * 1024 * 1024) {
      return orig.copy('${mediaDir.path}/$base.${ext == 'jpeg' ? 'jpg' : ext}');
    }
    // HEIC, very large, or unknown: let the phone convert it to a 4K JPEG, keeping the whole photo.
    const size = ThumbnailSize(3840, 2160);
    final Uint8List? jpg = await a.thumbnailDataWithOption(Platform.isIOS
        ? ThumbnailOption.ios(
            size: size,
            quality: 90,
            deliveryMode: DeliveryMode.highQualityFormat,
            resizeMode: ResizeMode.exact,
            resizeContentMode: ResizeContentMode.fit,
          )
        : const ThumbnailOption(size: size, quality: 90));
    if (jpg == null || jpg.isEmpty) return null;
    final out = File('${mediaDir.path}/$base.jpg');
    await out.writeAsBytes(jpg);
    return out;
  }

  static String _shortHash(String s) {
    final d = SHA1Digest().process(Uint8List.fromList(utf8.encode(s)));
    return d.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
