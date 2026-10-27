import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

typedef SocksLog = void Function(String message);

/// Original loopback SOCKS5 server. TCP CONNECT requests become SSH direct-tcpip
/// channels; UDP ASSOCIATE datagrams use the documented badvpn-udpgw framing over
/// an SSH channel to the server's configured gateway port.
class SshSocksServer {
  SshSocksServer({required this.client, required this.log, required this.udpGatewayPort, this.shareProxy = false, this.authUser = '', this.authPassword = ''});
  final SSHClient client;
  final SocksLog log;
  final int udpGatewayPort;
  final bool shareProxy;
  final String authUser;
  final String authPassword;
  ServerSocket? _server;
  final Set<Socket> _clients = <Socket>{};
  final Set<_UdpGatewayRelay> _relays = <_UdpGatewayRelay>{};
  bool _stopping = false;

  Future<int> start({required int port}) async {
    if (_server != null) throw StateError('SOCKS server is already running');
    if (shareProxy && (authUser.isEmpty || authPassword.isEmpty)) throw StateError('Set a username and password before sharing the SOCKS proxy');
    _server = await ServerSocket.bind(shareProxy ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port, shared: false);
    _server!.listen((socket) {
      _clients.add(socket);
      unawaited(_handle(socket));
    }, onError: (Object error) => log('SOCKS listener error: $error'));
    log('SSH SOCKS5 listener bound to ${shareProxy ? '0.0.0.0' : '127.0.0.1'}:${_server!.port} (TCP via SSH${udpGatewayPort > 0 ? ', UDPGW :$udpGatewayPort' : ', UDP disabled'}${shareProxy ? ', external clients require authentication' : ''})');
    return _server!.port;
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    await _server?.close();
    _server = null;
    for (final relay in _relays.toList()) {
      await relay.close();
    }
    _relays.clear();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    _clients.clear();
  }

