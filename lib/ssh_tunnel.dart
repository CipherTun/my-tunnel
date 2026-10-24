import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'bytebuf.dart';
import 'payload.dart';
import 'udpgw.dart';

export 'payload.dart';

typedef Log = void Function(String message);

final Random _rng = Random.secure();

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
    this.proxyType = 'http',
    this.proxyUser = '',
    this.proxyPass = '',
    this.useTls = false,
    this.sni = '',
    this.allowInsecure = true,
    this.wsFraming = false,
    this.keepAlive = 20,
    this.udpgwPort = 0,
    this.shareHotspot = false,
    this.hotspotUser = '',
    this.hotspotPass = '',
    this.verifyHostKey,
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

  /// 'http' (CONNECT) or 'socks5' upstream proxy in front of the SSH server.
  final String proxyType;
  final String proxyUser;
  final String proxyPass;
  final bool useTls;
  final String sni;

  /// Accept any TLS certificate for the SNI/TLS wrapper (normal for domain
  /// fronting, where the certificate never matches the SNI).
  final bool allowInsecure;
  final bool wsFraming;
  final int keepAlive;

  /// Port of `badvpn-udpgw` on the SSH server (usually 7300). 0 = UDP off.
  final int udpgwPort;
  final bool shareHotspot;
  final String hotspotUser;
  final String hotspotPass;

  /// Host-key check (trust-on-first-use pinning is implemented by the caller).
  final SSHHostkeyVerifyHandler? verifyHostKey;
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
  final ByteBuf _buf = ByteBuf();
  final ByteBuf _wsBuf = ByteBuf();
  Completer<String>? _head;
  bool _pass;

  // upstream SOCKS5 proxy handshake
  Completer<void>? _socksDone;
  int _socksState = -1;
  String _sHost = '', _sUser = '', _sPass = '';
  int _sPort = 0;

  void _deliver(Uint8List d) {
    if (!_ws) {
      _in.add(d);
      return;
    }
    _wsBuf.add(d);
    _parseFrames();
  }

  void _onData(Uint8List d) {
    if (_pass) {
      _deliver(d);
      return;
    }
    _buf.add(d);
    if (_socksState >= 0) {
      _advanceSocks();
      return;
    }
    final h = _head;
    if (h == null || h.isCompleted) return;

    if (_buf.length >= 4 && latin1.decode(_buf.peek(4)) == 'SSH-') {
      _pass = true;
      final all = _buf.take(_buf.length);
      _deliver(all);
      h.complete('(no HTTP header, SSH banner received)');
      return;
    }
    final end = _indexOfHeaderEnd();
    if (end < 0) {
      if (_buf.length > 65536) h.completeError('Reply header too large');
      return;
    }
    final header = latin1.decode(_buf.take(end + 4), allowInvalid: true);
    _pass = true;
    if (_buf.length > 0) _deliver(_buf.take(_buf.length));
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
        if (len < 0 || len > (1 << 26)) {
          _socket.destroy();
          return;
        }
      }
      final masked = (b1 & 0x80) != 0;
      if (masked) off += 4;
      if (_wsBuf.length < off + len) return;
      final hdr = _wsBuf.take(off);
      final payload = Uint8List.fromList(_wsBuf.take(len));
      if (masked) {
        final m = hdr.sublist(off - 4, off);
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= m[i & 3];
        }
      }
      switch (opcode) {
        case 0:
        case 1:
        case 2:
          if (payload.isNotEmpty && !_in.isClosed) _in.add(payload);
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
    final hdr = BytesBuilder();
    hdr.addByte(0x80 | opcode);
    if (len < 126) {
      hdr.addByte(0x80 | len);
    } else if (len < 65536) {
      hdr.addByte(0x80 | 126);
      hdr.addByte(len >> 8);
      hdr.addByte(len & 255);
    } else {
      hdr.addByte(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        hdr.addByte((len >> (8 * i)) & 255);
      }
    }
    final mask = Uint8List.fromList(List<int>.generate(4, (_) => _rng.nextInt(256)));
    hdr.add(mask);
    final body = Uint8List(len);
    for (var i = 0; i < len; i++) {
      body[i] = data[i] ^ mask[i & 3];
    }
    hdr.add(body);
    return hdr.toBytes();
  }

  /// RFC 1928 CONNECT through an upstream SOCKS5 proxy (RFC 1929 login optional).
  Future<void> socks5Connect(String host, int port, {String user = '', String pass = ''}) async {
    _socksDone = Completer<void>();
    _pass = false; // buffer the proxy replies for the handshake, do not hand them to SSH
    _socksState = 0;
    _sHost = host;
    _sPort = port;
    _sUser = user;
    _sPass = pass;
    _socket.add(user.isEmpty ? [5, 1, 0] : [5, 2, 0, 2]);
    await _socket.flush();
    await _socksDone!.future.timeout(const Duration(seconds: 12));
  }

  void _socksFail(Object e) {
    final c = _socksDone;
    if (c != null && !c.isCompleted) c.completeError(e);
  }

  void _sendSocksConnect() {
    final h = utf8.encode(_sHost);
    _socket.add([5, 1, 0, 3, h.length, ...h, (_sPort >> 8) & 255, _sPort & 255]);
  }

  void _advanceSocks() {
    final c = _socksDone;
    if (c == null || c.isCompleted) return;
    try {
      if (_socksState == 0) {
        if (_buf.length < 2) return;
        final m = _buf.take(2);
        if (m[0] != 5 || m[1] == 0xff) {
          _socksFail('SOCKS5 proxy refused the login method');
          return;
        }
        if (m[1] == 2) {
          final u = utf8.encode(_sUser), p = utf8.encode(_sPass);
          _socket.add([1, u.length, ...u, p.length, ...p]);
          _socksState = 1;
        } else {
          _sendSocksConnect();
          _socksState = 2;
        }
      }
      if (_socksState == 1) {
        if (_buf.length < 2) return;
        final r = _buf.take(2);
        if (r[1] != 0) {
          _socksFail('SOCKS5 proxy rejected the username/password');
          return;
        }
        _sendSocksConnect();
        _socksState = 2;
      }
      if (_socksState == 2) {
        if (_buf.length < 5) return;
        final atyp = _buf[3];
        final total = atyp == 1 ? 10 : (atyp == 4 ? 22 : 7 + _buf[4]);
        if (_buf.length < total) return;
        final rep = _buf.take(total);
        if (rep[1] != 0) {
          _socksFail('SOCKS5 proxy could not reach the server (reply code ${rep[1]})');
          return;
        }
        _pass = true;
        _socksState = -1;
        if (_buf.length > 0) _deliver(_buf.take(_buf.length));
        c.complete();
      }
    } catch (e) {
      _socksFail(e);
    }
  }

  Future<String> sendPayload(List<PayloadPart> parts) async {
    _head = Completer<String>();
    for (var i = 0; i < parts.length; i++) {
      _socket.add(utf8.encode(parts[i].text));
      await _socket.flush();
      if (parts[i].delayMs > 0 && i < parts.length - 1) {
        await Future<void>.delayed(Duration(milliseconds: parts[i].delayMs));
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
    log('TLS handshake (SNI: $sni${o.allowInsecure ? '' : ', verified'})');
    sock = await SecureSocket.secure(sock,
        host: sni, onBadCertificate: o.allowInsecure ? (_) => true : null);
  }

  if (useProxy && o.proxyType == 'socks5') {
    final ts = TunnelSocket(sock, expectHeader: false, ws: o.wsFraming);
    log('SOCKS5 CONNECT ${o.host}:${o.port}');
    try {
      await ts.socks5Connect(o.host, o.port, user: o.proxyUser, pass: o.proxyPass);
    } catch (e) {
      ts.destroy();
      rethrow;
    }
    return ts;
  }

  var template = o.payload.trim();
  if (template.isEmpty && useProxy) {
    final auth = o.proxyUser.isEmpty
        ? ''
        : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${o.proxyUser}:${o.proxyPass}'))}[crlf]';
    template = 'CONNECT [host_port] [protocol][crlf]Host: [host][crlf]$auth[crlf]';
  }

  final ts = TunnelSocket(sock, expectHeader: template.isNotEmpty, ws: o.wsFraming);
  if (template.isNotEmpty) {
    final chunks = buildPayloadParts(template, host: o.host, port: o.port);
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

/// Opens only the transport (TCP, proxy, TLS, payload) and waits for the SSH
/// banner, so a payload / SNI / proxy can be verified without logging in.
Future<String> testTransport(SshOptions o) async {
  final sw = Stopwatch()..start();
  final log = <String>[];
  try {
    final ts = await openTransport(o, log.add);
    String banner;
    try {
      final first = await ts.stream.first.timeout(const Duration(seconds: 6));
      banner = latin1.decode(first, allowInvalid: true).split('\n').first.trim();
    } catch (_) {
      banner = '(no data from the server within 6 s)';
    }
    ts.destroy();
    final ok = banner.startsWith('SSH-');
    return '${log.join('\n')}\nServer: $banner\n'
        '${ok ? 'OK: an SSH server answered' : 'Reached the endpoint, but it did not answer like SSH'}'
        ' (${sw.elapsedMilliseconds} ms)';
  } catch (e) {
    return '${log.join('\n')}\nFailed: $e';
  }
}

/// TCP connect latency in ms, or -1 when unreachable.
Future<int> tcpPing(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    final ms = sw.elapsedMilliseconds;
    s.destroy();
    return ms;
  } catch (_) {
    return -1;
  }
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
          onBytes?.call(d.length);
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
        if (!_closed.isCompleted) _closed.complete();
        try {
          _sink?.close();
        } catch (_) {}
      },
      onError: (Object _) {
        _done = true;
        _wake();
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }

  final List<int> _buf = [];
  Completer<void>? _c;
  bool _done = false;
  final Completer<void> _closed = Completer<void>();
  StreamSink<List<int>>? _sink;

  /// Completes when the client socket ends (used by UDP ASSOCIATE).
  Future<void> get closed => _closed.future;

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

  void Function(int n)? onBytes;

  void pipeTo(StreamSink<List<int>> sink, {void Function(int n)? onBytes}) {
    this.onBytes = onBytes;
    if (_buf.isNotEmpty) {
      onBytes?.call(_buf.length);
      sink.add(List<int>.from(_buf));
      _buf.clear();
    }
    _sink = sink;
  }
}

class _Flow {
  _Flow(this.relay, this.ip, this.port, this.key);
  final UdpRelay relay;
  final Uint8List ip;
  final int port;
  final String key;
}

String _hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// UDP over SSH using the badvpn-udpgw protocol (see udpgw.dart). One SSH
/// channel to 127.0.0.1:<udpgwPort> on the server carries every UDP flow.
class UdpGw {
  UdpGw(this._client, this._port, this._log);
  final SSHClient _client;
  final int _port;
  final Log _log;

  SSHForwardChannel? _ch;
  Future<SSHForwardChannel>? _opening;
  UdpgwParser _parser = UdpgwParser();
  final Map<int, _Flow> _byId = {};
  final Map<String, int> _byKey = {};
  Timer? _ka;
  bool _closed = false;
  int _next = 1;
  bool _warnedClosed = false;
  DateTime? _failUntil;

  Future<SSHForwardChannel> _channel() {
    final c = _ch;
    if (c != null) return Future.value(c);
    return _opening ??= _open();
  }

  Future<SSHForwardChannel> _open() async {
    try {
      final ch = await _client.forwardLocal('127.0.0.1', _port);
      _ch = ch;
      _parser = UdpgwParser();
      _log('UDPGW channel open (server 127.0.0.1:$_port)');
      ch.stream.listen(_onData,
          onDone: _onClosed, onError: (Object _) => _onClosed(), cancelOnError: true);
      _ka?.cancel();
      _ka = Timer.periodic(const Duration(seconds: 25), (_) => _write(udpgwKeepalive()));
      return ch;
    } finally {
      _opening = null;
    }
  }

  void _onClosed() {
    _ch = null;
    _ka?.cancel();
    _byId.clear();
    _byKey.clear();
    if (!_closed && !_warnedClosed) {
      _warnedClosed = true;
      _log('UDPGW channel closed (is badvpn-udpgw running on the server?)');
    }
  }

  void _write(Uint8List bytes) {
    try {
      _ch?.sink.add(bytes);
    } catch (_) {}
  }

  int _alloc() {
    for (var i = 0; i < 65535; i++) {
      final id = _next;
      _next = _next >= 65535 ? 1 : _next + 1;
      if (!_byId.containsKey(id)) return id;
    }
    throw 'no free udpgw connection id';
  }

  Future<void> send(UdpRelay relay, Uint8List ip, int port, Uint8List data) async {
    if (_closed) return;
    final fu = _failUntil;
    if (fu != null && DateTime.now().isBefore(fu)) return; // server has no udpgw: back off
    final key = '${relay.id}|${_hex(ip)}:$port';
    var id = _byKey[key];
    if (id == null) {
      if (_byId.length >= 250) {
        final oldId = _byId.keys.first;
        final old = _byId.remove(oldId);
        if (old != null) _byKey.remove(old.key);
      }
      id = _alloc();
      _byKey[key] = id;
      _byId[id] = _Flow(relay, ip, port, key);
    } else {
      final f = _byId.remove(id);
      if (f != null) _byId[id] = f; // refresh LRU position
    }
    try {
      final pkt = buildUdpgwPacket(flags: 0, conid: id, ip: ip, port: port, data: data);
      await _channel();
      _write(pkt);
    } catch (e) {
      _failUntil = DateTime.now().add(const Duration(seconds: 30));
      _log('UDPGW unavailable, UDP dropped for 30s: $e');
    }
  }

  void _onData(Uint8List d) {
    for (final p in _parser.feed(d)) {
      if (p.isKeepalive) continue;
      _byId[p.conid]?.relay.deliver(p.ip, p.port, p.data);
    }
  }

  void forget(UdpRelay r) {
    final ids = [for (final e in _byId.entries) if (e.value.relay == r) e.key];
    for (final id in ids) {
      final f = _byId.remove(id);
      if (f != null) _byKey.remove(f.key);
    }
  }

  void close() {
    _closed = true;
    _ka?.cancel();
    try {
      _ch?.destroy();
    } catch (_) {}
    _ch = null;
    _byId.clear();
    _byKey.clear();
  }
}

/// One SOCKS5 UDP ASSOCIATE session: a loopback UDP socket the Xray core
/// talks to, bridged to the shared [UdpGw] channel.
class UdpRelay {
  UdpRelay(this.id, this._gw, this._log);
  final int id;
  final UdpGw _gw;
  final Log _log;
  RawDatagramSocket? _sock;
  InternetAddress? _peer;
  int _peerPort = 0;
  bool _warned = false;

  Future<int> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    _sock = s;
    s.listen(_onEvent);
    return s.port;
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    Datagram? d;
    while ((d = _sock?.receive()) != null) {
      final dg = d!;
      _peer = dg.address;
      _peerPort = dg.port;
      final p = Socks5Udp.parse(dg.data);
      if (p == null) {
        if (!_warned) {
          _warned = true;
          _log('UDP: dropped a datagram (fragment or domain destination; udpgw needs an IP)');
        }
        continue;
      }
      _gw.send(this, p.ip, p.port, p.data);
    }
  }

  void deliver(Uint8List ip, int port, Uint8List data) {
    final peer = _peer;
    if (peer == null) return;
    try {
      _sock?.send(Socks5Udp.build(ip, port, data), peer, _peerPort);
    } catch (_) {}
  }

  void close() {
    _sock?.close();
    _sock = null;
    _gw.forget(this);
  }
}

