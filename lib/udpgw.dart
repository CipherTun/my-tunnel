import 'dart:typed_data';

import 'bytebuf.dart';

/// badvpn "udpgw" wire format (what `badvpn-udpgw --listen-addr 127.0.0.1:7300`
/// speaks), verified against badvpn's udpgw.c / udpgw_proto.h / packetproto.h:
///
///   PacketProto frame : u16 LE length, then payload
///   payload           : u8 flags, u16 LE conid, address, UDP data
///   address (IPv4)    : 4 raw bytes + u16 big-endian port (network order)
///   address (IPv6)    : 16 raw bytes + u16 big-endian port, flags |= IPV6
///   keepalive         : flags = KEEPALIVE, no address, no data
class UdpgwFlags {
  static const keepalive = 1 << 0;
  static const rebind = 1 << 1;
  static const dns = 1 << 2;
  static const ipv6 = 1 << 3;
}

class UdpgwPacket {
  UdpgwPacket(this.flags, this.conid, this.ip, this.port, this.data);
  final int flags;
  final int conid;
  final Uint8List ip; // 4 or 16 bytes (empty for keepalive)
  final int port;
  final Uint8List data;

  bool get isKeepalive => (flags & UdpgwFlags.keepalive) != 0;
  bool get isV6 => (flags & UdpgwFlags.ipv6) != 0;
}

/// Maximum payload we accept/produce (PacketProto limit is 65535).
const int udpgwMaxPayload = 65535;

Uint8List buildUdpgwPacket({
  required int flags,
  required int conid,
  Uint8List? ip,
  int port = 0,
  List<int> data = const [],
}) {
  final addr = ip ?? Uint8List(0);
  if (addr.isNotEmpty && addr.length != 4 && addr.length != 16) {
    throw ArgumentError('ip must be 4 or 16 bytes');
  }
  final v6 = addr.length == 16;
  final f = flags | (v6 ? UdpgwFlags.ipv6 : 0);
  final bodyLen = 1 + 2 + (addr.isEmpty ? 0 : addr.length + 2) + data.length;
  if (bodyLen > udpgwMaxPayload) throw ArgumentError('datagram too large');
  final out = Uint8List(2 + bodyLen);
  var o = 0;
  out[o++] = bodyLen & 0xff;
  out[o++] = (bodyLen >> 8) & 0xff;
  out[o++] = f;
  out[o++] = conid & 0xff;
  out[o++] = (conid >> 8) & 0xff;
  if (addr.isNotEmpty) {
    out.setRange(o, o + addr.length, addr);
    o += addr.length;
    out[o++] = (port >> 8) & 0xff;
    out[o++] = port & 0xff;
  }
  out.setRange(o, o + data.length, data);
  return out;
}

Uint8List udpgwKeepalive() => buildUdpgwPacket(flags: UdpgwFlags.keepalive, conid: 0);

/// Incremental parser for the server -> client direction.
class UdpgwParser {
  final ByteBuf _buf = ByteBuf();

  List<UdpgwPacket> feed(List<int> bytes) {
    _buf.add(bytes);
    final out = <UdpgwPacket>[];
    while (_buf.length >= 2) {
      final len = _buf[0] | (_buf[1] << 8);
      if (_buf.length < 2 + len) break;
      _buf.take(2);
      final body = _buf.take(len);
      final p = _parse(body);
      if (p != null) out.add(p);
    }
    return out;
  }

  static UdpgwPacket? _parse(Uint8List b) {
    if (b.length < 3) return null;
    final flags = b[0];
    final conid = b[1] | (b[2] << 8);
    if ((flags & UdpgwFlags.keepalive) != 0) {
      return UdpgwPacket(flags, conid, Uint8List(0), 0, Uint8List(0));
    }
    final alen = (flags & UdpgwFlags.ipv6) != 0 ? 16 : 4;
    if (b.length < 3 + alen + 2) return null;
    final ip = Uint8List.fromList(b.sublist(3, 3 + alen));
    final port = (b[3 + alen] << 8) | b[4 + alen];
    final data = Uint8List.fromList(b.sublist(5 + alen));
    return UdpgwPacket(flags, conid, ip, port, data);
  }
}

/// SOCKS5 UDP datagram (RFC 1928 section 7) helpers.
class Socks5Udp {
  Socks5Udp(this.ip, this.port, this.data);
  final Uint8List ip;
  final int port;
  final Uint8List data;

  /// Returns null for fragmented datagrams or domain-name destinations
  /// (udpgw can only carry literal IPs).
  static Socks5Udp? parse(Uint8List d) {
    if (d.length < 10 || d[0] != 0 || d[1] != 0 || d[2] != 0) return null;
    final atyp = d[3];
    if (atyp == 1) {
      if (d.length < 10) return null;
      return Socks5Udp(Uint8List.fromList(d.sublist(4, 8)), (d[8] << 8) | d[9],
          Uint8List.fromList(d.sublist(10)));
    }
    if (atyp == 4) {
      if (d.length < 22) return null;
      return Socks5Udp(Uint8List.fromList(d.sublist(4, 20)), (d[20] << 8) | d[21],
          Uint8List.fromList(d.sublist(22)));
    }
    return null;
  }

  static Uint8List build(Uint8List ip, int port, List<int> data) {
    final v6 = ip.length == 16;
    final out = Uint8List(4 + ip.length + 2 + data.length);
    out[3] = v6 ? 4 : 1;
    out.setRange(4, 4 + ip.length, ip);
    out[4 + ip.length] = (port >> 8) & 0xff;
    out[5 + ip.length] = port & 0xff;
    out.setRange(6 + ip.length, out.length, data);
    return out;
  }
}
