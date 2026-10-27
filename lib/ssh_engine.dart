import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import 'models.dart';
import 'payload_engine.dart';
import 'ssh_socks.dart';

typedef TunnelLog = void Function(String message);

class SshSessionHandle {
  SshSessionHandle({required this.client, required this.profile, required this.socksPort, required this.socksServer});
  final SSHClient client;
  final ServerProfile profile;
  final int socksPort;
  final SshSocksServer socksServer;
  Future<void> close() async {
    await socksServer.stop();
    await client.close();
  }
}

/// SSH transport factory. It builds a real TCP/TLS/HTTP-payload/WebSocket byte
/// stream and hands that stream to DartSSH2. TLS certificate validation stays on.
class SshEngine {
  SshEngine({required this.log, required this.readHostPins, required this.saveHostPin});
  final TunnelLog log;
  final Future<Map<String, String>> Function() readHostPins;
  final Future<void> Function(String host, String fingerprint) saveHostPin;

  Future<SshSessionHandle> connect(ServerProfile profile, {int socksPort = 10808, int keepAliveSeconds = 20, bool shareProxy = false, String hotspotUser = '', String hotspotPassword = ''}) async {
    if (profile.kind != ProfileKind.ssh) throw ArgumentError('Expected an SSH profile');
    final host = profile.text('host').trim();
    final port = int.tryParse(profile.text('port', '22')) ?? 22;
    final username = profile.text('username').trim();
    if (host.isEmpty || username.isEmpty || port < 1 || port > 65535) {
      throw StateError('SSH host, username, or port is invalid');
    }
    log('SSH: opening transport to $host:$port');
    final socket = await _PayloadSshSocket.connect(profile, host: host, port: port, log: log);
    final pinKey = '$host:$port';
    final pins = await readHostPins();
    final privateKey = profile.text('privateKey').trim();
    List<SSHKeyPair>? identities;
    try {
      identities = privateKey.isEmpty ? null : SSHKeyPair.fromPem(privateKey, profile.text('keyPassphrase'));
      if (privateKey.isNotEmpty && (identities == null || identities.isEmpty)) throw StateError('The supplied SSH private key could not be decoded');
    } catch (error) {
      await socket.close();
      throw StateError('Could not load the SSH private key: $error');
    }
    final client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: profile.text('password').isEmpty ? null : () => profile.text('password'),
      handshakeTimeout: const Duration(seconds: 20),
      authTimeout: const Duration(seconds: 20),
      keepAliveInterval: Duration(seconds: keepAliveSeconds.clamp(5, 120).toInt()),
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = '$type ${utf8.decode(fingerprintBytes, allowMalformed: true)}';
        final existing = pins[pinKey];
        if (existing != null) {
          final matches = existing == fingerprint;
          if (!matches) log('SSH SECURITY ERROR: host key changed for $pinKey');
          return matches;
        }
        // Trust-on-first-use is explicit in the log and subsequent changes fail closed.
        log('SSH host key first seen ($type): $fingerprint');
        await saveHostPin(pinKey, fingerprint);
        return true;
      },
      printDebug: (message) {
        if (message != null && message.isNotEmpty) log('SSH: $message');
      },
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 25));
      log('SSH authentication accepted by ${client.remoteVersion ?? host}');
      final gatewayPort = int.tryParse(profile.text('udpgwPort', '7300')) ?? 7300;
      if (gatewayPort < 0 || gatewayPort > 65535) throw StateError('UDP gateway port must be 0–65535');
      if (gatewayPort > 0) {
        try {
          final probe = await client.forwardLocal('127.0.0.1', gatewayPort).timeout(const Duration(seconds: 7));
          await probe.close();
          log('SSH UDPGW endpoint is reachable on server loopback port $gatewayPort');
        } catch (error) {
          throw StateError('SSH authentication succeeded, but UDPGW is not reachable at 127.0.0.1:$gatewayPort. Start badvpn-udpgw on the SSH server, or set UDP gateway port to 0 for explicitly TCP-only mode. Details: $error');
        }
      } else {
        log('SSH profile explicitly selected TCP-only mode; UDP forwarding is disabled.');
      }
      final socksServer = SshSocksServer(client: client, log: log, udpGatewayPort: gatewayPort, shareProxy: shareProxy, authUser: hotspotUser, authPassword: hotspotPassword);
      final boundPort = await socksServer.start(port: socksPort);
      log('SSH SOCKS5 forwarding is ready on port $boundPort');
      return SshSessionHandle(client: client, profile: profile, socksPort: boundPort, socksServer: socksServer);
    } catch (_) {
      await client.close();
      rethrow;
    }
  }
}

