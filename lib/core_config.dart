import 'dart:convert';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'models.dart';

/// Routes that exclude RFC1918 LAN ranges (used when "Bypass LAN" is on).
const List<String> lanBypassSubnets = [
  '0.0.0.0/5', '8.0.0.0/7', '11.0.0.0/8', '12.0.0.0/6', '16.0.0.0/4',
  '32.0.0.0/3', '64.0.0.0/2', '128.0.0.0/3', '160.0.0.0/5', '168.0.0.0/6',
  '172.0.0.0/12', '172.32.0.0/11', '172.64.0.0/10', '172.128.0.0/9',
  '173.0.0.0/8', '174.0.0.0/7', '176.0.0.0/4', '192.0.0.0/9',
  '192.128.0.0/11', '192.160.0.0/13', '192.169.0.0/16', '192.170.0.0/15',
  '192.172.0.0/14', '192.176.0.0/12', '192.192.0.0/10', '193.0.0.0/8',
  '194.0.0.0/7', '196.0.0.0/6', '200.0.0.0/5', '208.0.0.0/4', '240.0.0.0/4',
];

String _q(Map<String, String?> m) => m.entries
    .where((e) => e.value != null && e.value!.isNotEmpty)
    .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}')
    .join('&');

String _s(Map<String, dynamic> d, String k, [String def = '']) {
  final v = d[k];
  return v == null ? def : v.toString().trim();
}

