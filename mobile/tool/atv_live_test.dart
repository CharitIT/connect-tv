// Live test of the Android TV Remote client (no Developer mode needed).
//
//   dart run tool/atv_live_test.dart check <tv-ip> [identity-file]   # connect only, nothing shows on the TV
//   dart run tool/atv_live_test.dart pair  <tv-ip> [identity-file]   # the TV shows a code; type it here
//   dart run tool/atv_live_test.dart key   <tv-ip> <keycode> [identity-file]   # e.g. 24 = volume up
//
// The identity (certificate + key) is kept in the identity file (default: a temp file) so
// pairing is remembered between runs.
import 'dart:io';

import 'package:connect_tv/adb/adb_crypto.dart';
import 'package:connect_tv/atv/atv_cert.dart';
import 'package:connect_tv/atv/atv_remote.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: atv_live_test.dart check|pair|key <tv-ip> [keycode] [identity-file]');
    exit(2);
  }
  final mode = args[0], host = args[1];
  final idPath = (mode == 'key' ? args.elementAtOrNull(3) : args.elementAtOrNull(2)) ??
      '${Directory.systemTemp.path}/connect-tv-atv-identity.json';
  final idFile = File(idPath);
  final AtvIdentity id;
  if (idFile.existsSync()) {
    id = AtvIdentity.deserialize(idFile.readAsStringSync());
  } else {
    stdout.writeln('Creating a new identity…');
    id = AtvIdentity.create(AdbKey.generate());
    idFile.writeAsStringSync(id.serialize());
  }

  if (mode == 'pair') {
    final p = await AtvPairing.start(host, id, clientName: 'Connect TV test');
    stdout.write('TV "${p.tvName}" is showing a code. Type it: ');
    final code = stdin.readLineSync() ?? '';
    await p.finish(code);
    p.close();
    stdout.writeln('Paired.');
  }

  try {
    final r = await AtvRemote.connect(host, id);
    await Future<void>.delayed(const Duration(seconds: 2));
    stdout.writeln('Remote connected. Screen on: ${r.isOn}, app on screen: ${r.currentApp}');
    if (mode == 'key') {
      await r.key(int.parse(args[2]));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      stdout.writeln('Sent key ${args[2]}.');
    }
    r.close();
  } on AtvNotPaired catch (e) {
    stdout.writeln('Not paired (expected before pairing): $e');
  }
}