class LocalSocks {
  LocalSocks(
    this._client,
    this._log, {
    this.bindAll = false,
    this.udpgwPort = 0,
    this.authUser = '',
    this.authPass = '',
  });
  final SSHClient _client;
  final Log _log;
  final bool bindAll;
  final int udpgwPort;

  /// RFC 1929 credentials, required only for non-loopback clients (hotspot).
  final String authUser;
  final String authPass;
  ServerSocket? _server;
  UdpGw? _udp;
  final Set<UdpRelay> _relays = {};
  int _relayId = 0;

  /// Bytes sent to / received from the server through this proxy (TCP flows).
  int txBytes = 0, rxBytes = 0;

  Future<void> start(int port) async {
    _server = await ServerSocket.bind(
        bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    _log('SOCKS5 listening on ${bindAll ? '0.0.0.0' : '127.0.0.1'}:$port'
        '${udpgwPort > 0 ? '  (UDP via udpgw :$udpgwPort)' : ''}');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final r in _relays.toList()) {
      r.close();
    }
    _relays.clear();
    _udp?.close();
    _udp = null;
  }

  Future<void> _handle(Socket s) async {
    final r = _Reader(s);
    try {
      final g = await r.read(2);
      if (g[0] != 5) throw 'not socks5';
      final methods = await r.read(g[1]);
      final needAuth = authUser.isNotEmpty && !s.remoteAddress.isLoopback;
      if (needAuth) {
        if (!methods.contains(2)) {
          s.add([5, 0xff]);
          await s.close();
          return;
        }
        s.add([5, 2]);
        final v = await r.read(2);
        final u = utf8.decode(await r.read(v[1]), allowMalformed: true);
        final pl = (await r.read(1))[0];
        final p = utf8.decode(await r.read(pl), allowMalformed: true);
        if (u != authUser || p != authPass) {
          s.add([1, 1]);
          await s.close();
          return;
        }
        s.add([1, 0]);
      } else {
        s.add([5, 0]);
      }

      final h = await r.read(4);
      String host;
      switch (h[3]) {
        case 1:
          host = (await r.read(4)).join('.');
          break;
        case 3:
          final len = (await r.read(1))[0];
          host = utf8.decode(await r.read(len), allowMalformed: true);
          break;
        case 4:
          host = InternetAddress.fromRawAddress(Uint8List.fromList(await r.read(16))).address;
          break;
        default:
          throw 'bad address type';
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];

      if (h[1] == 3) {
        await _udpAssociate(s, r);
        return;
      }
      if (h[1] != 1) {
        s.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        await s.close();
        return;
      }

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
          rxBytes += d.length;
          try {
            s.add(d);
          } catch (_) {}
        },
        onDone: () => s.close(),
        onError: (Object _) => s.destroy(),
        cancelOnError: true,
      );
      r.pipeTo(ch.sink, onBytes: (n) => txBytes += n);
    } catch (_) {
      s.destroy();
    }
  }

  Future<void> _udpAssociate(Socket s, _Reader r) async {
    if (udpgwPort <= 0) {
      s.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
      await s.close();
      return;
    }
    final gw = _udp ??= UdpGw(_client, udpgwPort, _log);
    final relay = UdpRelay(++_relayId, gw, _log);
    _relays.add(relay);
    try {
      final p = await relay.start();
      s.add([5, 0, 0, 1, 127, 0, 0, 1, (p >> 8) & 0xff, p & 0xff]);
      await r.closed; // the association lives as long as this TCP connection
    } finally {
      relay.close();
      _relays.remove(relay);
      s.destroy();
    }
  }
}

