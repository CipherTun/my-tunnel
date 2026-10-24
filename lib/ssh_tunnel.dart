import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show compute;

typedef LogFn = void Function(String message);

class SshOptions {
  SshOptions({
    required this.host,
    required this.port,
    required this.user,
    this.pass = '',
    this.keyPem = '',
    this.keyPass = '',
    this.payload = '',
    this.proxyHost = '',
    this.proxyPort = 8080,
    this.useTls = false,
    this.sni = '',
    this.ws = false,
    this.legacy = true,
    this.verifyHostKey = false,
    this.hostKey = '',
    this.onHostKey,
    this.verifyTls = false,
    this.pin = '',
    this.keepAlive = 15,
    this.socksPort = 10808,
    this.shareHotspot = false,
    this.lenient = false,
    this.authUser = '',
    this.authPass = '',
  });

  final String host;
  final int port;
  final String user;
  final String pass;
  final String keyPem;
  final String keyPass;
  final String payload;
  final String proxyHost;
  final int proxyPort;
  final bool useTls;
  final String sni;
  final bool ws;
  final bool legacy;
  final bool verifyHostKey;
  final String hostKey;
  final void Function(String)? onHostKey;
  final bool verifyTls;
  final String pin;
  final int keepAlive;
  final int socksPort;
  final bool shareHotspot;

  /// Accept any HTTP status from the payload response (some proxies answer 4xx but still relay).
  final bool lenient;

  /// Credentials for the [auth] payload placeholder (Proxy-Authorization: Basic).
  final String authUser;
  final String authPass;
}

// ---------------------------------------------------------------- byte queue

class _ByteQueue {
  Uint8List _b = Uint8List(4096);
  int _s = 0;
  int _e = 0;

  int get length => _e - _s;
  int operator [](int i) => _b[_s + i];

  void add(List<int> d) {
    if (_e + d.length > _b.length) {
      final len = length;
      if (_s > 0 && len + d.length <= _b.length) {
        _b.setRange(0, len, _b, _s);
      } else {
        final nb = Uint8List(max(_b.length * 2, len + d.length));
        nb.setRange(0, len, _b, _s);
        _b = nb;
      }
      _s = 0;
      _e = len;
    }
    _b.setRange(_e, _e + d.length, d);
    _e += d.length;
  }

  Uint8List peek(int n) => Uint8List.sublistView(_b, _s, _s + n);

  Uint8List take(int n) {
    final r = Uint8List.fromList(Uint8List.sublistView(_b, _s, _s + n));
    skip(n);
    return r;
  }

  void skip(int n) {
    _s += n;
    if (_s >= _e) {
      _s = 0;
      _e = 0;
    }
  }

