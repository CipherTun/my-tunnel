import 'dart:convert';

import 'models.dart';

/// Builds sing-box 1.14-compatible JSON for common standard share links.
/// Unsupported transports/protocols throw instead of generating a fake config.
String buildSingboxConfig(Profile p, AppSettings settings) {
  Map<String, dynamic> outbound;
  if (p.type == ProfileType.wireguard) {
    outbound = _wireguard(p.s('config'));
  } else if (p.type != ProfileType.v2ray) {
    throw 'sing-box engine supports standard proxy profiles and WireGuard; SSH payload uses the existing Xray bridge.';
  } else if (p.s('mode') == 'json') {
    return _normalizeRawSingbox(p.s('json'), settings);
  } else {
    final link = p.s('mode') == 'link' ? p.s('link') : _manualLink(p);
    outbound = _linkOutbound(link);
  }
  outbound['tag'] = 'proxy';
  return jsonEncode(_baseConfig(outbound, settings));
}

String _manualLink(Profile p) {
  final d = p.data;
  final proto = (d['proto'] ?? 'vless').toString().toLowerCase();
  final host = (d['address'] ?? '').toString().trim();
  final port = (d['port'] ?? '443').toString().trim();
  final id = (d['id'] ?? '').toString();
  if (host.isEmpty) throw 'Server address is empty';
  final q = <String, String>{
    'type': (d['network'] ?? 'tcp').toString(),
    'security': (d['security'] ?? 'none').toString(),
  };
  for (final k in ['host','path','sni','fp','alpn','pbk','sid','serviceName']) {
    final v = (d[k] ?? '').toString();
    if (v.isNotEmpty) q[k] = v;
  }
  if (proto == 'shadowsocks') {
    return Uri(scheme: 'ss', userInfo: '$id', host: host, port: int.tryParse(port) ?? 443, fragment: p.name).toString();
  }
  return Uri(scheme: proto == 'hysteria2' ? 'hysteria2' : proto,
    userInfo: id, host: host, port: int.tryParse(port) ?? 443,
    queryParameters: q, fragment: p.name).toString();
}

