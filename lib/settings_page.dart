import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';

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
  late final _shareUser = TextEditingController(text: s.shareUsername);
  late final _sharePass = TextEditingController(text: s.sharePassword);
  late final _max = TextEditingController(text: '${s.reconnectMax}');

  static const _quick = {
    'WhatsApp': 'com.whatsapp',
    'YouTube': 'com.google.android.youtube',
    'Telegram': 'org.telegram.messenger',
    'Chrome': 'com.android.chrome',
    'Instagram': 'com.instagram.android',
    'Facebook': 'com.facebook.katana',
    'TikTok': 'com.zhiliaoapp.musically',
  };

  InputDecoration _dec(String l, [String? h]) =>
      InputDecoration(border: const OutlineInputBorder(), labelText: l, hintText: h);

  Future<void> _save() async {
    if (s.shareHotspot && (_shareUser.text.trim().isEmpty || _sharePass.text.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set a proxy username and password before enabling LAN sharing.')),
      );
      return;
    }
    s
      ..dns1 = _dns1.text
      ..dns2 = _dns2.text
      ..fallbackDns = _fb.text
      ..bypassApps = _apps.text
      ..socksPort = int.tryParse(_port.text) ?? 10808
      ..sshKeepalive = int.tryParse(_ka.text) ?? 20
      ..reconnectMax = int.tryParse(_max.text) ?? 5
      ..shareUsername = _shareUser.text.trim()
      ..sharePassword = _sharePass.text;
    await widget.ctrl.saveSettings(s);
    if (mounted) Navigator.pop(context);
  }

  Widget _h(String t) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(t, style: Theme.of(context).textTheme.titleMedium));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
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
            child: Text('SSH mode always resolves DNS over TCP.',
                style: TextStyle(fontSize: 12)),
          ),
          _h('VPN engine'),
          DropdownButtonFormField<String>(
            initialValue: s.coreEngine,
            decoration: _dec('Core engine'),
            items: const [
              DropdownMenuItem(value: 'xray', child: Text('Xray-core (existing engine)')),
              DropdownMenuItem(value: 'singbox', child: Text('sing-box (independent engine)')),
            ],
            onChanged: (v) => setState(() => s.coreEngine = v ?? 'xray'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('sing-box supports standard compatible links and sing-box JSON. Custom SSH payload profiles continue to use the existing Xray SOCKS bridge. Unsupported link transports fail validation instead of silently falling back.', style: TextStyle(fontSize: 12)),
          ),
          _h('Connection'),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-reconnect'),
              value: s.autoReconnect,
              onChanged: (v) => setState(() => s.autoReconnect = v)),
          if (s.autoReconnect)
            TextField(
                controller: _max,
                keyboardType: TextInputType.number,
                decoration: _dec('Max retries')),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bypass LAN / local network'),
              value: s.bypassLan,
              onChanged: (v) => setState(() => s.bypassLan = v)),
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
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Expose SSH SOCKS proxy to LAN'),
              subtitle: const Text('Exposes an authenticated SOCKS5 proxy to devices on your hotspot/LAN. Clients must enter the proxy address, port, username and password. SSH profiles only; this is not transparent routing for every app.'),
              value: s.shareHotspot,
              onChanged: (v) => setState(() => s.shareHotspot = v)),
          if (s.shareHotspot) ...[
            const SizedBox(height: 10),
            TextField(controller: _shareUser, autocorrect: false, decoration: _dec('Proxy username')),
            const SizedBox(height: 10),
            TextField(controller: _sharePass, obscureText: true, autocorrect: false, decoration: _dec('Proxy password')),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Use a strong, unique password. Saved locally on this phone. Share only with trusted devices.', style: TextStyle(fontSize: 12)),
            ),
          ],
          _h('Apps that bypass the VPN'),
          Wrap(spacing: 8, runSpacing: 4, children: [
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
        ]),
      );
}
