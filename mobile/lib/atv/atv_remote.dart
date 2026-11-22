// Android TV Remote protocol (v2): the protocol Google's own TV remote app uses.
// It works without Developer mode. Two TLS connections, both using the phone's own
// client certificate (see atv_cert.dart):
//   • port 6467: pairing. The TV shows a 6-character code; the phone proves it saw it.
//   • port 6466: remote control: keys, opening apps, and which app is on screen.
// Messages are protobuf, each prefixed with its length as a varint. We encode the few
// messages we need by hand, so no protobuf package is required.
//
// Pure Dart (dart:io only) so it can be tested from the command line.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA256Digest;

import '../adb/adb_client.dart' show AdbException;
import 'atv_cert.dart';

const atvRemotePort = 6466;
const atvPairingPort = 6467;

/// Thrown when the TV doesn't know this phone yet, so it must be paired with a code first.
class AtvNotPaired extends AdbException {
  AtvNotPaired() : super('This phone isn\'t paired with the TV yet. Pair it with the code shown on the TV.');
}

// ---------- tiny protobuf ----------

class _Pb {
  final _b = BytesBuilder();
  void _varint(int v) {
    while (v >= 0x80) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  void int32(int field, int v) {
    _varint(field << 3);
    _varint(v);
  }

  void bytes(int field, List<int> v) {
    _varint((field << 3) | 2);
    _varint(v.length);
    _b.add(v);
  }

  void str(int field, String v) => bytes(field, utf8.encode(v));
  void msg(int field, _Pb m) => bytes(field, m.toBytes());
  Uint8List toBytes() => _b.toBytes();

  /// Wrap with a varint length prefix, ready to send.
  Uint8List framed() {
    final body = toBytes();
    return Uint8List.fromList([...(_Pb().._varint(body.length)).toBytes(), ...body]);
  }
}

/// Decoded protobuf message: field number → values (int for varints, Uint8List for bytes/messages).
class _Fields {
  final Map<int, List<Object>> f = {};
  _Fields(Uint8List b) {
    var i = 0;
    int varint() {
      var r = 0, s = 0;
      while (true) {
        final x = b[i++];
        r |= (x & 0x7f) << s;
        if (x < 0x80) return r;
        s += 7;
      }
    }

    while (i < b.length) {
      final key = varint();
      final field = key >> 3;
      switch (key & 7) {
        case 0:
          (f[field] ??= []).add(varint());
        case 2:
          final len = varint();
          (f[field] ??= []).add(Uint8List.sublistView(b, i, i + len));
          i += len;
        case 1:
          i += 8;
        case 5:
          i += 4;
        default:
          return; // unknown wire type: stop
      }
    }
  }

  bool has(int field) => f.containsKey(field);
  int int_(int field, [int def = 0]) => (f[field]?.first as int?) ?? def;
  _Fields? sub(int field) => f[field] == null ? null : _Fields(f[field]!.first as Uint8List);
  String? str(int field) => f[field] == null ? null : utf8.decode(f[field]!.first as Uint8List, allowMalformed: true);
}

/// Splits the TLS byte stream into length-prefixed messages.
class _Framer {
  final _buf = BytesBuilder(copy: false);
  final _out = StreamController<_Fields>();
  Stream<_Fields> get messages => _out.stream;

  void add(List<int> data) {
    _buf.add(data);
    var bytes = _buf.takeBytes();
    var o = 0;
    while (true) {
      var len = 0, s = 0, i = o;
      var complete = false;
      while (i < bytes.length) {
        final x = bytes[i++];
        len |= (x & 0x7f) << s;
        s += 7;
        if (x < 0x80) {
          complete = true;
          break;
        }
      }
      if (!complete || i + len > bytes.length) break;
      _out.add(_Fields(Uint8List.sublistView(bytes, i, i + len)));
      o = i + len;
    }
    if (o < bytes.length) _buf.add(Uint8List.sublistView(bytes, o));
  }

  void close() => _out.close();
}

Future<SecureSocket> _tls(String host, int port, AtvIdentity id, Duration timeout) async {
  final ctx = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(id.certPem))
    ..usePrivateKeyBytes(utf8.encode(id.keyPem));
  // The TV uses a self-signed certificate, so there is no authority to check it against.
  return SecureSocket.connect(host, port, context: ctx, onBadCertificate: (_) => true, timeout: timeout);
}

