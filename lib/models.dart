import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

String makeId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';
int _idCounter = 0;

enum ProfileKind { ssh, xray, chain, group }

extension ProfileKindLabel on ProfileKind {
  String get label => switch (this) { ProfileKind.ssh => 'SSH Tunnel', ProfileKind.xray => 'Xray', ProfileKind.chain => 'Proxy Chain', ProfileKind.group => 'Failover Group' };
}

class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.kind,
    Map<String, dynamic>? data,
  }) : data = data ?? <String, dynamic>{};

  final String id;
  String name;
  ProfileKind kind;
  Map<String, dynamic> data;

  String text(String key, [String fallback = '']) => (data[key] ?? fallback).toString();
  bool flag(String key, [bool fallback = false]) => data[key] is bool ? data[key] as bool : fallback;

  String get subtitle {
    if (kind == ProfileKind.group) {
      final members = (data['members'] as List?)?.length ?? 0;
      return '$members servers, tried in order';
    }
    if (kind == ProfileKind.chain) return 'Entry → Exit Xray proxy chain';
    if (kind == ProfileKind.ssh) {
      final host = text('host');
      final port = text('port', '22');
      final features = <String>[
        if (flag('tls')) 'TLS/SNI',
        if (flag('websocket')) 'WebSocket',
        if (text('payload').trim().isNotEmpty) 'Payload',
        if (text('proxyHost').trim().isNotEmpty) 'Upstream proxy',
      ];
      return 'SSH $host:$port${features.isEmpty ? '' : ' · ${features.join(' · ')}'}';
    }
    if (text('json').trim().isNotEmpty) return 'Xray JSON configuration';
    final link = text('link');
    if (link.contains('://')) {
      final uri = Uri.tryParse(link);
      final label = uri?.scheme.toUpperCase() ?? 'Xray';
      if (uri?.scheme == 'vmess' && (uri?.host.length ?? 0) > 64) return 'VMess share link';
      return '$label share link';
    }
    return 'Xray profile';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'data': data,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: (json['id'] ?? makeId()).toString(),
        name: (json['name'] ?? 'Server').toString(),
        kind: ProfileKind.values.firstWhere(
          (kind) => kind.name == json['kind'],
          orElse: () => ProfileKind.xray,
        ),
        data: Map<String, dynamic>.from((json['data'] as Map?) ?? const {}),
      );
}

class SubscriptionSource {
  SubscriptionSource({required this.id, required this.name, required this.url, this.lastRefresh, this.profileCount = 0});
  final String id;
  String name;
  String url;
  DateTime? lastRefresh;
  int profileCount;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'lastRefresh': lastRefresh?.toIso8601String(), 'profileCount': profileCount};
  factory SubscriptionSource.fromJson(Map<String, dynamic> json) => SubscriptionSource(
    id: (json['id'] ?? makeId()).toString(),
    name: (json['name'] ?? json['url'] ?? 'Subscription').toString(),
    url: (json['url'] ?? '').toString(),
    lastRefresh: DateTime.tryParse((json['lastRefresh'] ?? '').toString()),
    profileCount: (json['profileCount'] as num?)?.toInt() ?? 0,
  );
}

class AppPreferences {
  String theme = 'system';
  int accent = 0xFF147D76;
  bool autoReconnect = true;
  int maxReconnectAttempts = 5;
  bool healthCheck = true;
  bool autoConnect = false;
  bool bypassLan = false;
  bool proxyOnly = false;
  bool blockQuic = false;
  bool autoUpdateSubscriptions = true;
  String dnsMode = 'cloudflare';
  String customDns = '1.1.1.1';
  String logLevel = 'warning';
  int sshKeepaliveSeconds = 20;
  String socksBindAddress = '127.0.0.1';
  int socksPort = 10808;
  bool shareProxy = false;
  String hotspotUser = 'xrayvpn';
  String hotspotPassword = '';
  String appBypassList = '';
  String speedTestUrl = 'https://speed.cloudflare.com/__down?bytes=10000000';

  Map<String, dynamic> toJson() => {
        'theme': theme,
        'accent': accent,
        'autoReconnect': autoReconnect,
        'maxReconnectAttempts': maxReconnectAttempts,
        'healthCheck': healthCheck,
        'autoConnect': autoConnect,
        'bypassLan': bypassLan,
        'proxyOnly': proxyOnly,
        'blockQuic': blockQuic,
        'autoUpdateSubscriptions': autoUpdateSubscriptions,
        'dnsMode': dnsMode,
        'customDns': customDns,
        'logLevel': logLevel,
        'sshKeepaliveSeconds': sshKeepaliveSeconds,
        'socksBindAddress': socksBindAddress,
        'socksPort': socksPort,
        'shareProxy': shareProxy,
        'hotspotUser': hotspotUser,
        'hotspotPassword': hotspotPassword,
        'appBypassList': appBypassList,
        'speedTestUrl': speedTestUrl,
      };

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    final p = AppPreferences();
    p.theme = (json['theme'] ?? p.theme).toString();
    p.accent = (json['accent'] as num?)?.toInt() ?? p.accent;
    p.autoReconnect = json['autoReconnect'] as bool? ?? p.autoReconnect;
    p.maxReconnectAttempts = (json['maxReconnectAttempts'] as num?)?.toInt() ?? p.maxReconnectAttempts;
    p.healthCheck = json['healthCheck'] as bool? ?? p.healthCheck;
    p.autoConnect = json['autoConnect'] as bool? ?? p.autoConnect;
    p.bypassLan = json['bypassLan'] as bool? ?? p.bypassLan;
    p.proxyOnly = json['proxyOnly'] as bool? ?? p.proxyOnly;
    p.blockQuic = json['blockQuic'] as bool? ?? p.blockQuic;
    p.autoUpdateSubscriptions = json['autoUpdateSubscriptions'] as bool? ?? p.autoUpdateSubscriptions;
    p.dnsMode = (json['dnsMode'] ?? p.dnsMode).toString();
    p.customDns = (json['customDns'] ?? p.customDns).toString();
    p.logLevel = (json['logLevel'] ?? p.logLevel).toString();
    p.sshKeepaliveSeconds = (json['sshKeepaliveSeconds'] as num?)?.toInt() ?? p.sshKeepaliveSeconds;
    p.socksBindAddress = (json['socksBindAddress'] ?? p.socksBindAddress).toString();
    p.socksPort = (json['socksPort'] as num?)?.toInt() ?? p.socksPort;
    p.shareProxy = json['shareProxy'] as bool? ?? p.shareProxy;
    p.hotspotUser = (json['hotspotUser'] ?? p.hotspotUser).toString();
    p.hotspotPassword = (json['hotspotPassword'] ?? p.hotspotPassword).toString();
    p.appBypassList = (json['appBypassList'] ?? p.appBypassList).toString();
    p.speedTestUrl = (json['speedTestUrl'] ?? p.speedTestUrl).toString();
    return p;
  }
}

