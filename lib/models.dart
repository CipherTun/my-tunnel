import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_tweaks.dart';
import 'subscription.dart';

enum ProfileType { ssh, v2ray, proxy, wireguard, openvpn, chain, group }

String typeLabel(ProfileType t) => switch (t) {
      ProfileType.ssh => 'SSH Tunnel',
      ProfileType.v2ray => 'V2Ray / Xray / Hysteria2',
      ProfileType.proxy => 'HTTP / HTTPS / SOCKS5 Proxy',
      ProfileType.wireguard => 'WireGuard',
      ProfileType.openvpn => 'OpenVPN',
      ProfileType.chain => 'Proxy Chain (entry → exit)',
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

  /// Id of the subscription this profile came from ('' = created by hand).
  String get subId => s('sub');

  /// Optional IP/host to dial instead of the profile's own address.
  String get connectAddr => s('connectAddr').trim();

  /// Host:port that identifies the SSH server (key pinning, latency tests).
  String get hostKey => '${s('host').trim()}:${s('port').isEmpty ? '22' : s('port')}';

  String get subtitle {
    switch (type) {
      case ProfileType.ssh:
        final extra = <String>[
          if (b('tls')) 'TLS/SNI',
          if (s('proxyHost').isNotEmpty) (s('proxyType') == 'socks5' ? 'SOCKS5 proxy' : 'HTTP proxy'),
          if (s('payload').isNotEmpty) 'payload',
          if (b('ws')) 'WS',
          if ((int.tryParse(s('udpgwPort')) ?? 0) > 0) 'UDP',
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
      case ProfileType.proxy:
        final k = s('kind').isEmpty ? 'http' : s('kind');
        return '${k == 'socks5' ? 'SOCKS5' : k.toUpperCase()} proxy ${s('address')}:${s('port')}';
      case ProfileType.wireguard:
        return 'WireGuard';
      case ProfileType.openvpn:
        final r = parseOvpnRemote(s('config'));
        return r == null ? 'OpenVPN' : 'OpenVPN ${r.host}:${r.port} ${r.proto.toUpperCase()}';
      case ProfileType.chain:
        return 'Chain of 2 servers';
      case ProfileType.group:
        return '${members.length} servers, tried in order';
    }
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type.name, 'data': data};

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: (j['name'] ?? 'Profile') as String,
        type: ProfileType.values
            .firstWhere((t) => t.name == j['type'], orElse: () => ProfileType.ssh),
        data: Map<String, dynamic>.from(j['data'] ?? {}),
      );
}

String _safeDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

/// socks5://user:pass@host:1080, and http(s)://user:pass@host:8080 when the URL
/// looks like a proxy (explicit port, no path/query) rather than a web page or
/// a subscription URL.
Profile? _proxyFromUrl(String t, String id) {
  final u = Uri.tryParse(t);
  if (u == null || u.host.isEmpty) return null;
  final sch = u.scheme.toLowerCase();
  String kind;
  if (sch == 'socks5' || sch == 'socks5h') {
    kind = 'socks5';
  } else if (sch == 'http' || sch == 'https') {
    final bare = u.path.isEmpty || u.path == '/';
    if (!u.hasPort || !bare || u.hasQuery) return null;
    kind = sch;
  } else {
    return null;
  }
  final ui = u.userInfo.split(':');
  return Profile(
    id: id,
    name: u.fragment.isNotEmpty ? _safeDecode(u.fragment) : u.host,
    type: ProfileType.proxy,
    data: {
      'kind': kind,
      'address': u.host,
      'port': (u.hasPort ? u.port : (kind == 'socks5' ? 1080 : 8080)).toString(),
      'user': ui.first.isEmpty ? '' : _safeDecode(ui.first),
      'pass': ui.length > 1 ? _safeDecode(ui.sublist(1).join(':')) : '',
    },
  );
}

int _idCounter = 0;
String newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