// ---------- pairing (port 6467) ----------

/// Pairing session. [start] makes the TV show a code; [finish] sends the code back.
class AtvPairing {
  final SecureSocket _s;
  final AtvIdentity _id;
  final StreamIterator<_Fields> _in;
  String? tvName;

  AtvPairing._(this._s, this._id, _Framer framer) : _in = StreamIterator(framer.messages);

  static Future<AtvPairing> start(String host, AtvIdentity id, {String clientName = 'Connect TV'}) async {
    final SecureSocket s;
    try {
      s = await _tls(host, atvPairingPort, id, const Duration(seconds: 6));
    } on SocketException {
      throw AdbException('Could not reach the TV at $host. Make sure it is switched on and on the same Wi-Fi as this phone.');
    } on HandshakeException {
      throw AdbException('The TV refused the secure connection. Restart the TV and try again.');
    }
    final framer = _Framer();
    s.listen(framer.add, onDone: framer.close, onError: (_) => framer.close(), cancelOnError: true);
    final p = AtvPairing._(s, id, framer);
    try {
      // 1. Pairing request → ack (contains the TV's name).
      final ack = await p._send(10, _Pb()..str(1, 'atvremote')..str(2, clientName));
      p.tvName = ack.sub(11)?.str(1);
      // 2. Options: we type a 6-character hexadecimal code.
      final enc = _Pb()..int32(1, 3)..int32(2, 6);
      await p._send(20, _Pb()..msg(1, enc)..int32(3, 1));
      // 3. Configuration → ack. The TV now shows the code.
      await p._send(30, _Pb()..msg(1, enc)..int32(2, 1));
    } catch (e) {
      p.close();
      rethrow;
    }
    return p;
  }

  /// Send an outer pairing message with [payload] in [field]; return the TV's reply.
  Future<_Fields> _send(int field, _Pb payload) async {
    final outer = _Pb()
      ..int32(1, 2) // protocol version
      ..int32(2, 200) // status OK
      ..msg(field, payload);
    _s.add(outer.framed());
    final ok = await _in.moveNext().timeout(const Duration(seconds: 15), onTimeout: () => false);
    if (!ok) throw AdbException('The TV stopped answering during pairing. Try again.');
    final reply = _in.current;
    final status = reply.int_(2, 200);
    if (status == 402) throw AdbException('That code is not right. Check the code on the TV and try again.');
    if (status != 200) throw AdbException('The TV rejected the pairing (error $status). Try again.');
    return reply;
  }

  /// Send the code shown on the TV. Throws if it's wrong.
  Future<void> finish(String code) async {
    code = code.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(code)) {
      throw AdbException('The code has 6 characters: digits 0–9 and letters A–F.');
    }
    final cert = _s.peerCertificate;
    if (cert == null) throw AdbException('The TV did not send its certificate. Try again.');
    final tv = rsaPublicKeyOfCert(cert.der);
    final h = SHA256Digest();
    for (final part in [
      unsignedBytes(_id.n),
      unsignedBytes(_id.e),
      unsignedBytes(tv.n),
      unsignedBytes(tv.e),
      _hex(code.substring(2)),
    ]) {
      h.update(part, 0, part.length);
    }
    final secret = Uint8List(32);
    h.doFinal(secret, 0);
    // The first two characters of the code are a checksum of the rest.
    if (secret[0] != int.parse(code.substring(0, 2), radix: 16)) {
      throw AdbException('That code is not right. Check the code on the TV and try again.');
    }
    await _send(40, _Pb()..bytes(1, secret));
  }

  void close() => _s.destroy();

  static Uint8List _hex(String s) =>
      Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

// ---------- remote control (port 6466) ----------

class AtvRemote {
  final SecureSocket _s;
  final _Framer _framer = _Framer();
  final _ready = Completer<void>();
  final _done = Completer<void>();
  bool _closed = false;

  /// Package of the app on screen, when the TV reports it.
  String? currentApp;

  /// Whether the TV screen is on, when the TV reports it.
  bool? isOn;

  /// Volume as the TV reports it (it sends this whenever the volume changes).
  int? volume, volumeMax;
  bool? muted;