  int indexOfCrlfCrlf() {
    for (var i = 0; i + 3 < length; i++) {
      if (_b[_s + i] == 13 && _b[_s + i + 1] == 10 && _b[_s + i + 2] == 13 && _b[_s + i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

// ------------------------------------------------------------ tunnel socket

/// A transport for the SSH client. It optionally strips HTTP responses that a
/// payload/proxy produces before the SSH banner, and optionally speaks
/// WebSocket framing (client frames masked, server frames parsed).
class TunnelSocket implements SSHSocket {
  TunnelSocket(this._socket, {required bool expectHeader, required this.ws}) {
    _pass = !expectHeader;
    if (expectHeader) _head = Completer<String>();
    _sub = _socket.listen(
      _onData,
      onError: (Object e, StackTrace s) => _fail(e),
      onDone: _onDone,
      cancelOnError: true,
    );
    if (ws) _framed = _FramedSink(this);
  }

  final Socket _socket;
  final bool ws;
  late final StreamSubscription<Uint8List> _sub;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final _ByteQueue _hq = _ByteQueue();
  final _ByteQueue _wq = _ByteQueue();
  final Random _rng = Random.secure();
  Completer<String>? _head;
  _FramedSink? _framed;
  bool _pass = false;
  bool _closed = false;
  int _skipBody = 0;
  int _headers = 0;

  Future<String> awaitHeader(Duration t) => _head!.future.timeout(t, onTimeout: () {
        throw 'No response to payload within ${t.inSeconds}s';
      });

  void _fail(Object e) {
    if (_head != null && !_head!.isCompleted) _head!.completeError(e);
    if (!_in.isClosed) {
      _in.addError(e);
      _in.close();
    }
  }

  void _onDone() {
    _closed = true;
    if (_head != null && !_head!.isCompleted) {
      _head!.completeError('Connection closed before any response');
    }
    if (!_in.isClosed) _in.close();
  }

  void _onData(Uint8List d) {
    if (_pass) {
      _deliver(d);
      return;
    }
    _hq.add(d);
    _drainHeaders();
  }

  void _drainHeaders() {
    while (true) {
      if (_skipBody > 0) {
        final n = min(_skipBody, _hq.length);
        _hq.skip(n);
        _skipBody -= n;
        if (_skipBody > 0) return;
      }
      if (_hq.length == 0) return;
      final n = min(5, _hq.length);
      final prefix = latin1.decode(_hq.peek(n), allowInvalid: true);
      final maybeHttp = prefix.length < 5 ? 'HTTP/'.startsWith(prefix) : prefix == 'HTTP/';
      if (!maybeHttp) {
        // Not an HTTP response: the SSH banner (or raw data) starts here.
        if (_head != null && !_head!.isCompleted) _head!.complete('(no HTTP response; raw data)');
        _passThrough();
        return;
      }
      if (prefix.length < 5) return; // need more bytes to decide
      final end = _hq.indexOfCrlfCrlf();
      if (end < 0) {
        if (_hq.length > 16384) _fail('Oversized HTTP response header');
        return;
      }
      final header = latin1.decode(_hq.take(end + 4), allowInvalid: true);
      final first = header.split('\r\n').first;
      final code = int.tryParse(first.split(' ').length > 1 ? first.split(' ')[1] : '') ?? 0;
      final ok = code == 101 || (code >= 200 && code < 300);
      if (_headers == 0) {
        if (_head != null && !_head!.isCompleted) _head!.complete(first);
      } else if (!ok) {
        _fail('Proxy rejected request: $first');
        return;
      }
      _headers++;
      final cl = RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(header);
      if (cl != null && code != 101) _skipBody = int.parse(cl.group(1)!);
      if (ws) {
        _passThrough();
        return;
      }
    }
  }

  void _passThrough() {
    _pass = true;
    if (_hq.length > 0) _deliver(_hq.take(_hq.length));
  }

  void _deliver(Uint8List d) {
    if (_in.isClosed) return;
    if (!ws) {
      _in.add(d);
      return;
    }
    _wq.add(d);
    _parseFrames();
  }

  void _parseFrames() {
    while (_wq.length >= 2) {
      final b0 = _wq[0];
      final b1 = _wq[1];
      final op = b0 & 15;
      var len = b1 & 127;
      var off = 2;
      if (len == 126) {
        if (_wq.length < 4) return;
        len = (_wq[2] << 8) | _wq[3];
        off = 4;
      } else if (len == 127) {
        if (_wq.length < 10) return;
        len = 0;
        for (var i = 2; i < 10; i++) {
          len = (len << 8) | _wq[i];
        }
        off = 10;
      }
      if (len > 16 * 1024 * 1024) {
        _fail('WebSocket frame too large');
        return;
      }
      final masked = (b1 & 0x80) != 0;
      final hdr = off + (masked ? 4 : 0);
      if (_wq.length < hdr + len) return;
      final all = _wq.take(hdr + len);
      final payload = Uint8List.sublistView(all, hdr);
      if (masked) {
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= all[off + (i & 3)];
        }
      }
      if (op == 0 || op == 1 || op == 2) {
        if (payload.isNotEmpty && !_in.isClosed) _in.add(payload);
      } else if (op == 8) {
        _socket.destroy();
        return;
      } else if (op == 9) {
        _socket.add(_frame(payload, 10));
      }
    }
  }

  Uint8List _frame(List<int> data, int opcode) {
    final len = data.length;
    final hl = len < 126 ? 2 : (len < 65536 ? 4 : 10);
    final out = Uint8List(hl + 4 + len);
    out[0] = 0x80 | opcode;
    if (len < 126) {
      out[1] = 0x80 | len;
    } else if (len < 65536) {
      out[1] = 0x80 | 126;
      out[2] = len >> 8;
      out[3] = len & 255;
    } else {
      out[1] = 0x80 | 127;
      for (var i = 0; i < 8; i++) {
        out[2 + i] = (len >> (8 * (7 - i))) & 255;
      }
    }
    for (var i = 0; i < 4; i++) {
      out[hl + i] = _rng.nextInt(256);
    }
    for (var i = 0; i < len; i++) {
      out[hl + 4 + i] = data[i] ^ out[hl + (i & 3)];
    }
    return out;
  }

  void rawWrite(List<int> d) => _socket.add(d);
  Future<void> rawFlush() => _socket.flush();

  @override
  Stream<Uint8List> get stream => _in.stream;

  @override
  StreamSink<List<int>> get sink => ws ? _framed! : _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }

  @override
  void destroy() {
    _socket.destroy();
  }

  /// Newer dartssh2 releases ask sockets to flush buffered output.
  /// Declared without @override so it compiles whether or not the interface has it.
  Future<void> flush() => _socket.flush();

  Future<void> cancel() async {
    try {
      await _sub.cancel();
    } catch (_) {}
  }

  bool get isClosed => _closed;
}

class _FramedSink implements StreamSink<List<int>> {
  _FramedSink(this._t);
  final TunnelSocket _t;

  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    _t.rawWrite(_t._frame(data, 2));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final d in stream) {
      add(d);
    }
  }

  @override
  Future<void> close() async {
    try {
      _t.rawWrite(_t._frame(const [], 8));
      await _t.rawFlush();
    } catch (_) {}
    await _t.close();
  }

  @override
  Future<void> get done => _t.done;
}

// --------------------------------------------------------------- transport

class PayloadStep {
  const PayloadStep(this.data, this.delayMs);