  Future<void> _handle(Socket socket) async {
    final reader = _SocksReader(socket);
    try {
      final hello = await reader.read(2).timeout(const Duration(seconds: 10));
      if (hello[0] != 5) throw const FormatException('Only SOCKS5 is supported');
      final methods = await reader.read(hello[1]).timeout(const Duration(seconds: 10));
      final externalClient = !socket.remoteAddress.isLoopback;
      final requiredMethod = externalClient && shareProxy ? 2 : 0;
      if (!methods.contains(requiredMethod)) {
        socket.add(const <int>[5, 255]);
        return;
      }
      socket.add(<int>[5, requiredMethod]);
      if (requiredMethod == 2) {
        final authHeader = await reader.read(2).timeout(const Duration(seconds: 10));
        if (authHeader[0] != 1) { socket.add(const <int>[1, 1]); return; }
        final userLength = authHeader[1];
        final user = utf8.decode(await reader.read(userLength).timeout(const Duration(seconds: 10)), allowMalformed: true);
        final passLength = (await reader.read(1).timeout(const Duration(seconds: 10)))[0];
        final pass = utf8.decode(await reader.read(passLength).timeout(const Duration(seconds: 10)), allowMalformed: true);
        final accepted = user == authUser && pass == authPassword;
        socket.add(<int>[1, accepted ? 0 : 1]);
        if (!accepted) return;
      }

      final request = await reader.read(4).timeout(const Duration(seconds: 10));
      if (request[0] != 5 || request[2] != 0) throw const FormatException('Malformed SOCKS5 request');
      final address = await _readAddress(reader, request[3]);
      final portBytes = await reader.read(2).timeout(const Duration(seconds: 10));
      final port = (portBytes[0] << 8) | portBytes[1];

      if (request[1] == 1) {
        final channel = await client.forwardLocal(address, port).timeout(const Duration(seconds: 20));
        socket.add(const <int>[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        reader.startForwarding((bytes) => channel.sink.add(bytes));
        final remoteSubscription = channel.stream.listen(
          (bytes) => socket.add(bytes),
          onError: (Object error) { log('SSH TCP channel error: $error'); socket.destroy(); },
          onDone: () { socket.destroy(); },
          cancelOnError: true,
        );
        try {
          await socket.done;
        } finally {
          await remoteSubscription.cancel();
          await channel.close();
        }
        return;
      }

      if (request[1] == 3) {
        if (udpGatewayPort < 1 || udpGatewayPort > 65535) {
          socket.add(const <int>[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
          return;
        }
        var advertisedAddress = InternetAddress.loopbackIPv4;
        if (shareProxy) {
          final interfaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4,
            includeLoopback: false,
          );
          for (final interface in interfaces) {
            if (interface.addresses.isNotEmpty) {
              advertisedAddress = interface.addresses.first;
              break;
            }
          }
        }
        final relay = _UdpGatewayRelay(
          client: client,
          gatewayPort: udpGatewayPort,
          log: log,
          bindAddress: shareProxy ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
          advertisedAddress: advertisedAddress,
        );
        _relays.add(relay);
        try {
          final endpoint = await relay.start();
          final addressBytes = endpoint.address.rawAddress;
          socket.add(<int>[5, 0, 0, addressBytes.length == 16 ? 4 : 1, ...addressBytes, (endpoint.port >> 8) & 255, endpoint.port & 255]);
          await socket.done;
        } catch (error) {
          log('UDPGW setup failed (check badvpn-udpgw on the SSH server): $error');
          socket.add(const <int>[5, 1, 0, 1, 0, 0, 0, 0, 0, 0]);
        } finally {
          await relay.close();
          _relays.remove(relay);
        }
        return;
      }

      socket.add(const <int>[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
    } catch (error) {
      if (!_stopping) log('SOCKS client closed or failed: $error');
    } finally {
      _clients.remove(socket);
      await reader.cancel();
      socket.destroy();
    }
  }

  Future<String> _readAddress(_SocksReader reader, int type) async {
    if (type == 1) {
      final bytes = await reader.read(4).timeout(const Duration(seconds: 10));
      return InternetAddress.fromRawAddress(bytes, type: InternetAddressType.IPv4).address;
    }
    if (type == 4) {
      final bytes = await reader.read(16).timeout(const Duration(seconds: 10));
      return InternetAddress.fromRawAddress(bytes, type: InternetAddressType.IPv6).address;
    }
    if (type == 3) {
      final length = (await reader.read(1).timeout(const Duration(seconds: 10)))[0];
      return utf8.decode(await reader.read(length).timeout(const Duration(seconds: 10)));
    }
    throw const FormatException('Unsupported SOCKS5 address type');
  }
}

class _SocksReader {
  _SocksReader(this.socket) {
    _subscription = socket.listen(_onData, onError: (Object error, StackTrace stack) {
      if (!_closed.isCompleted) _closed.complete();
      _wakeReader(error);
    }, onDone: () {
      if (!_closed.isCompleted) _closed.complete();
      _wakeReader(StateError('SOCKS client closed'));
    }, cancelOnError: false);
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = <int>[];
  final Completer<void> _closed = Completer<void>();
  Completer<void>? _available;
  bool _forwarding = false;
  void Function(List<int>)? _forward;

  Future<void> get closed => _closed.future;

  void _onData(Uint8List data) {
    if (_forwarding) {
      _forward?.call(data);
      return;
    }
    _buffer.addAll(data);
    _available?.complete();
    _available = null;
  }

  void _wakeReader([Object? error]) {
    if (_available != null && !_available!.isCompleted) {
      if (error == null) _available!.complete(); else _available!.completeError(error);
    }
    _available = null;
  }

  Future<Uint8List> read(int length) async {
    if (length < 0) throw ArgumentError.value(length, 'length');
    while (_buffer.length < length) {
      if (_closed.isCompleted) throw StateError('SOCKS client closed while reading');
      final waiter = Completer<void>();
      _available = waiter;
      await waiter.future;
    }
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return result;
  }

  void startForwarding(void Function(List<int>) forward) {
    _forward = forward;
    _forwarding = true;
    if (_buffer.isNotEmpty) {
      forward(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
  }

  Future<void> cancel() => _subscription.cancel();
}

class _UdpGatewayRelay {
  _UdpGatewayRelay({required this.client, required this.gatewayPort, required this.log, required this.bindAddress, required this.advertisedAddress});
  final SSHClient client;
  final int gatewayPort;
  final SocksLog log;
  final InternetAddress bindAddress;
  final InternetAddress advertisedAddress;
  SSHForwardChannel? _channel;
  RawDatagramSocket? _udp;
  StreamSubscription<Uint8List>? _channelSubscription;
  Timer? _keepalive;
  final List<int> _streamBuffer = <int>[];
  final Map<String, int> _idByDestination = <String, int>{};
  final Map<int, ({Uint8List ip, int port})> _destinationById = <int, ({Uint8List ip, int port})>{};
  int _nextId = 1;
  InternetAddress? _lastClientAddress;
  int _lastClientPort = 0;
  bool _closed = false;

  Future<({InternetAddress address, int port})> start() async {
    _channel = await client.forwardLocal('127.0.0.1', gatewayPort).timeout(const Duration(seconds: 15));
    _channelSubscription = _channel!.stream.listen(_onGatewayData, onError: (Object e) => log('UDPGW SSH channel error: $e'), onDone: () => log('UDPGW SSH channel closed'));
    _udp = await RawDatagramSocket.bind(bindAddress, 0);
    _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = _udp!.receive()) != null) {
        final packet = datagram!;
        _lastClientAddress = packet.address;
        _lastClientPort = packet.port;
        unawaited(_sendSocksDatagram(packet.data));
      }
    }, onError: (Object e) => log('UDPGW local UDP socket error: $e'));
    _keepalive = Timer.periodic(const Duration(seconds: 25), (_) => _writeFrame(_makePacket(flags: 1, id: 0)));
    log('UDPGW relay active on local UDP port ${_udp!.port} -> SSH server 127.0.0.1:$gatewayPort');
    return (address: advertisedAddress, port: _udp!.port);
  }

  Future<void> _sendSocksDatagram(Uint8List datagram) async {
    if (_closed || _channel == null) return;
    if (datagram.length < 10 || datagram[0] != 0 || datagram[1] != 0 || datagram[2] != 0) return;
    final type = datagram[3];
    var offset = 4;
    Uint8List ip;
    if (type == 1) {
      if (datagram.length < 10) return;
      ip = Uint8List.fromList(datagram.sublist(4, 8));
      offset = 8;
    } else if (type == 4) {
      if (datagram.length < 22) return;
      ip = Uint8List.fromList(datagram.sublist(4, 20));
      offset = 20;
    } else if (type == 3) {
      if (datagram.length < 7) return;
      final length = datagram[4];
      if (datagram.length < 5 + length + 2) return;
      final domain = utf8.decode(datagram.sublist(5, 5 + length), allowMalformed: true);
      final resolved = await _resolveDomainThroughVpn(domain);
      if (resolved == null) {
        log('UDPGW could not resolve $domain through the local Xray proxy');
        return;
      }
      ip = Uint8List.fromList(resolved.rawAddress);
      offset = 5 + length;
    } else {
      return;
    }
    if (datagram.length < offset + 2) return;
    final port = (datagram[offset] << 8) | datagram[offset + 1];
    final dataOffset = offset + 2;
    final payload = datagram.sublist(dataOffset);
    final key = '${ip.length}:${ip.join('.')}:$port';
    var id = _idByDestination[key];
    if (id == null) {
      id = _allocateId();
      _idByDestination[key] = id;
      _destinationById[id] = (ip: ip, port: port);
    }
    final flags = port == 53 ? 4 : 0;
    _writeFrame(_makePacket(flags: flags, id: id, ip: ip, port: port, data: payload));
  }

  Future<InternetAddress?> _resolveDomainThroughVpn(String domain) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'PROXY 127.0.0.1:10809';
    try {
      final uri = Uri.https('cloudflare-dns.com', '/dns-query', {'name': domain, 'type': 'A'});
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) return null;
      final body = jsonDecode(await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 8)));
      if (body is! Map || body['Answer'] is! List) return null;
      for (final answer in body['Answer'] as List) {
        if (answer is Map && (answer['type'] == 1 || answer['type'] == '1')) {
          final address = InternetAddress.tryParse((answer['data'] ?? '').toString());
          if (address != null && address.type == InternetAddressType.IPv4) return address;
        }
      }
      return null;
    } catch (error) {
      log('DoH lookup for UDP destination failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  int _allocateId() {
    for (var i = 0; i < 65535; i++) {
      final candidate = _nextId;
      _nextId = _nextId >= 65535 ? 1 : _nextId + 1;
      if (!_destinationById.containsKey(candidate)) return candidate;
    }
    throw StateError('UDPGW connection ID space is exhausted');
  }

  Uint8List _makePacket({required int flags, required int id, Uint8List? ip, int port = 0, List<int> data = const <int>[]}) {
    final address = ip ?? Uint8List(0);
    final actualFlags = flags | (address.length == 16 ? 8 : 0);
    final bodyLength = 3 + (address.isEmpty ? 0 : address.length + 2) + data.length;
    if (bodyLength > 65535) throw ArgumentError('UDPGW datagram exceeds frame limit');
    final result = Uint8List(2 + bodyLength);
    result[0] = bodyLength & 255;
    result[1] = (bodyLength >> 8) & 255;
    result[2] = actualFlags;
    result[3] = id & 255;
    result[4] = (id >> 8) & 255;
    var offset = 5;
    if (address.isNotEmpty) {
      result.setRange(offset, offset + address.length, address);
      offset += address.length;
      result[offset++] = (port >> 8) & 255;
      result[offset++] = port & 255;
    }
    result.setRange(offset, offset + data.length, data);
    return result;
  }

  void _writeFrame(List<int> frame) {
    if (_closed || _channel == null) return;
    try { _channel!.sink.add(frame); } catch (e) { log('UDPGW write failed: $e'); }
  }

  void _onGatewayData(Uint8List data) {
    _streamBuffer.addAll(data);
    while (_streamBuffer.length >= 2) {
      final length = _streamBuffer[0] | (_streamBuffer[1] << 8);
      if (length < 3) { _streamBuffer.removeRange(0, 2); continue; }
      if (_streamBuffer.length < length + 2) return;
      final body = Uint8List.fromList(_streamBuffer.sublist(2, length + 2));
      _streamBuffer.removeRange(0, length + 2);
      _handleGatewayPacket(body);
    }
  }

  void _handleGatewayPacket(Uint8List body) {
    if (body.length < 3) return;
    final flags = body[0];
    final id = body[1] | (body[2] << 8);
    if ((flags & 1) != 0) return;
    final ipv6 = (flags & 8) != 0;
    final addressLength = ipv6 ? 16 : 4;
    if (body.length < 3 + addressLength + 2) return;
    final ip = Uint8List.fromList(body.sublist(3, 3 + addressLength));
    final offset = 3 + addressLength;
    final port = (body[offset] << 8) | body[offset + 1];
    final payload = body.sublist(offset + 2);
    final destination = _destinationById[id];
    final lastAddress = _lastClientAddress;
    final udp = _udp;
    if (destination == null || lastAddress == null || udp == null) return;
    final socksPacket = Uint8List(4 + ip.length + 2 + payload.length);
    socksPacket[3] = ipv6 ? 4 : 1;
    socksPacket.setRange(4, 4 + ip.length, ip);
    socksPacket[4 + ip.length] = (port >> 8) & 255;
    socksPacket[5 + ip.length] = port & 255;
    socksPacket.setRange(6 + ip.length, socksPacket.length, payload);
    udp.send(socksPacket, lastAddress, _lastClientPort);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepalive?.cancel();
    await _channelSubscription?.cancel();
    _udp?.close();
    try { await _channel?.close(); } catch (_) {}
    _channel = null;
    _idByDestination.clear();
    _destinationById.clear();
  }
}
