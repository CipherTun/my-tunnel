import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

typedef Log = void Function(String message);

final Random _rng = Random.secure();
int _rotateCounter = 0;

/// Called once per user-initiated connect so [rotate=...] advances.
void bumpRotation() => _rotateCounter++;

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
    this.wsFraming = false,
    this.keepAlive = 20,
    this.shareHotspot = false,
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
  final bool wsFraming;
  final int keepAlive;
  final bool shareHotspot;
}

/// [random=a,b,c] picks one at random, [rotate=a,b,c] advances per connection.
String expandRandomRotate(String s) {
  List<String> opts(String raw) =>
      raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  s = s.replaceAllMapped(RegExp(r'\[random=([^\]]*)\]'), (m) {
    final o = opts(m[1]!);
    return o.isEmpty ? '' : o[_rng.nextInt(o.length)];
  });
  s = s.replaceAllMapped(RegExp(r'\[rotate=([^\]]*)\]'), (m) {
    final o = opts(m[1]!);
    return o.isEmpty ? '' : o[_rotateCounter % o.length];
  });
  return s;
}

/// Tokens: [crlf] [cr] [lf] [host] [port] [host_port] [protocol] [ua] [netData]
/// [random=a,b] [rotate=a,b]; [split] / [delay_split] / [instant_split]
/// break the payload into separately sent packets.
List<String> buildPayload(String template,
    {required String host, required int port}) {
  return expandRandomRotate(template)
      .split(RegExp(r'\[(?:delay_|instant_)?split\]'))
      .map((chunk) => chunk
          .replaceAll('[crlf]', '\r\n')
          .replaceAll('[cr]', '\r')
          .replaceAll('[lf]', '\n')
          .replaceAll('[host_port]', '$host:$port')
          .replaceAll('[host]', host)
          .replaceAll('[port]', '$port')
          .replaceAll('[protocol]', 'HTTP/1.1')
          .replaceAll('[ua]', 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36')
          .replaceAll('[netData]', 'CONNECT $host:$port HTTP/1.1')
          .replaceAll(r'\r', '\r')
          .replaceAll(r'\n', '\n'))
      .where((c) => c.isNotEmpty)
      .toList();
}

/// Transport that can send a payload, strip the HTTP reply, optionally speak
/// WebSocket framing, then hand a clean byte stream to the SSH client.
class TunnelSocket implements SSHSocket {
  TunnelSocket(this._socket, {required bool expectHeader, bool ws = false})
      : _pass = !expectHeader,
        _ws = ws {
    _framed = _FramedSink(_socket);
    _socket.listen(
      _onData,
      onError: (Object e) {
        if (!_in.isClosed) _in.addError(e);
        final h = _head;
        if (h != null && !h.isCompleted) h.completeError(e);
      },
      onDone: () {
        if (!_in.isClosed) _in.close();
        final h = _head;
        if (h != null && !h.isCompleted) h.completeError('Connection closed by server');
      },
    );
  }

  final Socket _socket;
  final bool _ws;
  late final _FramedSink _framed;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final List<int> _buf = [];
  final List<int> _wsBuf = [];
  Completer<String>? _head;
  bool _pass;

  void _deliver(Uint8List d) {
    if (!_ws) {
      _in.add(d);
      return;
    }
    _wsBuf.addAll(d);
    _parseFrames();
  }

  void _onData(Uint8List d) {
    if (_pass) {
      _deliver(d);
      return;
    }
    _buf.addAll(d);
    final h = _head;
    if (h == null || h.isCompleted) return;

    if (_buf.length >= 4 && latin1.decode(_buf.sublist(0, 4)) == 'SSH-') {
      _pass = true;
      final all = Uint8List.fromList(_buf);
      _buf.clear();
      _deliver(all);
      h.complete('(no HTTP header, SSH banner received)');
      return;
    }
    final end = _indexOfHeaderEnd();
    if (end < 0) return;
    final header = latin1.decode(_buf.sublist(0, end + 4), allowInvalid: true);
    final rest = _buf.sublist(end + 4);
    _buf.clear();
    _pass = true;
    if (rest.isNotEmpty) _deliver(Uint8List.fromList(rest));
    h.complete(header);
  }

  int _indexOfHeaderEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _parseFrames() {
    while (_wsBuf.length >= 2) {
      final b0 = _wsBuf[0], b1 = _wsBuf[1];
      final opcode = b0 & 0x0f;
      var len = b1 & 0x7f;
      var off = 2;
      if (len == 126) {
        if (_wsBuf.length < 4) return;
        len = (_wsBuf[2] << 8) | _wsBuf[3];
        off = 4;
      } else if (len == 127) {
        if (_wsBuf.length < 10) return;
        len = 0;
        for (var i = 2; i < 10; i++) {
          len = (len << 8) | _wsBuf[i];
        }
        off = 10;
      }
      final masked = (b1 & 0x80) != 0;
      if (masked) off += 4;
      if (_wsBuf.length < off + len) return;
      var payload = _wsBuf.sublist(off, off + len);
      if (masked) {
        final m = _wsBuf.sublist(off - 4, off);
        payload = [for (var i = 0; i < payload.length; i++) payload[i] ^ m[i % 4]];
      }
      _wsBuf.removeRange(0, off + len);
      switch (opcode) {
        case 0:
        case 1:
        case 2:
          if (payload.isNotEmpty) _in.add(Uint8List.fromList(payload));
          break;
        case 8:
          _socket.destroy();
          return;
        case 9:
          _socket.add(_frame(payload, 10));
          break;
      }
    }
  }

  static Uint8List _frame(List<int> data, int opcode) {
    final len = data.length;
    final out = BytesBuilder();
    out.addByte(0x80 | opcode);
    if (len < 126) {
      out.addByte(0x80 | len);
    } else if (len < 65536) {
      out.addByte(0x80 | 126);
      out.addByte(len >> 8);
      out.addByte(len & 255);
    } else {
      out.addByte(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        out.addByte((len >> (8 * i)) & 255);
      }
    }
    final mask = List<int>.generate(4, (_) => _rng.nextInt(256));
    out.add(mask);
    out.add([for (var i = 0; i < len; i++) data[i] ^ mask[i % 4]]);
    return out.toBytes();
  }

  Future<String> sendPayload(List<String> chunks) async {
    _head = Completer<String>();
    for (var i = 0; i < chunks.length; i++) {
      _socket.add(utf8.encode(chunks[i]));
      await _socket.flush();
      if (i < chunks.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final header = await _head!.future.timeout(const Duration(seconds: 10));
    return header.split('\r\n').first;
  }

  @override
  Stream<Uint8List> get stream => _in.stream;
  @override
  StreamSink<List<int>> get sink => _ws ? _framed : _socket;
  @override
  Future<void> get done => _socket.done;
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future<void> close() async => _socket.close();
  @override
  void destroy() => _socket.destroy();
}

class _FramedSink implements StreamSink<List<int>> {
  _FramedSink(this._s);
  final Socket _s;

  @override
  void add(List<int> data) {
    for (var i = 0; i < data.length; i += 16384) {
      _s.add(TunnelSocket._frame(data.sublist(i, min(i + 16384, data.length)), 2));
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _s.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.listen(add).asFuture<void>();

  @override
  Future<void> close() async {
    try {
      _s.add(TunnelSocket._frame(const [], 8));
    } catch (_) {}
    await _s.close();
  }

  @override
  Future<void> get done => _s.done;
}

Future<TunnelSocket> openTransport(SshOptions o, Log log) async {
  final useProxy = o.proxyHost.isNotEmpty;
  final firstHost = useProxy ? o.proxyHost : o.host;
  final firstPort = useProxy ? o.proxyPort : o.port;

  log('Connecting to $firstHost:$firstPort${useProxy ? ' (proxy)' : ''}');
  Socket sock =
      await Socket.connect(firstHost, firstPort, timeout: const Duration(seconds: 15));
  sock.setOption(SocketOption.tcpNoDelay, true);

  if (o.useTls) {
    final sni = expandRandomRotate(o.sni.isNotEmpty ? o.sni : o.host);
    log('TLS handshake (SNI: $sni)');
    sock = await SecureSocket.secure(sock, host: sni, onBadCertificate: (_) => true);
  }

  var template = o.payload.trim();
  if (template.isEmpty && useProxy) {
    template = 'CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]';
  }

  final ts = TunnelSocket(sock, expectHeader: template.isNotEmpty, ws: o.wsFraming);
  if (template.isNotEmpty) {
    final chunks = buildPayload(template, host: o.host, port: o.port);
    log('Sending payload (${chunks.length} packet${chunks.length == 1 ? '' : 's'})');
    final line = await ts.sendPayload(chunks);
    log('Reply: $line');
    final ok = line.contains(' 101') || line.contains(' 200') || line.startsWith('(');
    if (!ok) {
      ts.destroy();
      throw 'Proxy/server rejected payload: $line';
    }
  }
  return ts;
}

/// Quick reachability test used by the Host Checker tool.
Future<String> hostCheck({
  required String host,
  required int port,
  bool tls = false,
  String sni = '',
  String payload = '',
}) async {
  final sw = Stopwatch()..start();
  try {
    Socket s = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    final tcp = sw.elapsedMilliseconds;
    var tlsMs = 0;
    final name = expandRandomRotate(sni.isEmpty ? host : sni);
    if (tls) {
      s = await SecureSocket.secure(s, host: name, onBadCertificate: (_) => true);
      tlsMs = sw.elapsedMilliseconds - tcp;
    }
    final body = payload.trim().isEmpty
        ? 'GET / HTTP/1.1\r\nHost: $name\r\nConnection: close\r\n\r\n'
        : buildPayload(payload, host: host, port: port).join();
    s.add(utf8.encode(body));
    final first = await s.first.timeout(const Duration(seconds: 8));
    s.destroy();
    final line = latin1.decode(first, allowInvalid: true).split('\r\n').first;
    return 'TCP ${tcp}ms${tls ? '  ·  TLS ${tlsMs}ms' : ''}\nReply: $line';
  } catch (e) {
    return 'Failed: $e';
  }
}

class _Reader {
  _Reader(Socket s) {
    s.listen(
      (d) {
        final sink = _sink;
        if (sink != null) {
          try {
            sink.add(d);
          } catch (_) {}
        } else {
          _buf.addAll(d);
          _wake();
        }
      },
      onDone: () {
        _done = true;
        _wake();
        try {
          _sink?.close();
        } catch (_) {}
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  final List<int> _buf = [];
  Completer<void>? _c;
  bool _done = false;
  StreamSink<List<int>>? _sink;

  void _wake() {
    final c = _c;
    _c = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<List<int>> read(int n) async {
    while (_buf.length < n) {
      if (_done) throw 'closed';
      _c = Completer<void>();
      await _c!.future;
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  void pipeTo(StreamSink<List<int>> sink) {
    if (_buf.isNotEmpty) {
      sink.add(List<int>.from(_buf));
      _buf.clear();
    }
    _sink = sink;
  }
}

class LocalSocks {
  LocalSocks(this._client, this._log, {this.bindAll = false});
  final SSHClient _client;
  final Log _log;
  final bool bindAll;
  ServerSocket? _server;

  Future<void> start(int port) async {
    _server = await ServerSocket.bind(
        bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    _log('SOCKS5 listening on ${bindAll ? '0.0.0.0' : '127.0.0.1'}:$port');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(Socket s) async {
    final r = _Reader(s);
    try {
      final g = await r.read(2);
      if (g[0] != 5) throw 'not socks5';
      await r.read(g[1]);
      s.add([5, 0]);

      final h = await r.read(4);
      if (h[1] != 1) {
        s.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        await s.close();
        return;
      }
      String host;
      switch (h[3]) {
        case 1:
          host = (await r.read(4)).join('.');
          break;
        case 3:
          final len = (await r.read(1))[0];
          host = utf8.decode(await r.read(len));
          break;
        case 4:
          host = InternetAddress.fromRawAddress(Uint8List.fromList(await r.read(16))).address;
          break;
        default:
          throw 'bad address type';
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];

      SSHForwardChannel ch;
      try {
        ch = await _client.forwardLocal(host, port);
      } catch (_) {
        s.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
        await s.close();
        return;
      }
      s.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

      ch.stream.listen(
        (d) {
          try {
            s.add(d);
          } catch (_) {}
        },
        onDone: () => s.close(),
        onError: (Object _) => s.destroy(),
        cancelOnError: true,
      );
      r.pipeTo(ch.sink);
    } catch (_) {
      s.destroy();
    }
  }
}

class SshTunnel {
  SSHClient? _client;
  LocalSocks? _socks;
  void Function()? onClosed;

  Future<int> start(SshOptions o, Log log, {int socksPort = 10808}) async {
    final sock = await openTransport(o, log);
    log('SSH handshake + auth as ${o.user}');
    List<SSHKeyPair>? ids;
    if (o.keyPem.trim().isNotEmpty) {
      ids = SSHKeyPair.fromPem(o.keyPem, o.keyPass.isEmpty ? null : o.keyPass);
    }
    final client = SSHClient(
      sock,
      username: o.user,
      identities: ids,
      onPasswordRequest: o.pass.isEmpty ? null : () => o.pass,
      keepAliveInterval: Duration(seconds: o.keepAlive),
    );
    _client = client;
    await client.authenticated.timeout(const Duration(seconds: 25));
    log('SSH authenticated');

    client.done.then((_) {
      log('SSH session ended');
      onClosed?.call();
    }).catchError((Object e) {
      log('SSH error: $e');
      onClosed?.call();
    });

    _socks = LocalSocks(client, log, bindAll: o.shareHotspot);
    await _socks!.start(socksPort);
    return socksPort;
  }

  Future<void> stop() async {
    onClosed = null;
    await _socks?.stop();
    _socks = null;
    _client?.close();
    _client = null;
  }
}