  /// Text to send.
  final String data;

  /// Pause after sending it (before the next step).
  final int delayMs;
}

const String kUserAgent =
    'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

int _rotate = 0;

/// Placeholders: [host] [port] [host_port] [crlf] [cr] [lf] [ua] [random]
/// [auth] (a full Proxy-Authorization header line incl. CRLF, empty without
/// credentials) [rotate=a;b;c] [split] [delay=ms].
List<PayloadStep> renderPayload(String raw, String host, int port, {String authUser = '', String authPass = ''}) {
  var s = raw.replaceAllMapped(RegExp(r'\[rotate=([^\]]*)\]'), (m) {
    final opts = m.group(1)!.split(';');
    return opts[_rotate % opts.length];
  });
  _rotate++;
  final rnd = Random.secure();
  s = s.replaceAllMapped(RegExp(r'\[random\]'), (_) => rnd.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'));
  final auth = authUser.isEmpty
      ? ''
      : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('$authUser:$authPass'))}\r\n';
  s = s
      .replaceAll('[auth]', auth)
      .replaceAll('[ua]', kUserAgent)
      .replaceAll('[host_port]', '$host:$port')
      .replaceAll('[host]', host)
      .replaceAll('[port]', '$port')
      .replaceAll('[crlf]', '\r\n')
      .replaceAll('[cr]', '\r')
      .replaceAll('[lf]', '\n')
      .replaceAll('\\r', '\r')
      .replaceAll('\\n', '\n');
  final steps = <PayloadStep>[];
  var last = 0;
  for (final m in RegExp(r'\[split\]|\[delay=(\d+)\]').allMatches(s)) {
    final chunk = s.substring(last, m.start);
    final d = m.group(1) != null ? int.parse(m.group(1)!).clamp(0, 10000).toInt() : 200;
    if (chunk.isNotEmpty) steps.add(PayloadStep(chunk, d));
    last = m.end;
  }
  final tail = s.substring(last);
  if (tail.isNotEmpty) steps.add(PayloadStep(tail, 0));
  return steps;
}

String _normHex(String s) => s.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');

