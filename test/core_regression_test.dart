import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/models.dart';
import 'package:vpn/ssh_tunnel.dart';
import 'package:vpn/singbox_config.dart';
import 'dart:convert';

void main() {
  group('SSH payload expansion', () {
    test('expands host, port and CRLF tokens', () {
      final chunks = buildPayload(
        'CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]',
        host: 'edge.example.net',
        port: 443,
      );
      expect(chunks, [
        'CONNECT edge.example.net:443 HTTP/1.1\r\n'
            'Host: edge.example.net\r\n\r\n'
      ]);
    });

    test('splits payload at explicit split marker', () {
      final chunks = buildPayload(
        'A[split]B',
        host: 'example.net',
        port: 22,
      );
      expect(chunks, ['A', 'B']);
    });
  });

  group('connection input validation', () {
    test('accepts valid ports and rejects invalid ports', () {
      expect(() => validatePort(1, 'SSH port'), returnsNormally);
      expect(() => validatePort(65535, 'SSH port'), returnsNormally);
      expect(() => validatePort(0, 'SSH port'), throwsA(isA<String>()));
      expect(() => validatePort(65536, 'SSH port'), throwsA(isA<String>()));
    });
  });

  group('settings normalization', () {
    test('clamps persisted socket and retry settings to valid ranges', () {
      final settings = AppSettings.fromJson({
        'socksPort': 70000,
        'sshKeepalive': -3,
        'reconnectMax': 999,
      });
      expect(settings.socksPort, 65535);
      expect(settings.sshKeepalive, 0);
      expect(settings.reconnectMax, 20);
      expect(settings.coreEngine, 'xray');
      expect(AppSettings.fromJson({'coreEngine':'singbox'}).coreEngine, 'singbox');
    });

    test('persists LAN proxy authentication without enabling sharing by default', () {
      final settings = AppSettings.fromJson({
        'shareHotspot': true,
        'shareUsername': 'client',
        'sharePassword': 'a-long-unique-password',
      });
      expect(settings.shareHotspot, isTrue);
      expect(settings.shareUsername, 'client');
      expect(settings.sharePassword, 'a-long-unique-password');
      expect(AppSettings().shareHotspot, isFalse);
    });
  });

  group('sing-box config generation', () {
    test('builds a real VLESS WebSocket TLS outbound and VPN TUN inbound', () {
      final p = importProfile(
        'vless://123e4567-e89b-12d3-a456-426614174000@example.net:443'
        '?type=ws&security=tls&sni=example.net&host=cdn.example.net&path=%2Fws#singbox-test',
      )!;
      final config = jsonDecode(buildSingboxConfig(p, AppSettings())) as Map<String, dynamic>;
      final inbound = (config['inbounds'] as List).first as Map;
      final outbound = (config['outbounds'] as List).first as Map;
      expect(inbound['type'], 'tun');
      expect(inbound['auto_route'], true);
      expect(outbound['type'], 'vless');
      expect(outbound['uuid'], '123e4567-e89b-12d3-a456-426614174000');
      expect((outbound['transport'] as Map)['type'], 'ws');
      expect((outbound['tls'] as Map)['enabled'], true);
    });

    test('rejects Xray JSON instead of treating it as sing-box JSON', () {
      final p = Profile(id: 'raw', name: 'Xray JSON', type: ProfileType.v2ray,
        data: {'mode':'json','json':jsonEncode({'outbounds':[{'protocol':'freedom'}]})});
      expect(() => buildSingboxConfig(p, AppSettings()), throwsA(isA<String>()));
    });

    test('rejects unsupported transports instead of silently downgrading', () {
      final p = importProfile(
        'vless://123e4567-e89b-12d3-a456-426614174000@example.net:443?type=kcp&security=none',
      )!;
      expect(() => buildSingboxConfig(p, AppSettings()), throwsA(isA<String>()));
    });
  });

  group('profile import validation', () {
    test('imports a VLESS share link without inventing fields', () {
      final profile = importProfile(
        'vless://123e4567-e89b-12d3-a456-426614174000@example.net:443'
        '?type=ws&security=tls#test',
      );
      expect(profile, isNotNull);
      expect(profile!.type, ProfileType.v2ray);
      expect(profile.s('mode'), 'link');
      expect(profile.s('link'), contains('vless://'));
    });

    test('rejects unsupported or empty input', () {
      expect(importProfile(''), isNull);
      expect(importProfile('unknown://host'), isNull);
    });

    test('requires complete SSH host and username only at connection time', () {
      final profile = importProfile('ssh://alice:secret@example.net:22');
      expect(profile, isNotNull);
      expect(profile!.s('host'), 'example.net');
      expect(profile.s('user'), 'alice');
      expect(profile.s('pass'), 'secret');
    });
  });
}
