import 'dart:convert';
import 'dart:math';

/// Pure-Dart helpers (no plugin imports) so they can be unit tested.

/// Everything except private/LAN ranges (so LAN traffic bypasses the tunnel).
const lanBypassSubnets = <String>[
  '0.0.0.0/5', '8.0.0.0/7', '11.0.0.0/8', '12.0.0.0/6', '16.0.0.0/4',
  '32.0.0.0/3', '64.0.0.0/2', '128.0.0.0/3', '160.0.0.0/5', '168.0.0.0/6',
  '172.0.0.0/12', '172.32.0.0/11', '172.64.0.0/10', '172.128.0.0/9',
  '173.0.0.0/8', '174.0.0.0/7', '176.0.0.0/4', '192.0.0.0/9',
  '192.128.0.0/11', '192.160.0.0/13', '192.169.0.0/16', '192.170.0.0/15',
  '192.172.0.0/14', '192.176.0.0/12', '192.192.0.0/10', '193.0.0.0/8',
  '194.0.0.0/7', '196.0.0.0/6', '200.0.0.0/5', '208.0.0.0/4', '240.0.0.0/4',
];

/// Applies DNS servers. [tcpOnly] is used for SSH mode (only TCP is carried
/// unless UDPGW is on; TCP DNS always works).
String patchDnsJson(String cfg, List<String> servers, {bool tcpOnly = false}) {
  var list = servers;
  if (tcpOnly) {
    list = (list.isEmpty ? ['1.1.1.1', '8.8.8.8'] : list)
        .map((e) => e.contains('://') ? e : 'tcp://$e')
        .toList();
  }
  if (list.isEmpty) return cfg;
  try {
    final m = jsonDecode(cfg) as Map<String, dynamic>;
    final dns = Map<String, dynamic>.from((m['dns'] as Map?) ?? {});
    dns['servers'] = list;
    m['dns'] = dns;
    return jsonEncode(m);
  } catch (_) {
    return cfg;
  }
}

bool _isRange(String s) => RegExp(r'^\d+(-\d+)?$').hasMatch(s.trim());