Future<TunnelSocket> openTransport(
  SshOptions o,
  LogFn log, {
  String? targetHost,
  int? targetPort,
}) async {
  final viaProxy = o.proxyHost.isNotEmpty;
  final host = viaProxy ? o.proxyHost : o.host;
  final port = viaProxy ? o.proxyPort : o.port;
  log('TCP connect $host:$port');
  Socket sock = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
  sock.setOption(SocketOption.tcpNoDelay, true);

  if (o.useTls) {
    final sni = o.sni.isNotEmpty ? o.sni : (viaProxy && o.host.isNotEmpty ? o.host : host);
    log('TLS handshake (SNI $sni)');
    final tls = await SecureSocket.secure(
      sock,
      host: sni,
      onBadCertificate: (_) => !o.verifyTls,
    ).timeout(const Duration(seconds: 15));
    if (o.pin.trim().isNotEmpty) {
      final c = tls.peerCertificate;
      if (c == null) {
        tls.destroy();
        throw 'TLS pin set but server sent no certificate';
      }
      final got = crypto.sha256.convert(c.der).toString();
      if (got != _normHex(o.pin)) {
        tls.destroy();
        throw 'TLS certificate pin mismatch (got $got)';
      }
      log('TLS certificate pin OK');
    }
    sock = tls;
  }

  final steps = o.payload.trim().isEmpty
      ? <PayloadStep>[]
      : renderPayload(
          o.payload,
          targetHost ?? o.host,
          targetPort ?? o.port,
          authUser: o.authUser,
          authPass: o.authPass,
        );
  final t = TunnelSocket(sock, expectHeader: steps.isNotEmpty, ws: o.ws);
  if (steps.isNotEmpty) {
    for (var i = 0; i < steps.length; i++) {
      t.rawWrite(latin1.encode(steps[i].data));
      await t.rawFlush();
      if (i < steps.length - 1 && steps[i].delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: steps[i].delayMs));
      }
    }
    final first = await t.awaitHeader(const Duration(seconds: 12));
    final m = RegExp(r'^HTTP/\S+\s+(\d{3})').firstMatch(first);
    if (m != null) {
      final c = int.parse(m.group(1)!);
      final ok = c == 101 || (c >= 200 && c < 300);
      if (!ok && !o.lenient) {
        t.destroy();
        throw 'Payload rejected: $first';
      }
    }
    if (targetHost == null) log('Payload response: $first');
  }
  return t;
}

// --------------------------------------------------------------- SSH tunnel

SSHAlgorithms _algorithms(bool legacy) {
  const d = SSHAlgorithms();
  if (!legacy) return d;
  List<T> merge<T>(List<T> a, List<T> b) => [...a, ...b.where((x) => !a.contains(x))];
  return SSHAlgorithms(
    kex: merge(d.kex, [SSHKexType.dh14Sha1, SSHKexType.dhGexSha1, SSHKexType.dh1Sha1]),
    hostkey: merge(d.hostkey, [SSHHostkeyType.rsaSha1]),
    cipher: merge(d.cipher, [
      SSHCipherType.aes128ctr,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes128cbc,
      SSHCipherType.aes256cbc,
    ]),
    mac: merge(d.mac, [SSHMacType.hmacSha1, SSHMacType.hmacMd5]),
  );
}

List<SSHKeyPair> _parseKeys(List<String> a) => SSHKeyPair.fromPem(a[0], a[1].isEmpty ? null : a[1]);

String _hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

class SshTunnel {
  SSHClient? _client;
  TunnelSocket? _transport;
  LocalSocks? _socks;
  bool _stopping = false;
  void Function(String reason)? onClosed;

  bool get active => _client != null;

