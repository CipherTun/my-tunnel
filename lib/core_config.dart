import 'dart:convert';
import 'package:v2ray_box/v2ray_box.dart';
import 'models.dart';

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

Map<String, dynamic> wgToOutbound(String conf) {
  final iface = <String, String>{};
  final peer = <String, String>{};
  var sec = '';
  for (var line in conf.split('\n')) {
    line = line.split('#').first.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      sec = line.toLowerCase();
      continue;
    }
    final i = line.indexOf('=');
    if (i < 0) continue;
    (sec == '[peer]' ? peer : iface)[line.substring(0, i).trim().toLowerCase()] =
        line.substring(i + 1).trim();
  }
  List<String> list(String? s) =>
      (s ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (iface['privatekey'] == null ||
      peer['publickey'] == null ||
      peer['endpoint'] == null) {
    throw 'WireGuard config needs PrivateKey, PublicKey and Endpoint';
  }
  return {
    'tag': 'proxy',
    'protocol': 'wireguard',
    'settings': {
      'secretKey': iface['privatekey'],
      'address': list(iface['address']),
      'peers': [
        {
          'publicKey': peer['publickey'],
          if (peer['presharedkey'] != null) 'preSharedKey': peer['presharedkey'],
          'endpoint': peer['endpoint'],
          'allowedIPs':
              peer['allowedips'] == null ? ['0.0.0.0/0', '::/0'] : list(peer['allowedips']),
          'keepAlive': int.tryParse(peer['persistentkeepalive'] ?? '') ?? 25,
        }
      ],
      'mtu': int.tryParse(iface['mtu'] ?? '') ?? 1280,
    },
  };
}

Future<String> _template(V2rayBox box) =>
    box.generateConfig('socks://127.0.0.1:1080#tpl');

Future<String> _withOutbound(
    Map<String, dynamic> outbound, V2rayBox box) async {
  final m = jsonDecode(await _template(box)) as Map<String, dynamic>;
  final outs = (m['outbounds'] as List).cast<Map<String, dynamic>>();
  var idx = outs.indexWhere((o) => o['tag'] == 'proxy');
  if (idx < 0) idx = 0;
  outs[idx] = outbound;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

/// Applies the DNS changer settings. [tcpOnly] is used for SSH mode, where
/// only TCP can be carried.
String patchDns(String cfg, AppSettings s, {bool tcpOnly = false}) {
  var servers = s.dnsServers;
  if (tcpOnly) {
    servers = (servers.isEmpty ? ['1.1.1.1', '8.8.8.8'] : servers)
        .map((e) => e.contains('://') ? e : 'tcp://$e')
        .toList();
  }
  if (servers.isEmpty) return cfg;
  try {
    final m = jsonDecode(cfg) as Map<String, dynamic>;
    final dns = Map<String, dynamic>.from((m['dns'] as Map?) ?? {});
    dns['servers'] = servers;
    m['dns'] = dns;
    return jsonEncode(m);
  } catch (_) {
    return cfg;
  }
}

Future<String> buildXrayConfig(
    Profile p, AppSettings s, V2rayBox box) async {
  switch (p.s('mode')) {
    case 'json':
      final raw = p.s('json').trim();
      try {
        jsonDecode(raw);
      } catch (e) {
        throw 'Invalid JSON: $e';
      }
      return raw;
    case 'link':
      return patchDns(
          await box.generateConfig(p.s('link').trim()), s);
    default:
      final link = buildShareLink(p.data, p.name);
      return patchDns(await box.generateConfig(link), s);
  }
}

Future<String> buildWireguardConfig(
        String conf, AppSettings s, V2rayBox box) async =>
    patchDns(await _withOutbound(wgToOutbound(conf), box), s);

Future<String> buildSocksConfig(
    int port, AppSettings s, V2rayBox box) async {
  final cfg = await box.generateConfig('socks://127.0.0.1:$port#SSH');
  return patchDns(cfg, s, tcpOnly: true);
}
