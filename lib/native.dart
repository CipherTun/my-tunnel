import 'dart:typed_data';
import 'package:flutter/services.dart';

class AppInfo {
  AppInfo(this.package, this.label);
  final String package;
  final String label;
}

/// Thin wrapper around the Kotlin MethodChannel written by tools/patch_android.py.
class Native {
  static const _c = MethodChannel('xyz.xray.vpn/system');

  static Future<List<AppInfo>> listApps() async {
    try {
      final r = await _c.invokeListMethod<Map>('listApps') ?? const [];
      return [
        for (final m in r) AppInfo('${m['package']}', '${m['label']}'),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<Uint8List?> icon(String package) async {
    try {
      return await _c.invokeMethod<Uint8List>('appIcon', package);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _bool(String m) async {
    try {
      return await _c.invokeMethod<bool>(m) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openVpnSettings() => _bool('openVpnSettings');
  static Future<bool> ignoringBatteryOptimizations() => _bool('isIgnoringBattery');
  static Future<bool> openBatterySettings() => _bool('openBatterySettings');
  static Future<bool> requestNotifications() => _bool('requestNotifications');
}