  Future<int> start(SshOptions o, LogFn log) async {
    _stopping = false;
    final transport = await openTransport(o, log);
    _transport = transport;

    List<SSHKeyPair>? ids;
    if (o.keyPem.trim().isNotEmpty) {
      log('Decoding private key');
      try {
        ids = await compute(_parseKeys, [o.keyPem, o.keyPass]);
      } catch (_) {
        ids = _parseKeys([o.keyPem, o.keyPass]);
      }
    }

    log('SSH handshake${o.legacy ? ' (legacy algorithms allowed)' : ''}');
    final client = SSHClient(
      transport,
      username: o.user,
      identities: ids,
      onPasswordRequest: o.pass.isEmpty ? null : () => o.pass,
      keepAliveInterval: Duration(seconds: o.keepAlive),
      algorithms: _algorithms(o.legacy),
      onUserauthBanner: (b) => log('Server banner: ${b.trim()}'),
      onVerifyHostKey: o.verifyHostKey
          ? (String type, Uint8List fp) {
              final seen = '$type:${_hex(fp)}';
              if (o.hostKey.isEmpty) {
                log('Host key pinned on first use ($type)');
                o.onHostKey?.call(seen);
                return true;
              }
              if (o.hostKey == seen) return true;
              log('HOST KEY CHANGED - refusing to connect');
              return false;
            }
          : null,
    );
    _client = client;

    try {
      await client.authenticated.timeout(const Duration(seconds: 30));
    } catch (e) {
      await stop();
      throw _friendly(e);
    }
    log('SSH authenticated as ${o.user}');

    client.done.then(
      (_) {
        if (!_stopping) onClosed?.call('SSH connection closed by server');
      },
      onError: (Object e) {
        if (!_stopping) onClosed?.call('SSH error: $e');
      },
    );

    final socks = LocalSocks((h, p) async {
      final ch = await client.forwardLocal(h, p);
      return TunnelChannel(ch.stream, ch.sink, ch.destroy);
    });
    await socks.start(o.socksPort, any: o.shareHotspot);
    _socks = socks;
    log('SOCKS5 listening on ${o.shareHotspot ? '0.0.0.0' : '127.0.0.1'}:${o.socksPort}');
    return o.socksPort;
  }

  String _friendly(Object e) {
    final t = e.toString();
    if (e is SSHAuthFailError || t.contains('SSHAuthFailError')) {
      return 'Authentication failed (check username, password or key)';
    }
    if (t.toLowerCase().contains('host key') || t.contains('SSHHostkeyError')) {
      return 'Server host key rejected. If you trust the server, reset the pinned key in the profile.';
    }
    if (e is TimeoutException) return 'SSH handshake timed out';
    return t;
  }

  /// Plain HTTP/1.0 GET through the tunnel (for the connection test).
  Future<String> httpGet(String host, String path) async {
    final c = _client;
    if (c == null) throw 'SSH tunnel is not active';
    final ch = await c.forwardLocal(host, 80).timeout(const Duration(seconds: 15));
    try {
      ch.sink.add(utf8.encode('GET $path HTTP/1.0\r\nHost: $host\r\nUser-Agent: curl/8\r\n\r\n'));
      final bb = BytesBuilder();
      await ch.stream.timeout(const Duration(seconds: 15)).forEach(bb.add);
      final s = utf8.decode(bb.takeBytes(), allowMalformed: true);
      final i = s.indexOf('\r\n\r\n');
      return i < 0 ? s : s.substring(i + 4);
    } finally {
      ch.destroy();
    }
  }

  Future<void> stop() async {
    _stopping = true;
    final s = _socks;
    final c = _client;
    final t = _transport;
    _socks = null;
    _client = null;
    _transport = null;
    try {
      await s?.stop();
    } catch (_) {}
    try {
      await c?.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    t?.destroy();
    await t?.cancel();
  }
}

// ------------------------------------------------------------- SOCKS5 server

class _Reader {
  _Reader(this._s) {
    _s.listen(_onData, onDone: _onDone, onError: (Object _) => _onDone(), cancelOnError: true);
  }

  final Socket _s;
  final List<int> _buf = <int>[];
  Completer<void>? _wait;
  bool closed = false;
  void Function(Uint8List)? onData;
  void Function()? onClosed;

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _onData(Uint8List d) {
    final cb = onData;
    if (cb != null) {
      cb(d);
      return;
    }
    _buf.addAll(d);
    _wake();
  }

  void _onDone() {
    closed = true;
    _wake();
    onClosed?.call();
  }

  Future<List<int>> read(int n) async {
    while (_buf.length < n) {
      if (closed) throw 'closed';
      _wait = Completer<void>();
      await _wait!.future;
    }
    final r = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return r;
  }

