import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions.dart';
import 'apps_page.dart';
import 'controller.dart';
import 'models.dart';
import 'native.dart';
import 'widgets.dart';

/// Settings are saved the moment they change; connection-related ones apply
/// from the next connect.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  VpnController get ctrl => widget.ctrl;
  AppSettings get s => ctrl.settings;
  Timer? _debounce;

  late final _dns1 = TextEditingController(text: s.dns1);
  late final _dns2 = TextEditingController(text: s.dns2);
  late final _fb = TextEditingController(text: s.fallbackDns);
  late final _port = TextEditingController(text: '${s.socksPort}');
  late final _ka = TextEditingController(text: '${s.sshKeepalive}');
  late final _hu = TextEditingController(text: s.hotspotUser);
  late final _hp = TextEditingController(text: s.hotspotPass);
  late final _fl = TextEditingController(text: s.fragLength);
  late final _fi = TextEditingController(text: s.fragInterval);
  late final _mc = TextEditingController(text: '${s.muxConcurrency}');
  late final _su = TextEditingController(text: s.speedUrl);

  bool _battery = false;
  String _core = '';

  @override
  void initState() {
    super.initState();
    Native.ignoringBatteryOptimizations().then((v) {
      if (mounted) setState(() => _battery = v);
    });
    ctrl.coreVersion().then((v) {
      if (mounted) setState(() => _core = v);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    ctrl.saveSettings(s);
    super.dispose();
  }

  /// Immediate save (toggles, dropdowns).
  void _set(VoidCallback change) {
    setState(change);
    ctrl.saveSettings(s);
  }

  /// Debounced save (text fields).
  void _typed(VoidCallback change) {
    change();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => ctrl.saveSettings(s));
  }

  bool _range(String v) => RegExp(r'^\d+(-\d+)?$').hasMatch(v.trim());

  InputDecoration _dec(String label, {String? hint, String? error}) =>
      InputDecoration(border: const OutlineInputBorder(), labelText: label, hintText: hint, errorText: error);

  Widget _pad(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 6), child: w);

  Widget _sw(String title, String sub, bool v, ValueChanged<bool> f) =>
      SwitchListTile(title: Text(title), subtitle: Text(sub), value: v, onChanged: (x) => _set(() => f(x)));

  Widget _drop(String label, String value, Map<String, String> items, ValueChanged<String> f) => _pad(
        DropdownButtonFormField<String>(
          initialValue: items.containsKey(value) ? value : items.keys.first,
          isExpanded: true,
          decoration: _dec(label),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) _set(() => f(v));
          },
        ),
      );

  Future<void> _pickApps() async {
    final r = await Navigator.push<Set<String>>(
      context,
      MaterialPageRoute(builder: (_) => AppsPickerPage(selected: s.blockedApps.toSet())),
    );
    if (r != null) _set(() => s.bypassApps = r.toList().join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final connected = ctrl.state != ConnState.disconnected;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        if (connected)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SectionCard(children: const [
              ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Changes apply the next time you connect'),
              ),
            ]),
          ),
        SectionCard(title: 'Connection', children: [
          _pad(SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.vpn_lock), label: Text('VPN')),
              ButtonSegment(value: true, icon: Icon(Icons.lan_outlined), label: Text('Proxy only')),
            ],
            selected: {s.proxyOnly},
            onSelectionChanged: (v) => _set(() => s.proxyOnly = v.first),
          )),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                s.proxyOnly
                    ? 'No VPN service: the app exposes a local proxy (SOCKS5 / HTTP) on port ${s.socksPort}. '
                        'Not available for OpenVPN.'
                    : 'Routes the whole device through the tunnel.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          _sw('Auto-reconnect', 'Retry with back-off when the connection drops', s.autoReconnect,
              (v) => s.autoReconnect = v),
          if (s.autoReconnect)
            _drop('Maximum retries', '${s.reconnectMax}', const {
              '1': '1', '3': '3', '5': '5', '10': '10', '20': '20', '50': '50'
            }, (v) => s.reconnectMax = int.tryParse(v) ?? 5),
          _sw('Health check', 'Probe an idle tunnel every 45 s, reconnect after 3 failures', s.healthCheck,
              (v) => s.healthCheck = v),
          _sw('Connect when the app opens', 'Uses the selected server', s.autoConnect, (v) => s.autoConnect = v),
          _sw('Refresh subscriptions automatically', 'At app start, when older than 24 hours', s.autoUpdateSubs,
              (v) => s.autoUpdateSubs = v),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Network', children: [
          _drop('DNS', s.dnsPreset, const {
            'default': 'Default (from the profile)',
            'google': 'Google',
            'cloudflare': 'Cloudflare',
            'quad9': 'Quad9',
            'adguard': 'AdGuard',
            'custom': 'Custom',
          }, (v) => s.dnsPreset = v),
          if (s.dnsPreset == 'custom') ...[
            _pad(TextField(
                controller: _dns1,
                decoration: _dec('Primary DNS', hint: 'IP address or https://… (DoH)'),
                onChanged: (v) => _typed(() => s.dns1 = v))),
            _pad(TextField(
                controller: _dns2,
                decoration: _dec('Secondary DNS'),
                onChanged: (v) => _typed(() => s.dns2 = v))),
          ],
          _pad(TextField(
              controller: _fb,
              decoration: _dec('Fallback DNS (optional)'),
              onChanged: (v) => _typed(() => s.fallbackDns = v))),
          _sw('Bypass LAN', 'Keep local-network traffic out of the tunnel', s.bypassLan, (v) => s.bypassLan = v),
          _sw('Block QUIC (UDP 443)', 'Forces apps back to TCP, which tunnels far more reliably', s.blockQuic,
              (v) => s.blockQuic = v),
          _pad(TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: _dec('Local proxy port', hint: '10808'),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1024 && n <= 65534) _typed(() => s.socksPort = n);
            },
          )),
          _sw('Share over Wi-Fi hotspot', 'Opens the local proxy to other devices on your network', s.shareHotspot,
              (v) => s.shareHotspot = v),
          if (s.shareHotspot) ...[
            _pad(TextField(
                controller: _hu,
                decoration: _dec('Proxy username (SSH mode)'),
                onChanged: (v) => _typed(() => s.hotspotUser = v.trim()))),
            _pad(TextField(
                controller: _hp,
                obscureText: true,
                decoration: _dec('Proxy password (SSH mode)'),
                onChanged: (v) => _typed(() => s.hotspotPass = v))),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Xray-based profiles share without a password. Anyone on the hotspot can use the proxy.',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Apps', children: [
          ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('Apps that bypass the VPN'),
            subtitle: Text(s.blockedApps.isEmpty ? 'None' : '${s.blockedApps.length} selected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickApps,
          ),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Anti-censorship (Xray servers)', children: [
          _sw('TLS fragment', 'Splits the TLS hello to defeat SNI filters (TLS / REALITY only)', s.fragment,
              (v) => s.fragment = v),
          if (s.fragment) ...[
            _pad(TextField(
              controller: _fl,
              decoration: _dec('Fragment length (bytes)',
                  hint: '100-200', error: _range(_fl.text) ? null : 'Use a number or a range like 100-200'),
              onChanged: (v) {
                if (_range(v)) _typed(() => s.fragLength = v.trim());
                setState(() {});
              },
            )),
            _pad(TextField(
              controller: _fi,
              decoration: _dec('Fragment interval (ms)',
                  hint: '10-20', error: _range(_fi.text) ? null : 'Use a number or a range like 10-20'),
              onChanged: (v) {
                if (_range(v)) _typed(() => s.fragInterval = v.trim());
                setState(() {});
              },
            )),
          ],
          _sw('Mux', 'Multiplex connections (skipped for Vision, gRPC, XHTTP, mKCP)', s.mux, (v) => s.mux = v),
          if (s.mux)
            _pad(TextField(
              controller: _mc,
              keyboardType: TextInputType.number,
              decoration: _dec('Mux concurrency'),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1 && n <= 1024) _typed(() => s.muxConcurrency = n);
              },
            )),
          _drop('uTLS fingerprint', s.fingerprint, const {
            'default': 'Server default',
            'chrome': 'Chrome',
            'firefox': 'Firefox',
            'safari': 'Safari',
            'ios': 'iOS',
            'android': 'Android',
            'edge': 'Edge',
            'randomized': 'Randomized',
          }, (v) => s.fingerprint = v),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'SSH', children: [
          _pad(TextField(
            controller: _ka,
            keyboardType: TextInputType.number,
            decoration: _dec('Keep-alive interval (seconds)'),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 5 && n <= 600) _typed(() => s.sshKeepalive = n);
            },
          )),
          ListTile(
            leading: const Icon(Icons.key_off_outlined),
            title: const Text('Forget all pinned host keys'),
            subtitle: const Text('Keys are pinned on first connect and verified afterwards'),
            onTap: () async {
              if (await confirm(context, 'Forget pinned keys?',
                  'The next connection to each server will pin its key again.',
                  action: 'Forget')) {
                await ctrl.clearAllPinnedKeys();
                if (mounted) toast(context, 'Pinned host keys cleared');
              }
            },
          ),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Diagnostics', children: [
          _drop('Xray log level', s.logLevel, const {
            'none': 'None',
            'error': 'Error',
            'warning': 'Warning',
            'info': 'Info',
            'debug': 'Debug',
          }, (v) => s.logLevel = v),
          _pad(TextField(
            controller: _su,
            decoration: _dec('Speed-test URL', hint: 'http://speedtest.tele2.net/10MB.zip'),
            onChanged: (v) => _typed(() => s.speedUrl = v.trim().isEmpty ? 'http://speedtest.tele2.net/10MB.zip' : v.trim()),
          )),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('SSH mode needs an http:// URL.', style: TextStyle(fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Reliability', children: [
          ListTile(
            leading: Icon(_battery ? Icons.check_circle : Icons.battery_alert,
                color: _battery ? const Color(0xFF2E9E5B) : null),
            title: const Text('Ignore battery optimisation'),
            subtitle: Text(_battery
                ? 'Enabled: Android will not suspend the tunnel while idle'
                : 'Recommended: stops Android from killing the tunnel in the background'),
            onTap: _battery
                ? null
                : () async {
                    await Native.requestIgnoreBatteryOptimizations();
                    final v = await Native.ignoringBatteryOptimizations();
                    if (mounted) setState(() => _battery = v);
                  },
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Always-on VPN and kill switch'),
            subtitle: const Text('Opens Android VPN settings: enable "Always-on VPN" and '
                '"Block connections without VPN"'),
            trailing: const Icon(Icons.open_in_new),
            onTap: Native.openVpnSettings,
          ),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'Appearance', children: [
          _pad(SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('System')),
              ButtonSegment(value: 'light', label: Text('Light')),
              ButtonSegment(value: 'dark', label: Text('Dark')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => _set(() => s.themeMode = v.first),
          )),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'About', children: [
          ListTile(
            title: const Text('XRay Vpn 2.3.0'),
            subtitle: Text('Package xyz.xray.vpn  ·  Xray core ${_core.isEmpty ? '…' : _core}'),
            trailing: const Icon(Icons.copy, size: 18),
            onTap: () => Clipboard.setData(ClipboardData(text: 'XRay Vpn 2.3.0, core $_core')),
          ),
        ]),
      ]),
    );
  }
}
