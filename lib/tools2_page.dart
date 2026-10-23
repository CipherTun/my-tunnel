import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'scanner.dart';

/// CDN clean-IP scanner: finds IPs that complete a TLS handshake fastest.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _sni = TextEditingController();
  final _ranges = TextEditingController();
  final _count = TextEditingController(text: '200');
  bool _running = false;
  bool _stop = false;
  int _done = 0, _total = 0;
  List<ScanResult> _results = [];
  String _msg = '';

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _loadCf() async {
    try {
      final r = await fetchCloudflareRanges();
      setState(() => _ranges.text = r.join('\n'));
    } catch (e) {
      _snack('Could not load ranges: $e');
    }
  }

  Future<void> _scan() async {
    if (widget.ctrl.state != ConnState.disconnected) {
      return _snack('Disconnect first: a scan through the VPN would measure the wrong path');
    }
    final sni = _sni.text.trim();
    if (sni.isEmpty) return _snack('Enter the domain (SNI) of your server');
    final ips = sampleRanges(
        _ranges.text.split(RegExp(r'[\s,]+')).where((e) => e.isNotEmpty).toList(),
        (int.tryParse(_count.text) ?? 200).clamp(10, 2000).toInt());
    if (ips.isEmpty) return _snack('Add IPv4 ranges (CIDR) or load the Cloudflare ranges');
    setState(() {
      _running = true;
      _stop = false;
      _done = 0;
      _total = ips.length;
      _results = [];
      _msg = '';
    });
    final r = await scanIps(
      ips,
      sni,
      onProgress: (d, t) {
        if (mounted) setState(() => _done = d);
      },
      cancelled: () => _stop,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = r.take(30).toList();
      _msg = r.isEmpty ? 'No IP answered. Try another range or domain.' : '${r.length} of ${ips.length} IPs answered';
    });
  }

  Future<void> _apply(String ip) async {
    final c = widget.ctrl;
    final opts = c.profiles
        .where((p) => p.type == ProfileType.v2ray && p.s('mode') != 'json')
        .toList();
    if (opts.isEmpty) return _snack('No link/manual V2Ray profile to apply it to');
    final p = await showDialog<Profile>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text('Use $ip for…'),
        children: [for (final o in opts) SimpleDialogOption(onPressed: () => Navigator.pop(context, o), child: Text(o.name))],
      ),
    );
    if (p == null) return;
    p.data['connectAddr'] = ip;
    await c.upsert(p);
    _snack('Set as connect address of "${p.name}"');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Clean IP scanner')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Tests TCP + TLS handshake time to random IPs of a CDN range, presenting your '
              'server domain as SNI. Use the fastest IP as "Connect address override" of a profile.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
              controller: _sni,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), labelText: 'Domain / SNI of your server')),
          const SizedBox(height: 12),
          TextField(
            controller: _ranges,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'IPv4 ranges (CIDR, one per line)',
                alignLabelWithHint: true),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: _running ? null : _loadCf,
                icon: const Icon(Icons.cloud_download),
                label: const Text('Load Cloudflare ranges')),
          ),
          TextField(
              controller: _count,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), labelText: 'IPs to test (10-2000)')),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _running ? () => setState(() => _stop = true) : _scan,
            child: Text(_running ? 'Stop ($_done / $_total)' : 'Scan'),
          ),
          if (_running) Padding(padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: _total == 0 ? null : _done / _total)),
          if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg)),
          for (final r in _results)
            ListTile(
              dense: true,
              title: Text(r.ip, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text('${r.ms} ms'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => Clipboard.setData(ClipboardData(text: r.ip))),
                IconButton(icon: const Icon(Icons.check_circle_outline, size: 18), onPressed: () => _apply(r.ip)),
              ]),
            ),
        ]),
      );
}

const _guide = r'''# --- UDP over SSH: badvpn-udpgw on your SSH server (Debian/Ubuntu) ---
sudo apt update && sudo apt install -y badvpn
# If the package does not exist on your distro, build it:
#   sudo apt install -y cmake build-essential git
#   git clone https://github.com/ambrop72/badvpn.git && cd badvpn
#   mkdir build && cd build
#   cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 && make && sudo make install

# Find the binary path (usually /usr/bin or /usr/local/bin)
command -v badvpn-udpgw

# systemd service (edit ExecStart if the path differs)
sudo tee /etc/systemd/system/udpgw.service >/dev/null <<'UNIT'
[Unit]
Description=badvpn UDP gateway for SSH tunnels
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now udpgw
systemctl status udpgw --no-pager

# --- sshd must allow TCP forwarding (default is yes) ---
grep -i '^AllowTcpForwarding' /etc/ssh/sshd_config

# In XRay Vpn: SSH profile > "UDP gateway port" = 7300
# (the gateway listens on 127.0.0.1 only; the app reaches it through the SSH session)
''';

class ServerGuidePage extends StatelessWidget {
  const ServerGuidePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SSH server setup'), actions: [
          IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: _guide));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Copied')));
              }),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: const [
          Text('Commands to enable UDP (DNS, QUIC, calls, games) on your own SSH server. '
              'Paths and package names vary by distribution, check before running.',
              style: TextStyle(fontSize: 12)),
          SizedBox(height: 12),
          SelectableText(_guide, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
        ]),
      );
}
