// Renders every setup page and the home tabs (without a TV) to catch layout errors.

import 'dart:io';

import 'package:connect_tv/app_state.dart';
import 'package:connect_tv/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ctv'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppState> state(WidgetTester t, Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    return (await t.runAsync(() => AppState.load(docsDir: tmp)))!;
  }

  testWidgets('setup wizard walks through its pages', (t) async {
    t.view.physicalSize = const Size(1170, 2532); // iPhone-sized
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final s = await state(t, {});
    await t.pumpWidget(ConnectTvApp(state: s));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Connect TV'), findsOneWidget);

    await t.tap(find.text('Get started'));
    await t.pumpAndSettle();
    expect(find.text('Which TV do you have?'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await t.tap(find.text('TCL (Google TV)'));
    await t.pumpAndSettle();
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    expect(find.text('Turn on Developer mode'), findsOneWidget);
    expect(find.textContaining('Android TV OS build'), findsWidgets);

    await t.tap(find.text('I\'ve done this'));
    await t.pumpAndSettle();
    expect(find.text('Connect to your TV'), findsOneWidget);
    expect(find.text('Find my TV'), findsOneWidget);
    // Can't continue without a connection.
    final next = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'));
    expect(next.onPressed, isNull);
  });

  testWidgets('home tabs render when the TV is not connected', (t) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final s = await state(t, {
      'onboarded': true,
      'tv': '{"address":"192.0.2.1","name":"Living room TV","profileId":"tcl-google-tv"}',
    });
    await t.pumpWidget(ConnectTvApp(state: s));
    await t.pump();
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);

    await t.tap(find.text('Settings'));
    await t.pump();
    expect(find.text('How to turn on Developer mode'), findsOneWidget);
    expect(find.text('Forget this TV'), findsOneWidget);
    s.disconnect();
    await t.pump();
  });
}
