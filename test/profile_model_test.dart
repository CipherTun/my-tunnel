import 'package:flutter_test/flutter_test.dart';
import 'package:xray_vpn/models.dart';

void main() {
  test('imports SSH share URI without losing authentication fields', () {
    final profile = parseSimpleProfile('ssh://demo:secret@example.net:2222#Primary');
    expect(profile, isNotNull);
    expect(profile!.kind, ProfileKind.ssh);
    expect(profile.name, 'Primary');
    expect(profile.text('host'), 'example.net');
    expect(profile.text('port'), '2222');
    expect(profile.text('username'), 'demo');
    expect(profile.text('password'), 'secret');
  });

  test('imports raw Xray JSON as an Xray profile', () {
    final profile = parseSimpleProfile('{"outbounds":[{"protocol":"freedom"}]}');
    expect(profile, isNotNull);
    expect(profile!.kind, ProfileKind.xray);
    expect(profile.text('json'), contains('outbounds'));
  });

  test('serializes profile fields', () {
    final original = ServerProfile(id: 'abc', name: 'Node', kind: ProfileKind.ssh, data: {'host': 'host.test', 'password': 'sensitive'});
    final restored = ServerProfile.fromJson(original.toJson());
    expect(restored.id, 'abc');
    expect(restored.text('host'), 'host.test');
    expect(restored.text('password'), 'sensitive');
  });
}
