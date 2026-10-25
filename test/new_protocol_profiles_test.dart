import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/models.dart';

void main() {
  test('OpenConnect profile serializes without changing its type', () {
    final p = Profile(id: 'oc-1', name: 'Office', type: ProfileType.openconnect, data: {
      'gateway': 'https://vpn.example.org',
      'user': 'alice',
      'noDtls': true,
    });
    final restored = Profile.fromJson(p.toJson());
    expect(restored.type, ProfileType.openconnect);
    expect(restored.s('gateway'), 'https://vpn.example.org');
    expect(restored.b('noDtls'), isTrue);
  });

  test('Psiphon profile serializes configuration without inventing server entries', () {
    final p = Profile(id: 'psi-1', name: 'Psiphon', type: ProfileType.psiphon, data: {
      'configJson': '{"SponsorId":"provided-by-deployment"}',
      'embeddedServerEntries': '',
      'region': 'US',
    });
    final restored = Profile.fromJson(p.toJson());
    expect(restored.type, ProfileType.psiphon);
    expect(restored.s('configJson'), contains('SponsorId'));
    expect(restored.s('embeddedServerEntries'), isEmpty);
  });
}
