// A small ADB client that talks to a TV's adbd over Wi-Fi (TCP port 5555), so the phone
// doesn't need the desktop `adb` tool. Supports: connect + RSA auth, shell commands, and
// pushing files (the "sync" protocol).
//
// Protocol reference: AOSP system/core/adb/protocol.txt and SYNC.TXT.
// Pure Dart (dart:io only) so it can be tested from the command line.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'adb_crypto.dart';

const int _cnxn = 0x4e584e43;
const int _auth = 0x48545541;
const int _open = 0x4e45504f;
const int _okay = 0x59414b4f;
const int _clse = 0x45534c43;
const int _wrte = 0x45545257;
const int _stls = 0x534c5453;

const int _version = 0x01000001;
const int _ourMaxData = 256 * 1024;

const int _authToken = 1;
const int _authSignature = 2;
const int _authRsaPublicKey = 3;

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override
  String toString() => message;
}

/// Shown when the TV is on but its debugging port is closed. This often happens after a
/// restart: the setting still says "on" but the TV stopped listening.
const adbOffMessage = 'Your TV is on, but it isn\'t accepting connections for the screensaver and app list right now. '
    'This usually happens after the TV restarts. On the TV, open Settings → System → Developer options, '
    'turn USB debugging off and then on again, then tap Reconnect.';

/// Ports an Android/Google TV answers on even without Developer mode:
/// the Android TV Remote service (6466, 6467) and Google Cast (8008, 8009).
const tvServicePorts = [6466, 6467, 8009, 8008];

/// True if something at [host] answers on a TV service port, i.e. the TV is on and reachable.
Future<bool> tvLooksOn(String host, {Duration timeout = const Duration(milliseconds: 1500)}) async {
  final probes = [
    for (final port in tvServicePorts)
      Socket.connect(host, port, timeout: timeout).then((s) {
        s.destroy();
        return true;
      }, onError: (_) => false),
  ];
  return (await Future.wait(probes)).any((ok) => ok);
}

class _Message {
  final int command, arg0, arg1;
  final Uint8List data;
  _Message(this.command, this.arg0, this.arg1, this.data);
}

class AdbClient {
  final Socket _socket;
  final AdbKey _key;
  final String _keyName;
  final void Function()? _onAuthPrompt;

  final BytesBuilder _in = BytesBuilder(copy: false);
  final Map<int, AdbStream> _streams = {};
  int _nextId = 1;
  int _maxData = 4096;
  bool _closed = false;
  String banner = '';

  final Completer<void> _connected = Completer<void>();
  final Completer<void> _done = Completer<void>();
  bool _sentSignature = false, _sentPublicKey = false;

  AdbClient._(this._socket, this._key, this._keyName, this._onAuthPrompt);

  /// Completes when the connection is closed for any reason.
  Future<void> get done => _done.future;
  bool get isOpen => !_closed;