  void pipe(StreamSink<List<int>> sink) {
    if (_buf.isNotEmpty) {
      sink.add(Uint8List.fromList(_buf));
      _buf.clear();
    }
    onData = (d) {
      try {
        sink.add(d);
      } catch (_) {}
    };
  }
}

/// One proxied connection: bytes in, bytes out, and a way to tear it down.
class TunnelChannel {
  TunnelChannel(this.stream, this.sink, this.destroy);
  final Stream<List<int>> stream;
  final StreamSink<List<int>> sink;
  final void Function() destroy;
}

typedef Connector = Future<TunnelChannel> Function(String host, int port);

class LocalSocks {
  LocalSocks(this._connect);
  final Connector _connect;
  ServerSocket? _server;
  int _active = 0;
  static const _maxActive = 400;

  Future<void> start(int port, {bool any = false}) async {
    _server = await ServerSocket.bind(
      any ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server!.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close();
  }

  static const _fail = [5, 1, 0, 1, 0, 0, 0, 0, 0, 0];
  static const _refused = [5, 5, 0, 1, 0, 0, 0, 0, 0, 0];
  static const _unsupported = [5, 7, 0, 1, 0, 0, 0, 0, 0, 0];

  Future<void> _reject(Socket s, List<int> reply) async {
    try {
      s.add(reply);
      await s.flush();
    } catch (_) {}
    s.destroy();
  }

  Future<void> _handle(Socket s) async {
    s.setOption(SocketOption.tcpNoDelay, true);
    if (_active >= _maxActive) {
      s.destroy();
      return;
    }
    _active++;
    s.done.then((_) {}, onError: (Object _) {}).whenComplete(() => _active--);
    final r = _Reader(s);
    try {
      final g = await r.read(2).timeout(const Duration(seconds: 10));
      if (g[0] != 5) {
        s.destroy();
        return;
      }
      await r.read(g[1]);
      s.add([5, 0]);
      final h = await r.read(4).timeout(const Duration(seconds: 10));
      if (h[1] != 1) {
        await _reject(s, _unsupported);
        return;
      }
      String host;
      switch (h[3]) {
        case 1:
          host = (await r.read(4)).join('.');
          break;
        case 3:
          final n = (await r.read(1))[0];
          host = utf8.decode(await r.read(n), allowMalformed: true);
          break;
        case 4:
          final b = await r.read(16);
          final parts = <String>[];
          for (var i = 0; i < 16; i += 2) {
            parts.add(((b[i] << 8) | b[i + 1]).toRadixString(16));
          }
          host = parts.join(':');
          break;
        default:
          await _reject(s, _fail);
          return;
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];

      TunnelChannel ch;
      try {
        ch = await _connect(host, port).timeout(const Duration(seconds: 25));
      } catch (e) {
        await _reject(s, _refused);
        return;
      }
      s.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      s.done.then((_) {}, onError: (Object _) {}).whenComplete(ch.destroy);

      // remote -> local (addStream applies back-pressure to the SSH channel)
      unawaited(
        s.addStream(ch.stream).then<void>(
          (_) => s.close(),
          onError: (Object _) {
            s.destroy();
          },
        ).catchError((Object _) {
          s.destroy();
        }),
      );
      // local -> remote
      r.onClosed = () {
        try {
          ch.sink.close();
        } catch (_) {}
      };
      r.pipe(ch.sink);
    } catch (_) {
      s.destroy();
    }
  }
}

// ------------------------------------------------------------ payload proxy

/// HTTP proxy tunnel with payload injection and no SSH: every proxied
/// connection opens a fresh transport to the proxy/CDN, sends the rendered
/// payload (with [host]/[port] set to that connection's target) and relays
/// bytes once the proxy answers 2xx/101.
class PayloadProxy {
  LocalSocks? _socks;
  bool get active => _socks != null;

