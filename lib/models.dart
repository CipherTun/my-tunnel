import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_info.dart';

enum ProfileType { ssh, v2ray, wireguard, openvpn, proxy, inject, group }

int _idCounter = 0;
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idCounter++).toRadixString(36)}';

String decodeB64(String s) {
  var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return utf8.decode(base64.decode(t), allowMalformed: true);
}

class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.type,
    Map<String, dynamic>? data,
    this.subId,
  }) : data = data ?? <String, dynamic>{};

  String id;
  String name;
  ProfileType type;
  Map<String, dynamic> data;

  /// Set when this profile was created by a subscription refresh.
  String? subId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'data': data,
        if (subId != null) 'sub': subId,
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: (j['id'] ?? newId()).toString(),
        name: (j['name'] ?? 'Profile').toString(),
        type: ProfileType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => ProfileType.v2ray,
        ),
        data: Map<String, dynamic>.from((j['data'] as Map?) ?? {}),
        subId: j['sub']?.toString(),
      );

  String get typeLabel => switch (type) {
        ProfileType.ssh => 'SSH',
        ProfileType.v2ray => _v2Label(),
        ProfileType.wireguard => 'WireGuard',
        ProfileType.openvpn => 'OpenVPN',
        ProfileType.proxy => _proxyLabel(),
        ProfileType.inject => 'HTTP Payload',
        ProfileType.group => 'Group',
      };

  String _proxyLabel() {
    final k = (data['kind'] ?? 'socks5').toString();
    return switch (k) { 'http' => 'HTTP proxy', 'https' => 'HTTPS proxy', _ => 'SOCKS5 proxy' };
  }

  String _v2Label() {
    final l = (data['link'] ?? '').toString();
    final i = l.indexOf('://');
    if (data['mode'] == 'json') return 'Xray JSON';
    if (i > 0) return l.substring(0, i).toUpperCase();
    final p = (data['proto'] ?? '').toString();
    return p.isEmpty ? 'Xray' : p.toUpperCase();
  }

  /// First-hop endpoint used for TCP latency tests. Null when unknown.
  ({String host, int port})? get endpoint {
    try {
      switch (type) {
        case ProfileType.ssh:
          final ph = (data['proxyHost'] ?? '').toString();
          if (ph.isNotEmpty) {
            return (host: ph, port: int.parse('${data['proxyPort'] ?? 8080}'));
          }
          final h = (data['host'] ?? '').toString();
          if (h.isEmpty) return null;
          return (host: h, port: int.parse('${data['port'] ?? 22}'));
        case ProfileType.v2ray:
          if (data['mode'] == 'json') return _jsonEndpoint('${data['json'] ?? ''}');
          if (data['mode'] == 'gui') {
            final a = '${data['address'] ?? ''}';
            if (a.isEmpty) return null;
            return (host: a, port: int.parse('${data['port'] ?? 443}'));
          }
          return linkEndpoint('${data['link'] ?? ''}');
        case ProfileType.wireguard:
          final m = RegExp(r'^\s*Endpoint\s*=\s*(.+?)\s*$', multiLine: true, caseSensitive: false)
              .firstMatch('${data['conf'] ?? ''}');
          if (m == null) return null;
          final v = m.group(1)!;
          final i = v.lastIndexOf(':');
          if (i < 0) return null;
          return (
            host: v.substring(0, i).replaceAll(RegExp(r'[\[\]]'), ''),
            port: int.parse(v.substring(i + 1)),
          );
        case ProfileType.openvpn:
          final m = RegExp(r'^\s*remote\s+(\S+)\s+(\d+)', multiLine: true)
              .firstMatch('${data['config'] ?? ''}');
          if (m == null) return null;
          return (host: m.group(1)!, port: int.parse(m.group(2)!));
        case ProfileType.proxy:
          final h = (data['host'] ?? '').toString();
          if (h.isEmpty) return null;
          return (host: h, port: int.parse('${data['port'] ?? 8080}'));
        case ProfileType.inject:
          final h = (data['proxyHost'] ?? '').toString();
          if (h.isEmpty) return null;
          return (host: h, port: int.parse('${data['proxyPort'] ?? 80}'));
        case ProfileType.group:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static ({String host, int port})? _jsonEndpoint(String src) {
    try {
      final m = jsonDecode(src) as Map;
      final o = (m['outbounds'] as List).first as Map;
      final s = o['settings'] as Map;
      final n = ((s['vnext'] ?? s['servers']) as List).first as Map;
      return (host: '${n['address']}', port: int.parse('${n['port']}'));
    } catch (_) {
      return null;
    }
  }

  static ({String host, int port})? linkEndpoint(String link) {
    try {
      final l = link.trim();
      if (l.startsWith('vmess://')) {
        final j = jsonDecode(decodeB64(l.substring(8))) as Map;
        return (host: '${j['add']}', port: int.parse('${j['port']}'));
      }
      var u = Uri.parse(l);
      if (u.host.isEmpty && l.startsWith('ss://')) {
        var body = l.substring(5);
        final h = body.indexOf('#');
        if (h >= 0) body = body.substring(0, h);
        final d = decodeB64(body);
        u = Uri.parse('ss://$d');
      }
      if (u.host.isEmpty || !u.hasPort) return null;
      return (host: u.host, port: u.port);
    } catch (_) {
      return null;
    }
  }
}

class Subscription {
  Subscription({required this.id, required this.name, required this.url, this.updated});
  String id;
  String name;
  String url;
  DateTime? updated;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (updated != null) 'updated': updated!.toIso8601String(),
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: (j['id'] ?? newId()).toString(),
        name: (j['name'] ?? 'Subscription').toString(),
        url: (j['url'] ?? '').toString(),
        updated: DateTime.tryParse('${j['updated']}'),
      );
}

class AppSettings {
  String dnsPreset = 'default';
  String dns1 = '';
  String dns2 = '';
  String fallbackDns = '';
  bool dnsIpv4Only = true;

  bool autoReconnect = true;
  int reconnectMax = 5;
  bool autoConnect = false;
  bool bypassLan = true;
  String bypassApps = '';

  bool watchdog = true;
  String watchdogUrl = 'https://www.gstatic.com/generate_204';
  int watchdogInterval = 45;
  int watchdogFails = 3;

  int socksPort = kDefaultSocksPort;
  bool shareHotspot = false;
  int sshKeepAlive = 15;

  String themeMode = 'dark';

  /// 'vpn' routes the whole device; 'proxy' only exposes a local SOCKS5 proxy.
  String vpnMode = 'vpn';

  /// 'tcp' = TCP connect time, 'real' = delay measured through the Xray core.
  String testMode = 'tcp';

  static const presets = <String, List<String>>{
    'google': ['8.8.8.8', '8.8.4.4'],
    'cloudflare': ['1.1.1.1', '1.0.0.1'],
    'quad9': ['9.9.9.9', '149.112.112.112'],
    'adguard': ['94.140.14.14', '94.140.15.15'],
    'opendns': ['208.67.222.222', '208.67.220.220'],
  };

  List<String> get blockedApps => bypassApps
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim())
      .where((e) => e.contains('.'))
      .toSet()
      .toList();

  /// Resolver list for the core. In SSH mode UDP cannot be tunnelled, so plain
  /// IPs are turned into tcp:// resolvers that ride the SOCKS/SSH channel.
  List<String> dnsServers({required bool tcp}) {
    final raw = <String>[];
    if (dnsPreset == 'custom') {
      raw.addAll([dns1, dns2]);
    } else if (presets.containsKey(dnsPreset)) {
      raw.addAll(presets[dnsPreset]!);
    }
    if (fallbackDns.trim().isNotEmpty) raw.add(fallbackDns);
    final out = <String>[];
    for (var s in raw.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      if (tcp && !s.contains('://')) {
        s = s.contains(':') ? 'tcp://[$s]' : 'tcp://$s';
      }
      if (!out.contains(s)) out.add(s);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'dnsPreset': dnsPreset,
        'dns1': dns1,
        'dns2': dns2,
        'fallbackDns': fallbackDns,
        'dnsIpv4Only': dnsIpv4Only,
        'autoReconnect': autoReconnect,
        'reconnectMax': reconnectMax,
        'autoConnect': autoConnect,
        'bypassLan': bypassLan,
        'bypassApps': bypassApps,
        'watchdog': watchdog,
        'watchdogUrl': watchdogUrl,
        'watchdogInterval': watchdogInterval,
        'watchdogFails': watchdogFails,
        'socksPort': socksPort,
        'shareHotspot': shareHotspot,
        'sshKeepAlive': sshKeepAlive,
        'themeMode': themeMode,
        'vpnMode': vpnMode,
        'testMode': testMode,
      };

  void applyJson(Map<String, dynamic> j) {
    String s(String k, String d) => (j[k] ?? d).toString();
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    int n(String k, int d) => int.tryParse('${j[k]}') ?? d;
    dnsPreset = s('dnsPreset', dnsPreset);
    dns1 = s('dns1', dns1);
    dns2 = s('dns2', dns2);
    fallbackDns = s('fallbackDns', fallbackDns);
    dnsIpv4Only = b('dnsIpv4Only', dnsIpv4Only);
    autoReconnect = b('autoReconnect', autoReconnect);
    reconnectMax = n('reconnectMax', reconnectMax).clamp(0, 50).toInt();
    autoConnect = b('autoConnect', autoConnect);
    bypassLan = b('bypassLan', bypassLan);
    bypassApps = s('bypassApps', bypassApps);
    watchdog = b('watchdog', watchdog);
    watchdogUrl = s('watchdogUrl', watchdogUrl);
    watchdogInterval = n('watchdogInterval', watchdogInterval).clamp(15, 300).toInt();
    watchdogFails = n('watchdogFails', watchdogFails).clamp(1, 10).toInt();
    socksPort = n('socksPort', socksPort);
    if (socksPort < 1024 || socksPort > 65535 || socksPort == kReservedPort) {
      socksPort = kDefaultSocksPort;
    }
    shareHotspot = b('shareHotspot', shareHotspot);
    sshKeepAlive = n('sshKeepAlive', sshKeepAlive).clamp(5, 120).toInt();
    themeMode = s('themeMode', themeMode);
    vpnMode = s('vpnMode', vpnMode) == 'proxy' ? 'proxy' : 'vpn';
    testMode = s('testMode', testMode) == 'real' ? 'real' : 'tcp';
  }
}

class Store {
  static const _kProfiles = 'profiles_v3';
  static const _kSettings = 'settings_v3';
  static const _kSubs = 'subs_v1';
  static const _kSelected = 'selected_v3';

  late SharedPreferences _p;

  Future<void> init() async => _p = await SharedPreferences.getInstance();

  List<Profile> loadProfiles() {
    try {
      final l = jsonDecode(_p.getString(_kProfiles) ?? '[]') as List;
      return [for (final e in l) Profile.fromJson(Map<String, dynamic>.from(e as Map))];
    } catch (_) {
      return [];
    }
  }

  List<Subscription> loadSubs() {
    try {
      final l = jsonDecode(_p.getString(_kSubs) ?? '[]') as List;
      return [for (final e in l) Subscription.fromJson(Map<String, dynamic>.from(e as Map))];
    } catch (_) {
      return [];
    }
  }

  AppSettings loadSettings() {
    final s = AppSettings();
    try {
      s.applyJson(Map<String, dynamic>.from(jsonDecode(_p.getString(_kSettings) ?? '{}') as Map));
    } catch (_) {}
    return s;
  }

  String? loadSelected() => _p.getString(_kSelected);

  Future<void> saveProfiles(List<Profile> l) =>
      _p.setString(_kProfiles, jsonEncode([for (final e in l) e.toJson()]));
  Future<void> saveSubs(List<Subscription> l) =>
      _p.setString(_kSubs, jsonEncode([for (final e in l) e.toJson()]));
  Future<void> saveSettings(AppSettings s) => _p.setString(_kSettings, jsonEncode(s.toJson()));
  Future<void> saveSelected(String? id) =>
      id == null ? _p.remove(_kSelected) : _p.setString(_kSelected, id);
}

String _fragName(Uri u, String fallback) {
  if (u.fragment.isEmpty) return fallback;
  try {
    return Uri.decodeComponent(u.fragment);
  } catch (_) {
    return u.fragment;
  }
}

/// Turns pasted text (share link, ssh:// URI, WireGuard conf, Xray JSON) into a
/// profile. Returns null when the text is not recognised.
Profile? importProfile(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;

  if (t.contains('[Interface]') && t.contains('[Peer]')) {
    return Profile(id: newId(), name: 'WireGuard', type: ProfileType.wireguard, data: {'conf': t});
  }
  if (RegExp(r'^\s*remote\s+\S+\s+\d+', multiLine: true).hasMatch(t) &&
      (t.contains('<ca>') || t.contains('auth-user-pass') || RegExp(r'^\s*client\s*$', multiLine: true).hasMatch(t))) {
    final m = RegExp(r'^\s*remote\s+(\S+)', multiLine: true).firstMatch(t);
    return Profile(
      id: newId(),
      name: 'OpenVPN ${m?.group(1) ?? ''}'.trim(),
      type: ProfileType.openvpn,
      data: {'config': t},
    );
  }
  if (t.startsWith('{')) {
    try {
      jsonDecode(t);
      return Profile(
        id: newId(),
        name: 'Xray JSON',
        type: ProfileType.v2ray,
        data: {'mode': 'json', 'json': t},
      );
    } catch (_) {
      return null;
    }
  }

  final i = t.indexOf('://');
  if (i <= 0) return null;
  final scheme = t.substring(0, i).toLowerCase();

  if (scheme == 'socks5' || scheme == 'socks5h') {
    try {
      final u = Uri.parse(t);
      final ui = u.userInfo.isEmpty ? <String>[] : u.userInfo.split(':');
      return Profile(
        id: newId(),
        name: _fragName(u, 'SOCKS5 ${u.host}'),
        type: ProfileType.proxy,
        data: {
          'kind': 'socks5',
          'host': u.host,
          'port': u.hasPort ? u.port : 1080,
          'user': ui.isNotEmpty ? Uri.decodeComponent(ui.first) : '',
          'pass': ui.length > 1 ? Uri.decodeComponent(ui.sublist(1).join(':')) : '',
        },
      );
    } catch (_) {
      return null;
    }
  }

  if (scheme == 'ssh') {
    try {
      final u = Uri.parse(t);
      final ui = u.userInfo.split(':');
      return Profile(
        id: newId(),
        name: _fragName(u, u.host),
        type: ProfileType.ssh,
        data: {
          'host': u.host,
          'port': u.hasPort ? u.port : 22,
          'user': Uri.decodeComponent(ui.first),
          'pass': ui.length > 1 ? Uri.decodeComponent(ui.sublist(1).join(':')) : '',
        },
      );
    } catch (_) {
      return null;
    }
  }

  const v2 = {'vmess', 'vless', 'trojan', 'ss', 'hysteria2', 'hy2', 'hysteria', 'socks'};
  if (!v2.contains(scheme)) return null;

  var name = scheme.toUpperCase();
  try {
    if (scheme == 'vmess') {
      final j = jsonDecode(decodeB64(t.substring(8))) as Map;
      name = (j['ps'] ?? name).toString();
    } else {
      name = _fragName(Uri.parse(t), name);
    }
  } catch (_) {}
  return Profile(
    id: newId(),
    name: name.isEmpty ? scheme.toUpperCase() : name,
    type: ProfileType.v2ray,
    data: {'mode': 'link', 'link': t},
  );
}
