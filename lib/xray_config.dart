import 'dart:convert';

import 'models.dart';

Map<String, dynamic> buildXrayVpnConfig({
  required ServerProfile profile,
  required AppPreferences preferences,
  required List<dynamic> importedOutbounds,
  bool useTun = true,
}) {
  final logLevel = preferences.logLevel;
  final inbounds = <Map<String, dynamic>>[
    if (useTun) {
      'tag': 'tun-in',
      'port': 0,
      'protocol': 'tun',
      'settings': {'name': 'xray-vpn', 'mtu': 1500},
    },
    {
      'tag': 'diagnostics-http',
      'listen': '127.0.0.1',
      'port': 10809,
      'protocol': 'http',
      'settings': {'allowTransparent': false},
    },
  ];
  if (profile.kind != ProfileKind.ssh && (preferences.shareProxy || !useTun)) {
    if (preferences.shareProxy && (preferences.hotspotUser.trim().isEmpty || preferences.hotspotPassword.isEmpty)) {
      throw const FormatException('Set proxy sharing username and password before enabling sharing');
    }
    inbounds.add({
      'tag': 'local-socks',
      'listen': preferences.shareProxy ? '0.0.0.0' : '127.0.0.1',
      'port': preferences.socksPort,
      'protocol': 'socks',
      'settings': preferences.shareProxy
          ? {'auth': 'password', 'accounts': [{'user': preferences.hotspotUser, 'pass': preferences.hotspotPassword}], 'udp': true}
          : {'auth': 'noauth', 'udp': true},
    });
  }
  final outbounds = importedOutbounds.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  if (profile.kind == ProfileKind.ssh) {
    outbounds
      ..clear()
      ..add({
        'tag': 'proxy',
        'protocol': 'socks',
        'settings': {
          'servers': [
            {'address': '127.0.0.1', 'port': preferences.socksPort},
          ],
          'version': '5',
        },
      });
  }
  if (outbounds.isEmpty) throw const FormatException('The selected profile has no usable Xray outbound');
  String? directTag;
  if (preferences.bypassLan) {
    final direct = outbounds.where((outbound) => outbound['protocol'] == 'freedom').toList();
    if (direct.isEmpty) {
      outbounds.add({'tag': 'direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}});
      directTag = 'direct';
    } else {
      directTag = (direct.first['tag'] ?? 'direct').toString();
      direct.first['tag'] ??= directTag;
    }
  }

  final preferred = outbounds.firstWhere(
    (outbound) => !{'freedom', 'blackhole', 'dns'}.contains(outbound['protocol']),
    orElse: () => outbounds.first,
  );
  final preferredTag = (preferred['tag'] ?? 'proxy').toString();
  if (preferred['tag'] == null) preferred['tag'] = preferredTag;

  final config = <String, dynamic>{
    'log': {'loglevel': logLevel},
    'dns': {
      'servers': profile.kind == ProfileKind.ssh
          ? ['https://1.1.1.1/dns-query']
          : _dnsServers(preferences),
    },
    'inbounds': inbounds,
    'outbounds': outbounds,
    'routing': {'domainStrategy': 'AsIs', 'rules': <Map<String, dynamic>>[]},
    'metrics': {'listen': '127.0.0.1:49227'},
    'policy': {
      'system': {
        'statsInboundUplink': true,
        'statsInboundDownlink': true,
        'statsOutboundUplink': true,
        'statsOutboundDownlink': true,
      },
    },
    'stats': <String, dynamic>{},
  };
  if (preferences.blockQuic && !outbounds.any((outbound) => outbound['tag'] == 'block')) {
    outbounds.add({'tag': 'block', 'protocol': 'blackhole', 'settings': {'response': {'type': 'none'}}});
  }
  final rules = <Map<String, dynamic>>[
    if (preferences.blockQuic) {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    {'type': 'field', 'inboundTag': ['diagnostics-http', if (profile.kind != ProfileKind.ssh && (preferences.shareProxy || !useTun)) 'local-socks'], 'outboundTag': preferredTag},
    if (preferences.bypassLan) {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': directTag ?? 'direct'},
    if (useTun) {'type': 'field', 'inboundTag': ['tun-in'], 'outboundTag': preferredTag},
  ];
  config['routing'] = {'domainStrategy': 'AsIs', 'rules': rules};
  return config;
}

List<String> _dnsServers(AppPreferences preferences) {
  return switch (preferences.dnsMode) {
    'google' => ['8.8.8.8', '8.8.4.4'],
    'quad9' => ['9.9.9.9', '149.112.112.112'],
    'adguard' => ['94.140.14.14', '94.140.15.15'],
    'custom' => [preferences.customDns.trim().isEmpty ? '1.1.1.1' : preferences.customDns.trim()],
    _ => ['1.1.1.1', '1.0.0.1'],
  };
}

String normalizeRawXrayJson(String raw, AppPreferences preferences, {bool useTun = true}) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) throw const FormatException('Xray JSON must be an object');
  if (decoded['outbounds'] is! List || (decoded['outbounds'] as List).isEmpty) {
    throw const FormatException('Xray JSON must contain at least one outbound');
  }
  final inbounds = <Map<String, dynamic>>[
    if (useTun) {'tag': 'tun-in', 'port': 0, 'protocol': 'tun', 'settings': {'name': 'xray-vpn', 'mtu': 1500}},
    {'tag': 'diagnostics-http', 'listen': '127.0.0.1', 'port': 10809, 'protocol': 'http', 'settings': {'allowTransparent': false}},
  ];
  if (preferences.shareProxy || !useTun) {
    if (preferences.shareProxy && (preferences.hotspotUser.trim().isEmpty || preferences.hotspotPassword.isEmpty)) {
      throw const FormatException('Set proxy sharing username and password before enabling sharing');
    }
    inbounds.add({'tag': 'local-socks', 'listen': preferences.shareProxy ? '0.0.0.0' : '127.0.0.1', 'port': preferences.socksPort, 'protocol': 'socks',
      'settings': preferences.shareProxy ? {'auth': 'password', 'accounts': [{'user': preferences.hotspotUser, 'pass': preferences.hotspotPassword}], 'udp': true} : {'auth': 'noauth', 'udp': true}});
  }
  decoded['inbounds'] = inbounds;
  final outbounds = (decoded['outbounds'] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  if (outbounds.isEmpty) throw const FormatException('Xray JSON has no valid outbound objects');
  String? directTag;
  if (preferences.bypassLan) {
    final direct = outbounds.where((item) => item['protocol'] == 'freedom').toList();
    if (direct.isEmpty) { outbounds.add({'tag': 'direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}}); directTag = 'direct'; }
    else { directTag = (direct.first['tag'] ?? 'direct').toString(); direct.first['tag'] ??= directTag; }
  }
  final preferred = outbounds.firstWhere((item) => !{'freedom', 'blackhole', 'dns'}.contains(item['protocol']), orElse: () => outbounds.first);
  final preferredTag = (preferred['tag'] ?? 'proxy').toString();
  preferred['tag'] ??= preferredTag;
  decoded['outbounds'] = outbounds;
  final routing = Map<String, dynamic>.from((decoded['routing'] as Map?) ?? const {});
  final rules = (routing['rules'] as List?)?.map((item) => Map<String, dynamic>.from(item as Map)).toList() ?? <Map<String, dynamic>>[];
  rules.insert(0, {'type': 'field', 'inboundTag': ['diagnostics-http', if (preferences.shareProxy || !useTun) 'local-socks'], 'outboundTag': preferredTag});
  if (preferences.blockQuic && !outbounds.any((item) => item['tag'] == 'block')) {
    outbounds.add({'tag': 'block', 'protocol': 'blackhole', 'settings': {'response': {'type': 'none'}}});
  }
  if (preferences.blockQuic) rules.insert(0, {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'});
  if (preferences.bypassLan) rules.insert(preferences.blockQuic ? 2 : 1, {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': directTag ?? 'direct'});
  if (useTun) rules.add({'type': 'field', 'inboundTag': ['tun-in'], 'outboundTag': preferredTag});
  routing['rules'] = rules;
  decoded['routing'] = routing;
  decoded['log'] = {'loglevel': preferences.logLevel};
  decoded['metrics'] = {'listen': '127.0.0.1:49227'};
  decoded['policy'] = {
    'system': {
      'statsInboundUplink': true,
      'statsInboundDownlink': true,
      'statsOutboundUplink': true,
      'statsOutboundDownlink': true,
    },
  };
  decoded['stats'] ??= <String, dynamic>{};
  decoded['env'] = Map<String, dynamic>.from((decoded['env'] as Map?) ?? const {});
  if (!useTun) (decoded['env'] as Map<String, dynamic>).remove('xray.tun.fd');
  return jsonEncode(decoded);
}
