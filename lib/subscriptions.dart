import 'dart:convert';
import 'dart:io';
import 'models.dart';

/// Downloads a subscription body (max 5 MB, 20 s).
Future<String> fetchSubscription(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
    throw 'Not a valid http(s) URL';
  }
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'XRayVpn/3.0';
  try {
    final req = await c.getUrl(uri).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'Server answered HTTP ${res.statusCode}';
    final bb = BytesBuilder();
    await for (final d in res.timeout(const Duration(seconds: 20))) {
      bb.add(d);
      if (bb.length > 5 * 1024 * 1024) throw 'Subscription is larger than 5 MB';
    }
    return utf8.decode(bb.takeBytes(), allowMalformed: true);
  } finally {
    c.close(force: true);
  }
}

/// Subscription bodies are either plain share links (one per line) or the
/// same list base64-encoded.
List<String> splitLinks(String body) {
  var t = body.trim();
  if (!t.contains('://')) {
    try {
      t = decodeB64(t);
    } catch (_) {
      return [];
    }
  }
  return t
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.contains('://'))
      .toList();
}

/// Parses a subscription body into profiles (unrecognised lines are skipped).
List<Profile> parseSubscription(String body, String subId) {
  final out = <Profile>[];
  for (final l in splitLinks(body)) {
    final p = importProfile(l);
    if (p != null) {
      p.subId = subId;
      out.add(p);
    }
  }
  return out;
}

/// Stable identity of an imported profile, used to keep ids/edits on refresh.
String profileKey(Profile p) => '${p.type.name}|${p.data['link'] ?? p.data['json'] ?? p.data['conf'] ?? '${p.data['host']}:${p.data['port']}'}';
