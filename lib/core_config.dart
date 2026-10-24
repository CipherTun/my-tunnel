import 'dart:convert';

import 'package:flutter_v2ray_client/flutter_v2ray.dart';

import 'config_tweaks.dart';
import 'models.dart';

export 'config_tweaks.dart' show lanBypassSubnets;

String _template() => V2ray.parseFromURL('socks://127.0.0.1:1080#tpl').getFullConfiguration();

String _withOutbound(Map<String, dynamic> outbound) {
  final m = jsonDecode(_template()) as Map<String, dynamic>;
  final outs = (m['outbounds'] as List).cast<Map<String, dynamic>>();
  var idx = outs.indexWhere((o) => o['tag'] == 'proxy');
  if (idx < 0) idx = 0;
  outs[idx] = outbound;
  m['outbounds'] = outs;
  return jsonEncode(m);
}

String patchDns(String cfg, AppSettings s, {bool tcpOnly = false}) =>
    patchDnsJson(cfg, s.dnsServers, tcpOnly: tcpOnly);

/// Final touches shared by every Xray config: the inbound port/listen address
/// (so the app always knows where the local proxy is) and the log level.
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

String buildXrayConfig(Profile p, AppSettings s) {
  switch (p.s('mode')) {
    case 'json':
      // Raw JSON is passed through untouched: the user owns it completely.
      final raw = p.s('json').trim();
      try {
        jsonDecode(raw);
      } catch (e) {
        throw 'Invalid JSON: $e';
      }
      return raw;
    case 'link':
      return _finish(
          _tweak(
              overrideAddress(
                  patchDns(V2ray.parseFromURL(p.s('link').trim()).getFullConfiguration(), s),
                  p.connectAddr),
              s),
          s,
          s.socksPort);
    default:
      return _finish(
          _tweak(
              overrideAddress(
                  patchDns(
                      V2ray.parseFromURL(buildShareLink(p.data, p.name)).getFullConfiguration(), s),
                  p.connectAddr),
              s),
          s,
          s.socksPort);
  }
}

/// HTTP / HTTPS / SOCKS5 upstream proxy as the VPN's outbound.
String buildProxyConfig(Profile p, AppSettings s) => _finish(
    _tweak(
        overrideAddress(patchDns(_withOutbound(buildProxyOutbound(p.data)), s), p.connectAddr), s),
    s,
    s.socksPort);

/// entry -> exit chain of two Xray profiles (see [chainConfigs]).
String buildChainConfig(Profile entry, Profile exit, AppSettings s) {
  for (final p in [entry, exit]) {
    if (p.type != ProfileType.v2ray || p.s('mode') == 'json') {
      throw 'Chains use link/manual V2Ray profiles only (${p.name} is not)';
    }
  }
  // Build both without tweaks, chain them, then tweak the combined config.
  String raw(Profile p) {
    final link = p.s('mode') == 'link' ? p.s('link').trim() : buildShareLink(p.data, p.name);
    return overrideAddress(
        patchDns(V2ray.parseFromURL(link).getFullConfiguration(), s), p.connectAddr);
  }

  return _finish(_tweak(chainConfigs(raw(exit), raw(entry)), s), s, s.socksPort);
}

String buildWireguardConfig(String conf, AppSettings s) =>
    _finish(patchDns(_withOutbound(wgToOutbound(conf)), s), s, s.socksPort);

/// Xray config that forwards everything to our local SOCKS5 server (SSH mode).
String buildSocksConfig(int port, AppSettings s) {
  final cfg = V2ray.parseFromURL('socks://127.0.0.1:$port#SSH').getFullConfiguration();
  // Xray's own inbound must not collide with the SSH local SOCKS server on [port].
  return _finish(patchDns(cfg, s, tcpOnly: true), s, port >= 65535 ? port - 1 : port + 1);
}

/// Share link of a v2ray profile (for the QR code / clipboard), or null.
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
