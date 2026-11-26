import 'dart:convert';
import 'dart:io';

import 'package:connect_tv/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ctv'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('several TVs: the old single TV moves over, add/cancel, forget, reload', () async {
    // Saved by an older version: one TV under "tv".
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      'tv': jsonEncode(SavedTv('127.0.0.1', name: 'Living room').toJson()),
    });
    var s = await AppState.load(docsDir: tmp);
    expect(s.tvs.map((t) => t.displayName), ['Living room']);
    expect(s.tv!.address, '127.0.0.1');

    // Add a TV, then cancel: back to the first one.
    s.addTv();
    expect(s.addingTv, isTrue);
    expect(s.tv, isNull);
    expect(s.onboarded, isFalse);
    s.cancelAddTv();
    expect(s.tv!.address, '127.0.0.1');
    expect(s.onboarded, isTrue);
    s.disconnect();

    // A second TV is saved next to the first and becomes the current one.
    s.addTv();
    s.tv = SavedTv('127.0.0.2', name: 'Bedroom');
    s.finishSetup();
    expect(s.tvs.map((t) => t.displayName), ['Living room', 'Bedroom']);

    // After a restart both are there, and the current TV is remembered.
    s = await AppState.load(docsDir: tmp);
    expect(s.tvs.length, 2);
    expect(s.tv!.displayName, 'Bedroom');

    // Forgetting the current TV switches to the other one; forgetting the last starts the setup.
    s.forgetTv();
    expect(s.tv!.displayName, 'Living room');
    expect(s.onboarded, isTrue);
    s.disconnect();
    s.forgetTv();
    expect(s.tv, isNull);
    expect(s.tvs, isEmpty);
    expect(s.onboarded, isFalse);
  });
}