class _HeaderRead {
  const _HeaderRead(this.header, this.remainder);
  final Uint8List header;
  final Uint8List remainder;
}

class _SocketPump implements SSHSocket {
  _SocketPump(this._socket) {
    _socketSubscription = _socket.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        if (!_incoming.isClosed) _incoming.addError(error, stack);
        if (!_done.isCompleted) _done.completeError(error, stack);
      },
      onDone: () {
        if (!_incoming.isClosed) _incoming.close();
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: false,
    );
    _outboundSubscription = _outbound.stream.listen(
      (data) => _socket.add(Uint8List.fromList(data)),
      onError: (Object error, StackTrace stack) {
        if (!_done.isCompleted) _done.completeError(error, stack);
      },
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outbound = StreamController<List<int>>();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Uint8List> _socketSubscription;
  late final StreamSubscription<List<int>> _outboundSubscription;
  final List<int> _buffer = <int>[];
  Completer<_HeaderRead>? _headerWaiter;
  bool _streaming = false;
  bool _closed = false;

  @override
  Future<void> get done => _done.future;
  @override
  StreamSink<List<int>> get sink => _outbound.sink;
  @override
  Stream<Uint8List> get stream => _incoming.stream;

  void _onData(Uint8List data) {
    if (_headerWaiter != null && !_headerWaiter!.isCompleted) {
      _buffer.addAll(data);
      _completeHeaderIfReady();
    } else if (_streaming && !_incoming.isClosed) {
      _incoming.add(data);
    } else {
      _buffer.addAll(data);
    }
  }

  void writeBytes(List<int> bytes) => _outbound.add(bytes);
  void writeText(String text) => writeBytes(utf8.encode(text));

  Future<_HeaderRead> readHeader({Duration timeout = const Duration(seconds: 12)}) async {
    if (_headerWaiter != null) throw StateError('A transport header read is already active');
    final waiter = Completer<_HeaderRead>();
    _headerWaiter = waiter;
    _completeHeaderIfReady();
    try {
      return await waiter.future.timeout(timeout, onTimeout: () {
        throw TimeoutException('Timed out waiting for the remote HTTP response');
      });
    } finally {
      if (identical(_headerWaiter, waiter)) _headerWaiter = null;
    }
  }

  void _completeHeaderIfReady() {
    final waiter = _headerWaiter;
    if (waiter == null || waiter.isCompleted) return;
    final end = _findHeaderEnd(_buffer);
    if (end < 0) return;
    final header = Uint8List.fromList(_buffer.sublist(0, end));
    final remainder = Uint8List.fromList(_buffer.sublist(end + 4));
    _buffer.clear();
    waiter.complete(_HeaderRead(header, remainder));
  }

  void startStreaming([List<int> prefix = const <int>[]]) {
    if (_streaming) return;
    _streaming = true;
    if (prefix.isNotEmpty && !_incoming.isClosed) _incoming.add(Uint8List.fromList(prefix));
    if (_buffer.isNotEmpty && !_incoming.isClosed) {
      _incoming.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return done;
    _closed = true;
    await _outbound.close();
    await _socketSubscription.cancel();
    await _outboundSubscription.cancel();
    try {
      await _socket.close();
    } finally {
      if (!_incoming.isClosed) await _incoming.close();
      if (!_done.isCompleted) _done.complete();
    }
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_outbound.isClosed) unawaited(_outbound.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() => _socket.flush();
}

int _findHeaderEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
  }
  return -1;
}

String _headerValue(String header, String key) {
  for (final line in header.split('\r\n').skip(1)) {
    final split = line.indexOf(':');
    if (split > 0 && line.substring(0, split).trim().toLowerCase() == key.toLowerCase()) {
      return line.substring(split + 1).trim();
    }
  }
  return '';
}

class _PayloadSshSocket {
  static Future<SSHSocket> connect(ServerProfile profile, {required String host, required int port, required TunnelLog log}) async {
    final proxyHost = profile.text('proxyHost').trim();
    final proxyPort = int.tryParse(profile.text('proxyPort', '8080')) ?? 8080;
    if (proxyHost.isNotEmpty && profile.flag('tls')) {
      throw StateError('TLS through a plain HTTP proxy is not enabled in this build; use direct TLS or a TLS-capable proxy.');
    }

    late final Socket raw;
    if (proxyHost.isNotEmpty) {
      raw = await Socket.connect(proxyHost, proxyPort, timeout: const Duration(seconds: 15));
    } else if (profile.flag('tls')) {
      final rawSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
      try {
        raw = await SecureSocket.secure(
          rawSocket,
          host: profile.text('sni', host).trim().isEmpty ? host : profile.text('sni', host).trim(),
          onBadCertificate: (_) => false,
        ).timeout(const Duration(seconds: 15));
      } catch (_) {
        rawSocket.destroy();
        rethrow;
      }
    } else {
      raw = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    }

    raw.setOption(SocketOption.tcpNoDelay, true);
    final pump = _SocketPump(raw);
    final prefix = <int>[];
    try {
      if (proxyHost.isNotEmpty) {
        final authorization = profile.text('proxyUser').isNotEmpty
            ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${profile.text('proxyUser')}:${profile.text('proxyPassword')}'))}\r\n'
            : '';
        pump.writeText('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n${authorization}Proxy-Connection: keep-alive\r\n\r\n');
        final reply = await pump.readHeader().timeout(const Duration(seconds: 12));
        final status = utf8.decode(reply.header, allowMalformed: true).split('\r\n').first;
        if (!RegExp(r'^HTTP/\d(?:\.\d)?\s+200\b', caseSensitive: false).hasMatch(status)) {
          throw StateError('Upstream proxy rejected CONNECT: $status');
        }
        prefix.addAll(reply.remainder);
        log('SSH: upstream HTTP CONNECT established');
      }

      if (profile.flag('websocket')) {
        final wsPath = profile.text('wsPath', '/').trim().isEmpty ? '/' : profile.text('wsPath', '/').trim();
        final key = base64Encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
        final sniHost = profile.text('sni', host).trim().isEmpty ? host : profile.text('sni', host).trim();
        final wsHost = profile.text('wsHost').trim().isEmpty ? sniHost : profile.text('wsHost').trim();
        final extra = profile.text('payload').trim();
        final extraHeaders = extra.isEmpty ? '' : '${utf8.decode(expandPayload(extra, host: wsHost, port: port, sni: sniHost, method: 'GET').chunks.expand((part) => part).toList(), allowMalformed: true)}\r\n';
        pump.writeText('GET $wsPath HTTP/1.1\r\nHost: $wsHost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n$extraHeaders\r\n');
        final reply = await pump.readHeader().timeout(const Duration(seconds: 12));
        final headerText = utf8.decode(reply.header, allowMalformed: true);
        final status = headerText.split('\r\n').first;
        if (!RegExp(r'^HTTP/\d(?:\.\d)?\s+101\b', caseSensitive: false).hasMatch(status)) {
          throw StateError('WebSocket upgrade rejected: $status');
        }
        final expected = base64Encode(sha1.convert(utf8.encode('$key' + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
        if (_headerValue(headerText, 'Sec-WebSocket-Accept') != expected) {
          throw StateError('WebSocket server returned an invalid Sec-WebSocket-Accept value');
        }
        pump.startStreaming([...prefix, ...reply.remainder]);
        log('SSH: WebSocket transport established');
        return _WebSocketSshSocket(pump);
      }

      final payloadText = profile.text('payload');
      if (payloadText.trim().isNotEmpty) {
        final expansion = expandPayload(payloadText, host: host, port: port, sni: profile.text('sni', host));
        for (var i = 0; i < expansion.chunks.length; i++) {
          pump.writeBytes(expansion.chunks[i]);
          if (expansion.chunks.length > 1) await pump.flush();
          if (expansion.delay > Duration.zero && i < expansion.chunks.length - 1) await Future<void>.delayed(expansion.delay);
        }
        if (!expansion.raw) {
          final reply = await pump.readHeader().timeout(const Duration(seconds: 12));
          final response = utf8.decode(reply.header, allowMalformed: true);
          final status = response.split('\r\n').first;
          if (!RegExp(r'^HTTP/\d(?:\.\d)?\s+(?:200|101)\b', caseSensitive: false).hasMatch(status)) {
            throw StateError('Payload gateway rejected the request: $status');
          }
          prefix.addAll(reply.remainder);
          log('SSH: payload gateway accepted the request');
        }
      }
      pump.startStreaming(prefix);
      return pump;
    } catch (_) {
      await pump.close();
      rethrow;
    }
  }
}

class _WebSocketSshSocket implements SSHSocket {
  _WebSocketSshSocket(this._raw) {
    _rawSub = _raw.stream.listen(_onRaw, onError: (Object error, StackTrace stack) => _incoming.addError(error, stack), onDone: _onDone, cancelOnError: false);
    _outSub = _outbound.stream.listen(_sendBinaryFrame, onError: _incoming.addError);
  }
  final _SocketPump _raw;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outbound = StreamController<List<int>>();
  final List<int> _buffer = <int>[];
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Uint8List> _rawSub;
  late final StreamSubscription<List<int>> _outSub;
  bool _closed = false;

  @override
  Future<void> get done => _done.future;
  @override
  StreamSink<List<int>> get sink => _outbound.sink;
  @override
  Stream<Uint8List> get stream => _incoming.stream;

  void _onRaw(Uint8List data) {
    _buffer.addAll(data);
    while (_buffer.length >= 2) {
      final first = _buffer[0];
      final second = _buffer[1];
      final opcode = first & 0x0f;
      final masked = (second & 0x80) != 0;
      var length = second & 0x7f;
      var offset = 2;
      if (length == 126) {
        if (_buffer.length < 4) return;
        length = (_buffer[2] << 8) | _buffer[3];
        offset = 4;
      } else if (length == 127) {
        if (_buffer.length < 10) return;
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = (length << 8) | _buffer[i];
          if (length > 16 * 1024 * 1024) throw StateError('WebSocket frame exceeds the 16 MiB safety limit');
        }
        offset = 10;
      }
      final maskOffset = offset;
      if (masked) offset += 4;
      if (_buffer.length < offset + length) return;
      final payload = Uint8List.fromList(_buffer.sublist(offset, offset + length));
      if (masked) {
        final mask = _buffer.sublist(maskOffset, maskOffset + 4);
        for (var i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      }
      _buffer.removeRange(0, offset + length);
      if (opcode == 0x2 || opcode == 0x0) {
        if (payload.isNotEmpty) _incoming.add(payload);
      } else if (opcode == 0x8) {
        unawaited(close());
        return;
      } else if (opcode == 0x9) {
        _sendFrame(0xA, payload);
      }
    }
  }

  void _sendBinaryFrame(List<int> data) => _sendFrame(0x2, data);

  void _sendFrame(int opcode, List<int> data) {
    if (_closed) return;
    final mask = List<int>.generate(4, (_) => Random.secure().nextInt(256));
    final header = <int>[0x80 | opcode];
    if (data.length < 126) {
      header.add(0x80 | data.length);
    } else if (data.length <= 65535) {
      header.addAll([0x80 | 126, (data.length >> 8) & 255, data.length & 255]);
    } else {
      header.add(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) header.add((data.length >> shift) & 255);
    }
    header.addAll(mask);
    final masked = List<int>.generate(data.length, (i) => data[i] ^ mask[i & 3]);
    _raw.writeBytes([...header, ...masked]);
  }

  void _onDone() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    if (_closed) return done;
    _sendFrame(0x8, const <int>[]);
    _closed = true;
    await _outbound.close();
    await _rawSub.cancel();
    await _outSub.cancel();
    await _raw.close();
    if (!_incoming.isClosed) await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    _raw.destroy();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_outbound.isClosed) unawaited(_outbound.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() => _raw.flush();
}
