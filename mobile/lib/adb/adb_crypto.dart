// RSA key handling for the ADB authentication handshake.
//
// The TV sends a 20-byte random token. We sign it with our private key (the same way
// `adb` does: PKCS#1 v1.5 with the SHA-1 DigestInfo, treating the token itself as the digest).
// The first time, the TV doesn't know our key, so we send our public key in Android's
// "mincrypt" format; the TV then shows "Allow USB debugging?".
//
// Pure Dart (no Flutter imports) so it can be tested from the command line.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class AdbKey {
  final BigInt n; // modulus
  final BigInt e; // public exponent
  final BigInt d; // private exponent
  final BigInt p, q;

  AdbKey(this.n, this.e, this.d, this.p, this.q);

  static const int bits = 2048;
  static const int _words = bits ~/ 32;

  /// Generate a new 2048-bit RSA key. Takes a few seconds; run it in an isolate.
  static AdbKey generate() {
    final rnd = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    final secure = FortunaRandom()..seed(KeyParameter(seed));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64), secure));
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;
    return AdbKey(pub.modulus!, pub.publicExponent!, priv.privateExponent!, priv.p!, priv.q!);
  }

  // ---------- storage ----------

  String serialize() => jsonEncode({
        'n': n.toRadixString(16),
        'e': e.toRadixString(16),
        'd': d.toRadixString(16),
        'p': p.toRadixString(16),
        'q': q.toRadixString(16),
      });

  static AdbKey deserialize(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    BigInt h(String k) => BigInt.parse(m[k] as String, radix: 16);
    return AdbKey(h('n'), h('e'), h('d'), h('p'), h('q'));
  }

  // ---------- signing ----------

  static final Uint8List _sha1DigestInfo =
      Uint8List.fromList([0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14]);

  static final Uint8List _sha256DigestInfo = Uint8List.fromList([
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20
  ]);

  /// Sign the TV's auth token exactly like OpenSSL's RSA_sign(NID_sha1, token).
  Uint8List signToken(Uint8List token) => _pkcs1Sign(Uint8List.fromList([..._sha1DigestInfo, ...token]));

  /// SHA256withRSA (PKCS#1 v1.5) signature of [data], used for the remote-control certificate.
  Uint8List signSha256(Uint8List data) =>
      _pkcs1Sign(Uint8List.fromList([..._sha256DigestInfo, ...SHA256Digest().process(data)]));

  Uint8List _pkcs1Sign(Uint8List t) {
    const k = bits ~/ 8;
    final em = Uint8List(k);
    em[0] = 0x00;
    em[1] = 0x01;
    final psEnd = k - t.length - 1;
    for (var i = 2; i < psEnd; i++) {
      em[i] = 0xff;
    }
    em[psEnd] = 0x00;
    em.setRange(psEnd + 1, k, t);
    final m = _toBigInt(em);
    final s = _crt(m);
    return _toBytes(s, k);
  }

  // Chinese Remainder Theorem: much faster than m.modPow(d, n).
  BigInt _crt(BigInt m) {
    final dp = d % (p - BigInt.one);
    final dq = d % (q - BigInt.one);
    final qInv = q.modInverse(p);
    final m1 = m.modPow(dp, p);
    final m2 = m.modPow(dq, q);
    final h = (qInv * (m1 - m2)) % p;
    return m2 + h * q;
  }

  // ---------- public key in Android's format ----------

  /// `"base64(RSAPublicKey struct) name\0"`, as sent in AUTH(RSAPUBLICKEY).
  Uint8List androidPublicKey(String name) {
    final b = ByteData(4 + 4 + _words * 4 * 2 + 4);
    var o = 0;
    final mask32 = BigInt.from(0xffffffff);
    final two32 = BigInt.one << 32;

    b.setUint32(o, _words, Endian.little);
    o += 4;
    // n0inv = -1 / n[0] mod 2^32
    final n0 = n & mask32;
    final n0inv = (two32 - n0.modInverse(two32)) & mask32;
    b.setUint32(o, n0inv.toInt(), Endian.little);
    o += 4;
    // modulus as little-endian 32-bit words
    var t = n;
    for (var i = 0; i < _words; i++) {
      b.setUint32(o, (t & mask32).toInt(), Endian.little);
      t >>= 32;
      o += 4;
    }
    // rr = (2^2048)^2 mod n
    var rr = (BigInt.one << (bits * 2)) % n;
    for (var i = 0; i < _words; i++) {
      b.setUint32(o, (rr & mask32).toInt(), Endian.little);
      rr >>= 32;
      o += 4;
    }
    b.setInt32(o, e.toInt(), Endian.little);

    final text = '${base64.encode(b.buffer.asUint8List())} $name';
    return Uint8List.fromList([...utf8.encode(text), 0]);
  }

  // ---------- helpers ----------

  /// Private-key parts needed for a PKCS#1 key file.
  BigInt get dp => d % (p - BigInt.one);
  BigInt get dq => d % (q - BigInt.one);
  BigInt get qInv => q.modInverse(p);

  static BigInt _toBigInt(Uint8List bytes) {
    var r = BigInt.zero;
    for (final x in bytes) {
      r = (r << 8) | BigInt.from(x);
    }
    return r;
  }

  static Uint8List _toBytes(BigInt v, int len) {
    final out = Uint8List(len);
    var t = v;
    final mask = BigInt.from(0xff);
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (t & mask).toInt();
      t >>= 8;
    }
    return out;
  }
}
