import 'dart:convert';
import 'dart:io';

const shareSchemes = ['vmess', 'vless', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2', 'hysteria', 'ssh'];

class Subscription {
  Subscription({required this.id, required this.name, required this.url, this.updated = 0});
  final String id;
  String name;
  String url;
  int updated; // millisecondsSinceEpoch, 0 = never

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'updated': updated};

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        updated: (j['updated'] ?? 0) as int,
      );
}

String? _tryBase64(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  if (t.isEmpty || RegExp(r'[^A-Za-z0-9+/=]').hasMatch(t)) return null;
  t = t.replaceAll('=', '');
  t += '=' * ((4 - t.length % 4) % 4);
  try {
    return utf8.decode(base64.decode(t), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Subscription bodies are either plain newline-separated share links or the
/// same list base64-encoded (the de-facto standard used by v2rayN / v2rayNG).
List<String> parseSubscriptionBody(String body) {
  var t = body.trim();
  if (!t.contains('://')) {
    t = _tryBase64(t) ?? t;
  }
  final out = <String>[];
  for (final line in t.split(RegExp(r'[\r\n]+'))) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final scheme = l.split('://').first.toLowerCase();
    if (l.contains('://') && shareSchemes.contains(scheme)) out.add(l);
  }
  return out;
}

/// Display name of a share link (URL fragment, or `ps` of a vmess:// JSON).
String shareLinkName(String link) {
  final l = link.trim();
  if (l.toLowerCase().startsWith('vmess://')) {
    final j = _tryBase64(l.substring(8));
    if (j != null) {
      try {
        final ps = (jsonDecode(j) as Map)['ps'];
        if (ps != null && ps.toString().isNotEmpty) return ps.toString();
      } catch (_) {}
    }
  }
  final i = l.indexOf('#');
  if (i >= 0 && i < l.length - 1) {
    try {
      return Uri.decodeComponent(l.substring(i + 1));
    } catch (_) {
      return l.substring(i + 1);
    }
  }
  return l.split('://').first.toUpperCase();
}

Future<String> fetchSubscription(String url, {Duration timeout = const Duration(seconds: 20)}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw 'Subscription URL must start with http:// or https://';
  }
  final c = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await c.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, 'XRayVpn/2.1 (v2rayN-compatible)');
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) throw 'Server answered HTTP ${res.statusCode}';
    final bytes = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 5 * 1024 * 1024) throw 'Subscription is larger than 5 MB';
    }
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    c.close(force: true);
  }
}
