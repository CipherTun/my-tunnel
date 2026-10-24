import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/config_tweaks.dart';

String _cfg({String security = 'tls', String network = 'ws', String flow = ''}) => jsonEncode({
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': 'a.example',
                'port': 443,
                'users': [
                  {'id': 'u', 'flow': flow}
                ]
              }
            ]
          },
          'streamSettings': {'network': network, 'security': security},
        },
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    });

void main() {
  extraTests();
  test('fragment adds a freedom outbound and chains the proxy through it', () {
    final out = jsonDecode(applyTweaks(_cfg(), fragment: true)) as Map;
    final outs = out['outbounds'] as List;
    final frag = outs.firstWhere((o) => o['tag'] == 'fragment') as Map;
    expect(frag['protocol'], 'freedom');
    expect(frag['settings']['fragment']['packets'], 'tlshello');
    final proxy = outs.firstWhere((o) => o['tag'] == 'proxy') as Map;
    expect(proxy['streamSettings']['sockopt']['dialerProxy'], 'fragment');
  });

  test('fragment is skipped without TLS', () {
    final out = jsonDecode(applyTweaks(_cfg(security: 'none'), fragment: true)) as Map;
    expect((out['outbounds'] as List).any((o) => o['tag'] == 'fragment'), isFalse);
  });

  test('invalid fragment ranges fall back to safe defaults', () {
    final out = jsonDecode(applyTweaks(_cfg(), fragment: true, fragLength: 'abc', fragInterval: ''))
        as Map;
    final frag = (out['outbounds'] as List).firstWhere((o) => o['tag'] == 'fragment') as Map;
    expect(frag['settings']['fragment']['length'], '100-200');
    expect(frag['settings']['fragment']['interval'], '10-20');
  });

  test('mux is enabled, but not for XTLS Vision or gRPC', () {
    final on = jsonDecode(applyTweaks(_cfg(), mux: true, muxConcurrency: 4)) as Map;
    expect((on['outbounds'] as List).first['mux'], {'enabled': true, 'concurrency': 4});
    final vision = jsonDecode(applyTweaks(_cfg(flow: 'xtls-rprx-vision'), mux: true)) as Map;
    expect((vision['outbounds'] as List).first.containsKey('mux'), isFalse);
    final grpc = jsonDecode(applyTweaks(_cfg(network: 'grpc'), mux: true)) as Map;
    expect((grpc['outbounds'] as List).first.containsKey('mux'), isFalse);
  });

  test('nothing enabled leaves the config untouched', () {
    final c = _cfg();
    expect(applyTweaks(c), c);
  });

  test('DNS patch, TCP-only mode prefixes tcp://', () {
    final out = jsonDecode(patchDnsJson('{"dns":{"servers":["x"]}}', ['8.8.8.8'], tcpOnly: true)) as Map;
    expect(out['dns']['servers'], ['tcp://8.8.8.8']);
  });

  test('WireGuard config converts to an Xray outbound', () {
    final ob = wgToOutbound('[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n'
        '[Peer]\nPublicKey = p\nEndpoint = 1.2.3.4:51820\n');
    expect(ob['protocol'], 'wireguard');
    expect(ob['settings']['peers'][0]['endpoint'], '1.2.3.4:51820');
    expect(
      ob['settings']['peers'][0]['allowedIPs'],
      ['0.0.0.0/0', '::/0'],
    );
    expect(() => wgToOutbound('[Interface]\nPrivateKey = k\n'), throwsA(isA<String>()));
  });

  test('share link builder produces a vless link', () {
    final l = buildShareLink({
      'proto': 'vless',
      'address': 'h.example',
      'port': '443',
      'id': '11111111-1111-1111-1111-111111111111',
      'network': 'ws',
      'path': '/p',
      'security': 'tls',
      'sni': 'h.example',
    }, 'name');
    expect(l.startsWith('vless://11111111-1111-1111-1111-111111111111@h.example:443'), isTrue);
    expect(l.contains('type=ws'), isTrue);
    expect(l.contains('security=tls'), isTrue);
  });
}

String _vless(String addr, {String net = 'tcp'}) => jsonEncode({
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {'address': addr, 'port': 443, 'users': [{'id': 'u'}]}
            ]
          },
          'streamSettings': {
            'network': net,
            'security': 'tls',
            'tlsSettings': {'serverName': 'real.example', 'fingerprint': 'chrome'},
          },
        },
      ],
      'routing': {'rules': [{'type': 'field', 'outboundTag': 'proxy', 'port': '1-65535'}]},
    });

