import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/dnstt.dart';
import 'package:vpn/models.dart';
import 'package:vpn/ssh_tunnel.dart';

const _key = '0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff';

DnsttConfig _cfg({
  String domain = 't.example.com',
  String key = _key,
  String mode = 'udp',
  String resolver = '8.8.8.8:53',
}) =>
    DnsttConfig(domain: domain, pubKey: key, mode: mode, resolver: resolver);

void main() {
  group('DnsttConfig.validate', () {
    test('accepts the documented forms', () {
      expect(_cfg().validate(), isNull);
      expect(_cfg(mode: 'dot', resolver: '1.1.1.1:853').validate(), isNull);
      expect(_cfg(mode: 'doh', resolver: 'https://1.1.1.1/dns-query').validate(), isNull);
      expect(_cfg(resolver: 'dns.example.net:53').validate(), isNull);
    });

    test('rejects a bad domain', () {
      expect(_cfg(domain: '').validate(), isNotNull);
      expect(_cfg(domain: 'localhost').validate(), isNotNull);
      expect(_cfg(domain: 'bad domain.com').validate(), isNotNull);
      expect(_cfg(domain: '-x.example.com').validate(), isNotNull);
    });

    test('public key must be exactly 64 hex characters', () {
      expect(_cfg(key: '').validate(), isNotNull);
      expect(_cfg(key: _key.substring(1)).validate(), isNotNull);
      expect(_cfg(key: '${_key}0').validate(), isNotNull);
      expect(_cfg(key: 'z' * 64).validate(), isNotNull);
      expect(_cfg(key: _key.toUpperCase()).validate(), isNull);
    });

    test('resolver checks per transport', () {
      expect(_cfg(resolver: '8.8.8.8').validate(), isNotNull);
      expect(_cfg(resolver: '8.8.8.8:0').validate(), isNotNull);
      expect(_cfg(resolver: '8.8.8.8:70000').validate(), isNotNull);
      expect(_cfg(resolver: ':53').validate(), isNotNull);
      expect(_cfg(mode: 'doh', resolver: 'http://1.1.1.1/dns-query').validate(), isNotNull);
      expect(_cfg(mode: 'doh', resolver: '1.1.1.1:443').validate(), isNotNull);
      expect(_cfg(mode: 'quic').validate(), isNotNull);
    });
  });

  group('buildDnsttArgs', () {
    test('plain UDP matches the dnstt-client command line', () {
      expect(buildDnsttArgs(_cfg(), 7000), [
        '-udp',
        '8.8.8.8:53',
        '-pubkey',
        _key,
        't.example.com',
        '127.0.0.1:7000',
      ]);
    });

    test('DoH and DoT use their own flag', () {
      expect(buildDnsttArgs(_cfg(mode: 'doh', resolver: 'https://1.1.1.1/dns-query'), 7001).first,
          '-doh');
      expect(buildDnsttArgs(_cfg(mode: 'dot', resolver: '1.1.1.1:853'), 7002).first, '-dot');
    });

    test('flags come before the positional DOMAIN and LOCALADDR', () {
      final a = buildDnsttArgs(_cfg(), 7003);
      expect(a[a.length - 2], 't.example.com');
      expect(a.last, '127.0.0.1:7003');
      expect(a.indexOf('-pubkey'), lessThan(a.indexOf('t.example.com')));
    });

    test('a resolved resolver replaces the configured one', () {
      final a = buildDnsttArgs(_cfg(resolver: 'dns.example.net:53'), 7004, resolver: '9.9.9.9:53');
      expect(a[1], '9.9.9.9:53');
    });
  });

  group('SSH profile with DNSTT', () {
    test('host key falls back to the tunnel domain when the host is empty', () {
      final p = Profile(id: 'a', name: 'n', type: ProfileType.ssh, data: {
        'dnstt': true,
        'dnsttDomain': 't.example.com',
        'port': '22',
      });
      expect(p.hostKey, 't.example.com:22');
      expect(p.subtitle, contains('DNSTT'));
      expect(p.subtitle, contains('t.example.com'));
    });

    test('host key is unchanged without DNSTT', () {
      final p = Profile(id: 'a', name: 'n', type: ProfileType.ssh, data: {
        'host': '1.2.3.4',
        'port': '2222',
      });
      expect(p.hostKey, '1.2.3.4:2222');
    });

    test('viaLocalPort keeps the login and drops proxy / TLS / payload / WS', () {
      final o = SshOptions(
        host: 'ignored',
        port: 22,
        user: 'u',
        pass: 'p',
        payload: 'GET / HTTP/1.1',
        proxyHost: 'proxy',
        useTls: true,
        sni: 'x.example',
        wsFraming: true,
        udpgwPort: 7300,
        dnstt: _cfg(),
      );
      final v = o.viaLocalPort(7005);
      expect((v.host, v.port, v.user, v.pass), ('127.0.0.1', 7005, 'u', 'p'));
      expect(v.payload, isEmpty);
      expect(v.proxyHost, isEmpty);
      expect(v.useTls, isFalse);
      expect(v.wsFraming, isFalse);
      expect(v.udpgwPort, 7300);
      expect(v.dnstt, isNull);
    });
  });
}
