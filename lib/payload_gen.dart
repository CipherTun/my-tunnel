/// Payload generator modelled on the HTTP Injector / HTTP Custom generator:
/// injection methods (normal, front/back inject, front/back query), extra
/// headers, dual CONNECT, raw, and split modes. Tags are expanded at connect
/// time by buildPayloadParts() in payload.dart.
enum InjectMethod { normal, frontInject, backInject, frontQuery, backQuery }

enum SplitMode { none, split, delaySplit, instantSplit }

class PayloadSpec {
  PayloadSpec({
    this.method = InjectMethod.normal,
    this.verb = 'GET',
    this.frontHosts = const ['[host]'],
    this.keepAlive = false,
    this.reverseProxy = false,
    this.onlineHost = false,
    this.forwardHost = false,
    this.userAgent = false,
    this.websocket = false,
    this.dualConnect = false,
    this.raw = false,
    this.split = SplitMode.none,
    this.extraHeaders = const [],
  });

  InjectMethod method;
  String verb; // used for the injected (front) request
  List<String> frontHosts; // several hosts -> [rotate=a,b,c]
  bool keepAlive, reverseProxy, onlineHost, forwardHost, userAgent, websocket;
  bool dualConnect, raw;
  SplitMode split;
  List<String> extraHeaders;
}

String _splitTag(SplitMode m) => switch (m) {
      SplitMode.none => '',
      SplitMode.split => '[split]',
      SplitMode.delaySplit => '[delay_split]',
      SplitMode.instantSplit => '[instant_split]',
    };

String generatePayload(PayloadSpec s) {
  final hosts = s.frontHosts.where((e) => e.trim().isNotEmpty).map((e) => e.trim()).toList();
  final host = hosts.isEmpty
      ? '[host]'
      : hosts.length == 1
          ? hosts.first
          : '[rotate=${hosts.join(',')}]';

  final headers = StringBuffer();
  if (s.websocket) {
    headers.write('Upgrade: websocket[crlf]Connection: Upgrade[crlf]');
  } else if (s.keepAlive) {
    headers.write('Connection: Keep-Alive[crlf]');
  }
  if (s.reverseProxy) headers.write('Proxy-Connection: Keep-Alive[crlf]');
  if (s.onlineHost) headers.write('X-Online-Host: $host[crlf]');
  if (s.forwardHost) headers.write('X-Forward-Host: $host[crlf]');
  if (s.userAgent) headers.write('User-Agent: [ua][crlf]');
  for (final h in s.extraHeaders) {
    if (h.trim().isNotEmpty) headers.write('${h.trim()}[crlf]');
  }

  final connect = s.raw ? '[raw]' : 'CONNECT [host_port] [protocol][crlf][crlf]';
  final verb = s.verb.isEmpty ? 'GET' : s.verb;
  final sp = _splitTag(s.split);
  String out;
  switch (s.method) {
    case InjectMethod.normal:
      out = s.raw
          ? '[raw]'
          : 'CONNECT [host_port] [protocol][crlf]Host: $host[crlf]$headers[crlf]';
      break;
    case InjectMethod.frontInject:
      out = '$verb http://$host/ HTTP/1.1[crlf]Host: $host[crlf]$headers[crlf]$sp$connect';
      break;
    case InjectMethod.backInject:
      out = 'CONNECT [host_port] HTTP/1.1[crlf][crlf]$sp'
          '$verb http://$host/ [protocol][crlf]Host: $host[crlf]$headers[crlf]';
      break;
    case InjectMethod.frontQuery:
      out = 'CONNECT $host@[host_port] [protocol][crlf]$sp'
          '$verb http://$host/ [protocol][crlf]Host: $host[crlf]$headers[crlf]';
      break;
    case InjectMethod.backQuery:
      out = 'CONNECT [host_port]@$host [protocol][crlf]$sp'
          '$verb http://$host/ [protocol][crlf]Host: $host[crlf]$headers[crlf]';
      break;
  }
  if (s.dualConnect) {
    out += '${sp.isEmpty ? '[split]' : sp}CONNECT [host_port] [protocol][crlf][crlf]';
  }
  return out;
}
