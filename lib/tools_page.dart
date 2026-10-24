import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'payload_gen.dart';
import 'ssh_tunnel.dart';

class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key, required this.ctrl, this.addNow = false, this.initialUrl = ''});
  final VpnController ctrl;
  final bool addNow;
  final String initialUrl;
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  String? _busyId;

  VpnController get ctrl => widget.ctrl;

  @override
  void initState() {
    super.initState();
    if (widget.addNow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _add());
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _add() async {
    final name = TextEditingController();
    final url = TextEditingController(text: widget.initialUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add subscription'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name (optional)')),
          const SizedBox(height: 8),
          TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'https://… subscription URL')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyId = 'new');
    try {
      final n = await ctrl.addSubscription(name.text, url.text);
      _snack('Imported $n servers');
    } catch (e) {
      _snack('Failed: $e');
    }
    if (mounted) setState(() => _busyId = null);
  }

  Future<void> _refresh(String id) async {
    setState(() => _busyId = id);
    try {
      final n = await ctrl.updateSubscription(id);
      _snack('Updated: $n servers');
    } catch (e) {
      _snack('Update failed: $e');
    }
    if (mounted) setState(() => _busyId = null);
  }

  String _when(int ms) {
    if (ms == 0) return 'never updated';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return 'updated ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Subscriptions')),
        floatingActionButton: ctrl.state != ConnState.disconnected || _busyId != null
            ? null
            : FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
        body: ListenableBuilder(
          listenable: ctrl,
          builder: (_, __) => ctrl.subs.isEmpty
              ? const Center(child: Text('No subscriptions yet'))
              : ListView(children: [
                  if (_busyId != null) const LinearProgressIndicator(),
                  for (final s in ctrl.subs)
                    ListTile(
                      leading: const Icon(Icons.rss_feed),
                      title: Text(s.name),
                      subtitle: Text(
                          '${ctrl.profiles.where((p) => p.subId == s.id).length} servers · ${_when(s.updated)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed:
                              _busyId != null || ctrl.state != ConnState.disconnected
                                  ? null
                                  : () => _refresh(s.id),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: ctrl.state != ConnState.disconnected
                              ? null
                              : () => ctrl.removeSubscription(s.id),
                        ),
                      ]),
                    ),
                ]),
        ),
      );
}

class PayloadGeneratorPage extends StatefulWidget {
  const PayloadGeneratorPage({super.key, this.pick = false});
  final bool pick;
  @override
  State<PayloadGeneratorPage> createState() => _PayloadGeneratorPageState();
}

class _PayloadGeneratorPageState extends State<PayloadGeneratorPage> {
  final PayloadSpec _s = PayloadSpec();
  final _hosts = TextEditingController(text: '[host]');
  final _extra = TextEditingController();

  static const _methodNames = {
    InjectMethod.normal: 'Normal',
    InjectMethod.frontInject: 'Front inject',
    InjectMethod.backInject: 'Back inject',
    InjectMethod.frontQuery: 'Front query',
    InjectMethod.backQuery: 'Back query',
  };
  static const _methodHelp = {
    InjectMethod.normal: 'CONNECT with a spoofed Host header.',
    InjectMethod.frontInject: 'A harmless request to the front host first, then CONNECT.',
    InjectMethod.backInject: 'CONNECT first, then a request to the front host.',
    InjectMethod.frontQuery: 'CONNECT host@server, then a request to the front host.',
    InjectMethod.backQuery: 'CONNECT server@host, then a request to the front host.',
  };
  static const _splitNames = {
    SplitMode.none: 'No split',
    SplitMode.split: 'Split (300 ms pause)',
    SplitMode.delaySplit: 'Delay split (1 s pause)',
    SplitMode.instantSplit: 'Instant split (no pause)',
  };

  String get _out {
    _s.frontHosts = _hosts.text.split(RegExp(r'[\n,]+')).map((e) => e.trim()).toList();
    _s.extraHeaders = _extra.text.split('\n');
    return generatePayload(_s);
  }

