import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/models.dart';
import 'package:vpn/usage.dart';

void main() {
  test('usage accumulates per day and per profile', () {
    final u = UsageStore();
    final day = DateTime(2026, 10, 23);
    u.add('A', 100, 200, at: day);
    u.add('A', 50, 50, at: day);
    u.add('B', 10, 10, at: day.subtract(const Duration(days: 3)));
    expect(u.total(days: 1, now: day), [150, 250]);
    expect(u.total(days: 7, now: day), [160, 260]);
    expect(u.byProfile(days: 30, now: day)['A'], [150, 250]);
    u.add('A', -5, 0, at: day); // negatives are ignored
    expect(u.total(days: 1, now: day), [150, 250]);
  });

  test('usage survives a JSON round trip and trims old days', () {
    final u = UsageStore();
    final now = DateTime(2026, 10, 23);
    u.add('A', 1, 2, at: now);
    u.add('A', 9, 9, at: now.subtract(const Duration(days: 200)));
    u.trim(now: now);
    final v = UsageStore()..loadJson(u.toJson());
    expect(v.total(days: 1, now: now), [1, 2]);
    expect(v.total(days: 365, now: now), [1, 2]);
  });

  test('new profile types import and describe themselves', () {
    final o = importProfile('client\ndev tun\nproto udp\nremote 5.6.7.8 1194\n')!;
    expect(o.type, ProfileType.openvpn);
    expect(o.subtitle, 'OpenVPN 5.6.7.8:1194 UDP');
    expect(typeLabel(ProfileType.chain), contains('Chain'));
  });

  test('AppSettings keeps the new fields through JSON', () {
    final s = AppSettings()
      ..fingerprint = 'firefox'
      ..blockQuic = true
      ..autoUpdateSubs = false;
    final r = AppSettings.fromJson(s.toJson());
    expect((r.fingerprint, r.blockQuic, r.autoUpdateSubs), ('firefox', true, false));
    expect(AppSettings.fromJson({}).fingerprint, 'default');
  });
}
