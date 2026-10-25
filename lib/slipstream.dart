import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'native.dart';

typedef SlipstreamLog = void Function(String message);

class SlipstreamConfig {
  const SlipstreamConfig({
    required this.domain,
    required this.resolver,
    this.mode = 'resolver',
    this.certPem = '',
  });

  final String domain;
  final String resolver;
  /// `resolver` uses recursive DNS; `authoritative` connects directly to a
  /// resolver/server endpoint configured for authoritative Slipstream mode.
  final String mode;
  /// Optional PEM leaf certificate for strict certificate pinning.
  final String certPem;

  static final _domainRe = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$');

  String? validate() {
    final d = domain.trim();
    if (!_domainRe.hasMatch(d)) return 'Slipstream: enter a valid tunnel domain';
    if (mode != 'resolver' && mode != 'authoritative') return 'Slipstream: unknown DNS mode';
    final endpoint = resolver.trim();
    final i = endpoint.lastIndexOf(':');
    if (i <= 0 || i == endpoint.length - 1) return 'Slipstream: resolver must be host:port';
    final host = endpoint.substring(0, i).replaceAll(RegExp(r'^\[|\]$'), '');
    final port = int.tryParse(endpoint.substring(i + 1));
    if (host.isEmpty || host.contains(' ') || port == null || port < 1 || port > 65535) {
      return 'Slipstream: invalid resolver host or port';
    }
    if (certPem.trim().isNotEmpty && !certPem.contains('-----BEGIN CERTIFICATE-----')) {
      return 'Slipstream: certificate must be PEM encoded';
    }
    return null;
  }
}

List<String> buildSlipstreamArgs(SlipstreamConfig config, int localPort, {String? resolver, String? certPath}) {
  final endpoint = resolver ?? config.resolver.trim();
  return [
    '--tcp-listen-host', '127.0.0.1',
    '--tcp-listen-port', '$localPort',
    '--domain', config.domain.trim(),
    '--${config.mode}', endpoint,
    if (certPath != null && certPath.isNotEmpty) ...['--cert', certPath],
  ];
}

/// Runs the upstream slipstream-client binary as a child process. The remote
/// endpoint must forward the tunnel to a SOCKS-compatible service; Xray then
/// routes app traffic through that local TCP listener.
class SlipstreamRunner {
  SlipstreamRunner(this.config, this.log);
  final SlipstreamConfig config;
  final SlipstreamLog log;
  void Function()? onExit;

  Process? _process;
  bool _stopping = false;
  bool _exited = false;
  String _lastLine = '';
  File? _certFile;
  int port = 0;

  Future<int> start({int avoidPort = 0}) async {
    final bad = config.validate();
    if (bad != null) throw bad;
    final dir = await Native.nativeLibraryDir();
    if (dir == null || dir.isEmpty) throw 'Slipstream: cannot locate native library directory';
    final exe = '$dir/libslipstream.so';
    if (!await File(exe).exists()) throw 'Slipstream engine is not included for this CPU in this build';

    port = await _freePort(avoidPort: avoidPort);
    final resolver = await _resolveEndpoint(config.resolver.trim());
    String? certPath;
    if (config.certPem.trim().isNotEmpty) {
      final cert = File('${Directory.systemTemp.path}/xray-vpn-slipstream-${DateTime.now().microsecondsSinceEpoch}.pem');
      await cert.writeAsString(config.certPem.trim(), flush: true);
      _certFile = cert;
      certPath = cert.path;
    }
    final args = buildSlipstreamArgs(config, port, resolver: resolver, certPath: certPath);
    log('Slipstream: ${config.mode} via $resolver, domain ${config.domain.trim()}');

    try {
      _process = await Process.start(exe, args);
    } on ProcessException catch (e) {
      await _cleanupCert();
      throw 'Slipstream engine could not be started: ${e.message}';
    }
    final p = _process!;
    void line(String value) {
      final v = value.trim();
      if (v.isNotEmpty) {
        _lastLine = v;
        log('slipstream: $v');
      }
    }
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(line, onError: (Object _) {});
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(line, onError: (Object _) {});
    unawaited(p.exitCode.then((code) {
      _exited = true;
      if (_stopping) return;
      log('Slipstream engine exited (code $code)${_lastLine.isEmpty ? '' : ': $_lastLine'}');
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
    final p = _process;
    _process = null;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
      }
    }
    await _cleanupCert();
  }

  Future<void> _cleanupCert() async {
    final cert = _certFile;
    _certFile = null;
    if (cert != null) {
      try { await cert.delete(); } catch (_) {}
    }
  }

  Future<void> _waitListening() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (_exited) throw 'Slipstream exited during startup${_lastLine.isEmpty ? '' : ': $_lastLine'}';
      try {
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await probe.close();
      } on SocketException {
        return; // The engine owns the local listening port.
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw 'Slipstream did not open its local TCP port within 10 seconds';
  }

  static Future<int> _freePort({int avoidPort = 0}) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final result = server.port;
      await server.close();
      if (result != avoidPort) return result;
    }
    throw 'Slipstream: could not allocate a local port distinct from $avoidPort';
  }

  static Future<String> _resolveEndpoint(String endpoint) async {
    final i = endpoint.lastIndexOf(':');
    final hostRaw = endpoint.substring(0, i);
    final host = hostRaw.startsWith('[') && hostRaw.endsWith(']') ? hostRaw.substring(1, hostRaw.length - 1) : hostRaw;
    final port = endpoint.substring(i + 1);
    if (InternetAddress.tryParse(host) != null) return endpoint;
    final addresses = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    if (addresses.isEmpty) throw 'Slipstream: cannot resolve resolver $host';
    return '${addresses.first.address}:$port';
  }
}
