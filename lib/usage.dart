import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Data-usage log: bytes up/down per day per profile. Stored in preferences
/// (no secrets inside) and trimmed to the last 90 days.
class UsageStore {
  static const _k = 'usage_v1';

  /// day (yyyy-MM-dd) -> profileName -> [up, down]
  final Map<String, Map<String, List<int>>> data = {};

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void add(String profile, int up, int down, {DateTime? at}) {
    if (up <= 0 && down <= 0) return;
    final day = data.putIfAbsent(dayKey(at ?? DateTime.now()), () => {});
    final e = day.putIfAbsent(profile, () => [0, 0]);
    e[0] += up < 0 ? 0 : up;
    e[1] += down < 0 ? 0 : down;
  }

  /// Totals [up, down] for the last [days] days including today.
  List<int> total({int days = 1, DateTime? now}) {
    final n = now ?? DateTime.now();
    var up = 0, down = 0;
    for (var i = 0; i < days; i++) {
      final d = data[dayKey(DateTime(n.year, n.month, n.day - i))];
      if (d == null) continue;
      for (final v in d.values) {
        up += v[0];
        down += v[1];
      }
    }
    return [up, down];
  }

  /// profile -> [up, down] over the last [days] days.
  Map<String, List<int>> byProfile({int days = 30, DateTime? now}) {
    final n = now ?? DateTime.now();
    final out = <String, List<int>>{};
    for (var i = 0; i < days; i++) {
      final d = data[dayKey(DateTime(n.year, n.month, n.day - i))];
      if (d == null) continue;
      d.forEach((k, v) {
        final e = out.putIfAbsent(k, () => [0, 0]);
        e[0] += v[0];
        e[1] += v[1];
      });
    }
    return out;
  }

  void trim({int keepDays = 90, DateTime? now}) {
    final n = now ?? DateTime.now();
    final oldest = dayKey(DateTime(n.year, n.month, n.day - keepDays));
    data.removeWhere((k, _) => k.compareTo(oldest) < 0);
  }

  Map<String, dynamic> toJson() => data.map((d, m) => MapEntry(d, m));

  void loadJson(Map<String, dynamic> j) {
    data.clear();
    j.forEach((d, m) {
      final day = <String, List<int>>{};
      (m as Map).forEach((k, v) => day[k.toString()] = (v as List).map((e) => (e as num).toInt()).toList());
      data[d] = day;
    });
  }

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_k);
    if (raw == null) return;
    try {
      loadJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  Future<void> save() async {
    trim();
    await (await SharedPreferences.getInstance()).setString(_k, jsonEncode(toJson()));
  }

  Future<void> clear() async {
    data.clear();
    await save();
  }
}