Map<String, dynamic> _linkOutbound(String raw) {
  final trimmed = raw.trim();
  final scheme = trimmed.split('://').first.toLowerCase();
  if (scheme == 'vmess') return _vmess(trimmed);
  if (scheme == 'ss') return _shadowsocks(trimmed);
  if (scheme == 'vless' || scheme == 'trojan' || scheme == 'hysteria2' || scheme == 'hy2' || scheme == 'socks' || scheme == 'hysteria') {
    final uri = Uri.parse(trimmed);
    if (uri.host.isEmpty || !uri.hasPort) throw 'Share link must contain a server host and port';
    final q = uri.queryParameters;
    final host = uri.host;
    final port = uri.port;
    final user = Uri.decodeComponent(uri.userInfo);
    final type = scheme == 'hy2' ? 'hysteria2' : scheme;
    final out = <String, dynamic>{'type': type == 'hysteria' ? 'hysteria' : type, 'tag': 'proxy', 'server': host, 'server_port': port};
    if (type == 'vless') {
      if (user.isEmpty) throw 'VLESS link is missing its UUID';
      out['uuid'] = user;
      if ((q['flow'] ?? '').isNotEmpty) out['flow'] = q['flow'];
      out['packet_encoding'] = 'xudp';
    } else if (type == 'trojan') {
      if (user.isEmpty) throw 'Trojan link is missing its password';
      out['password'] = user;
    } else if (type == 'hysteria2') {
      if (user.isEmpty) throw 'Hysteria2 link is missing its password';
      out['password'] = user;
      final obfs = q['obfs'] ?? '';
      if (obfs.isNotEmpty) out['obfs'] = {'type': obfs, if ((q['obfs-password'] ?? '').isNotEmpty) 'password': q['obfs-password']};
    } else if (type == 'hysteria') {
      if (user.isEmpty) throw 'Hysteria link is missing its auth token';
      out['auth_str'] = user;
    } else if (type == 'socks') {
      if (user.contains(':')) {
        final parts = user.split(':');
        out['username'] = parts.first;
        out['password'] = parts.skip(1).join(':');
      } else if (user.isNotEmpty) {
        out['username'] = user;
      }
    }
    if (type == 'hysteria2' || type == 'hysteria') {
      final tls = <String, dynamic>{'enabled': true};
      final sni = q['sni'] ?? q['server_name'] ?? q['host'] ?? host;
      if (sni.isNotEmpty) tls['server_name'] = sni;
      final fp = q['fp'] ?? '';
      if (fp.isNotEmpty && fp != 'none') tls['utls'] = {'enabled': true, 'fingerprint': fp};
      if (q['insecure'] == '1' || q['allowInsecure'] == '1') tls['insecure'] = true;
      out['tls'] = tls;
    }
    if (type == 'vless' || type == 'trojan') {
      final security = (q['security'] ?? (type == 'trojan' ? 'tls' : 'none')).toLowerCase();
      if (security == 'tls' || security == 'reality') {
        final tls = <String, dynamic>{'enabled': true};
        final sni = q['sni'] ?? q['serverName'] ?? q['host'] ?? host;
        if (sni.isNotEmpty) tls['server_name'] = sni;
        final fp = q['fp'] ?? '';
        if (fp.isNotEmpty && fp != 'none') tls['utls'] = {'enabled': true, 'fingerprint': fp};
        if (security == 'reality') {
          final key = q['pbk'] ?? '';
          if (key.isEmpty) throw 'Reality link is missing the public key (pbk)';
          tls['reality'] = {'enabled': true, 'public_key': key, if ((q['sid'] ?? '').isNotEmpty) 'short_id': q['sid']};
        }
        if ((q['alpn'] ?? '').isNotEmpty) tls['alpn'] = q['alpn']!.split(',');
        if (q['allowInsecure'] == '1' || q['insecure'] == '1') tls['insecure'] = true;
        out['tls'] = tls;
      } else if (security != 'none' && security.isNotEmpty) {
        throw 'Unsupported TLS/security mode: $security';
      }
      final network = (q['type'] ?? 'tcp').toLowerCase();
      if (network == 'ws') {
        final headers = <String, dynamic>{};
        if ((q['host'] ?? '').isNotEmpty) headers['Host'] = q['host'];
        out['transport'] = {'type': 'ws', 'path': q['path'] ?? '/', if (headers.isNotEmpty) 'headers': headers};
      } else if (network == 'grpc') {
        out['transport'] = {'type': 'grpc', 'service_name': q['serviceName'] ?? q['service_name'] ?? ''};
      } else if (network == 'httpupgrade') {
        final headers = <String, dynamic>{};
        if ((q['host'] ?? '').isNotEmpty) headers['Host'] = q['host'];
        out['transport'] = {'type': 'httpupgrade', 'path': q['path'] ?? '/', if (headers.isNotEmpty) 'headers': headers};
      } else if (network != 'tcp' && network != 'raw') {
        throw 'sing-box adapter does not currently map the $network transport. Use Xray engine or a supported transport (tcp/ws/grpc/httpupgrade).';
      }
    }
    return out;
  }
  throw 'Unsupported sing-box share-link protocol: $scheme';
}