/// Builds a share link from the guided form fields.
String buildShareLink(Profile p) {
  final d = p.data;
  final proto = _s(d, 'proto', 'vless');
  final addr = _s(d, 'address');
  final port = _s(d, 'port', '443');
  final id = _s(d, 'id');
  if (addr.isEmpty) throw 'Server address is empty';
  if (id.isEmpty) throw 'UUID / password is empty';
  final name = Uri.encodeComponent(p.name);
  final net = _s(d, 'net', 'tcp');
  final sec = _s(d, 'security', 'tls');

  switch (proto) {
    case 'vmess':
      final j = {
        'v': '2',
        'ps': p.name,
        'add': addr,
        'port': port,
        'id': id,
        'aid': '0',
        'scy': 'auto',
        'net': net,
        'type': 'none',
        'host': _s(d, 'host'),
        'path': _s(d, 'path'),
        'tls': sec == 'tls' ? 'tls' : '',
        'sni': _s(d, 'sni'),
        'alpn': _s(d, 'alpn'),
        'fp': _s(d, 'fp'),
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    case 'trojan':
      final q = _q({
        'type': net,
        'security': sec,
        'sni': _s(d, 'sni'),
        'fp': _s(d, 'fp'),
        'alpn': _s(d, 'alpn'),
        'host': _s(d, 'host'),
        'path': _s(d, 'path'),
        'pcs': _s(d, 'pcs'),
      });
      return 'trojan://${Uri.encodeComponent(id)}@$addr:$port?$q#$name';
    case 'ss':
      final method = _s(d, 'method', 'aes-256-gcm');
      final ui = base64.encode(utf8.encode('$method:$id')).replaceAll('=', '');
      return 'ss://$ui@$addr:$port#$name';
    case 'hysteria2':
      final q = _q({
        'sni': _s(d, 'sni'),
        'obfs': _s(d, 'obfs'),
        'obfs-password': _s(d, 'obfsPassword'),
        'pinSHA256': _s(d, 'pcs'),
        'mport': _s(d, 'mport'),
      });
      return 'hysteria2://${Uri.encodeComponent(id)}@$addr:$port${q.isEmpty ? '' : '?$q'}#$name';
    case 'vless':
    default:
      final q = _q({
        'type': net,
        'security': sec,
        'encryption': _s(d, 'encryption', 'none'),
        'flow': _s(d, 'flow'),
        'sni': _s(d, 'sni'),
        'fp': _s(d, 'fp'),
        'alpn': _s(d, 'alpn'),
        'host': _s(d, 'host'),
        'path': _s(d, 'path'),
        'pbk': _s(d, 'pbk'),
        'sid': _s(d, 'sid'),
        'spx': _s(d, 'spx'),
        'pcs': _s(d, 'pcs'),
      });
      return 'vless://$id@$addr:$port?$q#$name';
  }
}

Map<String, dynamic> _template(String socksUrl) {
  final cfg = V2ray.parseFromURL(socksUrl).getFullConfiguration();
  return Map<String, dynamic>.from(jsonDecode(cfg) as Map);
}

/// Config for a link / guided / raw-JSON Xray profile.
String buildV2rayConfig(Profile p) {
  final mode = _s(p.data, 'mode', 'link');
  if (mode == 'json') {
    final src = _s(p.data, 'json');
    jsonDecode(src); // validate early with a clear FormatException
    return src;
  }
  final link = mode == 'gui' ? buildShareLink(p) : _s(p.data, 'link');
  if (link.isEmpty) throw 'No link configured';
  try {
    return V2ray.parseFromURL(link).getFullConfiguration();
  } catch (e) {
    throw 'Link rejected by parser: $e';
  }
}

/// Local SOCKS outbound used for SSH mode (the SSH client exposes this port).
String buildSocksConfig(int port) => V2ray.parseFromURL('socks://127.0.0.1:$port#SSH').getFullConfiguration();

/// HTTP / HTTPS / SOCKS5 upstream proxy as an Xray outbound.
String buildProxyConfig(Profile p) {
  final d = p.data;
  final kind = _s(d, 'kind', 'socks5');
  final host = _s(d, 'host');
  final port = int.tryParse(_s(d, 'port')) ?? (kind == 'socks5' ? 1080 : 8080);
  final user = _s(d, 'user');
  if (host.isEmpty) throw 'Proxy host is empty';
  final m = _template('socks://127.0.0.1:10809#PX');
  final out = <String, dynamic>{
    'tag': 'proxy',
    'protocol': kind == 'socks5' ? 'socks' : 'http',
    'settings': {
      'servers': [
        {
          'address': host,
          'port': port,
          if (user.isNotEmpty)
            'users': [
              {'user': user, 'pass': (d['pass'] ?? '').toString()}
            ],
        }
      ],
    },
    if (kind == 'https')
      'streamSettings': {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'serverName': _s(d, 'sni').isEmpty ? host : _s(d, 'sni')},
      },
  };
  final outs = (m['outbounds'] as List).toList();
  outs[0] = out;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

String buildWireGuardConfig(Profile p) {
  final conf = _s(p.data, 'conf');
  final iface = <String, String>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? cur;
  for (final raw in conf.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.toLowerCase() == '[interface]') {
      cur = iface;
    } else if (line.toLowerCase() == '[peer]') {
      cur = <String, String>{};
      peers.add(cur);
    } else if (cur != null && line.contains('=')) {
      final i = line.indexOf('=');
      cur[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
  }
  if (iface['privatekey'] == null || peers.isEmpty) {
    throw 'WireGuard config needs [Interface] PrivateKey and at least one [Peer]';
  }
  List<String> list(String? v) =>
      (v ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  final m = _template('socks://127.0.0.1:10809#WG');
  final out = <String, dynamic>{
    'tag': 'proxy',
    'protocol': 'wireguard',
    'settings': {
      'secretKey': iface['privatekey'],
      'address': list(iface['address']),
      'mtu': int.tryParse(iface['mtu'] ?? '') ?? 1280,
      'peers': [
        for (final pr in peers)
          {
            'publicKey': pr['publickey'],
            if (pr['presharedkey'] != null) 'preSharedKey': pr['presharedkey'],
            'endpoint': pr['endpoint'],
            'allowedIPs': list(pr['allowedips']).isEmpty ? ['0.0.0.0/0', '::/0'] : list(pr['allowedips']),
            if (pr['persistentkeepalive'] != null)
              'keepAlive': int.tryParse(pr['persistentkeepalive']!) ?? 0,
          }
      ],
    },
  };
  final outs = (m['outbounds'] as List).toList();
  outs[0] = out;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

/// Applies DNS handling to a generated config.
///
/// Uses Xray's documented DNS hijack: a `dns` outbound plus a port-53 routing
/// rule hands app DNS queries to the built-in resolver. `dns.tag` is used as an
/// inbound tag so the resolver's own upstream queries are routed through the
/// proxy outbound instead of looping back into the hijack rule.
///
/// [tcpOnly] is for SSH mode: UDP cannot ride an SSH channel, so resolvers are
/// tcp:// and other UDP is rejected quickly (apps fall back to TCP).
String applyNetwork(String cfg, AppSettings s, {bool tcpOnly = false}) {
  final custom = s.dnsPreset != 'default' || s.fallbackDns.trim().isNotEmpty;
  if (!tcpOnly && !custom) return cfg;

  final m = Map<String, dynamic>.from(jsonDecode(cfg) as Map);
  var servers = s.dnsServers(tcp: tcpOnly);
  if (servers.isEmpty) {
    servers = tcpOnly ? ['tcp://1.1.1.1', 'tcp://8.8.8.8'] : ['8.8.8.8', '8.8.4.4'];
  }
  final dns = Map<String, dynamic>.from((m['dns'] as Map?) ?? {});
  dns['servers'] = servers;
  dns['tag'] = 'dns_in';
  if (s.dnsIpv4Only) dns['queryStrategy'] = 'UseIPv4';
  m['dns'] = dns;

  final outs = [
    for (final o in (m['outbounds'] as List? ?? const [])) Map<String, dynamic>.from(o as Map)
  ];
  final proxyTag = outs.isNotEmpty ? '${outs.first['tag'] ?? 'proxy'}' : 'proxy';
  String? blockTag;
  for (final o in outs) {
    if (o['protocol'] == 'blackhole') blockTag = '${o['tag']}';
  }
  if (!outs.any((o) => o['tag'] == 'dns-out')) {
    outs.add({'tag': 'dns-out', 'protocol': 'dns'});
  }
  m['outbounds'] = outs;

  final routing = Map<String, dynamic>.from((m['routing'] as Map?) ?? {});
  final rules = <dynamic>[
    {'type': 'field', 'inboundTag': ['dns_in'], 'outboundTag': proxyTag},
    {'type': 'field', 'port': '53', 'outboundTag': 'dns-out'},
    if (tcpOnly && blockTag != null) {'type': 'field', 'network': 'udp', 'outboundTag': blockTag},
    ...((routing['rules'] as List?) ?? const []),
  ];
  routing['rules'] = rules;
  m['routing'] = routing;
  return jsonEncode(m);
}

/// HTTP / HTTPS / SOCKS5 upstream proxy, carried by an Xray outbound.
/// HTTPS means TLS to the proxy itself (then CONNECT inside it).
String buildProxyConfig(Profile p) {
  final d = p.data;
  final kind = _s(d, 'kind', 'socks5');
  final host = _s(d, 'host');
  final port = int.tryParse(_s(d, 'port', kind == 'socks5' ? '1080' : '8080'));
  if (host.isEmpty) throw 'Proxy host is empty';
  if (port == null || port < 1 || port > 65535) throw 'Proxy port must be 1-65535';
  final user = _s(d, 'user');
  final server = <String, dynamic>{
    'address': host,
    'port': port,
    if (user.isNotEmpty)
      'users': [
        {'user': user, 'pass': _s(d, 'pass')}
      ],
  };
  final out = <String, dynamic>{
    'tag': 'proxy',
    'protocol': kind == 'socks5' ? 'socks' : 'http',
    'settings': {
      'servers': [server]
    },
    if (kind == 'https')
      'streamSettings': {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'serverName': _s(d, 'sni').isEmpty ? host : _s(d, 'sni')},
      },
  };
  final m = _template('socks://127.0.0.1:10809#Proxy');
  final outs = (m['outbounds'] as List).toList();
  outs[0] = out;
  m['outbounds'] = outs;
  return jsonEncode(m);
}