/// Turns pasted text into a profile: our own JSON export, a standard share link,
/// an ssh:// URL, or a wg-quick config. Returns null if not recognised.
Profile? importProfile(String raw, {String? id}) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  id ??= newId();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t) as Map<String, dynamic>;
      if (j.containsKey('type') && j.containsKey('data')) {
        return Profile.fromJson({...j, 'id': id});
      }
      if (j.containsKey('outbounds')) {
        return Profile(
            id: id, name: 'Xray JSON', type: ProfileType.v2ray, data: {'mode': 'json', 'json': t});
      }
    } catch (_) {}
    return null;
  }
  if (looksLikeOvpn(t)) {
    return Profile(id: id, name: 'OpenVPN', type: ProfileType.openvpn, data: {'config': t});
  }
  if (t.contains('[Interface]')) {
    return Profile(id: id, name: 'WireGuard', type: ProfileType.wireguard, data: {'config': t});
  }
  final proxy = _proxyFromUrl(t, id);
  if (proxy != null) return proxy;
  final scheme = t.split('://').first.toLowerCase();
  if (!t.contains('://') || !shareSchemes.contains(scheme)) return null;
  if (scheme == 'ssh') {
    final u = Uri.tryParse(t);
    if (u == null || u.host.isEmpty) return null;
    final ui = u.userInfo.split(':');
    return Profile(id: id, name: u.fragment.isNotEmpty ? _safeDecode(u.fragment) : u.host, type: ProfileType.ssh, data: {
      'host': u.host,
      'port': (u.hasPort ? u.port : 22).toString(),
      'user': Uri.decodeComponent(ui.first),
      'pass': ui.length > 1 ? Uri.decodeComponent(ui.sublist(1).join(':')) : '',
      'udpgwPort': '7300',
    });
  }
  return Profile(
      id: id, name: shareLinkName(t), type: ProfileType.v2ray, data: {'mode': 'link', 'link': t});
}

class AppSettings {
  String dnsPreset = 'default'; // default|google|cloudflare|quad9|adguard|custom
  String dns1 = '';
  String dns2 = '';
  String fallbackDns = '';
  bool autoReconnect = true;
  int reconnectMax = 5;
  bool healthCheck = true;
  bool autoConnect = false;
  bool bypassLan = false;
  String bypassApps = '';
  bool shareHotspot = false;
  String hotspotUser = '';
  String hotspotPass = '';
  int socksPort = 10808;
  int sshKeepalive = 20;
  String themeMode = 'system'; // system|light|dark
  bool fragment = false;
  String fragLength = '100-200';
  String fragInterval = '10-20';
  bool mux = false;
  int muxConcurrency = 8;
  String fingerprint = 'default'; // default|chrome|firefox|safari|ios|android|edge|randomized
  bool blockQuic = false;
  bool autoUpdateSubs = true;
  bool proxyOnly = false; // local proxy, no VPN service
  String logLevel = 'warning'; // none|error|warning|info|debug
  String speedUrl = 'http://speedtest.tele2.net/10MB.zip';

  List<String> get blockedApps =>
      bypassApps.split(RegExp(r'[\s,;]+')).where((e) => e.contains('.')).toSet().toList();