Map<String, dynamic> _vmess(String raw) {
  final encoded = raw.substring(raw.indexOf('://') + 3).split('#').first.trim();
  final normalized = base64.normalize(encoded.replaceAll('-', '+').replaceAll('_', '/'));
  final decoded = utf8.decode(base64.decode(normalized));
  final j = jsonDecode(decoded) as Map<String, dynamic>;
  final host = (j['add'] ?? '').toString();
  final port = int.tryParse((j['port'] ?? '').toString());
  final uuid = (j['id'] ?? '').toString();
  if (host.isEmpty || port == null || uuid.isEmpty) throw 'VMess link is missing host, port or UUID';
  final out = <String, dynamic>{'type':'vmess','tag':'proxy','server':host,'server_port':port,'uuid':uuid,
    'security': (j['scy'] ?? 'auto').toString(), 'alter_id': int.tryParse((j['aid'] ?? 0).toString()) ?? 0};
  final tlsValue = (j['tls'] ?? '').toString().toLowerCase();
  if (tlsValue == 'tls') {
    final tls = <String, dynamic>{'enabled':true};
    final sni = (j['sni'] ?? j['host'] ?? host).toString();
    if (sni.isNotEmpty) tls['server_name'] = sni;
    final fp = (j['fp'] ?? '').toString();
    if (fp.isNotEmpty) tls['utls'] = {'enabled':true,'fingerprint':fp};
    out['tls'] = tls;
  }
  final network = (j['net'] ?? 'tcp').toString().toLowerCase();
  if (network == 'ws') {
    final headers = <String,dynamic>{};
    if ((j['host'] ?? '').toString().isNotEmpty) headers['Host'] = j['host'];
    out['transport'] = {'type':'ws','path':(j['path'] ?? '/').toString(), if (headers.isNotEmpty) 'headers':headers};
  } else if (network == 'grpc') {
    out['transport'] = {'type':'grpc','service_name':(j['path'] ?? '').toString()};
  } else if (network != 'tcp') {
    throw 'sing-box adapter does not currently map the VMess $network transport.';
  }
  return out;
}

Map<String, dynamic> _shadowsocks(String raw) {
  final withoutFragment = raw.substring(raw.indexOf('://') + 3).split('#').first;
  if (withoutFragment.contains('?plugin=')) {
    throw 'Shadowsocks plugin parameters are not mapped by this sing-box adapter; use Xray engine or a server link without an unsupported plugin.';
  }
  final body = withoutFragment.split('?').first;
  String methodPassword;
  String host;
  int port;
  if (body.contains('@')) {
    final uri = Uri.parse('ss://$body');
    host = uri.host; port = uri.port;
    methodPassword = Uri.decodeComponent(uri.userInfo);
    if (!methodPassword.contains(':')) {
      try {
        methodPassword = utf8.decode(base64.decode(base64.normalize(methodPassword.replaceAll('-', '+').replaceAll('_', '/'))));
      } catch (_) {
        throw 'Invalid Shadowsocks method/password encoding';
      }
    }
  } else {
    final decoded = utf8.decode(base64.decode(base64.normalize(body.replaceAll('-', '+').replaceAll('_', '/'))));
    final at = decoded.lastIndexOf('@');
    if (at < 1) throw 'Invalid Shadowsocks link';
    methodPassword = decoded.substring(0, at);
    final endpoint = Uri.parse('ss://${decoded.substring(at + 1)}');
    host = endpoint.host; port = endpoint.port;
  }
  final sep = methodPassword.indexOf(':');
  if (sep < 1 || host.isEmpty || port < 1) throw 'Invalid Shadowsocks method/password/endpoint';
  return {'type':'shadowsocks','tag':'proxy','server':host,'server_port':port,
    'method':methodPassword.substring(0,sep),'password':methodPassword.substring(sep+1)};
}

Map<String, dynamic> _wireguard(String raw) {
  final sections = <String, Map<String, String>>{};
  String current = '';
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final clean = line.split('#').first.trim();
    if (clean.isEmpty) continue;
    final sec = RegExp(r'^\[(.+)\]$').firstMatch(clean);
    if (sec != null) { current = sec.group(1)!.toLowerCase(); sections.putIfAbsent(current, () => {}); continue; }
    final eq = clean.indexOf('=');
    if (eq > 0 && current.isNotEmpty) sections[current]![clean.substring(0,eq).trim().toLowerCase()] = clean.substring(eq+1).trim();
  }
  final iface = sections['interface'];
  final peer = sections['peer'];
  if (iface == null || peer == null) throw 'WireGuard config needs [Interface] and at least one [Peer]';
  final endpoint = peer['endpoint'] ?? '';
  final m = RegExp(r'^\[?(.+?)\]?:([0-9]+)$').firstMatch(endpoint);
  if (m == null) throw 'WireGuard peer Endpoint is invalid';
  final addresses = (iface['address'] ?? '').split(',').map((e)=>e.trim()).where((e)=>e.isNotEmpty).toList();
  final allowed = (peer['allowedips'] ?? '0.0.0.0/0, ::/0').split(',').map((e)=>e.trim()).where((e)=>e.isNotEmpty).toList();
  if ((iface['privatekey'] ?? '').isEmpty || (peer['publickey'] ?? '').isEmpty || addresses.isEmpty) throw 'WireGuard config is missing a key or interface address';
  return {'type':'wireguard','tag':'proxy',
    'server':m.group(1),'server_port':int.parse(m.group(2)!),
    'local_address':addresses,'private_key':iface['privatekey'],
    'peer_public_key':peer['publickey'], if ((peer['presharedkey'] ?? '').isNotEmpty) 'pre_shared_key':peer['presharedkey'],
    'allowed_ips':allowed,'mtu':int.tryParse(iface['mtu'] ?? '') ?? 1280,
    'persistent_keepalive_interval':int.tryParse(peer['persistentkeepalive'] ?? '') ?? 25};
}

