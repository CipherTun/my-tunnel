import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/udpgw.dart';

void main() {
  test('builds an IPv4 udpgw packet exactly as badvpn expects', () {
    final p = buildUdpgwPacket(
      flags: 0,
      conid: 0x0102,
      ip: Uint8List.fromList([8, 8, 8, 8]),
      port: 53,
      data: [1, 2, 3],
    );
    // u16 LE length (12), flags, u16 LE conid, raw IPv4, u16 BE port, data
    expect(p, [0x0c, 0x00, 0x00, 0x02, 0x01, 8, 8, 8, 8, 0x00, 0x35, 1, 2, 3]);
  });

  test('IPv6 sets the IPv6 flag and uses 16 address bytes', () {
    final ip = Uint8List(16)..[15] = 1;
    final p = buildUdpgwPacket(flags: 0, conid: 7, ip: ip, port: 443, data: [9]);
    expect(p[2] & UdpgwFlags.ipv6, UdpgwFlags.ipv6);
    expect(p.length, 2 + 1 + 2 + 16 + 2 + 1);
    expect(p[0] | (p[1] << 8), p.length - 2);
  });

  test('keepalive is flags=1, conid=0 and nothing else', () {
    expect(udpgwKeepalive(), [0x03, 0x00, 0x01, 0x00, 0x00]);
  });

  test('parser reassembles packets split across reads', () {
    final a = buildUdpgwPacket(
        flags: 0, conid: 5, ip: Uint8List.fromList([1, 2, 3, 4]), port: 5000, data: [7, 7]);
    final b = udpgwKeepalive();
    final all = Uint8List.fromList([...a, ...b]);
    final parser = UdpgwParser();
    final out = <UdpgwPacket>[];
    for (var i = 0; i < all.length; i += 3) {
      out.addAll(parser.feed(all.sublist(i, i + 3 > all.length ? all.length : i + 3)));
    }
    expect(out.length, 2);
    expect(out[0].conid, 5);
    expect(out[0].ip, [1, 2, 3, 4]);
    expect(out[0].port, 5000);
    expect(out[0].data, [7, 7]);
    expect(out[1].isKeepalive, isTrue);
  });

  test('SOCKS5 UDP datagram parse/build round trip', () {
    final ip = Uint8List.fromList([9, 9, 9, 9]);
    final d = Socks5Udp.build(ip, 853, [1, 2]);
    final p = Socks5Udp.parse(d)!;
    expect(p.ip, ip);
    expect(p.port, 853);
    expect(p.data, [1, 2]);
  });

  test('SOCKS5 UDP: fragments and domain names are rejected', () {
    expect(Socks5Udp.parse(Uint8List.fromList([0, 0, 1, 1, 1, 2, 3, 4, 0, 53])), isNull);
    expect(Socks5Udp.parse(Uint8List.fromList([0, 0, 0, 3, 3, 97, 98, 99, 0, 53, 1])), isNull);
  });
}
