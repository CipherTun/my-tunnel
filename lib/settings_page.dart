import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'controller.dart';
import 'models.dart';
import 'native.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppSettings s = AppSettings.fromJson(widget.ctrl.settings.toJson());
  late final _apps = TextEditingController(text: s.bypassApps);
  late final _dns1 = TextEditingController(text: s.dns1);
  late final _dns2 = TextEditingController(text: s.dns2);
  late final _fb = TextEditingController(text: s.fallbackDns);
  late final _port = TextEditingController(text: '${s.socksPort}');
  late final _ka = TextEditingController(text: '${s.sshKeepalive}');
  late final _max = TextEditingController(text: '${s.reconnectMax}');
  late final _hu = TextEditingController(text: s.hotspotUser);
  late final _hp = TextEditingController(text: s.hotspotPass);
  late final _fl = TextEditingController(text: s.fragLength);
  late final _fi = TextEditingController(text: s.fragInterval);
  late final _mc = TextEditingController(text: '${s.muxConcurrency}');
  late final _su = TextEditingController(text: s.speedUrl);
  bool _battery = false;
  String _core = '';

  static const _quick = {
    'WhatsApp': 'com.whatsapp',
    'YouTube': 'com.google.android.youtube',
    'Telegram': 'org.telegram.messenger',
    'Chrome': 'com.android.chrome',
    'Instagram': 'com.instagram.android',
    'Facebook': 'com.facebook.katana',
    'TikTok': 'com.zhiliaoapp.musically',
  };

  @override
  void initState() {
    super.initState();
    Native.ignoringBatteryOptimizations().then((v) {
      if (mounted) setState(() => _battery = v);
    });
    widget.ctrl.coreVersion().then((v) {
      if (mounted) setState(() => _core = v);
    });
  }

  InputDecoration _dec(String l, [String? h]) =>
      InputDecoration(border: const OutlineInputBorder(), labelText: l, hintText: h);

  bool _validRange(String v) => RegExp(r'^\d+(-\d+)?$').hasMatch(v.trim());

  Future<void> _save() async {
    if (s.fragment && (!_validRange(_fl.text) || !_validRange(_fi.text))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fragment length/interval must look like 100-200 or 50')));
      return;
    }
    s
      ..dns1 = _dns1.text
      ..dns2 = _dns2.text
      ..fallbackDns = _fb.text
      ..bypassApps = _apps.text
      ..hotspotUser = _hu.text.trim()
      ..hotspotPass = _hp.text
      ..speedUrl = _su.text.trim().isEmpty ? 'http://speedtest.tele2.net/10MB.zip' : _su.text.trim()
      ..fragLength = _fl.text.trim()
      ..fragInterval = _fi.text.trim()
      ..muxConcurrency = (int.tryParse(_mc.text) ?? 8).clamp(1, 1024).toInt()
      ..socksPort = (int.tryParse(_port.text) ?? 10808).clamp(1024, 65535).toInt()
      ..sshKeepalive = (int.tryParse(_ka.text) ?? 20).clamp(5, 600).toInt()
      ..reconnectMax = (int.tryParse(_max.text) ?? 5).clamp(0, 100).toInt();
    await widget.ctrl.saveSettings(s);
    if (mounted) Navigator.pop(context);
  }

  Widget _h(String t) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(t, style: Theme.of(context).textTheme.titleMedium));

  Widget _sw(String title, bool v, ValueChanged<bool> f, [String? sub]) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: sub == null ? null : Text(sub),
      value: v,
      onChanged: (x) => setState(() => f(x)));

  Future<void> _pickApps() async {
    final cur = _apps.text.split(RegExp(r'[\s,;]+')).where((e) => e.contains('.')).toSet();
    final r = await Navigator.push<Set<String>>(
        context, MaterialPageRoute(builder: (_) => AppsPickerPage(selected: cur)));
    if (r != null) setState(() => _apps.text = r.toList().join('\n'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          _h('Appearance'),
          DropdownButtonFormField<String>(
            initialValue: s.themeMode,
            decoration: _dec('Theme'),
            items: const [
              DropdownMenuItem(value: 'system', child: Text('System')),
              DropdownMenuItem(value: 'light', child: Text('Light')),
              DropdownMenuItem(value: 'dark', child: Text('Dark')),
            ],
            onChanged: (v) => setState(() => s.themeMode = v!),
          ),
          _h('DNS changer'),
          DropdownButtonFormField<String>(
            initialValue: s.dnsPreset,
            decoration: _dec('DNS'),
            items: const [
              DropdownMenuItem(value: 'default', child: Text('Default')),
              DropdownMenuItem(value: 'google', child: Text('Google')),
              DropdownMenuItem(value: 'cloudflare', child: Text('Cloudflare')),
              DropdownMenuItem(value: 'quad9', child: Text('Quad9')),
              DropdownMenuItem(value: 'adguard', child: Text('AdGuard')),
              DropdownMenuItem(value: 'custom', child: Text('Custom')),
            ],
            onChanged: (v) => setState(() => s.dnsPreset = v!),
          ),
          if (s.dnsPreset == 'custom') ...[
            const SizedBox(height: 12),
            TextField(controller: _dns1, decoration: _dec('Primary DNS', 'IPv4, IPv6 or https://…')),
            const SizedBox(height: 12),
            TextField(controller: _dns2, decoration: _dec('Secondary DNS')),
          ],
          const SizedBox(height: 12),
          TextField(controller: _fb, decoration: _dec('Fallback DNS (optional)')),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('SSH mode always resolves DNS over TCP.', style: TextStyle(fontSize: 12)),
          ),
          _h('Connection'),
          _sw('Auto-reconnect', s.autoReconnect, (v) => s.autoReconnect = v),
          if (s.autoReconnect)
            TextField(
                controller: _max,
                keyboardType: TextInputType.number,
                decoration: _dec('Max retries')),
          _sw('Health check', s.healthCheck, (v) => s.healthCheck = v,
              'Probes an idle tunnel every 45 s and reconnects after 3 failures'),
          _sw('Connect when the app opens', s.autoConnect, (v) => s.autoConnect = v),
          _sw('Refresh subscriptions automatically', s.autoUpdateSubs, (v) => s.autoUpdateSubs = v,
              'At app start, when older than 24 h'),
          const SizedBox(height: 8),
          TextField(
              controller: _su,
              decoration: _dec('Speed-test URL', 'http://speedtest.tele2.net/10MB.zip')),
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text('SSH mode needs an http:// URL.', style: TextStyle(fontSize: 12)),
          ),
          _sw('Bypass LAN / local network', s.bypassLan, (v) => s.bypassLan = v),
          _h('Anti-censorship (Xray profiles)'),
          _sw('TLS fragment', s.fragment, (v) => s.fragment = v,
              'Splits the TLS ClientHello to defeat SNI/DPI filters. TLS/REALITY outbounds only; '
              'not applied to raw JSON profiles.'),
          if (s.fragment) ...[
            TextField(
                controller: _fl,
                decoration: _dec('Fragment length (bytes)', '100-200')),
            const SizedBox(height: 12),
            TextField(
                controller: _fi,
                decoration: _dec('Fragment interval (ms)', '10-20')),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: s.fingerprint,
            decoration: _dec('uTLS fingerprint override'),
            items: [
              for (final f in ['default', 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'randomized'])
                DropdownMenuItem(value: f, child: Text(f))
            ],
            onChanged: (v) => setState(() => s.fingerprint = v!),
          ),
          _sw('Block QUIC (UDP 443)', s.blockQuic, (v) => s.blockQuic = v,
              'Forces browsers/apps to fall back to TCP, which tunnels far more reliably'),
          _sw('Mux', s.mux, (v) => s.mux = v,
              'Multiplexes connections. Skipped for XTLS-Vision, gRPC, XHTTP and mKCP.'),
          if (s.mux)
            TextField(
                controller: _mc,
                keyboardType: TextInputType.number,
                decoration: _dec('Mux concurrency')),
          _h('SSH mode'),
          TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: _dec('Local SOCKS5 port')),
          const SizedBox(height: 12),
          TextField(
              controller: _ka,
              keyboardType: TextInputType.number,
              decoration: _dec('Keep-alive interval (seconds)')),
          _sw('Share connection over hotspot', s.shareHotspot, (v) => s.shareHotspot = v,
              'Opens the SOCKS5 port on 0.0.0.0. Set a username and password below.'),
          if (s.shareHotspot) ...[
            TextField(controller: _hu, decoration: _dec('Hotspot SOCKS user')),
            const SizedBox(height: 12),
            TextField(controller: _hp, obscureText: true, decoration: _dec('Hotspot SOCKS password')),
            const SizedBox(height: 8),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Forget all pinned SSH host keys'),
            subtitle: const Text('Keys are pinned on first connect and checked afterwards'),
            trailing: const Icon(Icons.delete_outline),
            onTap: () async {
              await widget.ctrl.clearAllPinnedKeys();
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Pinned host keys cleared')));
              }
            },
          ),
          _h('Apps that bypass the VPN'),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ActionChip(
                avatar: const Icon(Icons.apps, size: 16),
                label: const Text('Choose apps…'),
                onPressed: _pickApps),
            for (final e in _quick.entries)
              ActionChip(
                label: Text(e.key),
                onPressed: () {
                  if (!_apps.text.contains(e.value)) {
                    _apps.text = '${_apps.text.trim()}\n${e.value}'.trim();
                  }
                },
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _apps,
            minLines: 4,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: _dec('Package names, one per line', 'com.example.app'),
          ),
          _h('Reliability'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ignore battery optimisation'),
            subtitle: Text(_battery
                ? 'Enabled: Android will not suspend the tunnel in the background'
                : 'Recommended: stops Android from killing the tunnel when idle'),
            trailing: Icon(_battery ? Icons.check_circle : Icons.battery_alert,
                color: _battery ? Colors.green : null),
            onTap: _battery
                ? null
                : () async {
                    await Native.requestIgnoreBatteryOptimizations();
                    final v = await Native.ignoringBatteryOptimizations();
                    if (mounted) setState(() => _battery = v);
                  },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Always-on VPN / block without VPN'),
            subtitle: const Text(
                'Opens Android VPN settings. Turn on "Always-on VPN" and "Block connections '
                'without VPN" for a system-level kill switch.'),
            trailing: const Icon(Icons.open_in_new),
            onTap: Native.openVpnSettings,
          ),
          _h('About'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('XRay Vpn 2.1.0'),
            subtitle: Text('Package xyz.xray.vpn  ·  Xray core ${_core.isEmpty ? '…' : _core}'),
            trailing: const Icon(Icons.copy),
            onTap: () => Clipboard.setData(ClipboardData(text: 'XRay Vpn 2.1.0, core $_core')),
          ),
        ]),
      );
}