  /// Connect and authenticate.
  ///
  /// The first time, the TV shows "Allow USB debugging?" and [onAuthPrompt] is called;
  /// we then wait up to [authTimeout] for the user to press Allow.
  static Future<AdbClient> connect(
    String host,
    AdbKey key, {
    int port = 5555,
    String keyName = 'connect-tv@phone',
    void Function()? onAuthPrompt,
    Duration connectTimeout = const Duration(seconds: 6),
    Duration authTimeout = const Duration(seconds: 90),
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on SocketException catch (e) {
      if (await tvLooksOn(host)) throw AdbException(adbOffMessage);
      throw AdbException('Could not reach the TV at $host. '
          'Make sure it is on, on the same Wi-Fi as this phone, and USB debugging is turned on. (${e.osError?.message ?? e.message})');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final c = AdbClient._(socket, key, keyName, onAuthPrompt);
    socket.listen(c._onData, onError: (_) => c._shutdown(), onDone: c._shutdown, cancelOnError: true);
    c._send(_cnxn, _version, _ourMaxData, Uint8List.fromList([...utf8.encode('host::'), 0]));
    try {
      await c._connected.future.timeout(authTimeout);
    } on TimeoutException {
      c.close();
      throw AdbException(c._sentPublicKey
          ? 'The TV did not allow the connection. On the TV, tick "Always allow" and choose Allow, then try again.'
          : 'The TV did not answer. Try turning USB debugging off and on again.');
    } catch (e) {
      c.close();
      rethrow;
    }
    return c;
  }

  void close() {
    if (_closed) return;
    _socket.destroy();
    _shutdown();
  }

  // ---------- high level ----------

  /// Run a shell command and return its output (stdout + stderr).
  Future<String> shell(String command, {Duration timeout = const Duration(seconds: 20)}) async {
    final s = await open('shell:$command');
    final out = BytesBuilder(copy: false);
    final sub = s.data.listen(out.add);
    try {
      await s.closed.timeout(timeout);
    } on TimeoutException {
      s.close();
      throw AdbException('The TV took too long to respond.');
    } finally {
      await sub.cancel();
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }

  /// Run a command and return its raw output bytes (no text conversion), e.g. a screenshot.
  Future<Uint8List> execBytes(String command, {Duration timeout = const Duration(seconds: 30)}) async {
    final s = await open('exec:$command');
    final out = BytesBuilder(copy: false);
    final sub = s.data.listen(out.add);
    try {
      await s.closed.timeout(timeout);
    } on TimeoutException {
      s.close();
      throw AdbException('The TV took too long to respond.');
    } finally {
      await sub.cancel();
    }
    return out.takeBytes();
  }

  /// Copy bytes to a file on the TV.
  Future<void> push(Uint8List bytes, String remotePath,
      {int mode = 420 /* 0644 */, void Function(int sent, int total)? onProgress}) {
    return pushStream(Stream.value(bytes), bytes.length, remotePath, mode: mode, onProgress: onProgress);
  }

  /// Copy a local file to the TV.
  Future<void> pushFile(File file, String remotePath, {void Function(int sent, int total)? onProgress}) async {
    final len = await file.length();
    return pushStream(file.openRead(), len, remotePath, onProgress: onProgress);
  }

  Future<void> pushStream(Stream<List<int>> source, int total, String remotePath,
      {int mode = 420, void Function(int sent, int total)? onProgress}) async {
    final s = await open('sync:');
    try {
      final pending = BytesBuilder(copy: false);
      Future<void> flush({bool force = false}) async {
        while (pending.length >= _maxData || (force && pending.isNotEmpty)) {
          final all = pending.takeBytes();
          final n = all.length < _maxData ? all.length : _maxData;
          await s.write(Uint8List.sublistView(all, 0, n));
          if (n < all.length) pending.add(Uint8List.sublistView(all, n));
        }
      }

      final pathMode = utf8.encode('$remotePath,${mode | 0x8000}');
      pending.add(_syncHeader('SEND', pathMode.length));
      pending.add(pathMode);

      var sent = 0;
      await for (final chunk in source) {
        var off = 0;
        while (off < chunk.length) {
          final n = (chunk.length - off) > 64 * 1024 ? 64 * 1024 : chunk.length - off;
          pending.add(_syncHeader('DATA', n));
          pending.add(chunk is Uint8List ? Uint8List.sublistView(chunk, off, off + n) : chunk.sublist(off, off + n));
          off += n;
          sent += n;
          await flush();
          onProgress?.call(sent, total);
        }
      }
      final mtime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      pending.add(_syncHeader('DONE', mtime));
      await flush(force: true);

      final reply = await s.read(8);
      final id = ascii.decode(reply.sublist(0, 4));
      final len = ByteData.sublistView(reply).getUint32(4, Endian.little);
      if (id == 'FAIL') {
        final msg = utf8.decode(await s.read(len), allowMalformed: true);
        throw AdbException('Could not copy the file to the TV: $msg');
      }
      if (id != 'OKAY') throw AdbException('Unexpected reply from the TV while copying ($id).');
      await s.write(_syncHeader('QUIT', 0));
    } finally {
      s.close();
    }
  }

  static Uint8List _syncHeader(String id, int value) {
    final b = ByteData(8);
    final idBytes = ascii.encode(id);
    for (var i = 0; i < 4; i++) {
      b.setUint8(i, idBytes[i]);
    }
    b.setUint32(4, value, Endian.little);
    return b.buffer.asUint8List();
  }

  /// Open a service stream, e.g. "shell:ls" or "sync:".
  Future<AdbStream> open(String destination) async {
    if (_closed) throw AdbException('Not connected to the TV.');
    final id = _nextId++;
    final s = AdbStream._(this, id);
    _streams[id] = s;
    _send(_open, id, 0, Uint8List.fromList([...utf8.encode(destination), 0]));
    await s._opened.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _streams.remove(id);
      throw AdbException('The TV did not respond.');
    });
    return s;
  }

  // ---------- wire format ----------

  void _send(int command, int arg0, int arg1, [Uint8List? data]) {
    if (_closed) return;
    final payload = data ?? Uint8List(0);
    var sum = 0;
    for (final b in payload) {
      sum += b;
    }
    final h = ByteData(24)
      ..setUint32(0, command, Endian.little)
      ..setUint32(4, arg0, Endian.little)
      ..setUint32(8, arg1, Endian.little)
      ..setUint32(12, payload.length, Endian.little)
      ..setUint32(16, sum & 0xffffffff, Endian.little)
      ..setUint32(20, command ^ 0xffffffff, Endian.little);
    _socket.add(h.buffer.asUint8List());
    if (payload.isNotEmpty) _socket.add(payload);
  }

  void _onData(Uint8List chunk) {
    _in.add(chunk);
    var buf = _in.takeBytes();
    var off = 0;
    while (buf.length - off >= 24) {
      final h = ByteData.sublistView(buf, off, off + 24);
      final len = h.getUint32(12, Endian.little);
      if (buf.length - off < 24 + len) break;
      final msg = _Message(
        h.getUint32(0, Endian.little),
        h.getUint32(4, Endian.little),
        h.getUint32(8, Endian.little),
        Uint8List.fromList(Uint8List.sublistView(buf, off + 24, off + 24 + len)),
      );
      off += 24 + len;
      _handle(msg);
    }
    if (off < buf.length) _in.add(Uint8List.sublistView(buf, off));
  }

  void _handle(_Message m) {
    switch (m.command) {
      case _auth:
        if (m.arg0 != _authToken) return;
        if (!_sentSignature) {
          _sentSignature = true;
          _send(_auth, _authSignature, 0, _key.signToken(m.data));
        } else if (!_sentPublicKey) {
          // The TV doesn't know our key yet: send it, the TV will ask the user.
          _sentPublicKey = true;
          _send(_auth, _authRsaPublicKey, 0, _key.androidPublicKey(_keyName));
          _onAuthPrompt?.call();
        }
        break;
      case _cnxn:
        _maxData = m.arg1 > 0 ? m.arg1 : 4096;
        banner = utf8.decode(m.data, allowMalformed: true);
        if (!_connected.isCompleted) _connected.complete();
        break;
      case _stls:
        if (!_connected.isCompleted) {
          _connected.completeError(AdbException(
              'This TV only accepts encrypted "Wireless debugging", which is not supported yet. Turn on "USB debugging" instead.'));
        }
        break;
      case _okay:
        final s = _streams[m.arg1];
        if (s == null) return;
        s._remoteId = m.arg0;
        if (!s._opened.isCompleted) {
          s._opened.complete();
        } else {
          s._writeAck?.complete();
          s._writeAck = null;
        }
        break;
      case _wrte:
        final s = _streams[m.arg1];
        if (s == null) return;
        _send(_okay, s.localId, m.arg0);
        s._receive(m.data);
        break;
      case _clse:
        final s = _streams.remove(m.arg1);
        if (s == null) return;
        if (!s._opened.isCompleted) {
          s._opened.completeError(AdbException('The TV refused the request.'));
        }
        s._finish();
        break;
    }
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    if (!_connected.isCompleted) {
      _connected.completeError(AdbException(_sentSignature
          ? 'The TV closed the connection. If it showed "Allow USB debugging?", choose Allow and try again.'
          : 'The TV closed the connection. Check that USB debugging is turned on.'));
    }
    for (final s in _streams.values.toList()) {
      if (!s._opened.isCompleted) s._opened.completeError(AdbException('Disconnected from the TV.'));
      s._finish(error: AdbException('Disconnected from the TV.'));
    }
    _streams.clear();
    if (!_done.isCompleted) _done.complete();
  }
}

class AdbStream {
  final AdbClient _client;
  final int localId;
  int _remoteId = 0;
  final Completer<void> _opened = Completer<void>();
  final Completer<void> _closedC = Completer<void>();
  final StreamController<Uint8List> _data = StreamController<Uint8List>();
  Completer<void>? _writeAck;
  bool _finished = false;