  /// Called when [currentApp], [isOn] or the volume changes.
  void Function()? onChange;

  AtvRemote._(this._s);

  Future<void> get done => _done.future;
  bool get isOpen => !_closed;

  static Future<AtvRemote> connect(String host, AtvIdentity id, {Duration timeout = const Duration(seconds: 6)}) async {
    final SecureSocket s;
    try {
      s = await _tls(host, atvRemotePort, id, timeout);
    } on HandshakeException {
      throw AtvNotPaired();
    } on SocketException catch (e) {
      // A TV that doesn't know our certificate may cut the connection during the handshake.
      if (e.message.contains('HANDSHAKE') || e.osError == null) throw AtvNotPaired();
      throw AdbException('Could not reach the TV at $host. Make sure it is switched on and on the same Wi-Fi as this phone.');
    }
    final r = AtvRemote._(s);
    r._framer.messages.listen(r._onMessage);
    s.listen(r._framer.add, onDone: r._shutdown, onError: (_) => r._shutdown(), cancelOnError: true);
    try {
      await r._ready.future.timeout(timeout);
    } on TimeoutException {
      r.close();
      throw AdbException('The TV didn\'t respond to the remote. Try again.');
    } catch (_) {
      r.close();
      rethrow;
    }
    return r;
  }

  void _send(int field, _Pb payload) {
    if (_closed) throw AdbException('The remote is disconnected. Tap Reconnect.');
    _s.add((_Pb()..msg(field, payload)).framed());
  }

  void _onMessage(_Fields m) {
    if (m.has(1)) {
      // RemoteConfigure: tell the TV which features we use (622 = keys, apps, volume, power, ping).
      final info = _Pb()
        ..str(1, 'Connect TV')
        ..str(2, 'Connect TV')
        ..int32(3, 1)
        ..str(4, '1')
        ..str(5, 'atvremote')
        ..str(6, '1.0.0');
      _send(1, _Pb()..int32(1, 622)..msg(2, info));
    } else if (m.has(2)) {
      // RemoteSetActive
      _send(2, _Pb()..int32(1, 622));
      if (!_ready.isCompleted) _ready.complete();
    } else if (m.has(8)) {
      // Ping: answer with the same value, or the TV drops us.
      _send(9, _Pb()..int32(1, m.sub(8)?.int_(1) ?? 0));
    } else if (m.has(20)) {
      // RemoteImeKeyInject carries the app on screen.
      final pkg = m.sub(20)?.sub(1)?.str(12);
      if (pkg != null && pkg != currentApp) {
        currentApp = pkg;
        onChange?.call();
      }
    } else if (m.has(50)) {
      // RemoteSetVolumeLevel: 6 = max, 7 = level, 8 = muted.
      final v = m.sub(50);
      if (v != null && v.has(6)) {
        volumeMax = v.int_(6);
        volume = v.int_(7);
        muted = v.int_(8) == 1;
        onChange?.call();
      }
    } else if (m.has(40)) {
      final on = m.sub(40)?.int_(1) == 1;
      if (on != isOn) {
        isOn = on;
        onChange?.call();
      }
    } else if (m.has(3) && !_ready.isCompleted) {
      _ready.completeError(AdbException('The TV reported an error on the remote connection. Try again.'));
    }
  }

  /// Press an Android key (KEYCODE_* number). [long] holds it like a long press.
  Future<void> key(int keyCode, {bool long = false}) async {
    if (!long) {
      _send(10, _Pb()..int32(1, keyCode)..int32(2, 3)); // SHORT
      return;
    }
    _send(10, _Pb()..int32(1, keyCode)..int32(2, 1)); // START_LONG
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _send(10, _Pb()..int32(1, keyCode)..int32(2, 2)); // END_LONG
  }

  /// Open a link on the TV. `market://launch?id=<package>` opens an installed app.
  Future<void> openLink(String url) async => _send(90, _Pb()..str(1, url));

  void close() {
    if (_closed) return;
    _s.destroy();
    _shutdown();
  }

  void _shutdown() {
    if (_closed && _done.isCompleted) return;
    _closed = true;
    _framer.close();
    if (!_ready.isCompleted) _ready.completeError(AtvNotPaired());
    if (!_done.isCompleted) _done.complete();
  }
}
