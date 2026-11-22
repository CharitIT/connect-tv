// The phone's identity for the Android TV Remote protocol: a self-signed X.509 certificate
// plus its RSA private key, both as PEM. The TV remembers this certificate after pairing.
//
// Contains a tiny DER (ASN.1) encoder/parser: just enough to build a certificate and read
// the RSA public key out of the TV's certificate. Pure Dart, no Flutter imports.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../adb/adb_crypto.dart';

// ---------- DER encoding ----------

Uint8List _tlv(int tag, List<int> body) {
  final len = body.length;
  final List<int> lenBytes;
  if (len < 0x80) {
    lenBytes = [len];
  } else {
    final b = <int>[];
    for (var l = len; l > 0; l >>= 8) {
      b.insert(0, l & 0xff);
    }
    lenBytes = [0x80 | b.length, ...b];
  }
  return Uint8List.fromList([tag, ...lenBytes, ...body]);
}

Uint8List _seq(List<List<int>> items) => _tlv(0x30, [for (final i in items) ...i]);
Uint8List _set(List<List<int>> items) => _tlv(0x31, [for (final i in items) ...i]);
Uint8List _null() => Uint8List.fromList([0x05, 0x00]);
Uint8List _utf8(String s) => _tlv(0x0c, utf8.encode(s));
Uint8List _bitString(List<int> bytes) => _tlv(0x03, [0, ...bytes]);
Uint8List _utcTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final u = t.toUtc();
  return _tlv(0x17, ascii.encode('${two(u.year % 100)}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z'));
}

Uint8List _integer(BigInt v) {
  var b = unsignedBytes(v);
  if (b.isEmpty) b = Uint8List.fromList([0]);
  if (b[0] & 0x80 != 0) b = Uint8List.fromList([0, ...b]);
  return _tlv(0x02, b);
}

Uint8List _oid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final out = <int>[parts[0] * 40 + parts[1]];
  for (final p in parts.skip(2)) {
    final chunk = <int>[p & 0x7f];
    for (var v = p >> 7; v > 0; v >>= 7) {
      chunk.insert(0, 0x80 | (v & 0x7f));
    }
    out.addAll(chunk);
  }
  return _tlv(0x06, out);
}

/// Big-endian bytes of a non-negative integer, without leading zeros.
Uint8List unsignedBytes(BigInt v) {
  final out = <int>[];
  for (var t = v; t > BigInt.zero; t >>= 8) {
    out.insert(0, (t & BigInt.from(0xff)).toInt());
  }
  return Uint8List.fromList(out);
}

BigInt _bytesToBig(List<int> b) => b.fold(BigInt.zero, (r, x) => (r << 8) | BigInt.from(x));

String _pem(String label, Uint8List der) {
  final b64 = base64.encode(der);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

// ---------- DER parsing ----------

class _Node {
  final int tag;
  final Uint8List value;
  _Node(this.tag, this.value);

  List<_Node> get children {
    final out = <_Node>[];
    var i = 0;
    while (i < value.length) {
      final (node, used) = _parse(value, i);
      out.add(node);
      i += used;
    }
    return out;
  }
}

(_Node, int) _parse(Uint8List b, int o) {
  final tag = b[o];
  var len = b[o + 1];
  var hdr = 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[o + 2 + i];
    }
    hdr += n;
  }
  if (o + hdr + len > b.length) throw const FormatException('Bad certificate');
  return (_Node(tag, Uint8List.sublistView(b, o + hdr, o + hdr + len)), hdr + len);
}

/// Read the RSA public key (modulus, exponent) from a DER X.509 certificate.
({BigInt n, BigInt e}) rsaPublicKeyOfCert(Uint8List der) {
  final cert = _parse(der, 0).$1;
  final tbs = cert.children[0].children;
  final hasVersion = tbs[0].tag == 0xa0;
  final spki = tbs[hasVersion ? 6 : 5].children;
  final bits = spki[1].value; // BIT STRING: first byte = unused bits
  final key = _parse(Uint8List.sublistView(bits, 1), 0).$1.children;
  return (n: _bytesToBig(key[0].value), e: _bytesToBig(key[1].value));
}

// ---------- the phone's identity ----------

class AtvIdentity {
  final String certPem, keyPem;
  final BigInt n, e;
  AtvIdentity(this.certPem, this.keyPem, this.n, this.e);

  /// Make a self-signed certificate for [key]. Done once; the result is stored.
  static AtvIdentity create(AdbKey key, {String commonName = 'connect-tv'}) {
    const sha256WithRsa = '1.2.840.113549.1.1.11';
    const rsaEncryption = '1.2.840.113549.1.1.1';
    final rnd = Random.secure();
    final serial = _bytesToBig([rnd.nextInt(0x7f) + 1, for (var i = 0; i < 7; i++) rnd.nextInt(256)]);
    final name = _seq([_set([_seq([_oid('2.5.4.3'), _utf8(commonName)])])]);
    final now = DateTime.now().toUtc();
    final pubKey = _seq([_integer(key.n), _integer(key.e)]);
    final tbs = _seq([
      _integer(serial),
      _seq([_oid(sha256WithRsa), _null()]),
      name,
      _seq([_utcTime(now.subtract(const Duration(days: 1))), _utcTime(DateTime.utc(2049, 12, 31))]),
      name,
      _seq([_seq([_oid(rsaEncryption), _null()]), _bitString(pubKey)]),
    ]);
    final cert = _seq([tbs, _seq([_oid(sha256WithRsa), _null()]), _bitString(key.signSha256(tbs))]);
    final priv = _seq([
      for (final v in [BigInt.zero, key.n, key.e, key.d, key.p, key.q, key.dp, key.dq, key.qInv]) _integer(v),
    ]);
    return AtvIdentity(_pem('CERTIFICATE', cert), _pem('RSA PRIVATE KEY', priv), key.n, key.e);
  }

  String serialize() => jsonEncode({'cert': certPem, 'key': keyPem, 'n': n.toRadixString(16), 'e': e.toRadixString(16)});

  static AtvIdentity deserialize(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return AtvIdentity(m['cert'], m['key'], BigInt.parse(m['n'], radix: 16), BigInt.parse(m['e'], radix: 16));
  }
}