/// Adds Xray TLS fragmentation and/or Mux to the outbound tagged `proxy`
/// (falls back to the first outbound).
///
/// Fragment: a `freedom` outbound tagged `fragment` carrying
/// `settings.fragment {packets, length, interval}`, chained from the proxy
/// outbound with `streamSettings.sockopt.dialerProxy = "fragment"`
/// (https://xtls.github.io/en/config/outbounds/freedom.html).
/// Only applied to TLS/REALITY TCP-based outbounds.
///
/// Mux: `outbound.mux {enabled, concurrency}`; skipped for XTLS-Vision flows,
/// gRPC/XHTTP/mKCP transports and non-multiplexable protocols.
String applyTweaks(
  String cfg, {
  bool fragment = false,
  String fragPackets = 'tlshello',
  String fragLength = '100-200',
  String fragInterval = '10-20',
  bool mux = false,
  int muxConcurrency = 8,
  String fingerprint = '',
  bool blockQuic = false,
}) {
  if (fingerprint == 'default') fingerprint = '';
  if (!fragment && !mux && fingerprint.isEmpty && !blockQuic) return cfg;
  final Map<String, dynamic> m;
  try {
    m = jsonDecode(cfg) as Map<String, dynamic>;
  } catch (_) {
    return cfg;
  }
  final outs = ((m['outbounds'] as List?) ?? const []).cast<dynamic>();
  if (outs.isEmpty) return cfg;
  var idx = outs.indexWhere((o) => o is Map && o['tag'] == 'proxy');
  if (idx < 0) idx = 0;
  final ob = Map<String, dynamic>.from(outs[idx] as Map);
  final proto = (ob['protocol'] ?? '').toString();
  final ss = Map<String, dynamic>.from((ob['streamSettings'] as Map?) ?? {});
  final security = (ss['security'] ?? 'none').toString();
  final network = (ss['network'] ?? 'tcp').toString();

  if (fragment &&
      (security == 'tls' || security == 'reality') &&
      const ['tcp', 'ws', 'httpupgrade', 'grpc', 'xhttp', 'splithttp', 'h2'].contains(network) &&
      proto != 'hysteria' &&
      proto != 'wireguard') {
    final sock = Map<String, dynamic>.from((ss['sockopt'] as Map?) ?? {});
    sock['dialerProxy'] = 'fragment';
    ss['sockopt'] = sock;
    ob['streamSettings'] = ss;
    if (!outs.any((o) => o is Map && o['tag'] == 'fragment')) {
      outs.add({
        'tag': 'fragment',
        'protocol': 'freedom',
        'settings': {
          'fragment': {
            'packets': fragPackets.trim().isEmpty ? 'tlshello' : fragPackets.trim(),
            'length': _isRange(fragLength) ? fragLength.trim() : '100-200',
            'interval': _isRange(fragInterval) ? fragInterval.trim() : '10-20',
          },
        },
        'streamSettings': {
          'sockopt': {'tcpNoDelay': true}
        },
      });
    }
  }

  if (mux && const ['vless', 'vmess', 'trojan', 'shadowsocks'].contains(proto)) {
    var vision = false;
    try {
      final users = ((ob['settings'] as Map)['vnext'] as List).first['users'] as List;
      vision = (users.first['flow'] ?? '').toString().isNotEmpty;
    } catch (_) {}
    if (!vision && !const ['grpc', 'xhttp', 'splithttp', 'kcp'].contains(network)) {
      ob['mux'] = {'enabled': true, 'concurrency': muxConcurrency.clamp(1, 1024).toInt()};
    }
  }

  // uTLS fingerprint override (TLS / REALITY only)
  if (fingerprint.isNotEmpty && fingerprint != 'default') {
    for (final key in const ['tlsSettings', 'realitySettings']) {
      final t = ss[key];
      if (t is Map) {
        ss[key] = {...Map<String, dynamic>.from(t), 'fingerprint': fingerprint};
        ob['streamSettings'] = ss;
      }
    }
  }

  outs[idx] = ob;
  m['outbounds'] = outs;

  // Block QUIC (UDP/443) so browsers fall back to TCP, which tunnels far better.
  // Do not block UDP/443 when the selected outbound itself needs UDP/443.
  final udpBasedProxy = const ['hysteria', 'hysteria2', 'wireguard']
      .contains(proto);
  if (blockQuic && !udpBasedProxy) {
    if (!outs.any((o) => o is Map && o['tag'] == 'block')) {
      outs.add({'tag': 'block', 'protocol': 'blackhole'});
    }
    final routing = Map<String, dynamic>.from((m['routing'] as Map?) ?? {});
    final rules = ((routing['rules'] as List?) ?? const []).toList();
    rules.insert(0, {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'});
    routing['rules'] = rules;
    routing.putIfAbsent('domainStrategy', () => 'AsIs');
    m['routing'] = routing;
  }
  return jsonEncode(m);
}

/// Replaces the server address of the `proxy` outbound (CDN clean-IP workflow:
/// connect to a fast IP while SNI / Host header keep the real domain).
String overrideAddress(String cfg, String addr) {
  final a = addr.trim();
  if (a.isEmpty) return cfg;
  final Map<String, dynamic> m;
  try {
    m = jsonDecode(cfg) as Map<String, dynamic>;
  } catch (_) {
    return cfg;
  }
  final outs = ((m['outbounds'] as List?) ?? const []).toList();
  var idx = outs.indexWhere((o) => o is Map && o['tag'] == 'proxy');
  if (idx < 0) idx = outs.isEmpty ? -1 : 0;
  if (idx < 0) return cfg;
  final ob = Map<String, dynamic>.from(outs[idx] as Map);
  final st = ob['settings'];
  if (st is Map) {
    final s = Map<String, dynamic>.from(st);
    var done = false;
    for (final key in const ['vnext', 'servers']) {
      final l = s[key];
      if (l is List && l.isNotEmpty && l.first is Map) {
        final first = Map<String, dynamic>.from(l.first as Map)..['address'] = a;
        s[key] = [first, ...l.skip(1)];
        done = true;
      }
    }
    if (!done && s.containsKey('address')) s['address'] = a;
    ob['settings'] = s;
  }
  outs[idx] = ob;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

/// Chains two single-proxy Xray configs: traffic goes client -> [entry] ->
/// [exit] -> internet. The exit outbound dials through the entry outbound using
/// `sockopt.dialerProxy`. Returns the exit config extended with the entry.
/// Only TCP-based outbounds can be chained this way.
String chainConfigs(String exitCfg, String entryCfg) {
  Map<String, dynamic> pick(String c, String what) {
    final m = jsonDecode(c) as Map<String, dynamic>;
    final outs = (m['outbounds'] as List).cast<dynamic>();
    var i = outs.indexWhere((o) => o is Map && o['tag'] == 'proxy');
    if (i < 0) i = 0;
    return {'cfg': m, 'index': i, 'ob': Map<String, dynamic>.from(outs[i] as Map)};
  }

  const udpBased = ['hysteria', 'hysteria2', 'wireguard'];
  final exit = pick(exitCfg, 'exit');
  final entry = pick(entryCfg, 'entry');
  final exitOb = exit['ob'] as Map<String, dynamic>;
  final entryOb = entry['ob'] as Map<String, dynamic>;
  if (udpBased.contains(entryOb['protocol'])) {
    throw 'The entry server must be TCP based (VLESS, VMess, Trojan, Shadowsocks, SOCKS)';
  }
  if (udpBased.contains(exitOb['protocol'])) {
    throw 'The exit server must be TCP based (VLESS, VMess, Trojan, Shadowsocks, SOCKS)';
  }
  entryOb['tag'] = 'entry';
  final ss = Map<String, dynamic>.from((exitOb['streamSettings'] as Map?) ?? {});
  final sock = Map<String, dynamic>.from((ss['sockopt'] as Map?) ?? {});
  sock['dialerProxy'] = 'entry';
  ss['sockopt'] = sock;
  exitOb['streamSettings'] = ss;
  exitOb['tag'] = 'proxy';

  final cfg = exit['cfg'] as Map<String, dynamic>;
  final outs = (cfg['outbounds'] as List).cast<dynamic>().toList();
  outs[exit['index'] as int] = exitOb;
  outs.add(entryOb);
  cfg['outbounds'] = outs;
  return jsonEncode(cfg);
}

/// Outbound for an HTTP / HTTPS / SOCKS5 upstream proxy, in the flat settings
/// format of current Xray docs (xtls.github.io/config/outbounds/http and /socks).
/// The legacy `servers` form is emitted as well so older cores still parse it.
/// HTTP proxies carry TCP only. HTTPS = HTTP over TLS (streamSettings.security).
Map<String, dynamic> buildProxyOutbound(Map<String, dynamic> d) {
  String g(String k) => (d[k] ?? '').toString().trim();
  final kind = g('kind').isEmpty ? 'http' : g('kind'); // http | https | socks5
  final host = g('address');
  final port = int.tryParse(g('port')) ?? (kind == 'socks5' ? 1080 : (kind == 'https' ? 443 : 8080));
  if (host.isEmpty) throw 'Proxy address is empty';
  final user = g('user');
  final pass = (d['pass'] ?? '').toString();
  final isSocks = kind == 'socks5';
  final settings = <String, dynamic>{
    'address': host,
    'port': port,
    if (user.isNotEmpty) 'user': user,
    if (user.isNotEmpty) 'pass': pass,
    'servers': [
      {
        'address': host,
        'port': port,
        if (user.isNotEmpty) 'users': [
          {'user': user, 'pass': pass}
        ],
      }
    ],
  };
  if (!isSocks) {
    final headers = <String, String>{};
    for (final line in g('headers').split(RegExp(r'[\r\n]+'))) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim().isNotEmpty) {
        headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
    }
    if (headers.isNotEmpty) settings['headers'] = headers;
  }
  final ob = <String, dynamic>{
    'tag': 'proxy',
    'protocol': isSocks ? 'socks' : 'http',
    'settings': settings,
  };
  if (kind == 'https') {
    final tls = <String, dynamic>{
      if (g('sni').isNotEmpty) 'serverName': g('sni'),
      if (g('pin').isNotEmpty) 'pinnedPeerCertSha256': g('pin'),
    };
    ob['streamSettings'] = {'network': 'tcp', 'security': 'tls', 'tlsSettings': tls};
  }
  return ob;
}

/// Sets port / listen address of the local socks/http inbounds so the app knows
/// where the proxy is and never clashes with the SSH local SOCKS server.
String applyInbound(String cfg, {required int port, bool listenAll = false}) {
  final Map<String, dynamic> m;
  try {
    m = jsonDecode(cfg) as Map<String, dynamic>;
  } catch (_) {
    return cfg;
  }
  final ins = m['inbounds'];
  if (ins is! List) return cfg;
  var changed = false;
  final out = <dynamic>[];
  for (final i in ins) {
    if (i is Map && (i['protocol'] == 'socks' || i['protocol'] == 'http') && !changed) {
      out.add({...Map<String, dynamic>.from(i), 'port': port, 'listen': listenAll ? '0.0.0.0' : '127.0.0.1'});
      changed = true;
    } else {
      out.add(i);
    }
  }
  if (!changed) return cfg;
  m['inbounds'] = out;
  return jsonEncode(m);
}

/// Sets Xray's log level (none | error | warning | info | debug).
String applyLogLevel(String cfg, String level) {
  if (level.isEmpty || level == 'default') return cfg;
  try {
    final m = jsonDecode(cfg) as Map<String, dynamic>;
    final log = Map<String, dynamic>.from((m['log'] as Map?) ?? {});
    log['loglevel'] = level;
    m['log'] = log;
    return jsonEncode(m);
  } catch (_) {
    return cfg;
  }
}

/// First `remote host port [proto]` of an .ovpn file.
({String host, int port, String proto})? parseOvpnRemote(String ovpn) {
  var proto = 'udp';
  for (final raw in ovpn.split('\n')) {
    final l = raw.trim();
    if (l.startsWith('proto ')) proto = l.substring(6).trim().toLowerCase();
  }
  for (final raw in ovpn.split('\n')) {
    final l = raw.trim();
    if (!l.startsWith('remote ')) continue;
    final p = l.split(RegExp(r'\s+'));
    if (p.length < 2) continue;
    final port = p.length > 2 ? int.tryParse(p[2]) ?? 1194 : 1194;
    final pr = p.length > 3 ? p[3].toLowerCase() : proto;
    return (host: p[1], port: port, proto: pr.startsWith('tcp') ? 'tcp' : 'udp');
  }
  return null;
}

/// Heuristic: does this text look like an OpenVPN client config?
bool looksLikeOvpn(String t) =>
    RegExp(r'(^|\n)\s*remote\s+\S+', multiLine: true).hasMatch(t) &&
    (t.contains('client') || t.contains('dev tun') || t.contains('<ca>'));

/// Expands CIDR ranges into up to [count] random IPv4 addresses (for the
/// clean-IP scanner). IPv6 and malformed ranges are skipped.
List<String> sampleCidrs(List<String> cidrs, int count, {int seed = 0}) {
  final rnd = seed == 0 ? null : seed;
  final r = rnd == null ? _fallbackRandom() : _SeededRandom(rnd);
  final ranges = <(int, int)>[]; // (start, size)
  for (final c in cidrs) {
    final p = c.trim().split('/');
    if (p.length != 2) continue;
    final o = p[0].split('.').map(int.tryParse).toList();
    final bits = int.tryParse(p[1]);
    if (o.length != 4 || o.any((e) => e == null || e < 0 || e > 255) || bits == null || bits < 8 || bits > 32) {
      continue;
    }
    final ip = (o[0]! << 24) | (o[1]! << 16) | (o[2]! << 8) | o[3]!;
    final size = 1 << (32 - bits);
    ranges.add((ip & ~(size - 1) & 0xFFFFFFFF, size));
  }
  if (ranges.isEmpty) return [];
  final out = <String>{};
  var guard = 0;
  while (out.length < count && guard++ < count * 20) {
    final rg = ranges[r.nextInt(ranges.length)];
    final ip = rg.$1 + r.nextInt(rg.$2);
    out.add('${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}');
  }
  return out.toList();
}

abstract class _Rng {
  int nextInt(int max);
}

class _SeededRandom implements _Rng {
  _SeededRandom(this._s);
  int _s;
  @override
  int nextInt(int max) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % max;
  }
}

class _SysRandom implements _Rng {
  final _r = Random();
  @override
  int nextInt(int max) => _r.nextInt(max);
}

_Rng _fallbackRandom() => _SysRandom();

Map<String, dynamic> wgToOutbound(
  String conf, {
  List<String> remoteDns = const [],
}) {
  final iface = <String, String>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? currentPeer;
  var section = '';

  for (final raw in conf.split('\n')) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.toLowerCase();
      if (section == '[interface]') {
        currentPeer = null;
      } else if (section == '[peer]') {
        currentPeer = <String, String>{};
        peers.add(currentPeer);
      } else {
        currentPeer = null;
      }
      continue;
    }

    final i = line.indexOf('=');
    if (i < 1) continue;
    final key = line.substring(0, i).trim().toLowerCase();
    final value = line.substring(i + 1).trim();

    if (section == '[interface]') {
      iface[key] = value;
    } else if (section == '[peer]' && currentPeer != null) {
      currentPeer[key] = value;
    }
  }

  List<String> csv(String? value) => (value ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final privateKey = iface['privatekey'];
  final addresses = csv(iface['address']);
  if (privateKey == null || privateKey.isEmpty || addresses.isEmpty) {
    throw 'WireGuard config needs PrivateKey and Address';
  }
  if (peers.isEmpty) {
    throw 'WireGuard config needs at least one [Peer] section';
  }

  final parsedPeers = <Map<String, dynamic>>[];
  for (final peer in peers) {
    final publicKey = peer['publickey'];
    final endpoint = peer['endpoint'];
    if (publicKey == null || publicKey.isEmpty ||
        endpoint == null || endpoint.isEmpty) {
      throw 'Every WireGuard peer needs PublicKey and Endpoint';
    }

    final allowed = csv(peer['allowedips']);
    if (allowed.isEmpty) {
      // Default to full-tunnel routing when AllowedIPs is omitted.
      allowed.addAll(['0.0.0.0/0', '::/0']);
    }

    final keepAlive = int.tryParse(peer['persistentkeepalive'] ?? '');
    parsedPeers.add({
      'publicKey': publicKey,
      'endpoint': endpoint,
      'allowedIPs': allowed,
      if ((peer['presharedkey'] ?? '').isNotEmpty)
        'preSharedKey': peer['presharedkey'],
      if (keepAlive != null && keepAlive >= 0) 'keepAlive': keepAlive,
    });
  }

  final dns = <String>[];
  for (final item in [
    ...csv(iface['dns']),
    ...remoteDns.map((e) => e.trim()),
  ]) {
    if (item.isNotEmpty && !dns.contains(item)) dns.add(item);
  }

  final reserved = csv(iface['reserved'])
      .map(int.tryParse)
      .toList();
  if (reserved.any((value) => value == null || value < 0 || value > 255)) {
    throw 'WireGuard Reserved must contain byte values from 0 to 255';
  }

  final mtu = int.tryParse(iface['mtu'] ?? '');
  return {
    'tag': 'proxy',
    'protocol': 'wireguard',
    'settings': {
      'secretKey': privateKey,
      'address': addresses,
      'peers': parsedPeers,
      'noKernelTun': true,
      if (dns.isNotEmpty) 'remoteDNS': dns,
      if (reserved.isNotEmpty) 'reserved': reserved.cast<int>(),
      if (mtu != null && mtu > 0) 'mtu': mtu,
    },
  };
}

