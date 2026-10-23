import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config_tweaks.dart';

class ScanResult {
  ScanResult(this.ip, this.ms);
  final String ip;
  final int ms;
}

/// Fetches Cloudflare's published IPv4 ranges (one CIDR per line).
Future<List<String>> fetchCloudflareRanges() async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(Uri.parse('https://www.cloudflare.com/ips-v4'));
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
    final body = await utf8.decodeStream(res);
    return body.split(RegExp(r'\s+')).where((e) => e.contains('/')).toList();
  } finally {
    c.close(force: true);
  }
}

/// Time (ms) of TCP connect + TLS handshake to [ip]:[port] presenting [sni];
/// -1 on failure. This is what a CDN "clean IP" scanner measures.
Future<int> probeTls(String ip, String sni,
    {int port = 443, Duration timeout = const Duration(seconds: 4)}) async {
  final sw = Stopwatch()..start();
  Socket? s;
  try {
    s = await Socket.connect(ip, port, timeout: timeout);
    final t = await SecureSocket.secure(s, host: sni, onBadCertificate: (_) => true)
        .timeout(timeout);
    final ms = sw.elapsedMilliseconds;
    t.destroy();
    return ms;
  } catch (_) {
    s?.destroy();
    return -1;
  }
}

/// Scans [ips] with [parallel] workers. [onProgress] gets (done, total).
Future<List<ScanResult>> scanIps(
  List<String> ips,
  String sni, {
  int parallel = 24,
  int port = 443,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final results = <ScanResult>[];
  var next = 0, done = 0;
  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() == true) return;
      final i = next++;
      if (i >= ips.length) return;
      final ms = await probeTls(ips[i], sni, port: port);
      if (ms > 0) results.add(ScanResult(ips[i], ms));
      onProgress?.call(++done, ips.length);
    }
  }

  await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
  results.sort((a, b) => a.ms.compareTo(b.ms));
  return results;
}

List<String> sampleRanges(List<String> cidrs, int count) => sampleCidrs(cidrs, count);
