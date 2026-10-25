import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'native.dart';

typedef DnsttLog = void Function(String message);

/// Settings of a DNSTT ("SlowDNS") tunnel placed in front of an SSH server.
///
/// The engine is the upstream `dnstt-client` (David Fifield). Its command line is
///
///     dnstt-client [-doh URL | -dot ADDR | -udp ADDR] (-pubkey HEX | -pubkey-file FILE) DOMAIN LOCALADDR
///
/// It listens on LOCALADDR (TCP) and forwards every connection through DNS
/// queries to the dnstt server, which forwards to its own upstream (the SSH
/// server). We run it as a child process (libdnstt.so in the native library
/// directory, built by tools/build_dnstt.sh) and point the SSH client at it.
class DnsttConfig {
  const DnsttConfig({
    required this.domain,
    required this.pubKey,
    this.mode = 'udp',
    this.resolver = '8.8.8.8:53',
  });

  /// Tunnel zone delegated to the dnstt server, e.g. `t.example.com`.
  final String domain;

  /// Server public key, 64 hex characters (`dnstt-server -gen-key`).
  final String pubKey;

  /// `udp` (plain DNS), `doh` (DNS over HTTPS) or `dot` (DNS over TLS).
  final String mode;

  /// udp / dot: `host:port`. doh: an `https://` URL.
  final String resolver;

  static final RegExp _domainRe =
      RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$');
  static final RegExp _keyRe = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Why these settings cannot be used, or null when they are fine.
  String? validate() {
    final d = domain.trim();
    if (d.isEmpty) return 'DNSTT: the tunnel domain is empty';
    if (!_domainRe.hasMatch(d)) return 'DNSTT: "$d" is not a valid domain name';
    if (!_keyRe.hasMatch(pubKey.trim())) {
      return 'DNSTT: the server public key must be exactly 64 hex characters';
    }
    final r = resolver.trim();
    switch (mode) {
      case 'udp':
      case 'dot':
        final i = r.lastIndexOf(':');
        if (i <= 0 || i == r.length - 1) return 'DNSTT: the resolver must look like host:port';
        final host = r.substring(0, i);
        final port = int.tryParse(r.substring(i + 1));
        if (host.startsWith('[') || host.contains(' ')) {
          return 'DNSTT: use an IPv4 address or a host name for the resolver';
        }
        if (port == null || port < 1 || port > 65535) return 'DNSTT: bad resolver port';
        return null;
      case 'doh':
        final u = Uri.tryParse(r);
        if (u == null || u.scheme != 'https' || u.host.isEmpty) {
          return 'DNSTT: a DoH resolver must be an https:// URL';
        }
        return null;
      default:
        return 'DNSTT: unknown DNS transport "$mode"';
    }
  }
}

/// Command-line arguments for `dnstt-client`. Flags first, then DOMAIN and
/// LOCALADDR (Go's flag package stops parsing at the first positional argument).
List<String> buildDnsttArgs(DnsttConfig c, int localPort, {String? resolver}) {
  final flag = switch (c.mode) {
    'doh' => '-doh',
    'dot' => '-dot',
    _ => '-udp',
  };
  return [
    flag,
    resolver ?? c.resolver.trim(),
    '-pubkey',
    c.pubKey.trim(),
    c.domain.trim(),
    '127.0.0.1:$localPort',
  ];
}

/// Runs one `dnstt-client` process and reports when it stops by itself.
class DnsttRunner {
  DnsttRunner(this.cfg, this.log);

  final DnsttConfig cfg;
  final DnsttLog log;

  /// Called once if the engine exits without [stop] having been called.
  void Function()? onExit;

  Process? _p;
  bool _stopping = false;
  bool _exited = false;
  String _lastLine = '';
  int port = 0;

  /// Starts the engine and returns the local TCP port it listens on.
  Future<int> start({int avoidPort = 0}) async {
    final bad = cfg.validate();
    if (bad != null) throw bad;

    final dir = await Native.nativeLibraryDir();
    if (dir == null || dir.isEmpty) {
      throw 'DNSTT: cannot locate the app native library directory';
    }
    final exe = '$dir/libdnstt.so';
    if (!await File(exe).exists()) {
      throw 'DNSTT engine (libdnstt.so) is not included for this CPU in this build';
    }

    port = await _freePort(avoidPort: avoidPort);
    final resolver = await _udpResolver();
    final args = buildDnsttArgs(cfg, port, resolver: resolver);
    log('DNSTT: ${cfg.mode.toUpperCase()} via $resolver, domain ${cfg.domain.trim()}');

    final Process p;
    try {
      p = await Process.start(exe, args);
    } on ProcessException catch (e) {
      throw 'DNSTT engine could not be started: ${e.message}';
    }
    _p = p;

    void line(String l) {
      final t = l.trim();
      if (t.isEmpty) return;
      _lastLine = t;
      log('dnstt: $t');
    }

    p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(line, onError: (Object _) {});
    p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(line, onError: (Object _) {});

    unawaited(p.exitCode.then((code) {
      _exited = true;
      if (_stopping) return;
      log('DNSTT engine exited (code $code)');
      onExit?.call();
    }));

    try {
      await _waitListening();
    } catch (_) {
      await stop();
      rethrow;
    }
    return port;
  }

  Future<void> stop() async {
    _stopping = true;
    final p = _p;
    _p = null;
    if (p == null) return;
    p.kill(ProcessSignal.sigterm);
    try {
      await p.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
  }

  /// The engine has no "ready" message, so probe the port: while we can still
  /// bind it nobody listens; once binding fails the engine is accepting.
  /// (A probe connection would start a real tunnel session, so we avoid it.)
  Future<void> _waitListening() async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (_exited) {
        throw 'DNSTT engine stopped right after it started'
            '${_lastLine.isEmpty ? '' : ': $_lastLine'}';
      }
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await s.close();
      } on SocketException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw 'DNSTT engine did not open its local port within 8 s';
  }

  static Future<int> _freePort({int avoidPort = 0}) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = s.port;
      await s.close();
      if (p != avoidPort) return p;
    }
    throw 'DNSTT: could not allocate a local port distinct from $avoidPort';
  }

  /// The engine is a static Go binary: on Android it cannot read the system
  /// DNS configuration, so a resolver given as a host name is resolved here
  /// (plain UDP mode only; DoH / DoT keep the name for certificate checking).
  Future<String> _udpResolver() async {
    final r = cfg.resolver.trim();
    if (cfg.mode != 'udp') return r;
    final i = r.lastIndexOf(':');
    final host = r.substring(0, i);
    if (InternetAddress.tryParse(host) != null) return r;
    final ips = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    if (ips.isEmpty) throw 'DNSTT: cannot resolve the DNS server $host';
    return '${ips.first.address}:${r.substring(i + 1)}';
  }
}