  Widget _sw(String t, bool v, ValueChanged<bool> f) => SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(t),
      value: v,
      onChanged: (x) => setState(() => f(x)));

  @override
  Widget build(BuildContext context) {
    final out = _out;
    return Scaffold(
      appBar: AppBar(title: const Text('Payload generator')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<InjectMethod>(
          initialValue: _s.method,
          isExpanded: true,
          items: [for (final e in _methodNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _s.method = v!),
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Injection method'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 12),
          child: Text(_methodHelp[_s.method]!, style: Theme.of(context).textTheme.bodySmall),
        ),
        TextField(
            controller: _hosts,
            onChanged: (_) => setState(() {}),
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Front / Host (several → rotated per connection)',
                hintText: '[host]  or  example.com'),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _s.verb,
          items: [for (final m in ['GET', 'POST', 'HEAD', 'PUT', 'PATCH', 'OPTIONS', 'DELETE']) DropdownMenuItem(value: m, child: Text(m))],
          onChanged: (v) => setState(() => _s.verb = v!),
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Request method of the front request'),
        ),
        const SizedBox(height: 8),
        _sw('WebSocket upgrade', _s.websocket, (v) => _s.websocket = v),
        _sw('Keep-Alive', _s.keepAlive, (v) => _s.keepAlive = v),
        _sw('Reverse proxy (Proxy-Connection)', _s.reverseProxy, (v) => _s.reverseProxy = v),
        _sw('X-Online-Host', _s.onlineHost, (v) => _s.onlineHost = v),
        _sw('X-Forward-Host', _s.forwardHost, (v) => _s.forwardHost = v),
        _sw('User-Agent', _s.userAgent, (v) => _s.userAgent = v),
        _sw('Dual CONNECT (second CONNECT as a new packet)', _s.dualConnect, (v) => _s.dualConnect = v),
        _sw('Raw (use the [raw] CONNECT request)', _s.raw, (v) => _s.raw = v),
        const SizedBox(height: 8),
        DropdownButtonFormField<SplitMode>(
          initialValue: _s.split,
          isExpanded: true,
          items: [for (final e in _splitNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _s.split = v!),
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Packet splitting (front/back methods)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _extra,
          minLines: 2,
          maxLines: 5,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Extra headers (one per line)',
              alignLabelWithHint: true),
        ),
        const SizedBox(height: 16),
        Text('Result', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(out, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Tag reference'),
          children: const [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '[host] [port] [host_port] [ssh]  server address\n'
                '[protocol]  HTTP/1.1      [method]  CONNECT\n'
                '[netData]  CONNECT host:port HTTP/1.1\n'
                '[raw] [real_raw]  full CONNECT request\n'
                '[crlf] [cr] [lf] [lfcr] [crlf*2]  line breaks\n'
                '[ua]  user agent\n'
                '[random=a,b] [rotate=a,b]  pick one / next per connect\n'
                '[split] [delay_split] [instant_split]  new packet',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: out));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
              child: const Text('Copy'),
            ),
          ),
          if (widget.pick) ...[
            const SizedBox(width: 12),
            Expanded(
                child: FilledButton(
                    onPressed: () => Navigator.pop(context, out), child: const Text('Use'))),
          ],
        ]),
      ]),
    );
  }
}

class HostCheckerPage extends StatefulWidget {
  const HostCheckerPage({super.key});
  @override
  State<HostCheckerPage> createState() => _HostCheckerPageState();
}

class _HostCheckerPageState extends State<HostCheckerPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _sni = TextEditingController();
  final _payload = TextEditingController();
  bool _tls = true;
  bool _busy = false;
  String _result = '';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _result = 'Testing…';
    });
    final r = await hostCheck(
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 443,
      tls: _tls,
      sni: _sni.text.trim(),
      payload: _payload.text,
    );
    if (mounted) {
      setState(() {
        _busy = false;
        _result = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Host checker')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
              controller: _host,
              decoration:
                  const InputDecoration(border: OutlineInputBorder(), labelText: 'Host / IP')),
          const SizedBox(height: 12),
          TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Port')),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('TLS'),
              value: _tls,
              onChanged: (v) => setState(() => _tls = v)),
          if (_tls)
            TextField(
                controller: _sni,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), labelText: 'SNI (blank = host)')),
          const SizedBox(height: 12),
          TextField(
              controller: _payload,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Payload (blank = plain GET)',
                  alignLabelWithHint: true)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _run, child: const Text('Test')),
          const SizedBox(height: 16),
          SelectableText(_result, style: const TextStyle(fontFamily: 'monospace')),
        ]),
      );
}
