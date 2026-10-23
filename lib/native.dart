import 'package:flutter/services.dart';

class AppInfo {
  const AppInfo(this.label, this.package);
  final String label;
  final String package;
}

/// Bridge to MainActivity.kt (installed in CI by tools/patch_android.py).
class Native {
  static const _c = MethodChannel('xyz.xray.vpn/native');
  static const ownPackage = 'xyz.xray.vpn';

  static Future<void> moveToBack() async {
    try {
      await _c.invokeMethod('moveToBack');
    } catch (_) {}
  }

  static void Function(String link)? _onLink;

  /// Receives links that open the app while it is already running.
  static void setLinkHandler(void Function(String link) handler) {
    _onLink = handler;
    _c.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        _onLink?.call(call.arguments as String);
      }
      return null;
    });
  }

  /// The link that launched the app (vless:// ...), once.
  static Future<String?> takeLink() async {
    try {
      return await _c.invokeMethod<String>('takeLink');
    } catch (_) {
      return null;
    }
  }

  static Future<List<AppInfo>> installedApps() async {
    final r = await _c.invokeMethod<List<dynamic>>('installedApps') ?? const [];
    return [
      for (final e in r)
        AppInfo((e as Map)['label'].toString(), e['package'].toString()),
    ];
  }

  static Future<bool> ignoringBatteryOptimizations() async {
    try {
      return await _c.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _c.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openVpnSettings() async {
    try {
      return await _c.invokeMethod<bool>('openVpnSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