class SshTunnel {
  SSHClient? _client;
  LocalSocks? _socks;
  bool _alive = false;
  void Function()? onClosed;

  bool get alive => _alive;
  int get txBytes => _socks?.txBytes ?? 0;
  int get rxBytes => _socks?.rxBytes ?? 0;

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
      onVerifyHostKey: o.verifyHostKey,
      keepAliveInterval: Duration(seconds: o.keepAlive),
    );
    _client = client;
    try {
      await client.authenticated.timeout(const Duration(seconds: 25));
    } catch (e) {
      client.close();
      _client = null;
      rethrow;
    }
    log('SSH authenticated');
    _alive = true;

    client.done.then((_) {
      _alive = false;
      log('SSH session ended');
      onClosed?.call();
    }).catchError((Object e) {
      _alive = false;
      log('SSH error: $e');
      onClosed?.call();
    });

    _socks = LocalSocks(
      client,
      log,
      bindAll: o.shareHotspot,
      udpgwPort: o.udpgwPort,
      authUser: o.shareHotspot ? o.hotspotUser : '',
      authPass: o.shareHotspot ? o.hotspotPass : '',
    );
    await _socks!.start(socksPort);
    return socksPort;
  }

  /// Plain HTTP GET through the SSH tunnel (used for the exit-IP check, since
  /// in SSH mode this app itself is excluded from the VPN).
  Future<String> httpGet(String host, String path) async {
    final c = _client;
    if (c == null || !_alive) throw 'SSH tunnel is not connected';
    final ch = await c.forwardLocal(host, 80).timeout(const Duration(seconds: 8));
    ch.sink.add(utf8.encode(
        'GET $path HTTP/1.0\r\nHost: $host\r\nConnection: close\r\nUser-Agent: curl/8.5\r\n\r\n'));
    final bb = BytesBuilder();
    try {
      await for (final d in ch.stream.timeout(const Duration(seconds: 8))) {
        bb.add(d);
        if (bb.length > 65536) break;
      }
    } finally {
      ch.destroy();
    }
    final txt = latin1.decode(bb.toBytes(), allowInvalid: true);
    final i = txt.indexOf('\r\n\r\n');
    return i < 0 ? txt : txt.substring(i + 4);
  }

  /// Streams an HTTP resource through the tunnel and returns the bytes received
  /// (headers excluded) within [maxSeconds] / [maxBytes]. Used by the speed test.
  Future<int> httpDownload(String host, int port, String path,
      {int maxSeconds = 10, int maxBytes = 30 * 1024 * 1024}) async {
    final c = _client;
    if (c == null || !_alive) throw 'SSH tunnel is not connected';
    final ch = await c.forwardLocal(host, port).timeout(const Duration(seconds: 8));
    ch.sink.add(utf8.encode(
        'GET $path HTTP/1.0\r\nHost: $host\r\nUser-Agent: curl/8.5\r\nAccept: */*\r\n\r\n'));
    final sw = Stopwatch()..start();
    var total = 0;
    var headerDone = false;
    final head = BytesBuilder();
    try {
      await for (final d in ch.stream.timeout(const Duration(seconds: 8))) {
        if (!headerDone) {
          head.add(d);
          final txt = latin1.decode(head.toBytes(), allowInvalid: true);
          final i = txt.indexOf('\r\n\r\n');
          if (i < 0) continue;
          final status = txt.split('\r\n').first;
          if (!status.contains(' 200')) throw 'Server answered: $status';
          headerDone = true;
          total += head.length - (i + 4);
        } else {
          total += d.length;
        }
        if (total >= maxBytes || sw.elapsed.inSeconds >= maxSeconds) break;
      }
    } finally {
      ch.destroy();
    }
    return total;
  }

  Future<void> stop() async {
    onClosed = null;
    _alive = false;
    await _socks?.stop();
    _socks = null;
    _client?.close();
    _client = null;
  }
}
