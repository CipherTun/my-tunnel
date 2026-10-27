import 'dart:convert';
import 'dart:math';

class PayloadExpansion {
  const PayloadExpansion({required this.chunks, required this.raw, required this.delay});
  final List<List<int>> chunks;
  final bool raw;
  final Duration delay;
}

PayloadExpansion expandPayload(String template, {required String host, required int port, String sni = '', String method = 'CONNECT'}) {
  var source = template;
  var raw = false;
  if (source.contains('[raw]')) {
    raw = true;
    source = source.replaceAll('[raw]', '');
  }
  var delayMs = source.toLowerCase().contains('[delay_split]') ? 250 : 0;
  final delayMatch = RegExp(r'\[delay:(\d+)\]', caseSensitive: false).firstMatch(source);
  if (delayMatch != null) {
    delayMs = int.tryParse(delayMatch.group(1) ?? '') ?? 0;
    source = source.replaceFirst(delayMatch.group(0)!, '');
  }
  source = source
      .replaceAll('[host]', host)
      .replaceAll('[port]', '$port')
      .replaceAll('[ssh]', '$host:$port')
      .replaceAll('[sni]', sni.isEmpty ? host : sni)
      .replaceAll('[method]', method)
      .replaceAll('[protocol]', 'HTTP/1.1')
      .replaceAll('[lfcr]', '\n\r')
      .replaceAll('[crlf*2]', '\r\n\r\n')
      .replaceAll('[crlf]', '\r\n')
      .replaceAll('[lf]', '\n')
      .replaceAll('[cr]', '\r');
  source = source.replaceAllMapped(RegExp(r'\[random\]', caseSensitive: false), (_) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  });
  final pieces = source.split(RegExp(r'\[(?:split|delay_split|instant_split)\]', caseSensitive: false));
  final chunks = pieces.map((part) => utf8.encode(part)).where((part) => part.isNotEmpty).toList();
  return PayloadExpansion(chunks: chunks, raw: raw, delay: Duration(milliseconds: delayMs));
}