  Future<int> start(SshOptions o, LogFn log, {required String probeHost, required int probePort}) async {
    if (o.proxyHost.isEmpty) throw 'Proxy host is empty';
    log('Probing proxy with $probeHost:$probePort');
    final probe = await openTransport(o, log, targetHost: probeHost, targetPort: probePort);
    log('Proxy accepted the payload');
    probe.destroy();
    final socks = LocalSocks((h, p) async {
      final t = await openTransport(o, (_) {}, targetHost: h, targetPort: p);
      return TunnelChannel(t.stream, t.sink, t.destroy);
    });
    await socks.start(o.socksPort, any: o.shareHotspot);
    _socks = socks;
    log('SOCKS5 listening on ${o.shareHotspot ? '0.0.0.0' : '127.0.0.1'}:${o.socksPort}');
    return o.socksPort;
  }

  Future<void> stop() async {
    final s = _socks;
    _socks = null;
    try {
      await s?.stop();
    } catch (_) {}
  }
}

/// Minimal HTTP/1.0 GET through a local SOCKS5 proxy. Used by the connection
/// test so the result reflects the tunnel, not the phone's own network.
Future<String> socksHttpGet(int socksPort, String host, String path) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, socksPort, timeout: const Duration(seconds: 8));
  try {
    final q = StreamIterator<Uint8List>(s);
    final buf = <int>[];
    Future<List<int>> read(int n) async {
      while (buf.length < n) {
        if (!await q.moveNext().timeout(const Duration(seconds: 20))) throw 'SOCKS closed';
        buf.addAll(q.current);
      }
      final r = buf.sublist(0, n);
      buf.removeRange(0, n);
      return r;
    }

    s.add([5, 1, 0]);
    final g = await read(2);
    if (g[1] != 0) throw 'SOCKS auth refused';
    final hb = utf8.encode(host);
    s.add([5, 1, 0, 3, hb.length, ...hb, 0, 80]);
    final r = await read(4);
    if (r[1] != 0) throw 'Tunnel refused the connection (code ${r[1]})';
    if (r[3] == 1) {
      await read(6);
    } else if (r[3] == 4) {
      await read(18);
    } else if (r[3] == 3) {
      final n = (await read(1))[0];
      await read(n + 2);
    }
    s.add(utf8.encode('GET $path HTTP/1.0\r\nHost: $host\r\nUser-Agent: curl/8\r\n\r\n'));
    final out = BytesBuilder()..add(buf);
    while (await q.moveNext().timeout(const Duration(seconds: 20))) {
      out.add(q.current);
      if (out.length > 200000) break;
    }
    final text = utf8.decode(out.takeBytes(), allowMalformed: true);
    final i = text.indexOf('\r\n\r\n');
    return i < 0 ? text : text.substring(i + 4);
  } finally {
    s.destroy();
  }
}

// -------------------------------------------------------------- host checker

/// Connects like the tunnel would and reports what the server says.
Future<String> hostCheck(String host, int port, {bool tls = false, String sni = ''}) async {
  final out = StringBuffer();
  final sw = Stopwatch()..start();
  Socket? sock;
  try {
    sock = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    out.writeln('TCP connect: ${sw.elapsedMilliseconds} ms');
    if (tls) {
      sw.reset();
      final t = await SecureSocket.secure(
        sock,
        host: sni.isNotEmpty ? sni : host,
        onBadCertificate: (_) => true,
      ).timeout(const Duration(seconds: 8));
      sock = t;
      out.writeln('TLS handshake: ${sw.elapsedMilliseconds} ms');
      final c = t.peerCertificate;
      if (c != null) {
        out.writeln('Cert subject: ${c.subject}');
        out.writeln('Cert SHA-256: ${crypto.sha256.convert(c.der)}');
      }
    }
    final bb = BytesBuilder();
    try {
      await sock.timeout(const Duration(seconds: 4)).forEach((d) {
        bb.add(d);
        if (bb.length >= 255 || bb.toBytes().contains(10)) throw const _Stop();
      });
    } on _Stop {
      // got enough
    } on TimeoutException {
      // server stayed silent
    }
    final banner = latin1.decode(bb.takeBytes(), allowInvalid: true).trim();
    out.writeln(banner.isEmpty ? 'Banner: (none within 4s)' : 'Banner: ${banner.split('\n').first}');
  } catch (e) {
    out.writeln('Failed: $e');
  } finally {
    sock?.destroy();
  }
  return out.toString().trim();
}

class _Stop implements Exception {
  const _Stop();
}
