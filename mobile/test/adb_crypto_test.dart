import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:connect_tv/adb/adb_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AdbKey key;

  setUpAll(() => key = AdbKey.generate());

  test('signature is valid PKCS#1 v1.5 over SHA-1 DigestInfo + token', () {
    final rnd = Random(1);
    final token = Uint8List.fromList(List.generate(20, (_) => rnd.nextInt(256)));
    final sig = key.signToken(token);
    expect(sig.length, 256);

    // Undo the signature with the public key and check the padded block.
    var s = BigInt.zero;
    for (final b in sig) {
      s = (s << 8) | BigInt.from(b);
    }
    final m = s.modPow(key.e, key.n);
    final em = Uint8List(256);
    var t = m;
    for (var i = 255; i >= 0; i--) {
      em[i] = (t & BigInt.from(0xff)).toInt();
      t >>= 8;
    }
    expect(em[0], 0x00);
    expect(em[1], 0x01);
    final sep = em.indexOf(0x00, 2);
    expect(em.sublist(2, sep).every((b) => b == 0xff), isTrue);
    expect(sep, 256 - 35 - 1);
    expect(em.sublist(sep + 1, sep + 16),
        [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14]);
    expect(em.sublist(sep + 16), token);
  });

  test('public key matches Android RSAPublicKey layout', () {
    final out = key.androidPublicKey('me@phone');
    expect(out.last, 0);
    final text = utf8.decode(out.sublist(0, out.length - 1));
    final parts = text.split(' ');
    expect(parts[1], 'me@phone');
    final raw = base64.decode(parts[0]);
    expect(raw.length, 524);
    final b = ByteData.sublistView(raw);
    expect(b.getUint32(0, Endian.little), 64);

    BigInt words(int offset) {
      var r = BigInt.zero;
      for (var i = 63; i >= 0; i--) {
        r = (r << 32) | BigInt.from(b.getUint32(offset + i * 4, Endian.little));
      }
      return r;
    }

    final n = words(8);
    expect(n, key.n);
    final n0inv = BigInt.from(b.getUint32(4, Endian.little));
    expect((n0inv * (key.n & BigInt.from(0xffffffff))) % (BigInt.one << 32), (BigInt.one << 32) - BigInt.one);
    expect(words(8 + 256), (BigInt.one << 4096) % key.n);
    expect(b.getInt32(520, Endian.little), 65537);
  });

  test('serialize round-trip', () {
    final k2 = AdbKey.deserialize(key.serialize());
    expect(k2.n, key.n);
    expect(k2.d, key.d);
  });
}
