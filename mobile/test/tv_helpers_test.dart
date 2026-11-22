import 'package:connect_tv/app_state.dart';
import 'package:connect_tv/sync/album_sync.dart';
import 'package:connect_tv/tv/tv_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('characters map to Android key codes for typing over the remote link', () {
    expect(charKeyCode('a'), 29);
    expect(charKeyCode('Z'), 54);
    expect(charKeyCode('0'), 7);
    expect(charKeyCode('9'), 16);
    expect(charKeyCode(' '), 62);
    expect(charKeyCode('@'), 77);
    expect(charKeyCode('é'), isNull);
  });

  test('links are found in shared text and only web links are accepted', () {
    expect(findLink('Watch this! https://youtu.be/abc123?t=5 so good'), 'https://youtu.be/abc123?t=5');
    expect(findLink('no link here'), isNull);
    expect(webLink.hasMatch('https://www.netflix.com/title/80100172'), isTrue);
    expect(webLink.hasMatch("https://x.com/a'; reboot"), isFalse);
    expect(webLink.hasMatch('javascript:alert(1)'), isFalse);
  });

  test('app bedtime settings survive saving', () {
    final l = AppLimits.fromJson(AppLimits(enabled: true, apps: ['com.netflix.ninja'], fromMin: 1320, toMin: 360).toJson());
    expect(l.enabled, isTrue);
    expect(l.apps, ['com.netflix.ninja']);
    expect((l.fromMin, l.toMin), (1320, 360));
  });

  test('screensaver settings round-trip, keeping keys this version does not know', () {
    final cfg = ScreensaverConfig.fromJson({
      'intervalSec': 5,
      'transition': 'slide',
      'showDate': true,
      'album': 'Family',
      'schedule': [
        {'album': 'Diwali', 'from': '10-25', 'to': '11-05'},
        {'album': 'Night', 'fromMin': 1320, 'toMin': 360},
      ],
      'soundOn': ['albums/Family/clip.mp4'],
      'captions': {'photo.jpg': 'Goa 2025'},
      'weather': {'lat': 17.38, 'lon': 78.49, 'place': 'Hyderabad', 'unit': 'c'},
      'futureKey': {'x': 1},
    });
    final again = ScreensaverConfig.fromJson(cfg.toJson());
    expect(again.intervalSec, 5);
    expect(again.transition, 'slide');
    expect(again.album, 'Family');
    expect(again.schedule.first.hasDates, isTrue);
    expect(again.schedule.last.hasTimes, isTrue);
    expect(again.schedule.last.hasDates, isFalse);
    expect(again.captions['photo.jpg'], 'Goa 2025');
    expect(again.weather?.place, 'Hyderabad');
    expect(again.toJson()['futureKey'], {'x': 1});
    expect(ScreensaverConfig.fromJson({'transition': 'spin'}).transition, 'fade');
  });

  test('album names and media keys', () {
    expect(albumNameRe.hasMatch('Family 2025'), isTrue);
    expect(albumNameRe.hasMatch('../etc'), isFalse);
    expect(albumNameRe.hasMatch(''), isFalse);
    expect(mediaKey('', 'a.jpg'), 'a.jpg');
    expect(mediaKey('Travel', 'a.jpg'), 'albums/Travel/a.jpg');
  });

  test('sync links survive saving', () {
    final l = SyncLink('id-1', 'Camera', 'Family', files: {'a1': 'CTV_S_abc.jpg'}, lastSync: DateTime(2026, 11, 21, 10));
    final again = SyncLink.fromJson(l.toJson());
    expect((again.phoneAlbumId, again.phoneAlbumName, again.tvAlbum), ('id-1', 'Camera', 'Family'));
    expect(again.files, {'a1': 'CTV_S_abc.jpg'});
    expect(again.lastSync, DateTime(2026, 11, 21, 10));
  });

  test('saved TV keeps favourites, and On this day dates', () {
    final tv = SavedTv('192.0.2.1', favourites: ['com.netflix.ninja', 'com.google.android.youtube.tv'])
      ..config.onThisDay = true
      ..config.dates['a.jpg'] = '2023-11-22';
    final again = SavedTv.fromJson(tv.toJson());
    expect(again.favourites, ['com.netflix.ninja', 'com.google.android.youtube.tv']);
    expect(again.config.onThisDay, isTrue);
    expect(again.config.dates['a.jpg'], '2023-11-22');
    expect(SavedTv.fromJson(SavedTv('192.0.2.1').toJson()).favourites, isNull); // null = default list
  });
}
