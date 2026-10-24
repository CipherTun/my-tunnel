import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'app_info.dart';
import 'controller.dart';
import 'logs_page.dart';
import 'native.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  VpnController get c => widget.ctrl;

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );

  Widget _sw(String t, String sub, bool v, void Function(bool) f) => SwitchListTile(
        title: Text(t),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        value: v,
        onChanged: (x) {
          setState(() => f(x));
          c.saveSettings();
        },
      );

  Widget _num(String label, int value, int min, int max, void Function(int) f, {String? help}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: TextFormField(
          initialValue: '$value',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, helperText: help ?? '$min - $max'),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= min && n <= max) {
              f(n);
              c.saveSettings();
            }
          },
        ),
      );

  Widget _text(String label, String value, void Function(String) f, {String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: TextFormField(
          initialValue: value,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onChanged: (v) {
            f(v.trim());
            c.saveSettings();
          },
        ),
      );

  Future<void> _pickApps() async {
    final r = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(builder: (_) => AppsPage(selected: c.settings.blockedApps.toSet())),
    );
    if (r != null) {
      setState(() => c.settings.bypassApps = (r.toList()..sort()).join('\n'));
      await c.saveSettings();
    }
  }

  Future<void> _import() async {
    final t = TextEditingController();
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if ((d?.text ?? '').contains('"profiles"')) t.text = d!.text!;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import backup'),
        content: TextField(controller: t, maxLines: 8, decoration: const InputDecoration(hintText: 'Paste backup JSON')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = await c.importBackup(t.text);
      if (mounted) {
        setState(() {});
        toast(context, 'Imported $n new profile(s)');
      }
    } catch (e) {
      if (mounted) toast(context, 'Invalid backup: ${errText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(children: [
        _h('Connection'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Latency test method'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'tcp', label: Text('TCP connect')),
                ButtonSegment(value: 'real', label: Text('Core delay')),
              ],
              selected: {s.testMode},
              onSelectionChanged: (v) {
                setState(() => s.testMode = v.first);
                c.saveSettings();
              },
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Core delay measures a real request through each Xray, WireGuard or proxy profile. Other types use TCP connect.', style: TextStyle(fontSize: 12)),
            ),
          ]),
        ),
        _sw('Auto-reconnect', 'Retry with back-off when the tunnel drops', s.autoReconnect, (v) => s.autoReconnect = v),
        if (s.autoReconnect) _num('Max retries', s.reconnectMax, 0, 50, (v) => s.reconnectMax = v),
        _sw('Connect on launch', 'Connect the selected profile when the app starts', s.autoConnect, (v) => s.autoConnect = v),
        _sw('Health check', 'Probe through the tunnel and reconnect when it stalls', s.watchdog, (v) => s.watchdog = v),
        if (s.watchdog) ...[
          _text('Health-check URL', s.watchdogUrl, (v) => s.watchdogUrl = v.isEmpty ? 'https://www.gstatic.com/generate_204' : v),
          _num('Interval (seconds)', s.watchdogInterval, 15, 300, (v) => s.watchdogInterval = v),
          _num('Failures before reconnect', s.watchdogFails, 1, 10, (v) => s.watchdogFails = v),
        ],
        _h('DNS'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: DropdownButtonFormField<String>(
            initialValue: ['default', 'google', 'cloudflare', 'quad9', 'adguard', 'opendns', 'custom'].contains(s.dnsPreset) ? s.dnsPreset : 'default',
            decoration: const InputDecoration(labelText: 'Resolver'),
            items: const [
              DropdownMenuItem(value: 'default', child: Text('Default')),
              DropdownMenuItem(value: 'google', child: Text('Google 8.8.8.8')),
              DropdownMenuItem(value: 'cloudflare', child: Text('Cloudflare 1.1.1.1')),
              DropdownMenuItem(value: 'quad9', child: Text('Quad9 9.9.9.9')),
              DropdownMenuItem(value: 'adguard', child: Text('AdGuard (ad blocking)')),
              DropdownMenuItem(value: 'opendns', child: Text('OpenDNS')),
              DropdownMenuItem(value: 'custom', child: Text('Custom')),
            ],
            onChanged: (v) {
              setState(() => s.dnsPreset = v ?? 'default');
              c.saveSettings();
            },
          ),
        ),
        if (s.dnsPreset == 'custom') ...[
          _text('Primary', s.dns1, (v) => s.dns1 = v, hint: '1.1.1.1 or https://dns.example/dns-query'),
          _text('Secondary', s.dns2, (v) => s.dns2 = v),
        ],
        _text('Fallback resolver (optional)', s.fallbackDns, (v) => s.fallbackDns = v),
        _sw('IPv4 answers only', 'Avoids unreachable IPv6 addresses on IPv4 tunnels', s.dnsIpv4Only, (v) => s.dnsIpv4Only = v),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            'App DNS queries are answered by the core\'s resolver using these servers. '
            'SSH mode always resolves over TCP through the tunnel.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        _h('Routing'),
        _sw('Bypass LAN', 'Keep local network traffic outside the VPN', s.bypassLan, (v) => s.bypassLan = v),
        ListTile(
          title: const Text('Apps that bypass the VPN'),
          subtitle: Text(s.blockedApps.isEmpty ? 'None' : '${s.blockedApps.length} selected'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickApps,
        ),
        _h('SSH'),
        _num('Local SOCKS port', s.socksPort, 1024, 65535, (v) {
          if (v != kReservedPort) s.socksPort = v;
        }, help: '1024 - 65535 (not $kReservedPort, used by the core)'),
        _num('Keep-alive (seconds)', s.sshKeepAlive, 5, 120, (v) => s.sshKeepAlive = v),
        _sw('Share over hotspot', 'Listen on all interfaces so other devices can use the SOCKS proxy', s.shareHotspot, (v) => s.shareHotspot = v),
        _h('Stability'),
        FutureBuilder<bool>(
          future: Native.ignoringBatteryOptimizations(),
          builder: (_, snap) => ListTile(
            title: const Text('Battery optimization'),
            subtitle: Text(snap.data == true ? 'App is exempt (recommended)' : 'Exempt this app so the system does not kill the tunnel'),
            trailing: snap.data == true ? const Icon(Icons.check_circle, color: kGood) : const Icon(Icons.open_in_new),
            onTap: () async {
              await Native.openBatterySettings();
            },
          ),
        ),
        ListTile(
          title: const Text('Always-on VPN & kill switch'),
          subtitle: const Text('Open Android VPN settings: enable "Always-on VPN" and "Block connections without VPN" for this app'),
          trailing: const Icon(Icons.open_in_new),
          onTap: Native.openVpnSettings,
        ),
        _h('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark')),
              ButtonSegment(value: 'light', label: Text('Light')),
              ButtonSegment(value: 'system', label: Text('System')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) {
              setState(() => s.themeMode = v.first);
              c.saveSettings();
            },
          ),
        ),
        _h('Diagnostics'),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('Logs'),
          subtitle: const Text('App events and engine logs'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LogsPage(ctrl: c))),
        ),
        _h('Backup'),
        ListTile(
          leading: const Icon(Icons.upload),
          title: const Text('Export to clipboard'),
          subtitle: const Text('Profiles, subscriptions and settings. Contains passwords - keep it private.'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: c.exportBackup()));
            if (mounted) toast(context, 'Backup copied');
          },
        ),
        ListTile(leading: const Icon(Icons.download), title: const Text('Import from clipboard'), onTap: _import),
        _h('About'),
        const ListTile(title: Text(kAppName), subtitle: Text('Version $kAppVersion  ·  $kAppId')),
        const SizedBox(height: 32),
      ]),
    );
  }
}
