import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/config_tweaks.dart';
import 'package:vpn/models.dart';
import 'package:vpn/payload.dart';
import 'package:vpn/payload_gen.dart';

void main() {
  group('proxy outbound', () {
    test('HTTP proxy with login and headers (flat + legacy settings)', () {
      final ob = buildProxyOutbound({
        'kind': 'http',
        'address': 'p.example',
        'port': '8080',
        'user': 'u',
        'pass': 'pw',
        'headers': 'Host: front.example\nX-Online-Host: front.example',
      });
      expect(ob['protocol'], 'http');
      final s = ob['settings'] as Map;
      expect(s['address'], 'p.example');
      expect(s['port'], 8080);
      expect(s['user'], 'u');
      expect(s['pass'], 'pw');
      expect(s['headers'], {'Host': 'front.example', 'X-Online-Host': 'front.example'});
      final legacy = (s['servers'] as List).first as Map;
      expect(legacy['users'], [
        {'user': 'u', 'pass': 'pw'}
      ]);
      expect(ob.containsKey('streamSettings'), isFalse);
    });

    test('HTTPS proxy enables TLS with SNI and pinning, never allowInsecure', () {
      final ob = buildProxyOutbound({
        'kind': 'https',
        'address': 'p.example',
        'port': '443',
        'sni': 'front.example',
        'pin': 'abcd',
      });
      final ss = ob['streamSettings'] as Map;
      expect(ss['security'], 'tls');
      expect((ss['tlsSettings'] as Map)['serverName'], 'front.example');
      expect((ss['tlsSettings'] as Map)['pinnedPeerCertSha256'], 'abcd');
      expect(jsonEncode(ob).contains('allowInsecure'), isFalse);
    });

    test('SOCKS5 proxy has no headers and no TLS', () {
      final ob = buildProxyOutbound({'kind': 'socks5', 'address': 's.example', 'port': '1080'});
      expect(ob['protocol'], 'socks');
      expect((ob['settings'] as Map).containsKey('headers'), isFalse);
      expect((ob['settings'] as Map).containsKey('user'), isFalse);
    });

    test('empty address is rejected', () {
      expect(() => buildProxyOutbound({'kind': 'http', 'address': ''}), throwsA(isA<String>()));
    });

    test('proxy URLs import, web pages and subscriptions do not', () {
      final a = importProfile('socks5://bob:s%40cret@1.2.3.4:1081#Home')!;
      expect(a.type, ProfileType.proxy);
      expect((a.s('kind'), a.s('address'), a.s('port'), a.s('user'), a.s('pass')),
          ('socks5', '1.2.3.4', '1081', 'bob', 's@cret'));
      expect(a.name, 'Home');
      final b = importProfile('http://user:pw@proxy.example:3128')!;
      expect((b.type, b.s('kind')), (ProfileType.proxy, 'http'));
      expect(importProfile('https://example.com/sub?token=1'), isNull);
      expect(importProfile('https://example.com:8443/api/sub'), isNull);
      expect(importProfile('http://example.com'), isNull);
    });
  });

  group('inbound and log level', () {
    const cfg = '{"log":{"loglevel":"warning"},"inbounds":[{"tag":"x","protocol":"socks","port":1,"listen":"0.0.0.0"}]}';

    test('applyInbound pins port and listen address', () {
      final m = jsonDecode(applyInbound(cfg, port: 10808)) as Map;
      final i = (m['inbounds'] as List).first as Map;
      expect((i['port'], i['listen']), (10808, '127.0.0.1'));
      final all = jsonDecode(applyInbound(cfg, port: 10808, listenAll: true)) as Map;
      expect(((all['inbounds'] as List).first as Map)['listen'], '0.0.0.0');
    });

    test('applyInbound leaves configs without a socks/http inbound alone', () {
      const other = '{"inbounds":[{"protocol":"tun"}]}';
      expect(applyInbound(other, port: 1), other);
      expect(applyInbound('not json', port: 1), 'not json');
    });

    test('applyLogLevel', () {
      final m = jsonDecode(applyLogLevel(cfg, 'debug')) as Map;
      expect((m['log'] as Map)['loglevel'], 'debug');
      expect(applyLogLevel(cfg, 'default'), cfg);
    });
  });

  group('payload engine', () {
    test('all documented tags expand', () {
      final out = buildPayload(
          '[method] [host_port] [protocol][crlf*2][ssh][lfcr][lf][cr][netData][host][port]',
          host: 's.example',
          port: 22);
      expect(out.single,
          'CONNECT s.example:22 HTTP/1.1\r\n\r\ns.example:22\n\r\n\rCONNECT s.example:22 HTTP/1.1s.example22');
    });

    test('[raw] is a complete CONNECT request', () {
      expect(buildPayload('[raw]', host: 'h', port: 443).single, 'CONNECT h:443 HTTP/1.1\r\n\r\n');
    });

    test('split markers set the pause after the packet before them', () {
      final p = buildPayloadParts('A[split]B[delay_split]C[instant_split]D', host: 'h', port: 1);
      expect(p.map((e) => e.text), ['A', 'B', 'C', 'D']);
      expect(p.map((e) => e.delayMs), [300, 1000, 0, 0]);
    });

    test('empty pieces are dropped', () {
      expect(buildPayload('[split][split]X', host: 'h', port: 1), ['X']);
    });
  });

  group('payload generator', () {
    test('normal CONNECT with spoofed Host', () {
      final out = generatePayload(PayloadSpec(frontHosts: ['front.example'], keepAlive: true));
      expect(out,
          'CONNECT [host_port] [protocol][crlf]Host: front.example[crlf]Connection: Keep-Alive[crlf][crlf]');
    });

    test('front inject puts the harmless request first', () {
      final out = generatePayload(PayloadSpec(method: InjectMethod.frontInject, frontHosts: ['f.example']));
      expect(out.startsWith('GET http://f.example/ HTTP/1.1[crlf]Host: f.example[crlf]'), isTrue);
      expect(out.endsWith('CONNECT [host_port] [protocol][crlf][crlf]'), isTrue);
    });

    test('back inject sends CONNECT first', () {
      final out = generatePayload(
          PayloadSpec(method: InjectMethod.backInject, frontHosts: ['f.example'], split: SplitMode.split));
      expect(out.startsWith('CONNECT [host_port] HTTP/1.1[crlf][crlf][split]GET http://f.example/'), isTrue);
    });

    test('several hosts are rotated, dual CONNECT and split tags are valid payload tags', () {
      final out = generatePayload(PayloadSpec(
          frontHosts: ['a.example', 'b.example'], dualConnect: true, split: SplitMode.delaySplit));
      expect(out.contains('[rotate=a.example,b.example]'), isTrue);
      final parts = buildPayloadParts(out, host: 'h', port: 22);
      expect(parts.length, 2);
      expect(parts.last.text, 'CONNECT h:22 HTTP/1.1\r\n\r\n');
      expect(parts.first.delayMs, 1000);
    });

    test('generated payloads always expand without leftover generator tags', () {
      for (final m in InjectMethod.values) {
        final out = generatePayload(PayloadSpec(
            method: m, frontHosts: ['[host]'], userAgent: true, websocket: true, raw: m == InjectMethod.normal));
        final text = buildPayload(out, host: 'h', port: 22).join();
        expect(RegExp(r'\[[a-z_*]+\]').hasMatch(text), isFalse, reason: '$m -> $text');
      }
    });
  });
}
