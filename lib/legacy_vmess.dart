import 'dart:convert';

/// Compatibility parser for legacy VMess QR-code JSON links. Current VMess AEAD
/// share URIs continue through official libXray parsing.
String? legacyVmessDisplayName(String link) {
  final trimmed = link.trim();
  if (!trimmed.toLowerCase().startsWith('vmess://')) return null;
  try {
    var encoded = trimmed.substring('vmess://'.length).split('#').first.trim().replaceAll('-', '+').replaceAll('_', '/');
    encoded = base64.normalize(encoded);
    final decoded = jsonDecode(utf8.decode(base64.decode(encoded)));
    if (decoded is Map) {
      final name = (decoded['ps'] ?? decoded['remarks'] ?? '').toString().trim();
      return name.isEmpty ? null : name;
    }
  } catch (_) {}
  return null;
}

String? legacyVmessToXrayJson(String link) {
  final trimmed = link.trim();
  if (!trimmed.toLowerCase().startsWith('vmess://')) return null;
  var encoded = trimmed.substring('vmess://'.length).split('#').first.trim();
  if (encoded.isEmpty) return null;
  try {
    encoded = encoded.replaceAll('-', '+').replaceAll('_', '/');
    encoded = base64.normalize(encoded);
    final decoded = jsonDecode(utf8.decode(base64.decode(encoded)));
    if (decoded is! Map) return null;
    final node = Map<String, dynamic>.from(decoded);
    final address = (node['add'] ?? node['address'] ?? '').toString().trim();
    final id = (node['id'] ?? '').toString().trim();
    final port = int.tryParse((node['port'] ?? '').toString());
    if (address.isEmpty || id.isEmpty || port == null || port < 1 || port > 65535) return null;

    final network = switch ((node['net'] ?? 'tcp').toString().toLowerCase()) {
      'ws' => 'ws',
      'grpc' => 'grpc',
      'h2' || 'http' => 'http',
      'httpupgrade' => 'httpupgrade',
      'xhttp' || 'splithttp' => 'xhttp',
      'kcp' || 'mkcp' => 'kcp',
      'quic' => 'quic',
      _ => 'tcp',
    };
    final tlsValue = (node['tls'] ?? '').toString().toLowerCase();
    final tls = tlsValue.isNotEmpty && tlsValue != 'none' && tlsValue != 'false' && tlsValue != '0';
    final hostHeader = (node['host'] ?? '').toString().trim();
    final path = (node['path'] ?? '').toString();
    final stream = <String, dynamic>{'network': network, 'security': tls ? 'tls' : 'none'};
    if (network == 'ws') {
      stream['wsSettings'] = {
        'path': path.isEmpty ? '/' : path,
        'headers': hostHeader.isNotEmpty ? {'Host': hostHeader} : <String, String>{},
      };
    } else if (network == 'http') {
      stream['httpSettings'] = {
        'path': path.isEmpty ? '/' : path,
        'host': hostHeader.isEmpty ? [address] : hostHeader.split(',').map((s) => s.trim()).toList(),
      };
    } else if (network == 'grpc') {
      stream['grpcSettings'] = {'serviceName': path.replaceFirst(RegExp(r'^/'), ''), 'multiMode': false};
    } else if (network == 'httpupgrade') {
      stream['httpupgradeSettings'] = {'path': path.isEmpty ? '/' : path, if (hostHeader.isNotEmpty) 'host': hostHeader};
    } else if (network == 'xhttp') {
      stream['xhttpSettings'] = {'path': path.isEmpty ? '/' : path, if (hostHeader.isNotEmpty) 'host': hostHeader};
    } else if (network == 'tcp' && (node['type'] ?? '').toString() == 'http') {
      stream['tcpSettings'] = {
        'header': {'type': 'http', 'request': {'path': [path.isEmpty ? '/' : path], 'headers': {'Host': hostHeader.isEmpty ? [address] : hostHeader.split(',')}}},
      };
    }
    if (tls) {
      final serverName = (node['sni'] ?? hostHeader).toString().trim();
      final alpn = (node['alpn'] ?? '').toString().split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      stream['tlsSettings'] = {
        'serverName': serverName.isEmpty ? address : serverName,
        if (alpn.isNotEmpty) 'alpn': alpn,
        if ((node['fp'] ?? '').toString().isNotEmpty) 'fingerprint': node['fp'].toString(),
      };
    }

    final alterId = int.tryParse((node['aid'] ?? '0').toString()) ?? 0;
    final security = (node['scy'] ?? 'auto').toString().trim().isEmpty ? 'auto' : (node['scy'] ?? 'auto').toString();
    final outbound = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vmess',
      'settings': {
        'vnext': [
          {
            'address': address,
            'port': port,
            'users': [
              {'id': id, 'alterId': alterId, 'security': security},
            ],
          },
        ],
      },
      'streamSettings': stream,
    };
    return jsonEncode({'outbounds': [outbound]});
  } catch (_) {
    return null;
  }
}
