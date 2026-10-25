import 'dart:convert';

import 'native.dart';
import 'config_tweaks.dart';
import 'models.dart';

export 'config_tweaks.dart' show lanBypassSubnets;

/// Minimal Xray config used as a safe base for share-link outbounds and local
/// proxy profiles. LibXray owns share-link parsing; this file owns app policy.
String _template() => jsonEncode({
      'log': {'loglevel': 'warning'},
      'dns': {'servers': ['1.1.1.1', '8.8.8.8']},
      'inbounds': [
        {
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': 10808,
          'protocol': 'socks',
          'settings': {'udp': true}
        }
      ],
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole', 'settings': {}}
      ]
    });

String _withOutbound(Map<String, dynamic> outbound) {
  final m = jsonDecode(_template()) as Map<String, dynamic>;
  final outs = (m['outbounds'] as List).cast<Map<String, dynamic>>();
  var idx = outs.indexWhere((o) => o['tag'] == 'proxy');
  if (idx < 0) idx = 0;
  outs[idx] = outbound;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

Future<String> _fromShareLink(String link) async {
  final request = jsonEncode({
    'apiVersion': 3,
    'method': 'convertShareLinksToXrayJson',
    'payload': {'text': link}
  });
  final response = jsonDecode(await Native.libXrayInvoke(request)) as Map<String, dynamic>;
  if (response['success'] != true) {
    throw 'LibXray could not parse this share link: ${response['error'] ?? 'unknown error'}';
  }
  dynamic data = response['data'];
  if (data is String) data = jsonDecode(data);
  if (data is! Map || data['outbounds'] is! List || (data['outbounds'] as List).isEmpty) {
    throw 'LibXray returned no usable outbound for this share link';
  }
  final outs = (data['outbounds'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  final m = jsonDecode(_template()) as Map<String, dynamic>;
  final base = (m['outbounds'] as List).cast<Map<String, dynamic>>();
  final idx = base.indexWhere((o) => o['tag'] == 'proxy');
  if (idx >= 0) {
    final primary = outs.first;
    primary['tag'] = 'proxy';
    base[idx] = primary;
  }
  base.addAll(outs.skip(1));
  m['outbounds'] = base;
  return jsonEncode(m);
}

String patchDns(String cfg, AppSettings s, {bool tcpOnly = false}) =>
    patchDnsJson(cfg, s.dnsServers, tcpOnly: tcpOnly);

String _finish(String cfg, AppSettings s, int inboundPort) =>
    applyLogLevel(applyInbound(cfg, port: inboundPort, listenAll: s.shareHotspot), s.logLevel);

String _tweak(String cfg, AppSettings s) => applyTweaks(
      cfg,
      fragment: s.fragment,
      fragLength: s.fragLength,
      fragInterval: s.fragInterval,
      mux: s.mux,
      muxConcurrency: s.muxConcurrency,
      fingerprint: s.fingerprint,
      blockQuic: s.blockQuic,
    );

Future<String> buildXrayConfig(Profile p, AppSettings s) async {
  if (p.s('mode') == 'json') {
    final raw = p.s('json').trim();
    try {
      jsonDecode(raw);
    } catch (e) {
      throw 'Invalid JSON: $e';
    }
    return raw;
  }
  final link = p.s('mode') == 'link' ? p.s('link').trim() : buildShareLink(p.data, p.name);
  return _finish(
    _tweak(overrideAddress(patchDns(await _fromShareLink(link), s), p.connectAddr), s),
    s,
    s.socksPort,
  );
}

String buildProxyConfig(Profile p, AppSettings s) => _finish(
    _tweak(
        overrideAddress(patchDns(_withOutbound(buildProxyOutbound(p.data)), s), p.connectAddr), s),
    s,
    s.socksPort);

Future<String> buildChainConfig(Profile entry, Profile exit, AppSettings s) async {
  for (final p in [entry, exit]) {
    if (p.type != ProfileType.v2ray || p.s('mode') == 'json') {
      throw 'Chains use link/manual V2Ray profiles only (${p.name} is not)';
    }
  }
  Future<String> raw(Profile p) async {
    final link = p.s('mode') == 'link' ? p.s('link').trim() : buildShareLink(p.data, p.name);
    return overrideAddress(patchDns(await _fromShareLink(link), s), p.connectAddr);
  }

  return _finish(_tweak(chainConfigs(await raw(exit), await raw(entry)), s), s, s.socksPort);
}

String buildWireguardConfig(String conf, AppSettings s) =>
    _finish(patchDns(_withOutbound(wgToOutbound(conf)), s), s, s.socksPort);

/// Xray config that forwards everything to a local TCP tunnel endpoint. The
/// remote endpoint must expose a SOCKS-compatible service through that tunnel.
String buildSocksConfig(int port, AppSettings s, {int? inboundPort}) {
  final cfg = _withOutbound(buildProxyOutbound({
    'kind': 'socks5',
    'address': '127.0.0.1',
    'port': '$port',
  }));
  return _finish(patchDns(cfg, s, tcpOnly: true), s,
      inboundPort ?? (port >= 65535 ? port - 1 : port + 1));
}

String? shareLinkOf(Profile p) {
  if (p.type != ProfileType.v2ray) return null;
  switch (p.s('mode')) {
    case 'link':
      return p.s('link').trim();
    case 'json':
      return null;
    default:
      try {
        return buildShareLink(p.data, p.name);
      } catch (_) {
        return null;
      }
  }
}
