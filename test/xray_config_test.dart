import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xray_vpn/models.dart';
import 'package:xray_vpn/xray_config.dart';

void main() {
  test('SSH profile uses Xray TUN and SOCKS outbound', () {
    final config = buildXrayVpnConfig(
      profile: ServerProfile(id: 'ssh', name: 'SSH', kind: ProfileKind.ssh, data: {'host': 'example.net'}),
      preferences: AppPreferences(),
      importedOutbounds: const [],
    );
    expect((config['inbounds'] as List).first['protocol'], 'tun');
    expect((config['outbounds'] as List).first['protocol'], 'socks');
    expect((config['outbounds'] as List).first['settings']['servers'][0]['port'], 10808);
    expect((config['inbounds'] as List).any((e) => e['tag'] == 'diagnostics-http'), isTrue);
  });

  test('Xray profile routes TUN and local diagnostics to selected outbound', () {
    final config = buildXrayVpnConfig(
      profile: ServerProfile(id: 'xray', name: 'Xray', kind: ProfileKind.xray),
      preferences: AppPreferences(),
      importedOutbounds: const [{'tag': 'proxy', 'protocol': 'vless', 'settings': {}}],
    );
    final rules = (config['routing'] as Map)['rules'] as List;
    expect(rules, hasLength(2));
    final diagnosticRule = rules.firstWhere((rule) => (rule['inboundTag'] as List).contains('diagnostics-http'));
    final tunRule = rules.firstWhere((rule) => (rule['inboundTag'] as List).contains('tun-in'));
    expect(diagnosticRule['outboundTag'], 'proxy');
    expect(tunRule['outboundTag'], 'proxy');
  });

  test('raw JSON normalization replaces inbounds and preserves proxy outbound', () {
    final result = jsonDecode(normalizeRawXrayJson('{"inbounds":[{"protocol":"socks"}],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{}}]}', AppPreferences())) as Map;
    expect((result['inbounds'] as List).first['protocol'], 'tun');
    expect((result['outbounds'] as List).first['protocol'], 'vless');
  });
}
