import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xray_vpn/legacy_vmess.dart';

void main() {
  test('converts a legacy VMess QR JSON link into a valid Xray outbound shape', () {
    final legacy = base64Encode(utf8.encode(jsonEncode({
      'add': 'edge.example.net', 'port': '443', 'id': '00000000-0000-4000-8000-000000000001',
      'aid': '0', 'net': 'ws', 'type': 'none', 'host': 'front.example.net', 'path': '/ws', 'tls': 'tls', 'sni': 'front.example.net', 'scy': 'auto',
    })));
    final result = legacyVmessToXrayJson('vmess://$legacy');
    expect(result, isNotNull);
    final json = jsonDecode(result!) as Map;
    final outbound = (json['outbounds'] as List).single as Map;
    expect(outbound['protocol'], 'vmess');
    expect(outbound['streamSettings']['network'], 'ws');
    expect(outbound['streamSettings']['security'], 'tls');
    expect(outbound['streamSettings']['wsSettings']['path'], '/ws');
  });

  test('does not misclassify VMess AEAD URIs as legacy QR JSON', () {
    expect(legacyVmessToXrayJson('vmess://uuid@example.net:443?type=ws'), isNull);
  });
}