class SecureStore {
  SecureStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _profilesKey = 'xrayvpn.profiles.v1';
  static const _settingsKey = 'xrayvpn.settings.v1';
  static const _hostPinsKey = 'xrayvpn.hostPins.v1';
  static const _subscriptionsKey = 'xrayvpn.subscriptions.v1';
  static const _usageKey = 'xrayvpn.usage.v1';

  Future<List<ServerProfile>> loadProfiles() async {
    final raw = await _storage.read(key: _profilesKey);
    if (raw == null || raw.isEmpty) return <ServerProfile>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <ServerProfile>[];
    return decoded.whereType<Map>().map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<void> saveProfiles(List<ServerProfile> profiles) =>
      _storage.write(key: _profilesKey, value: jsonEncode(profiles.map((p) => p.toJson()).toList()));

  Future<AppPreferences> loadPreferences() async {
    final raw = await _storage.read(key: _settingsKey);
    if (raw == null) return AppPreferences();
    return AppPreferences.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }

  Future<void> savePreferences(AppPreferences preferences) =>
      _storage.write(key: _settingsKey, value: jsonEncode(preferences.toJson()));

  Future<List<SubscriptionSource>> loadSubscriptions() async {
    final raw = await _storage.read(key: _subscriptionsKey);
    if (raw == null || raw.isEmpty) return <SubscriptionSource>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <SubscriptionSource>[];
    return decoded.whereType<Map>().map((e) => SubscriptionSource.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<void> saveSubscriptions(List<SubscriptionSource> sources) =>
      _storage.write(key: _subscriptionsKey, value: jsonEncode(sources.map((s) => s.toJson()).toList()));

  Future<List<Map<String, dynamic>>> loadUsageHistory() async {
    final raw = await _storage.read(key: _usageKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Map<String, dynamic>>[];
    return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> saveUsageHistory(List<Map<String, dynamic>> history) =>
      _storage.write(key: _usageKey, value: jsonEncode(history));

  Future<Map<String, String>> loadHostPins() async {
    final raw = await _storage.read(key: _hostPinsKey);
    if (raw == null) return <String, String>{};
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> saveHostPin(String host, String fingerprint) async {
    final pins = await loadHostPins();
    pins[host] = fingerprint;
    await _storage.write(key: _hostPinsKey, value: jsonEncode(pins));
  }

  Future<void> clearHostPins() => _storage.delete(key: _hostPinsKey);
}

ServerProfile? parseSimpleProfile(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('{')) {
    try {
      final value = jsonDecode(text);
      if (value is Map && value['outbounds'] is List) {
        return ServerProfile(id: makeId(), name: 'Xray JSON', kind: ProfileKind.xray, data: {'json': text});
      }
      if (value is Map && value['kind'] != null && value['data'] is Map) {
        return ServerProfile.fromJson(Map<String, dynamic>.from(value));
      }
    } catch (_) {
      return null;
    }
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme.toLowerCase() == 'ssh') {
    final auth = uri.userInfo.split(':');
    return ServerProfile(
      id: makeId(),
      name: uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : uri.host,
      kind: ProfileKind.ssh,
      data: {
        'host': uri.host,
        'port': (uri.hasPort ? uri.port : 22).toString(),
        'username': auth.isNotEmpty ? Uri.decodeComponent(auth.first) : '',
        'password': auth.length > 1 ? Uri.decodeComponent(auth.sublist(1).join(':')) : '',
        'privateKey': '',
        'keyPassphrase': '',
        'payload': '',
        'tls': false,
        'sni': uri.host,
        'websocket': false,
        'wsPath': '/',
        'wsHost': '',
        'proxyHost': '',
        'proxyPort': '8080',
        'udpgwPort': '7300',
      },
    );
  }
  const supported = {'vless', 'vmess', 'trojan', 'ss', 'hysteria2', 'hy2'};
  if (supported.contains(uri.scheme.toLowerCase())) {
    return ServerProfile(id: makeId(), name: uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : uri.host,
        kind: ProfileKind.xray, data: {'link': text, 'json': ''});
  }
  return null;
}
