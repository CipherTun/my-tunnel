import 'dart:convert';

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

  /// Directory where Android extracted native payloads. DNSTT and Slipstream
  /// executables are stored here under libdnstt.so / libslipstream.so.
  static Future<String?> nativeLibraryDir() async {
    try {
      return await _c.invokeMethod<String>('nativeLibraryDir');
    } catch (_) {
      return null;
    }
  }


  static Future<String> libXrayInvoke(String request) async {
    final result = await _c.invokeMethod<String>('libXrayInvoke', {'request': request});
    if (result == null || result.isEmpty) throw 'LibXray returned an empty response';
    return result;
  }

  static Future<bool> requestVpnPermission() async {
    return await _c.invokeMethod<bool>('requestVpnPermission') ?? false;
  }

  static Future<void> startXray({
    required String config,
    required String remark,
    required bool proxyOnly,
    required List<String> disallowedApps,
    required bool bypassLan,
  }) async {
    await _c.invokeMethod<void>('startXray', {
      'config': config,
      'remark': remark,
      'proxyOnly': proxyOnly,
      'disallowedApps': disallowedApps,
      'bypassLan': bypassLan,
    });
  }

  static Future<void> stopXray() async {
    try {
      await _c.invokeMethod<void>('stopXray');
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> xrayState() async {
    final value = await _c.invokeMethod<Map<dynamic, dynamic>>('xrayState');
    return value?.map((k, v) => MapEntry(k.toString(), v)) ?? const {};
  }

  static Future<int> pingXray(String config, {String url = 'https://cp.cloudflare.com/generate_204'}) async {
    final request = <String, dynamic>{
      'apiVersion': 3,
      'method': 'pingBatch',
      'payload': {
        'configs': [{'xrayJson': config}],
        'timeout': 5,
        'url': url,
      },
    };
    final response = await libXrayInvoke(jsonEncode(request));
    final root = jsonDecode(response) as Map<String, dynamic>;
    if (root['success'] != true) throw root['error'] ?? 'LibXray ping failed';
    dynamic data = root['data'];
    if (data is String) data = jsonDecode(data);
    if (data is! Map || data['results'] is! List || (data['results'] as List).isEmpty) {
      throw 'LibXray returned no ping result';
    }
    final first = (data['results'] as List).first;
    if (first is! Map || first['success'] != true) {
      throw (first is Map ? first['error'] : null) ?? 'Server probe failed';
    }
    return (first['delay'] as num?)?.toInt() ?? -1;
  }

  static Future<String> xrayVersion() async {
    final response = await libXrayInvoke(jsonEncode({'apiVersion': 3, 'method': 'xrayVersion'}));
    final root = jsonDecode(response) as Map<String, dynamic>;
    if (root['success'] != true) throw root['error'] ?? 'Unable to get Xray version';
    dynamic data = root['data'];
    if (data is String) data = jsonDecode(data);
    return data is Map ? (data['version'] ?? 'unknown').toString() : 'unknown';
  }

  /// Start a native OpenConnect engine. The Android side must report real state
  /// and must not mark the tunnel connected before its TUN and core are active.
  static Future<void> startOpenConnect(Map<String, dynamic> profile) async {
    await _c.invokeMethod<void>('startOpenConnect', {'profile': profile});
  }

  /// Start Psiphon in its own Android process, separate from LibXray's Go runtime.
  static Future<void> startPsiphon(Map<String, dynamic> profile) async {
    await _c.invokeMethod<void>('startPsiphon', {'profile': profile});
  }

  static Future<Map<String, dynamic>> externalEngineState(String engine) async {
    final value = await _c.invokeMethod<Map<dynamic, dynamic>>('externalEngineState', {'engine': engine});
    return value?.map((k, v) => MapEntry(k.toString(), v)) ?? const {};
  }

  static Future<void> stopExternalEngine(String engine) async {
    await _c.invokeMethod<void>('stopExternalEngine', {'engine': engine});
  }

  static Future<bool> openVpnSettings() async {
    try {
      return await _c.invokeMethod<bool>('openVpnSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