String _g(Map<String, dynamic> d, String k, [String def = '']) {
  final v = d[k];
  return v == null || v.toString().trim().isEmpty ? def : v.toString().trim();
}

/// Builds a standard share link from the manual GUI fields. The plugin's own
/// parser then produces the Xray config, so it always matches the bundled core.
String buildShareLink(Map<String, dynamic> d, String name) {
  final proto = _g(d, 'proto', 'vless');
  final host = _g(d, 'address');
  final port = int.tryParse(_g(d, 'port')) ?? 443;
  final id = _g(d, 'id');
  final network = _g(d, 'network', 'tcp');
  final security = _g(d, 'security', 'none');
  if (host.isEmpty) throw 'Server address is empty';

  final q = <String, String>{};
  if (proto != 'shadowsocks' && proto != 'socks' && proto != 'hysteria2') {
    q['type'] = network;
    switch (network) {
      case 'ws':
      case 'httpupgrade':
      case 'xhttp':
        if (_g(d, 'host').isNotEmpty) q['host'] = _g(d, 'host');
        q['path'] = _g(d, 'path', '/');
        break;
      case 'grpc':
        q['serviceName'] = _g(d, 'path');
        q['mode'] = 'gun';
        break;
      case 'kcp':
        q['headerType'] = 'none';
        if (_g(d, 'path').isNotEmpty) q['seed'] = _g(d, 'path');
        break;
      default:
        q['headerType'] = 'none';
    }
    if (security != 'none') {
      q['security'] = security;
      if (_g(d, 'sni').isNotEmpty) q['sni'] = _g(d, 'sni');
      if (_g(d, 'fp', 'chrome') != 'none') q['fp'] = _g(d, 'fp', 'chrome');
      if (_g(d, 'alpn').isNotEmpty) q['alpn'] = _g(d, 'alpn');
      if (security == 'reality') {
        q['pbk'] = _g(d, 'pbk');
        if (_g(d, 'sid').isNotEmpty) q['sid'] = _g(d, 'sid');
        if (_g(d, 'spx').isNotEmpty) q['spx'] = _g(d, 'spx');
      }
      if (_g(d, 'pcs').isNotEmpty) q['pcs'] = _g(d, 'pcs');
    }
  }

  Uri mk(String scheme, String userInfo, Map<String, String> params) => Uri(
        scheme: scheme,
        userInfo: userInfo.isEmpty ? null : userInfo,
        host: host,
        port: port,
        queryParameters: params.isEmpty ? null : params,
        fragment: name,
      );

  switch (proto) {
    case 'vless':
      if (id.isEmpty) throw 'UUID is empty';
      q['encryption'] = _g(d, 'encryption', 'none');
      if (_g(d, 'flow', 'none') != 'none') q['flow'] = _g(d, 'flow');
      return mk('vless', id, q).toString();
    case 'vmess':
      if (id.isEmpty) throw 'UUID is empty';
      final m = {
        'v': '2',
        'ps': name,
        'add': host,
        'port': '$port',
        'id': id,
        'aid': _g(d, 'aid', '0'),
        'scy': _g(d, 'scy', 'auto'),
        'net': network,
        'type': 'none',
        'host': _g(d, 'host'),
        'path': _g(d, 'path'),
        'tls': security == 'tls' ? 'tls' : '',
        'sni': _g(d, 'sni'),
        'alpn': _g(d, 'alpn'),
        'fp': _g(d, 'fp', 'chrome'),
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(m)))}';
    case 'trojan':
      if (id.isEmpty) throw 'Password is empty';
      return mk('trojan', id, q).toString();
    case 'shadowsocks':
      final ui = base64Url
          .encode(utf8.encode('${_g(d, 'method', 'aes-256-gcm')}:$id'))
          .replaceAll('=', '');
      return mk('ss', ui, {}).toString();
    case 'socks':
      final user = _g(d, 'user');
      return mk('socks', user.isEmpty ? '' : '$user:$id', {}).toString();
    case 'hysteria2':
      if (id.isEmpty) throw 'Auth password is empty';
      final h = <String, String>{};
      if (_g(d, 'sni').isNotEmpty) h['sni'] = _g(d, 'sni');
      if (_g(d, 'obfsPass').isNotEmpty) {
        h['obfs'] = 'salamander';
        h['obfs-password'] = _g(d, 'obfsPass');
      }
      if (_g(d, 'mport').isNotEmpty) h['mport'] = _g(d, 'mport');
      if (_g(d, 'pcs').isNotEmpty) h['pcs'] = _g(d, 'pcs');
      return mk('hysteria2', id, h).toString();
  }
  throw 'Unknown protocol $proto';
}