void extraTests() {
  test('fragment freedom outbound has no legacy domainStrategy (Xray 26.9+)', () {
    final out = jsonDecode(applyTweaks(_vless('a.example'), fragment: true)) as Map;
    final frag = (out['outbounds'] as List).firstWhere((o) => o['tag'] == 'fragment') as Map;
    expect((frag['settings'] as Map).containsKey('domainStrategy'), isFalse);
  });

  test('uTLS fingerprint override', () {
    final out = jsonDecode(applyTweaks(_vless('a.example'), fingerprint: 'firefox')) as Map;
    final tls = (out['outbounds'] as List).first['streamSettings']['tlsSettings'] as Map;
    expect(tls['fingerprint'], 'firefox');
    expect(applyTweaks(_vless('a.example'), fingerprint: 'default'), _vless('a.example'));
  });

  test('block QUIC adds a blackhole outbound and a first routing rule', () {
    final out = jsonDecode(applyTweaks(_vless('a.example'), blockQuic: true)) as Map;
    expect((out['outbounds'] as List).any((o) => o['tag'] == 'block' && o['protocol'] == 'blackhole'), isTrue);
    final first = (out['routing']['rules'] as List).first as Map;
    expect(first['network'], 'udp');
    expect(first['port'], '443');
    expect(first['outboundTag'], 'block');
    expect((out['routing']['rules'] as List).length, 2);
  });

  test('address override replaces vnext address only', () {
    final out = jsonDecode(overrideAddress(_vless('a.example'), '104.16.1.1')) as Map;
    final ob = (out['outbounds'] as List).first as Map;
    expect(ob['settings']['vnext'][0]['address'], '104.16.1.1');
    expect(ob['streamSettings']['tlsSettings']['serverName'], 'real.example');
    expect(overrideAddress(_vless('a.example'), '  '), _vless('a.example'));
  });

  test('chain: exit dials through entry', () {
    final out = jsonDecode(chainConfigs(_vless('exit.example'), _vless('entry.example'))) as Map;
    final outs = out['outbounds'] as List;
    final proxy = outs.firstWhere((o) => o['tag'] == 'proxy') as Map;
    final entry = outs.firstWhere((o) => o['tag'] == 'entry') as Map;
    expect(proxy['settings']['vnext'][0]['address'], 'exit.example');
    expect(entry['settings']['vnext'][0]['address'], 'entry.example');
    expect(proxy['streamSettings']['sockopt']['dialerProxy'], 'entry');
  });

  test('chain refuses UDP-based hops', () {
    final hy = jsonEncode({
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'hysteria', 'settings': {}}
      ]
    });
    expect(() => chainConfigs(_vless('x'), hy), throwsA(isA<String>()));
    expect(() => chainConfigs(hy, _vless('x')), throwsA(isA<String>()));
  });

  test('OpenVPN detection and remote parsing', () {
    const ovpn = 'client\ndev tun\nproto tcp\nremote vpn.example.com 443\n';
    expect(looksLikeOvpn(ovpn), isTrue);
    expect(looksLikeOvpn('hello'), isFalse);
    final r = parseOvpnRemote(ovpn)!;
    expect((r.host, r.port, r.proto), ('vpn.example.com', 443, 'tcp'));
    final u = parseOvpnRemote('client\nremote 1.2.3.4\n')!;
    expect((u.port, u.proto), (1194, 'udp'));
    final inline = parseOvpnRemote('client\nproto udp\nremote h 1194 tcp-client\n')!;
    expect(inline.proto, 'tcp');
    expect(parseOvpnRemote('client\n'), isNull);
  });

  test('CIDR sampling stays inside the ranges', () {
    final ips = sampleCidrs(['10.1.2.0/24', 'garbage', '192.168.0.0/30'], 40, seed: 7);
    expect(ips, isNotEmpty);
    for (final ip in ips) {
      expect(ip.startsWith('10.1.2.') || ip.startsWith('192.168.0.'), isTrue, reason: ip);
    }
    expect(ips.toSet().length, ips.length);
    expect(sampleCidrs(['nope'], 5), isEmpty);
  });
}
