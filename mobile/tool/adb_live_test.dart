// ignore_for_file: avoid_print
// Live test of the Dart ADB client against a real TV, run from a computer:
//
//   dart run tool/adb_live_test.dart 192.168.1.40 [keyfile]
//
// The first run with a new key makes the TV show "Allow USB debugging?". Only harmless
// things are done: read device properties, then copy a tiny file to /data/local/tmp, read it
// back, and delete it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connect_tv/adb/adb_client.dart';
import 'package:connect_tv/adb/adb_crypto.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/adb_live_test.dart <tv-ip> [keyfile]');
    exit(64);
  }
  final host = args[0];
  final keyFile = File(args.length > 1 ? args[1] : '${Directory.systemTemp.path}/connect_tv_test_key.json');

  final AdbKey key;
  if (keyFile.existsSync()) {
    key = AdbKey.deserialize(keyFile.readAsStringSync());
    print('Using saved key ${keyFile.path}');
  } else {
    final sw = Stopwatch()..start();
    key = AdbKey.generate();
    keyFile.writeAsStringSync(key.serialize());
    print('Generated new key in ${sw.elapsedMilliseconds} ms → ${keyFile.path}');
  }

  final sw = Stopwatch()..start();
  final adb = await AdbClient.connect(host, key, keyName: 'connect-tv-test@mac', onAuthPrompt: () {
    print('>>> Look at the TV: tick "Always allow" and choose Allow.');
  });
  print('Connected in ${sw.elapsedMilliseconds} ms. Banner: ${adb.banner.split(';').first}');

  final props = await adb.shell('getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release');
  print('Device: ${props.trim().split('\n').map((s) => s.trim()).join(' / ')}');

  final payload = Uint8List.fromList(utf8.encode('hello from connect-tv ${DateTime.now().toIso8601String()}\n' * 2000));
  const remote = '/data/local/tmp/connecttv_push_test.txt';
  sw.reset();
  await adb.push(payload, remote);
  print('Pushed ${payload.length} bytes in ${sw.elapsedMilliseconds} ms');
  final size = (await adb.shell('wc -c < $remote')).trim();
  print('Size on TV: $size (expected ${payload.length}) ${size == '${payload.length}' ? 'OK' : 'MISMATCH'}');
  await adb.shell('rm -f $remote');

  final dirs = await adb.shell("ls /sdcard/Android/data/com.connecttv.screensaver/files/screensaver/ 2>&1 | head -5");
  print('Screensaver folder:\n$dirs');

  adb.close();
  print('ALL OK');
}
