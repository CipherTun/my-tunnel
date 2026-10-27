import 'dart:convert';

import 'package:flutter/services.dart';

class NativeVpnBridge {
  static const MethodChannel _methods = MethodChannel('xyz.xray.vpn/control');
  static const EventChannel _events = EventChannel('xyz.xray.vpn/events');

  Stream<Map<String, dynamic>> get events => _events.receiveBroadcastStream().map((event) =>
      Map<String, dynamic>.from(event as Map));

  Future<bool> prepareVpn() async => await _methods.invokeMethod<bool>('prepareVpn') ?? false;

  Future<void> startVpn({required String config, required bool excludeApp, String bypassApps = '', bool useTun = true}) async {
    await _methods.invokeMethod<void>('startVpn', {'config': config, 'excludeApp': excludeApp, 'bypassApps': bypassApps, 'useTun': useTun});
  }

  Future<void> stopVpn() async => _methods.invokeMethod<void>('stopVpn');

  Future<Map<String, dynamic>> invokeLibXray(String method, [Map<String, dynamic> payload = const {}]) async {
    final request = jsonEncode({'apiVersion': 3, 'method': method, 'payload': payload});
    final response = await _methods.invokeMethod<String>('invokeLibXray', {'request': request});
    if (response == null) throw StateError('libXray returned no response');
    final decoded = Map<String, dynamic>.from(jsonDecode(response) as Map);
    if (decoded['success'] != true) throw StateError((decoded['error'] ?? 'libXray request failed').toString());
    return decoded;
  }

  Future<String?> takeInitialLink() => _methods.invokeMethod<String>('takeInitialLink');

  Future<bool> openSystemSettings(String page) async => await _methods.invokeMethod<bool>('openSystemSettings', {'page': page}) ?? false;

  Future<List<Map<String, dynamic>>> listApps() async {
    final apps = await _methods.invokeMethod<List<dynamic>>('listApps') ?? const [];
    return apps.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }

  Future<List<String>> readLogs() async {
    final value = await _methods.invokeMethod<List<dynamic>>('readLogs') ?? const [];
    return value.map((e) => e.toString()).toList();
  }
}