  List<String> get dnsServers {
    final base = switch (dnsPreset) {
      'google' => ['8.8.8.8', '8.8.4.4'],
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      'custom' => [dns1, dns2],
      _ => <String>[],
    };
    return [...base, fallbackDns].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  Map<String, dynamic> toJson() => {
        'dnsPreset': dnsPreset,
        'dns1': dns1,
        'dns2': dns2,
        'fallbackDns': fallbackDns,
        'autoReconnect': autoReconnect,
        'reconnectMax': reconnectMax,
        'healthCheck': healthCheck,
        'autoConnect': autoConnect,
        'bypassLan': bypassLan,
        'bypassApps': bypassApps,
        'shareHotspot': shareHotspot,
        'hotspotUser': hotspotUser,
        'hotspotPass': hotspotPass,
        'socksPort': socksPort,
        'sshKeepalive': sshKeepalive,
        'themeMode': themeMode,
        'fragment': fragment,
        'fragLength': fragLength,
        'fragInterval': fragInterval,
        'mux': mux,
        'muxConcurrency': muxConcurrency,
        'fingerprint': fingerprint,
        'blockQuic': blockQuic,
        'autoUpdateSubs': autoUpdateSubs,
        'proxyOnly': proxyOnly,
        'logLevel': logLevel,
        'speedUrl': speedUrl,
      };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings()
    ..dnsPreset = j['dnsPreset'] ?? 'default'
    ..dns1 = j['dns1'] ?? ''
    ..dns2 = j['dns2'] ?? ''
    ..fallbackDns = j['fallbackDns'] ?? ''
    ..autoReconnect = j['autoReconnect'] ?? true
    ..reconnectMax = j['reconnectMax'] ?? 5
    ..healthCheck = j['healthCheck'] ?? true
    ..autoConnect = j['autoConnect'] ?? false
    ..bypassLan = j['bypassLan'] ?? false
    ..bypassApps = j['bypassApps'] ?? ''
    ..shareHotspot = j['shareHotspot'] ?? false
    ..hotspotUser = j['hotspotUser'] ?? ''
    ..hotspotPass = j['hotspotPass'] ?? ''
    ..socksPort = j['socksPort'] ?? 10808
    ..sshKeepalive = j['sshKeepalive'] ?? 20
    ..themeMode = j['themeMode'] ?? 'system'
    ..fragment = j['fragment'] ?? false
    ..fragLength = j['fragLength'] ?? '100-200'
    ..fragInterval = j['fragInterval'] ?? '10-20'
    ..mux = j['mux'] ?? false
    ..muxConcurrency = j['muxConcurrency'] ?? 8
    ..fingerprint = j['fingerprint'] ?? 'default'
    ..blockQuic = j['blockQuic'] ?? false
    ..autoUpdateSubs = j['autoUpdateSubs'] ?? true
    ..proxyOnly = j['proxyOnly'] ?? false
    ..logLevel = j['logLevel'] ?? 'warning'
    ..speedUrl = j['speedUrl'] ?? 'http://speedtest.tele2.net/10MB.zip';
}

/// Profiles (which hold passwords / keys), subscription URLs (often contain
/// tokens) and pinned SSH host keys live in the Android Keystore-backed secure
/// storage. Plain preferences only hold non-sensitive UI state.
class Store {
  static const _kP = 'profiles_v2';
  static const _kS = 'selected_v2';
  static const _kSet = 'settings_v2';
  static const _kSubs = 'subs_v1';
  static const _kHosts = 'known_hosts_v1';
  static const _sec = FlutterSecureStorage();

  /// Receives storage problems so they show up in the app log instead of
  /// failing silently (a lost profile list is worse than a visible warning).
  static void Function(String message)? onError;

  static Future<String?> _secRead(String k) async {
    try {
      return await _sec.read(key: k);
    } catch (e) {
      onError?.call('Secure storage read failed ($k): $e');
      return null;
    }
  }

  static Future<void> _secWrite(String k, String v) async {
    try {
      await _sec.write(key: k, value: v);
    } catch (e) {
      onError?.call('Secure storage write failed ($k): $e. Your changes may not persist.');
    }
  }

  static Future<List<Profile>> loadProfiles() async {
    var raw = await _secRead(_kP);
    if (raw == null) {
      // one-time migration from the old plaintext SharedPreferences store
      final p = await SharedPreferences.getInstance();
      raw = p.getString(_kP);
      if (raw != null) {
        await _secWrite(_kP, raw);
        await p.remove(_kP);
      }
    }
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Profile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveProfiles(List<Profile> l) =>
      _secWrite(_kP, jsonEncode(l.map((e) => e.toJson()).toList()));

  static Future<List<Subscription>> loadSubs() async {
    final raw = await _secRead(_kSubs);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveSubs(List<Subscription> l) =>
      _secWrite(_kSubs, jsonEncode(l.map((e) => e.toJson()).toList()));

  static Future<Map<String, String>> loadHosts() async {
    final raw = await _secRead(_kHosts);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveHosts(Map<String, String> m) => _secWrite(_kHosts, jsonEncode(m));

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
