import 'dart:math';

/// HTTP-Injector style payload engine.
///
/// Tokens (names follow the HTTP Injector / HTTP Custom documentation):
///   [crlf] [cr] [lf] [lfcr] [crlf*2]            line breaks
///   [host] [port] [host_port] [ssh]             target (the SSH server)
///   [protocol] [method] [netData] [raw] [real_raw] [ua]
///   [random=a,b,c]  [rotate=a,b,c]              pick one / advance per connection
///   [split] [delay_split] [split_delay] [instant_split]   send what follows as a new packet
final Random _rng = Random.secure();
int _rotateCounter = 0;

/// Called once per user-initiated connect so [rotate=...] advances.
void bumpRotation() => _rotateCounter++;

/// [random=a,b,c] picks one at random, [rotate=a,b,c] advances per connection.
String expandRandomRotate(String s) {
  List<String> opts(String raw) =>
      raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  s = s.replaceAllMapped(RegExp(r'\[random=([^\]]*)\]'), (m) {
    final o = opts(m[1]!);
    return o.isEmpty ? '' : o[_rng.nextInt(o.length)];
  });
  s = s.replaceAllMapped(RegExp(r'\[rotate=([^\]]*)\]'), (m) {
    final o = opts(m[1]!);
    return o.isEmpty ? '' : o[_rotateCounter % o.length];
  });
  return s;
}

/// One packet of a payload and the pause to take *after* sending it.
class PayloadPart {
  const PayloadPart(this.text, this.delayMs);
  final String text;
  final int delayMs;
}

const _splitDelays = {
  'split': 300,
  'delay_split': 1000,
  'split_delay': 1000,
  'instant_split': 0,
};

String _expandTokens(String chunk, String host, int port) => chunk
    .replaceAll('[crlf*2]', '\r\n\r\n')
    .replaceAll('[crlf]', '\r\n')
    .replaceAll('[lfcr]', '\n\r')
    .replaceAll('[cr]', '\r')
    .replaceAll('[lf]', '\n')
    .replaceAll('[host_port]', '$host:$port')
    .replaceAll('[ssh]', '$host:$port')
    .replaceAll('[host]', host)
    .replaceAll('[port]', '$port')
    .replaceAll('[protocol]', 'HTTP/1.1')
    .replaceAll('[method]', 'CONNECT')
    .replaceAll('[ua]', 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36')
    .replaceAll('[netData]', 'CONNECT $host:$port HTTP/1.1')
    .replaceAll('[real_raw]', 'CONNECT $host:$port HTTP/1.1\r\n\r\n')
    .replaceAll('[raw]', 'CONNECT $host:$port HTTP/1.1\r\n\r\n')
    .replaceAll(r'\r', '\r')
    .replaceAll(r'\n', '\n');

/// Expands a payload template into the packets to send, with their delays.
List<PayloadPart> buildPayloadParts(String template,
    {required String host, required int port}) {
  final src = expandRandomRotate(template);
  final re = RegExp(r'\[(split|delay_split|split_delay|instant_split)\]');
  final parts = <PayloadPart>[];
  var last = 0;
  for (final m in re.allMatches(src)) {
    final text = _expandTokens(src.substring(last, m.start), host, port);
    if (text.isNotEmpty) parts.add(PayloadPart(text, _splitDelays[m[1]!]!));
    last = m.end;
  }
  final tail = _expandTokens(src.substring(last), host, port);
  if (tail.isNotEmpty) parts.add(PayloadPart(tail, 0));
  return parts;
}

/// Plain strings of [buildPayloadParts] (used by the host checker and tests).
List<String> buildPayload(String template, {required String host, required int port}) =>
    buildPayloadParts(template, host: host, port: port).map((e) => e.text).toList();