  // Buffered reader (used by the sync protocol).
  final List<int> _rbuf = [];
  Completer<void>? _rwait;
  StreamSubscription<Uint8List>? _readerSub;

  AdbStream._(this._client, this.localId);

  Stream<Uint8List> get data => _data.stream;
  Future<void> get closed => _closedC.future;

  Future<void> write(Uint8List bytes) async {
    if (_finished) throw AdbException('Disconnected from the TV.');
    final ack = Completer<void>();
    _writeAck = ack;
    _client._send(_wrte, localId, _remoteId, bytes);
    // _finish() completes `ack` with an error if the stream closes while we wait.
    await ack.future.timeout(const Duration(seconds: 30), onTimeout: () => throw AdbException('The TV stopped responding.'));
  }

  /// Read exactly [n] bytes.
  Future<Uint8List> read(int n) async {
    _readerSub ??= data.listen((d) {
      _rbuf.addAll(d);
      _rwait?.complete();
      _rwait = null;
    });
    while (_rbuf.length < n) {
      if (_finished) throw AdbException('The TV closed the connection.');
      _rwait = Completer<void>();
      await Future.any([_rwait!.future, _closedC.future]).timeout(const Duration(seconds: 60));
    }
    final out = Uint8List.fromList(_rbuf.sublist(0, n));
    _rbuf.removeRange(0, n);
    return out;
  }

  void close() {
    if (_finished) return;
    _client._send(_clse, localId, _remoteId);
    _client._streams.remove(localId);
    _finish();
  }

  void _receive(Uint8List d) {
    if (!_data.isClosed) _data.add(d);
  }

  void _finish({Object? error}) {
    if (_finished) return;
    _finished = true;
    _writeAck?.completeError(error ?? AdbException('The TV closed the connection.'));
    _writeAck = null;
    _rwait?.complete();
    _rwait = null;
    _data.close();
    if (!_closedC.isCompleted) _closedC.complete();
  }
}