Map<String, dynamic> _baseConfig(Map<String, dynamic> outbound, AppSettings settings) {
  final dnsIps = settings.dnsServers.isEmpty ? ['1.1.1.1'] : settings.dnsServers;
  final dnsServers = <Map<String,dynamic>>[];
  for (var i=0;i<dnsIps.length;i++) {
    final raw = dnsIps[i];
    final u = Uri.tryParse(raw);
    final scheme = u?.scheme ?? '';
    final server = (u != null && u.hasAuthority) ? u.host : raw;
    final type = scheme == 'https' ? 'https' : scheme == 'tls' ? 'tls' : scheme == 'tcp' ? 'tcp' : 'udp';
    dnsServers.add({'type':type,'tag':'dns-$i','server':server, if (u?.hasPort == true) 'server_port':u!.port, 'detour':'proxy'});
  }
  final config = <String,dynamic>{
    'log': {'level':'info','timestamp':true},
    'dns': {'servers':dnsServers,'final':dnsServers.first['tag'],'strategy':'prefer_ipv4'},
    'inbounds': [
      {'type':'tun','tag':'tun-in','interface_name':'tun0','address':['172.19.0.1/30','fdfe:dcba:9876::1/126'],
       'mtu':1500,'auto_route':true,'strict_route':true,'stack':'mixed'},
    ],
    'outbounds': [outbound, {'type':'direct','tag':'direct'}, {'type':'block','tag':'block'}],
    'route': {'auto_detect_interface':true,'final':'proxy'},
  };
  if (settings.bypassLan) {
    (config['route'] as Map<String,dynamic>)['route_exclude_address'] = ['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','fc00::/7','fe80::/10'];
  }
  return config;
}

String _normalizeRawSingbox(String raw, AppSettings settings) {
  Map<String, dynamic> cfg;
  try { cfg = Map<String,dynamic>.from(jsonDecode(raw) as Map); }
  catch (e) { throw 'Invalid sing-box JSON: $e'; }
  final outs = (cfg['outbounds'] as List?)?.whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList() ?? [];
  if (outs.isEmpty || !outs.any((o) => o['type'] != null)) {
    throw 'This JSON does not look like sing-box config. Xray JSON cannot be used by sing-box directly.';
  }
  if (!(cfg['inbounds'] as List? ?? []).whereType<Map>().any((i)=>i['type']=='tun')) {
    cfg['inbounds'] = [
      {'type':'tun','tag':'tun-in','interface_name':'tun0','address':['172.19.0.1/30','fdfe:dcba:9876::1/126'],'mtu':1500,'auto_route':true,'strict_route':true,'stack':'mixed'},
      ...((cfg['inbounds'] as List?) ?? const []),
    ];
  }
  final route = Map<String,dynamic>.from((cfg['route'] as Map?) ?? {});
  route.putIfAbsent('auto_detect_interface', () => true);
  route.putIfAbsent('final', () => outs.firstWhere(
    (o) => o['tag'] == 'proxy',
    orElse: () => outs.firstWhere((o) => o['tag'] != 'direct' && o['tag'] != 'block', orElse: () => outs.first),
  )['tag']);
  if (settings.bypassLan) route.putIfAbsent('route_exclude_address',()=>['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','fc00::/7','fe80::/10']);
  cfg['route'] = route;
  return jsonEncode(cfg);
}
