import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/slipstream.dart';
import 'package:vpn/models.dart';

void main() {
  group('SlipstreamConfig', () {
    test('accepts resolver and authoritative endpoint forms', () {
      expect(const SlipstreamConfig(domain: 's.example.com', resolver: '1.1.1.1:53').validate(), isNull);
      expect(const SlipstreamConfig(domain: 's.example.com', resolver: '203.0.113.4:8853', mode: 'authoritative').validate(), isNull);
    });

    test('rejects missing domain, malformed endpoint, mode and certificate', () {
      expect(const SlipstreamConfig(domain: '', resolver: '1.1.1.1:53').validate(), isNotNull);
      expect(const SlipstreamConfig(domain: 's.example.com', resolver: '1.1.1.1').validate(), isNotNull);
      expect(const SlipstreamConfig(domain: 's.example.com', resolver: '1.1.1.1:53', mode: 'unknown').validate(), isNotNull);
      expect(const SlipstreamConfig(domain: 's.example.com', resolver: '1.1.1.1:53', certPem: 'not a certificate').validate(), isNotNull);
    });
  });

  group('buildSlipstreamArgs', () {
    test('uses upstream resolver-mode CLI and local TCP listener', () {
      expect(buildSlipstreamArgs(const SlipstreamConfig(domain: 's.example.com', resolver: '1.1.1.1:53'), 5100), [
        '--tcp-listen-host', '127.0.0.1',
        '--tcp-listen-port', '5100',
        '--domain', 's.example.com',
        '--resolver', '1.1.1.1:53',
      ]);
    });

    test('authoritative mode and certificate use the documented flags', () {
      expect(buildSlipstreamArgs(const SlipstreamConfig(domain: 's.example.com', resolver: '203.0.113.1:8853', mode: 'authoritative'), 5101, certPath: '/data/cert.pem'), containsAll(['--authoritative', '203.0.113.1:8853', '--cert', '/data/cert.pem']));
    });
  });

  test('profile serialization recognizes Slipstream', () {
    final profile = Profile(id: 'slip-1', name: 'DNS tunnel', type: ProfileType.slipstream, data: {
      'domain': 's.example.com', 'resolver': '1.1.1.1:53', 'mode': 'resolver'
    });
    final restored = Profile.fromJson(profile.toJson());
    expect(restored.type, ProfileType.slipstream);
    expect(restored.s('domain'), 's.example.com');
  });
}
