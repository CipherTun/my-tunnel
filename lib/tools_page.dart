import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'edit_page.dart' show previewPayload;
import 'ssh_tunnel.dart';
import 'theme.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  // payload preview
  final _payload = TextEditingController(text: 'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]');
  final _pHost = TextEditingController(text: 'example.com');
  final _pPort = TextEditingController(text: '80');
  String _preview = '';

  // host checker
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _sni = TextEditingController();
  bool _tls = false;
  bool _checking = false;
  String _hostResult = '';

  // connection test
  bool _testing = false;
  String _testResult = '';

  @override
  void initState() {
    super.initState();
    _updatePreview();
  }

  void _updatePreview() {
    _preview = previewPayload(_payload.text, _pHost.text.trim(), int.tryParse(_pPort.text) ?? 80);
  }

  Future<void> _check() async {
    final port = int.tryParse(_port.text);
    if (_host.text.trim().isEmpty || port == null) {
      toast(context, 'Enter host and port');
      return;
    }
    setState(() {
      _checking = true;
      _hostResult = '';
    });
    final r = await hostCheck(_host.text.trim(), port, tls: _tls, sni: _sni.text.trim());
    if (mounted) {
      setState(() {
        _checking = false;
        _hostResult = r;
      });
    }
  }

  /// Verifies the tunnel end to end: public IP as seen from the internet,
  /// plus the core's own delay measurement.
  Future<void> _test() async {
    final c = widget.ctrl;
    if (c.state != ConnState.connected) {
      toast(context, 'Connect first');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final out = StringBuffer();
    const path = '/json?fields=status,message,query,country,city,isp';
    try {
      String body;
      final port = c.localSocks;
      if (port != null) {
        // SSH, payload and proxy-only sessions: go through the local SOCKS5 server,
        // because this app's own sockets bypass the VPN in those modes.
        body = await socksHttpGet(port, 'ip-api.com', path);
      } else {
        final h = HttpClient()..connectionTimeout = const Duration(seconds: 12);
        try {
          final req = await h.getUrl(Uri.parse('http://ip-api.com$path')).timeout(const Duration(seconds: 15));
          final res = await req.close().timeout(const Duration(seconds: 15));
          body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
        } finally {
          h.close(force: true);
        }
      }
      final j = jsonDecode(body.trim()) as Map<String, dynamic>;
      if (j['status'] == 'success') {
        out.writeln('Public IP: ${j['query']}');
        out.writeln('Location: ${j['city']}, ${j['country']}');
        out.writeln('ISP: ${j['isp']}');
      } else {
        out.writeln('IP lookup: ${j['message'] ?? 'failed'}');
      }
    } catch (e) {
      out.writeln('IP lookup failed: ${errText(e)}');
    }
    final d = await c.connectedDelay();
    out.writeln(d > 0 ? 'Tunnel delay: $d ms' : 'Tunnel delay: not available for this engine');
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = out.toString().trim();
      });
    }
  }

  Widget _result(String t) => t.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SelectableText(t, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) {
        final connected = widget.ctrl.state == ConnState.connected;
        return Scaffold(
          appBar: AppBar(title: const Text('Tools', style: TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Connection test', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Shows the public IP seen through the tunnel and the core\'s measured delay.', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: connected && !_testing ? _test : null,
                    icon: _testing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.travel_explore),
                    label: Text(connected ? 'Run test' : 'Connect first'),
                  ),
                  _result(_testResult),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Host checker', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(flex: 3, child: TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host'))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
                  ]),
                  SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('TLS'), value: _tls, onChanged: (v) => setState(() => _tls = v)),
                  if (_tls) TextField(controller: _sni, decoration: const InputDecoration(labelText: 'SNI (optional)')),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _checking ? null : _check,
                    icon: const Icon(Icons.network_check),
                    label: Text(_checking ? 'Checking…' : 'Check'),
                  ),
                  _result(_hostResult),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Payload preview', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Placeholders: [host] [port] [host_port] [crlf] [cr] [lf] [split]', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _payload,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Payload'),
                    onChanged: (_) => setState(_updatePreview),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(flex: 3, child: TextField(controller: _pHost, decoration: const InputDecoration(labelText: 'Host'), onChanged: (_) => setState(_updatePreview))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _pPort, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'), onChanged: (_) => setState(_updatePreview))),
                  ]),
                  _result(_preview),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
