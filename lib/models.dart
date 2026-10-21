import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum ProfileType { ssh, v2ray, wireguard, group }

String typeLabel(ProfileType t) => switch (t) {
      ProfileType.ssh => 'SSH Tunnel',
      ProfileType.v2ray => 'V2Ray / Xray / Hysteria2',
      ProfileType.wireguard => 'WireGuard',
      ProfileType.group => 'Failover Group',
    };

class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.type,
    Map<String, dynamic>? data,
  }) : data = data ?? {};

  final String id;
  String name;
  ProfileType type;
  Map<String, dynamic> data;

  String s(String k) => (data[k] ?? '').toString();
  bool b(String k) => data[k] == true;
  List<String> get members =>
      ((data['members'] as List?) ?? const []).map((e) => e.toString()).toList();

  String get subtitle {
    switch (type) {
      case ProfileType.ssh:
        final extra = <String>[
          if (b('tls')) 'TLS/SNI',
          if (s('proxyHost').isNotEmpty) 'proxy',
          if (s('payload').isNotEmpty) 'payload',
          if (b('ws')) 'WS',
        ].join(' + ');
        return 'SSH ${s('host')}:${s('port')}${extra.isEmpty ? '' : '  ·  $extra'}';
      case ProfileType.v2ray:
        switch (s('mode')) {
          case 'json':
            return 'Raw Xray JSON';
          case 'link':
            return s('link').split('://').first.toUpperCase();
          default:
            return '${s('proto').toUpperCase()} ${s('address')}:${s('port')}  ·  ${s('network')}/${s('security')}';
        }
      case ProfileType.wireguard:
        return 'WireGuard';
      case ProfileType.group:
        return '${members.length} servers, tried in order';
    }
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'type': type.name, 'data': data};

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: j['name'] as String,
        type: ProfileType.values
            .firstWhere((t) => t.name == j['type'], orElse: () => ProfileType.ssh),
        data: Map<String, dynamic>.from(j['data'] ?? {}),
      );
}

/// Turns pasted text into a profile: our own JSON export, a standard share link,
/// an ssh:// URL, or a wg-quick config.
Profile? importProfile(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final id = DateTime.now().microsecondsSinceEpoch.toString();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t) as Map<String, dynamic>;
      if (j.containsKey('type') && j.containsKey('data')) {
        return Profile.fromJson({...j, 'id': id});
      }
      if (j.containsKey('outbounds')) {
        return Profile(
            id: id,
            name: 'Xray JSON',
            type: ProfileType.v2ray,
            data: {'mode': 'json', 'json': t});
      }
    } catch (_) {}
    return null;
  }
  if (t.contains('[Interface]')) {
    return Profile(
        id: id, name: 'WireGuard', type: ProfileType.wireguard, data: {'config': t});
  }
  final scheme = t.split('://').first.toLowerCase();
  if (const ['vmess', 'vless', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2', 'hysteria']
      .contains(scheme)) {
    final frag = t.contains('#') ? Uri.decodeComponent(t.split('#').last) : '';
    return Profile(
        id: id,
        name: frag.isEmpty ? scheme.toUpperCase() : frag,
        type: ProfileType.v2ray,
        data: {'mode': 'link', 'link': t});
  }
  if (scheme == 'ssh') {
    final u = Uri.tryParse(t);
    if (u == null) return null;
    final ui = u.userInfo.split(':');
    return Profile(id: id, name: u.host, type: ProfileType.ssh, data: {
      'host': u.host,
      'port': (u.hasPort ? u.port : 22).toString(),
      'user': Uri.decodeComponent(ui.first),
      'pass': ui.length > 1 ? Uri.decodeComponent(ui.sublist(1).join(':')) : '',
    });
  }
  return null;
}

class AppSettings {
  String dnsPreset = 'default'; // default|google|cloudflare|quad9|adguard|custom
  String coreEngine = 'xray'; // xray|singbox; sing-box is used for supported standard links/configs
  String dns1 = '';
  String dns2 = '';
  String fallbackDns = '';
  bool autoReconnect = true;
  int reconnectMax = 5;
  bool bypassLan = false;
  String bypassApps = '';
  bool shareHotspot = false;
  String shareUsername = '';
  String sharePassword = '';
  int socksPort = 10808;
  int sshKeepalive = 20;

  List<String> get blockedApps => bypassApps
      .split(RegExp(r'[\s,;]+'))
      .where((e) => e.contains('.'))
      .toList();

  List<String> get dnsServers {
    final base = switch (dnsPreset) {
      'google' => ['8.8.8.8', '8.8.4.4'],
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      'custom' => [dns1, dns2],
      _ => <String>[],
    };
    final out = [...base, fallbackDns].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return out;
  }

  Map<String, dynamic> toJson() => {
        'dnsPreset': dnsPreset,
        'coreEngine': coreEngine,
        'dns1': dns1,
        'dns2': dns2,
        'fallbackDns': fallbackDns,
        'autoReconnect': autoReconnect,
        'reconnectMax': reconnectMax,
        'bypassLan': bypassLan,
        'bypassApps': bypassApps,
        'shareHotspot': shareHotspot,
        'shareUsername': shareUsername,
        'sharePassword': sharePassword,
        'socksPort': socksPort,
        'sshKeepalive': sshKeepalive,
      };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings()
    ..dnsPreset = j['dnsPreset'] ?? 'default'
    ..coreEngine = (j['coreEngine'] == 'singbox' ? 'singbox' : 'xray')
    ..dns1 = j['dns1'] ?? ''
    ..dns2 = j['dns2'] ?? ''
    ..fallbackDns = j['fallbackDns'] ?? ''
    ..autoReconnect = j['autoReconnect'] ?? true
    ..reconnectMax = ((j['reconnectMax'] as num?)?.toInt() ?? 5).clamp(0, 20).toInt()
    ..bypassLan = j['bypassLan'] ?? false
    ..bypassApps = j['bypassApps'] ?? ''
    ..shareHotspot = j['shareHotspot'] ?? false
    ..shareUsername = j['shareUsername'] ?? ''
    ..sharePassword = j['sharePassword'] ?? ''
    ..socksPort = ((j['socksPort'] as num?)?.toInt() ?? 10808).clamp(1, 65535).toInt()
    ..sshKeepalive = ((j['sshKeepalive'] as num?)?.toInt() ?? 20).clamp(0, 3600).toInt();
}

class Store {
  static const _kP = 'profiles_v2';
  static const _kS = 'selected_v2';
  static const _kSet = 'settings_v2';

  static Future<List<Profile>> loadProfiles() async {
    final raw = (await SharedPreferences.getInstance()).getString(_kP);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Profile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveProfiles(List<Profile> l) async => (await SharedPreferences.getInstance())
      .setString(_kP, jsonEncode(l.map((e) => e.toJson()).toList()));

  static Future<String?> loadSelected() async =>
      (await SharedPreferences.getInstance()).getString(_kS);

  static Future<void> saveSelected(String? id) async {
    final p = await SharedPreferences.getInstance();
    id == null ? await p.remove(_kS) : await p.setString(_kS, id);
  }

  static Future<AppSettings> loadSettings() async {
    final raw = (await SharedPreferences.getInstance()).getString(_kSet);
    if (raw == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  static Future<void> saveSettings(AppSettings s) async =>
      (await SharedPreferences.getInstance()).setString(_kSet, jsonEncode(s.toJson()));
}
