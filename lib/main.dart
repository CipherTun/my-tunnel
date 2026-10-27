import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'controller.dart';
import 'models.dart';
import 'payload_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = VpnController();
  await controller.init();
  runApp(XRayVpnApp(controller: controller));
}

class XRayVpnApp extends StatefulWidget {
  const XRayVpnApp({super.key, required this.controller});
  final VpnController controller;
  @override
  State<XRayVpnApp> createState() => _XRayVpnAppState();
}

class _XRayVpnAppState extends State<XRayVpnApp> {
  late final VpnController controller = widget.controller;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final dark = controller.preferences.theme == 'dark';
          final light = controller.preferences.theme == 'light';
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'XRay Vpn',
            themeMode: dark ? ThemeMode.dark : light ? ThemeMode.light : ThemeMode.system,
            theme: _theme(Color(controller.preferences.accent), Brightness.light),
            darkTheme: _theme(Color(controller.preferences.accent), Brightness.dark),
            home: AppShell(controller: controller),
          );
        },
      );

  ThemeData _theme(Color seed, Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
        brightness: brightness,
        scaffoldBackgroundColor: brightness == Brightness.dark ? const Color(0xFF101615) : const Color(0xFFF4F7F6),
        cardTheme: CardThemeData(elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final VpnController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int tab = 0;
  VpnController get c => widget.controller;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: tab, children: [
          HomePage(controller: c, openServers: () => setState(() => tab = 1)),
          ServersPage(controller: c),
          ToolsPage(controller: c),
          SettingsPage(controller: c),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (index) => setState(() => tab = index),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.shield_outlined), selectedIcon: Icon(Icons.shield), label: 'Home'),
            NavigationDestination(icon: Badge(isLabelVisible: c.profiles.isNotEmpty, label: Text('${c.profiles.length}'), child: const Icon(Icons.dns_outlined)), selectedIcon: const Icon(Icons.dns), label: 'Servers'),
            const NavigationDestination(icon: Icon(Icons.handyman_outlined), selectedIcon: Icon(Icons.handyman), label: 'Tools'),
            const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller, required this.openServers});
  final VpnController controller;
  final VoidCallback openServers;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final profile = c.selectedProfile;
    final connected = c.isConnected;
    final color = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 24), children: [
        Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(15)), child: Icon(Icons.shield_moon_rounded, color: color, size: 27)),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('XRay Vpn', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)), Text('Private connection, under your control')])) ,
          IconButton(tooltip: 'Logs', onPressed: () => _openLogs(context, c), icon: const Icon(Icons.receipt_long_outlined)),
        ]),
        const SizedBox(height: 22),
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
          Container(width: 104, height: 104, decoration: BoxDecoration(shape: BoxShape.circle, color: (connected ? color : Theme.of(context).colorScheme.surfaceContainerHighest).withValues(alpha: .28), border: Border.all(color: connected ? color : Theme.of(context).dividerColor, width: 2)), child: Icon(connected ? Icons.shield : Icons.shield_outlined, size: 56, color: connected ? color : Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          Text(_stateTitle(c.state), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(c.statusMessage, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, height: 54, child: FilledButton.icon(
            onPressed: c.state == ConnectionStateKind.connecting || c.state == ConnectionStateKind.disconnecting ? null : () async {
              try {
                if (c.isConnected) { await c.disconnect(); } else { await c.connect(); }
              } catch (e) { if (context.mounted) _toast(context, e.toString()); }
            },
            icon: Icon(connected ? Icons.stop_circle_outlined : Icons.power_settings_new),
            label: Text(connected ? 'DISCONNECT' : c.state == ConnectionStateKind.connecting ? 'CONNECTING…' : 'CONNECT'),
          )),
        ]))),
        const SizedBox(height: 14),
        Card(child: InkWell(borderRadius: BorderRadius.circular(20), onTap: openServers, child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          CircleAvatar(backgroundColor: color.withValues(alpha: .12), child: Icon(profile?.kind == ProfileKind.ssh ? Icons.terminal : Icons.public, color: color)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(profile?.name ?? 'No server selected', style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 3), Text(profile?.subtitle ?? 'Add an SSH or Xray profile to begin', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)])),
          const Icon(Icons.chevron_right),
        ])))),
        if (c.preferences.proxyOnly || c.preferences.shareProxy) ...[
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [const Icon(Icons.router_outlined), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Local SOCKS5 proxy', style: TextStyle(fontWeight: FontWeight.w700)), Text('${c.preferences.shareProxy ? 'Hotspot clients: phone hotspot IP' : 'This device: 127.0.0.1'}:${c.preferences.socksPort}', style: Theme.of(context).textTheme.bodySmall), if (c.preferences.shareProxy) Text('User: ${c.preferences.hotspotUser} · password required', style: Theme.of(context).textTheme.bodySmall)])), IconButton(tooltip: 'Copy port', onPressed: () async { await Clipboard.setData(ClipboardData(text: '${c.preferences.socksPort}')); if (context.mounted) _toast(context, 'Proxy port copied'); }, icon: const Icon(Icons.copy))]))),
        ],
        const SizedBox(height: 14),
        Row(children: [Expanded(child: _StatCard(icon: Icons.arrow_upward, title: 'Upload', value: _rate(c.uploadSpeed))), const SizedBox(width: 10), Expanded(child: _StatCard(icon: Icons.arrow_downward, title: 'Download', value: _rate(c.downloadSpeed)))]),
        const SizedBox(height: 10),
        Row(children: [Expanded(child: _StatCard(icon: Icons.data_usage, title: 'Sent', value: _bytes(c.uploadBytes))), const SizedBox(width: 10), Expanded(child: _StatCard(icon: Icons.download_done, title: 'Received', value: _bytes(c.downloadBytes)))]),
        const SizedBox(height: 20),
        Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ActionChip(avatar: const Icon(Icons.speed), label: const Text('Speed test'), onPressed: () => _run(context, () => c.runSpeedTest())),
          ActionChip(avatar: const Icon(Icons.public), label: const Text('Check exit IP'), onPressed: () => _run(context, () => c.checkExitIp())),
          ActionChip(avatar: const Icon(Icons.bolt), label: const Text('Connect fastest'), onPressed: () => _run(context, () => c.connectFastest())),
          ActionChip(avatar: const Icon(Icons.receipt_long), label: const Text('Connection logs'), onPressed: () => _openLogs(context, c)),
        ]),
        const SizedBox(height: 20),
        Row(children: [Expanded(child: Text('Session', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))), Text(_duration(c.connectedDuration), style: Theme.of(context).textTheme.titleMedium)]),
        const SizedBox(height: 8),
        Text('SSH uses DartSSH2 and an Xray SOCKS outbound. Xray profiles run through the native Android TUN service.', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.icon, required this.title, required this.value});
  final IconData icon;
  final String title;
  final String value;
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 8), Text(title, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 3), Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))])));
}

class ServersPage extends StatefulWidget {
  const ServersPage({super.key, required this.controller});
  final VpnController controller;
  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  String query = '';
  String filter = 'All';
  VpnController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final list = c.profiles.where((p) => (filter == 'All' || p.kind.label == filter) && '${p.name} ${p.subtitle}'.toLowerCase().contains(query.toLowerCase())).toList();
    return SafeArea(child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Servers'), backgroundColor: Colors.transparent, actions: [IconButton(tooltip: 'Import', onPressed: () => _importDialog(context, c), icon: const Icon(Icons.content_paste)), IconButton(tooltip: 'Backup', onPressed: () => _backupDialog(context, c), icon: const Icon(Icons.backup_outlined))]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search profiles'), onChanged: (v) => setState(() => query = v))),
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [for (final label in ['All', 'SSH Tunnel', 'Xray', 'Proxy Chain', 'Failover Group']) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(label), selected: filter == label, onSelected: (_) => setState(() => filter = label))])),
        Expanded(child: list.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.dns_outlined, size: 54, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 12), Text(c.profiles.isEmpty ? 'No servers yet' : 'No matching profiles', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 6), const Text('Add an SSH server or import an Xray share link / JSON.', textAlign: TextAlign.center), const SizedBox(height: 16), FilledButton.icon(onPressed: () => _addDialog(context, c), icon: const Icon(Icons.add), label: const Text('Add server'))]))) : ListView.separated(padding: const EdgeInsets.all(16), itemCount: list.length, separatorBuilder: (_, __) => const SizedBox(height: 8), itemBuilder: (context, i) {
          final p = list[i];
          final selected = p.id == c.selectedProfileId;
          return Card(child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            leading: CircleAvatar(backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest, child: Icon(p.kind == ProfileKind.ssh ? Icons.terminal : Icons.public)),
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(p.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: PopupMenuButton<String>(onSelected: (action) => _profileAction(context, c, p, action), itemBuilder: (_) => const [PopupMenuItem(value: 'connect', child: Text('Connect')), PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'duplicate', child: Text('Duplicate')), PopupMenuItem(value: 'copy', child: Text('Copy profile')), PopupMenuItem(value: 'qr', child: Text('Show QR')), PopupMenuItem(value: 'delete', child: Text('Delete'))]),
            onTap: () async { await c.select(p.id); if (!c.isConnected && c.state == ConnectionStateKind.disconnected) { try { await c.connect(p); } catch (e) { if (context.mounted) _toast(context, e.toString()); } } },
          ));
        })),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _addDialog(context, c), icon: const Icon(Icons.add), label: const Text('Add server')),
    ));
  }
}

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) => SafeArea(child: Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(title: const Text('Tools'), backgroundColor: Colors.transparent),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _ToolCard(icon: Icons.code, title: 'Payload generator', subtitle: 'Expand HTTP CONNECT / injection tokens before copying', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PayloadToolPage(controller: controller)))),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.network_check, title: 'Endpoint checker', subtitle: 'Check one SSH/CDN host and port without claiming a VPN test', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostCheckPage()))),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.terminal, title: 'SSH UDP gateway setup', subtitle: 'Server-side badvpn-udpgw requirements and example service', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UdpGatewayHelpPage()))),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.receipt_long, title: 'Connection logs', subtitle: 'Review tunnel and engine diagnostics', onTap: () => _openLogs(context, controller)),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.data_usage, title: 'Data usage', subtitle: 'Current session totals and rates', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UsagePage(controller: controller)))),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.qr_code_2, title: 'QR / profile sharing', subtitle: 'Show or copy a shareable profile', onTap: () => _shareDialog(context, controller)),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.cloud_download_outlined, title: 'Subscriptions', subtitle: '${controller.subscriptions.length} saved sources · refresh and manage server lists', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SubscriptionsPage(controller: controller)))),
      const SizedBox(height: 9),
      _ToolCard(icon: Icons.backup_outlined, title: 'Backup & restore', subtitle: 'Export or restore encrypted local profile data as JSON', onTap: () => _backupDialog(context, controller)),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Engine boundaries', style: TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 7), Text('This build is scoped to SSH and Xray. It does not include OpenVPN, WireGuard, Psiphon, SlowDNS, or other protocol engines.', style: Theme.of(context).textTheme.bodySmall)]))),
    ]),
  ));
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(child: ListTile(leading: CircleAvatar(child: Icon(icon)), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(subtitle), trailing: const Icon(Icons.chevron_right), onTap: onTap));
}

class HostCheckPage extends StatefulWidget {
  const HostCheckPage({super.key});
  @override
  State<HostCheckPage> createState() => _HostCheckPageState();
}

class _HostCheckPageState extends State<HostCheckPage> {
  final host = TextEditingController();
  final port = TextEditingController(text: '443');
  final sni = TextEditingController();
  bool tls = false;
  bool running = false;
  String result = 'No test run yet.';
  @override
  void dispose() { host.dispose(); port.dispose(); sni.dispose(); super.dispose(); }

  Future<void> _check() async {
    final target = host.text.trim();
    final targetPort = int.tryParse(port.text) ?? 0;
    if (target.isEmpty || targetPort < 1 || targetPort > 65535) { _toast(context, 'Enter a valid host and port'); return; }
    setState(() { running = true; result = 'Connecting directly to $target:$targetPort…'; });
    final watch = Stopwatch()..start();
    Socket? raw;
    try {
      final connected = await Socket.connect(target, targetPort, timeout: const Duration(seconds: 8));
      raw = connected;
      if (tls) {
        final secure = await SecureSocket.secure(connected, host: sni.text.trim().isEmpty ? target : sni.text.trim(), onBadCertificate: (_) => false).timeout(const Duration(seconds: 8));
        watch.stop();
        result = 'TCP + TLS succeeded in ${watch.elapsedMilliseconds} ms. Peer: ${secure.remoteAddress.address}:${secure.remotePort}. This is a direct endpoint check, not a VPN traffic test.';
        await secure.close();
        raw = null;
      } else {
        watch.stop();
        result = 'TCP connection succeeded in ${watch.elapsedMilliseconds} ms. Peer: ${raw.remoteAddress.address}:${raw.remotePort}. This is a direct endpoint check, not a VPN traffic test.';
      }
    } catch (e) {
      watch.stop();
      result = 'Endpoint check failed after ${watch.elapsedMilliseconds} ms: $e';
    } finally {
      raw?.destroy();
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Endpoint checker')), body: ListView(padding: const EdgeInsets.all(16), children: [
    TextField(controller: host, decoration: const InputDecoration(labelText: 'Host or IP address')),
    const SizedBox(height: 10), TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
    const SizedBox(height: 8), SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Verify TLS certificate'), value: tls, onChanged: (v) => setState(() => tls = v)),
    if (tls) TextField(controller: sni, decoration: const InputDecoration(labelText: 'SNI override (optional)')),
    const SizedBox(height: 12), FilledButton.icon(onPressed: running ? null : _check, icon: running ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check), label: const Text('Check endpoint')),
    const SizedBox(height: 14), Card(child: Padding(padding: const EdgeInsets.all(14), child: SelectableText(result))),
    const SizedBox(height: 8), Text('This check uses a direct socket from the app. It does not test SSH authentication, payload acceptance, Xray configuration, or traffic through the VPN.', style: Theme.of(context).textTheme.bodySmall),
  ]));
}

class UdpGatewayHelpPage extends StatelessWidget {
  const UdpGatewayHelpPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('SSH UDP gateway setup')), body: ListView(padding: const EdgeInsets.all(16), children: [
    const Text('SSH UDP forwarding requires a badvpn-udpgw listener on the SSH server. The app checks the configured server-loopback port before it reports the tunnel connected.', style: TextStyle(fontSize: 15)),
    const SizedBox(height: 14),
    const Text('Example for a Debian/Ubuntu server you administer', style: TextStyle(fontWeight: FontWeight.w800)),
    const SizedBox(height: 8),
    const SelectableText('sudo apt update\nsudo apt install badvpn\nbadvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 256 --max-connections-for-client 16', style: TextStyle(fontFamily: 'monospace')),
    const SizedBox(height: 12),
    const Text('Keep the UDP gateway bound to loopback unless you have a specific reason to expose it. Use a systemd unit or your server manager to keep it running. Confirm the package and command-line options for your server distribution before deploying.', style: TextStyle(fontSize: 12)),
    const SizedBox(height: 12),
    FilledButton.icon(onPressed: () async { await Clipboard.setData(const ClipboardData(text: 'sudo apt update\nsudo apt install badvpn\nbadvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 256 --max-connections-for-client 16')); if (context.mounted) _toast(context, 'Commands copied'); }, icon: const Icon(Icons.copy), label: const Text('Copy example commands')),
    const SizedBox(height: 12),
    const Text('If the server does not provide UDPGW, set the profile UDP gateway port to 0. That is an explicit TCP-only configuration and will not carry UDP applications.', style: TextStyle(fontSize: 12)),
  ]));
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final VpnController controller;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  VpnController get c => widget.controller;
  late final TextEditingController dns = TextEditingController(text: c.preferences.customDns);
  late final TextEditingController bypass = TextEditingController(text: c.preferences.appBypassList);
  late final TextEditingController speedUrl = TextEditingController(text: c.preferences.speedTestUrl);
  late final TextEditingController hotspotUser = TextEditingController(text: c.preferences.hotspotUser);
  late final TextEditingController hotspotPassword = TextEditingController(text: c.preferences.hotspotPassword);

  @override
  void dispose() { dns.dispose(); bypass.dispose(); speedUrl.dispose(); hotspotUser.dispose(); hotspotPassword.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (c.preferences.shareProxy && (hotspotUser.text.trim().isEmpty || hotspotPassword.text.isEmpty)) {
      _toast(context, 'Set a proxy username and password before enabling proxy sharing');
      return;
    }
    c.preferences.customDns = dns.text.trim();
    c.preferences.appBypassList = bypass.text.trim();
    c.preferences.speedTestUrl = speedUrl.text.trim();
    c.preferences.hotspotUser = hotspotUser.text.trim();
    c.preferences.hotspotPassword = hotspotPassword.text;
    await c.savePreferences();
    if (mounted) _toast(context, 'Settings saved');
  }

  @override
  Widget build(BuildContext context) => SafeArea(child: Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(title: const Text('Settings'), backgroundColor: Colors.transparent, actions: [IconButton(onPressed: _save, tooltip: 'Save', icon: const Icon(Icons.check))]),
    body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      _section(context, 'Appearance'),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        DropdownButtonFormField<String>(initialValue: c.preferences.theme, decoration: const InputDecoration(labelText: 'Theme'), items: const [DropdownMenuItem(value: 'system', child: Text('System')), DropdownMenuItem(value: 'light', child: Text('Light')), DropdownMenuItem(value: 'dark', child: Text('Dark'))], onChanged: (v) async { if (v != null) { c.preferences.theme = v; await c.savePreferences(); setState(() {}); } }),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 10, children: [for (final color in [0xFF147D76, 0xFF3867D6, 0xFF7B4DD6, 0xFFB45309, 0xFFB42355, 0xFF2F855A]) InkWell(onTap: () async { c.preferences.accent = color; await c.savePreferences(); setState(() {}); }, borderRadius: BorderRadius.circular(50), child: CircleAvatar(radius: 16, backgroundColor: Color(color), child: c.preferences.accent == color ? const Icon(Icons.check, size: 18, color: Colors.white) : null))]))
      ]))),
      _section(context, 'Connection'),
      Card(child: Column(children: [
        SwitchListTile(title: const Text('VPN mode'), subtitle: Text(c.preferences.proxyOnly ? 'Proxy only — apps must use the local proxy' : 'Full-device VPN — Android TUN routing'), value: !c.preferences.proxyOnly, onChanged: (v) async { c.preferences.proxyOnly = !v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Auto reconnect'), subtitle: const Text('Retry after an unexpected tunnel drop'), value: c.preferences.autoReconnect, onChanged: (v) async { c.preferences.autoReconnect = v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Tunnel health checks'), subtitle: const Text('Check the native Xray engine while connected'), value: c.preferences.healthCheck, onChanged: (v) async { c.preferences.healthCheck = v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Auto-connect last profile'), value: c.preferences.autoConnect, onChanged: (v) async { c.preferences.autoConnect = v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Refresh subscriptions automatically'), subtitle: const Text('Refresh saved subscriptions at startup and every 12 hours'), value: c.preferences.autoUpdateSubscriptions, onChanged: (v) async { c.preferences.autoUpdateSubscriptions = v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Block QUIC (UDP 443)'), subtitle: const Text('Route UDP/443 to the Xray blackhole outbound'), value: c.preferences.blockQuic, onChanged: (v) async { c.preferences.blockQuic = v; await c.savePreferences(); setState(() {}); }),
        SwitchListTile(title: const Text('Bypass private LAN addresses'), subtitle: const Text('Route RFC1918/private destinations directly instead of through the proxy'), value: c.preferences.bypassLan, onChanged: (v) async { c.preferences.bypassLan = v; await c.savePreferences(); setState(() {}); }),
        ListTile(title: const Text('Maximum reconnect attempts'), trailing: DropdownButton<int>(value: c.preferences.maxReconnectAttempts, items: [1, 3, 5, 10, 20].map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(), onChanged: (v) async { if (v != null) { c.preferences.maxReconnectAttempts = v; await c.savePreferences(); setState(() {}); } })),
      ])),
      _section(context, 'DNS & routing'),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        DropdownButtonFormField<String>(initialValue: c.preferences.dnsMode, decoration: const InputDecoration(labelText: 'DNS resolver'), items: const [DropdownMenuItem(value: 'cloudflare', child: Text('Cloudflare')), DropdownMenuItem(value: 'google', child: Text('Google')), DropdownMenuItem(value: 'quad9', child: Text('Quad9')), DropdownMenuItem(value: 'adguard', child: Text('AdGuard')), DropdownMenuItem(value: 'custom', child: Text('Custom IP'))], onChanged: (v) async { if (v != null) { c.preferences.dnsMode = v; await c.savePreferences(); setState(() {}); } }),
        const SizedBox(height: 12), TextField(controller: dns, decoration: const InputDecoration(labelText: 'Custom DNS IP', hintText: '1.1.1.1')),
        const SizedBox(height: 12), TextField(controller: bypass, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Bypass app package IDs', hintText: 'com.example.app, com.other.app', helperText: 'One package ID per line or comma-separated. These apps bypass the VPN in full-device mode.')),
        const SizedBox(height: 8), Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: () async { final selected = await Navigator.push<List<String>>(context, MaterialPageRoute(builder: (_) => AppPickerPage(controller: c, initial: bypass.text.split(RegExp(r'[\s,;]+')).where((s) => s.isNotEmpty).toSet()))); if (selected != null && mounted) setState(() => bypass.text = selected.join('\n')); }, icon: const Icon(Icons.apps), label: const Text('Pick installed apps'))),
      ]))),
      _section(context, 'Proxy sharing'),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Share local SOCKS5 proxy'), subtitle: const Text('Allow tethered devices to connect through this SSH/Xray profile'), value: c.preferences.shareProxy, onChanged: (v) async { c.preferences.shareProxy = v; await c.savePreferences(); setState(() {}); }),
        TextField(controller: hotspotUser, decoration: const InputDecoration(labelText: 'Proxy username')),
        const SizedBox(height: 10),
        TextField(controller: hotspotPassword, obscureText: true, decoration: const InputDecoration(labelText: 'Proxy password')),
        const SizedBox(height: 10),
        Text('When enabled, set a tethered device’s SOCKS5 proxy to this phone’s hotspot IP and port ${c.preferences.socksPort}. Credentials are required for non-local clients. This is explicit proxy sharing, not transparent routing of all hotspot traffic.', style: Theme.of(context).textTheme.bodySmall),
      ]))),
      _section(context, 'Diagnostics'),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        DropdownButtonFormField<String>(initialValue: c.preferences.logLevel, decoration: const InputDecoration(labelText: 'Xray log level'), items: const [DropdownMenuItem(value: 'none', child: Text('None')), DropdownMenuItem(value: 'error', child: Text('Error')), DropdownMenuItem(value: 'warning', child: Text('Warning')), DropdownMenuItem(value: 'info', child: Text('Info')), DropdownMenuItem(value: 'debug', child: Text('Debug'))], onChanged: (v) async { if (v != null) { c.preferences.logLevel = v; await c.savePreferences(); setState(() {}); } }),
        const SizedBox(height: 12), TextField(controller: speedUrl, decoration: const InputDecoration(labelText: 'Speed-test URL')),
        const SizedBox(height: 12), Text('App exclusions and Xray socket protection are applied by the Android VpnService. Android tethering clients are not automatically routed through a VpnService tunnel.', style: Theme.of(context).textTheme.bodySmall),
      ]))),
      _section(context, 'Android system settings'),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.vpn_lock), title: const Text('Always-on VPN & kill switch'), subtitle: const Text('Open Android VPN settings; enable Always-on and Block connections without VPN if available'), trailing: const Icon(Icons.open_in_new), onTap: () async { try { await c.bridge.openSystemSettings('vpn'); } catch (e) { if (context.mounted) _toast(context, e.toString()); } }),
        ListTile(leading: const Icon(Icons.battery_saver_outlined), title: const Text('Battery optimization'), subtitle: const Text('Allow background reconnects on Android'), trailing: const Icon(Icons.open_in_new), onTap: () async { try { await c.bridge.openSystemSettings('battery'); } catch (e) { if (context.mounted) _toast(context, e.toString()); } }),
        ListTile(leading: const Icon(Icons.key_off_outlined), title: const Text('Forget all pinned SSH host keys'), subtitle: const Text('Next connection will establish a new first-seen key pin'), onTap: () async { await c.store.clearHostPins(); c.log('All stored SSH host-key pins were cleared by user request'); if (context.mounted) _toast(context, 'Pinned SSH host keys cleared'); }),
      ])),
      const SizedBox(height: 16), FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save settings')),
    ]),
  ));
}

Widget _section(BuildContext context, String title) => Padding(padding: const EdgeInsets.fromLTRB(2, 18, 2, 8), child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)));

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key, required this.controller});
  final VpnController controller;

  Future<void> _add(BuildContext context) async {
    final url = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (dialog) => AlertDialog(title: const Text('Add subscription'), content: TextField(controller: url, decoration: const InputDecoration(labelText: 'HTTP(S) subscription URL')), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialog, url.text.trim()), child: const Text('Add & refresh'))]));
    url.dispose();
    if (value == null || value.isEmpty || !context.mounted) return;
    try { await controller.addSubscription(value); if (context.mounted) _toast(context, 'Subscription added and refreshed'); }
    catch (e) { if (context.mounted) _toast(context, 'Subscription failed: $e'); }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) => Scaffold(
    appBar: AppBar(title: Text('Subscriptions (${controller.subscriptions.length})'), actions: [IconButton(tooltip: 'Refresh all', onPressed: () => _run(context, controller.refreshAllSubscriptions), icon: const Icon(Icons.refresh))]),
    body: controller.subscriptions.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.cloud_download_outlined, size: 52), const SizedBox(height: 12), const Text('No subscriptions saved'), const SizedBox(height: 8), const Text('Add a URL to import and refresh SSH/Xray share links.', textAlign: TextAlign.center), const SizedBox(height: 14), FilledButton.icon(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Text('Add subscription'))]))) : ListView.separated(padding: const EdgeInsets.all(16), itemCount: controller.subscriptions.length, separatorBuilder: (_, __) => const SizedBox(height: 8), itemBuilder: (context, index) {
      final source = controller.subscriptions[index];
      return Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.cloud_outlined)), title: Text(source.name), subtitle: Text('${source.url}\n${source.profileCount} supported entries · ${source.lastRefresh?.toLocal().toString().split('.').first ?? 'Never refreshed'}', maxLines: 3, overflow: TextOverflow.ellipsis), isThreeLine: true, trailing: PopupMenuButton<String>(onSelected: (action) async { if (action == 'refresh') { try { await controller.refreshSubscription(source.id); } catch (e) { if (context.mounted) _toast(context, e.toString()); } } else if (action == 'delete') { await controller.removeSubscription(source.id); } }, itemBuilder: (_) => const [PopupMenuItem(value: 'refresh', child: Text('Refresh now')), PopupMenuItem(value: 'delete', child: Text('Remove subscription'))])));
    }),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Text('Add subscription')),
  ));
}

class AppPickerPage extends StatefulWidget {
  const AppPickerPage({super.key, required this.controller, required this.initial});
  final VpnController controller;
  final Set<String> initial;
  @override
  State<AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<AppPickerPage> {
  late final Set<String> selected = Set<String>.from(widget.initial);
  List<Map<String, dynamic>> apps = <Map<String, dynamic>>[];
  bool loading = true;
  String query = '';
  String error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try { apps = await widget.controller.bridge.listApps(); }
    catch (e) { error = e.toString(); }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = apps.where((app) => '${app['label']} ${app['package']}'.toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(appBar: AppBar(title: Text('Bypass apps (${selected.length})'), actions: [TextButton(onPressed: () => Navigator.pop(context, selected.toList()..sort()), child: const Text('Done'))]), body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search installed apps'), onChanged: (v) => setState(() => query = v)),),
      Expanded(child: loading ? const Center(child: CircularProgressIndicator()) : error.isNotEmpty ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Could not list apps: $error'))) : filtered.isEmpty ? const Center(child: Text('No matching apps')) : ListView.builder(itemCount: filtered.length, itemBuilder: (context, i) {
        final app = filtered[i];
        final package = app['package'].toString();
        return CheckboxListTile(value: selected.contains(package), title: Text(app['label'].toString()), subtitle: Text(package), secondary: Icon(app['system'] == true ? Icons.android : Icons.apps), onChanged: (value) => setState(() { if (value == true) selected.add(package); else selected.remove(package); }));
      })),
      Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context, selected.toList()..sort()), child: const Text('Apply app exclusions'))),),
    ]));
  }
}

class ProfileEditorPage extends StatefulWidget {
  const ProfileEditorPage({super.key, required this.controller, required this.profile});
  final VpnController controller;
  final ServerProfile profile;
  @override
  State<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends State<ProfileEditorPage> {
  late final TextEditingController name = TextEditingController(text: widget.profile.name);
  late final Map<String, TextEditingController> fields = {for (final entry in widget.profile.data.entries) if (entry.value is! bool && entry.value is! List && entry.value is! Map) entry.key: TextEditingController(text: entry.value.toString())};
  final Map<String, bool> switches = {};
  late final Set<String> groupMembers = ((widget.profile.data['members'] as List?) ?? const []).map((e) => e.toString()).toSet();
  late String entryId = widget.profile.text('entry');
  late String exitId = widget.profile.text('exit');
  ServerProfile get p => widget.profile;
  VpnController get c => widget.controller;

  TextEditingController field(String key, [String fallback = '']) => fields.putIfAbsent(key, () => TextEditingController(text: fallback));
  bool flag(String key, [bool fallback = false]) => switches[key] ?? p.flag(key, fallback);

  @override
  void dispose() { name.dispose(); for (final item in fields.values) { item.dispose(); } super.dispose(); }

  Widget _text(String key, String label, {String? hint, bool secret = false, int lines = 1, TextInputType? keyboard}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: field(key), obscureText: secret, minLines: lines, maxLines: lines == 1 ? 1 : 8, keyboardType: keyboard, decoration: InputDecoration(labelText: label, hintText: hint)));
  Widget _toggle(String key, String label, String subtitle) => SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(label), subtitle: Text(subtitle), value: flag(key), onChanged: (v) => setState(() => switches[key] = v));

  void _syncEditorToProfile() {
    p.name = name.text.trim().isEmpty ? p.kind.label : name.text.trim();
    for (final entry in fields.entries) { p.data[entry.key] = entry.value.text; }
    p.data.addAll(switches);
    if (p.kind == ProfileKind.group) p.data['members'] = groupMembers.toList();
    if (p.kind == ProfileKind.chain) { p.data['entry'] = entryId; p.data['exit'] = exitId; }
  }

  Future<void> _save() async {
    _syncEditorToProfile();
    if (p.kind == ProfileKind.group) {
      if (groupMembers.isEmpty) { _toast(context, 'Select at least one server for the failover group'); return; }
    } else if (p.kind == ProfileKind.chain) {
      if (entryId.isEmpty || exitId.isEmpty || entryId == exitId) { _toast(context, 'Choose different entry and exit Xray profiles'); return; }
    } else if (p.kind == ProfileKind.ssh) {
      final host = p.text('host').trim();
      final port = int.tryParse(p.text('port', '22')) ?? 22;
      if (host.isEmpty || p.text('username').trim().isEmpty || port < 1 || port > 65535) { _toast(context, 'Enter a valid host, port, and username'); return; }
    } else if (p.kind == ProfileKind.xray && p.text('json').trim().isEmpty && p.text('link').trim().isEmpty) {
      _toast(context, 'Enter an Xray share link or JSON configuration'); return;
    }
    await c.upsert(p);
    if (mounted) Navigator.pop(context);
  }

  Widget _chainDropdown(String label, String selectedId, ValueChanged<String?> onChanged, {required String excludeId}) {
    final options = c.profiles.where((item) => item.kind == ProfileKind.xray && item.id != excludeId).toList();
    if (options.isEmpty) return Text('Add at least two Xray profiles before creating a chain.', style: Theme.of(context).textTheme.bodySmall);
    final value = options.any((item) => item.id == selectedId) ? selectedId : null;
    return DropdownButtonFormField<String>(initialValue: value, decoration: InputDecoration(labelText: label), items: options.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: onChanged);
  }

  Future<void> _testSsh() async {
    _syncEditorToProfile();
    try {
      final engine = SshEngine(log: c.log, readHostPins: c.store.loadHostPins, saveHostPin: c.store.saveHostPin);
      final session = await engine.connect(p, socksPort: 0, keepAliveSeconds: c.preferences.sshKeepaliveSeconds);
      await session.close();
      if (mounted) _toast(context, 'SSH authentication and local SOCKS forwarding succeeded');
    } catch (e) { if (mounted) _toast(context, 'SSH test failed: $e'); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Edit ${p.kind.label}'), actions: [IconButton(onPressed: _save, icon: const Icon(Icons.check), tooltip: 'Save')]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Profile name')),
      const SizedBox(height: 14),
      if (p.kind == ProfileKind.ssh) ...[
        _section(context, 'SSH server'),
        _text('host', 'SSH host', hint: 'server.example.com'),
        Row(children: [Expanded(child: _text('port', 'Port', hint: '22', keyboard: TextInputType.number)), const SizedBox(width: 10), Expanded(child: _text('username', 'Username'))]),
        _text('password', 'Password (optional when using a private key)', secret: true),
        _text('privateKey', 'SSH private key (optional)', lines: 6),
        _text('keyPassphrase', 'Private-key passphrase', secret: true),
        _toggle('tls', 'TLS / SNI', 'Wrap the SSH transport in validated TLS'),
        if (flag('tls')) _text('sni', 'SNI / TLS hostname', hint: 'cdn.example.com'),
        _toggle('websocket', 'WebSocket transport', 'Upgrade to a real WebSocket byte stream before SSH'),
        if (flag('websocket')) _text('wsPath', 'WebSocket path', hint: '/ssh'),
        if (flag('websocket')) _text('wsHost', 'WebSocket Host header (optional)'),
        _section(context, 'Payload & upstream proxy'),
        _text('payload', flag('websocket') ? 'Custom WebSocket headers (optional)' : 'Custom payload', hint: flag('websocket') ? 'X-Forwarded-For: [host]' : '[method] [host] [protocol][crlf]Host: [host][crlf*2]', lines: 5),
        _text('proxyHost', 'HTTP proxy host (optional)'),
        _text('proxyPort', 'HTTP proxy port', hint: '8080', keyboard: TextInputType.number),
        _text('proxyUser', 'Proxy username (optional)'),
        _text('proxyPassword', 'Proxy password (optional)', secret: true),
        const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('TLS/SNI and an ordinary HTTP upstream proxy cannot be combined in this build. For TLS/SNI, leave the upstream proxy host empty.', style: TextStyle(fontSize: 12))),
        _text('udpgwPort', 'UDP gateway port (0 disables UDP)', hint: '7300', keyboard: TextInputType.number),
        const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('UDP over SSH requires badvpn-udpgw to be running on the SSH server at 127.0.0.1 on this port. TCP forwarding works independently.', style: TextStyle(fontSize: 12))),
        FilledButton.tonalIcon(onPressed: _testSsh, icon: const Icon(Icons.network_check), label: const Text('Test SSH authentication & forwarding')),
      ] else if (p.kind == ProfileKind.xray) ...[
        _section(context, 'Xray configuration'),
        _text('link', 'Share link', hint: 'vless://…', lines: 3),
        const Padding(padding: EdgeInsets.only(bottom: 12), child: Center(child: Text('— or paste a complete Xray JSON configuration —'))),
        _text('json', 'Xray JSON', hint: '{"outbounds":[…]}', lines: 8),
        const Text('Share links are parsed by the official libXray library. JSON is passed to the native engine after the TUN inbound and runtime environment are prepared.', style: TextStyle(fontSize: 12)),
      ] else if (p.kind == ProfileKind.group) ...[
        _section(context, 'Failover order'),
        const Text('Choose servers in the order they should be tried. The next member is attempted only if a previous connection fails.', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        for (final member in c.profiles.where((item) => item.id != p.id && item.kind != ProfileKind.group))
          CheckboxListTile(contentPadding: EdgeInsets.zero, value: groupMembers.contains(member.id), title: Text(member.name), subtitle: Text(member.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis), secondary: groupMembers.contains(member.id) ? Text('#${groupMembers.toList().indexOf(member.id) + 1}') : null, onChanged: (value) => setState(() { if (value == true) { groupMembers.add(member.id); } else { groupMembers.remove(member.id); } })),
      ] else ...[
        _section(context, 'Xray proxy chain'),
        const Text('Traffic flows through the entry server first, then exits through the second Xray server. Both hops must support TCP-based proxying; Hysteria2/UDP-only hops are not supported in chains.', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        _chainDropdown('Entry server (first hop)', entryId, (value) => setState(() => entryId = value ?? ''), excludeId: exitId),
        const SizedBox(height: 12),
        _chainDropdown('Exit server (last hop)', exitId, (value) => setState(() => exitId = value ?? ''), excludeId: entryId),
      ],
      const SizedBox(height: 20), FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save profile')),
    ]),
  );
}

class PayloadToolPage extends StatefulWidget {
  const PayloadToolPage({super.key, required this.controller});
  final VpnController controller;
  @override
  State<PayloadToolPage> createState() => _PayloadToolPageState();
}

class _PayloadToolPageState extends State<PayloadToolPage> {
  final host = TextEditingController(text: 'example.com');
  final port = TextEditingController(text: '443');
  final sni = TextEditingController(text: 'example.com');
  final payload = TextEditingController(text: '[method] [host] [protocol][crlf]Host: [host][crlf]Connection: keep-alive[crlf*2]');
  String get renderedPayload {
    final portNumber = int.tryParse(port.text) ?? 443;
    final expanded = expandPayload(payload.text, host: host.text, port: portNumber, sni: sni.text);
    return utf8.decode(expanded.chunks.expand((part) => part).toList(), allowMalformed: true);
  }
  @override
  void dispose() { host.dispose(); port.dispose(); sni.dispose(); payload.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Payload generator')), body: ListView(padding: const EdgeInsets.all(16), children: [
    TextField(controller: host, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Target host')),
    const SizedBox(height: 10), TextField(controller: port, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
    const SizedBox(height: 10), TextField(controller: sni, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'SNI / front host')),
    const SizedBox(height: 10), TextField(controller: payload, onChanged: (_) => setState(() {}), minLines: 5, maxLines: 10, decoration: const InputDecoration(labelText: 'Payload template')),
    const SizedBox(height: 12), FilledButton(onPressed: () async { try { await Clipboard.setData(ClipboardData(text: renderedPayload)); if (context.mounted) _toast(context, 'Expanded payload copied'); } catch (e) { if (context.mounted) _toast(context, e.toString()); } }, child: const Text('Copy expanded payload')),
    const SizedBox(height: 14), Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Expanded output', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8), SelectableText(renderedPayload, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))]))),
    const SizedBox(height: 14), const Text('Supported tokens: [host], [port], [ssh], [sni], [method], [protocol], [crlf], [crlf*2], [lfcr], [lf], [cr], [random], [delay:milliseconds], [raw]. Split markers: [split], [delay_split], [instant_split].', style: TextStyle(fontSize: 12)),
    const SizedBox(height: 10), const Text('A generated payload is not proof that a gateway accepts it. Use Test SSH on a real profile and check the connection log.', style: TextStyle(fontSize: 12)),
  ]));
}

class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) {
    final now = DateTime.now();
    final records = controller.usageHistory.where((record) {
      final date = DateTime.tryParse((record['endedAt'] ?? '').toString());
      return date != null && now.difference(date).inDays <= 30;
    }).toList().reversed.toList();
    int sum(String key, DateTime cutoff) => controller.usageHistory.where((record) {
      final date = DateTime.tryParse((record['endedAt'] ?? '').toString());
      return date != null && !date.isBefore(cutoff);
    }).fold<int>(0, (total, record) => total + ((record[key] as num?)?.toInt() ?? 0));
    final todayStart = DateTime(now.year, now.month, now.day);
    final weekStart = now.subtract(const Duration(days: 7));
    final todayBytes = sum('uploadBytes', todayStart) + sum('downloadBytes', todayStart) + (controller.isConnected ? controller.uploadBytes + controller.downloadBytes : 0);
    final weekBytes = sum('uploadBytes', weekStart) + sum('downloadBytes', weekStart) + (controller.isConnected ? controller.uploadBytes + controller.downloadBytes : 0);
    return Scaffold(appBar: AppBar(title: const Text('Data usage')), body: ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [Expanded(child: _StatCard(icon: Icons.calendar_today, title: 'Today', value: _bytes(todayBytes))), const SizedBox(width: 10), Expanded(child: _StatCard(icon: Icons.date_range, title: 'Last 7 days', value: _bytes(weekBytes)))]),
      const SizedBox(height: 10),
      Row(children: [Expanded(child: _StatCard(icon: Icons.arrow_upward, title: 'Current upload', value: _bytes(controller.uploadBytes))), const SizedBox(width: 10), Expanded(child: _StatCard(icon: Icons.arrow_downward, title: 'Current download', value: _bytes(controller.downloadBytes)))]),
      const SizedBox(height: 10),
      _StatCard(icon: Icons.timer_outlined, title: 'Current session', value: _duration(controller.connectedDuration)),
      const SizedBox(height: 18),
      Text('Recent sessions (30 days)', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (records.isEmpty) const Padding(padding: EdgeInsets.all(18), child: Text('No completed sessions recorded yet.')),
      for (final record in records) Card(child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.shield_outlined)),
        title: Text((record['profileName'] ?? 'Server').toString()),
        subtitle: Text('${DateTime.tryParse((record['endedAt'] ?? '').toString())?.toLocal().toString().split('.').first ?? 'Unknown time'} · ${_duration(Duration(seconds: (record['durationSeconds'] as num?)?.toInt() ?? 0))}'),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [Text('↑ ${_bytes((record['uploadBytes'] as num?)?.toInt() ?? 0)}'), Text('↓ ${_bytes((record['downloadBytes'] as num?)?.toInt() ?? 0)}')]),
      )),
      const SizedBox(height: 10), Text('Traffic totals come from the native Xray metrics endpoint. Per-session history is stored in encrypted local storage.', style: Theme.of(context).textTheme.bodySmall),
    ]));
  });
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.controller});
  final VpnController controller;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String filter = '';
  @override
  Widget build(BuildContext context) {
    final logs = widget.controller.logs.where((line) => line.toLowerCase().contains(filter.toLowerCase())).toList();
    return Scaffold(appBar: AppBar(title: const Text('Connection logs'), actions: [IconButton(tooltip: 'Copy logs', onPressed: () async { await Clipboard.setData(ClipboardData(text: logs.join('\n'))); if (context.mounted) _toast(context, 'Logs copied'); }, icon: const Icon(Icons.copy_all)), IconButton(tooltip: 'Refresh native logs', onPressed: () async { final native = await widget.controller.bridge.readLogs(); widget.controller.logs.addAll(native); if (mounted) setState(() {}); }, icon: const Icon(Icons.refresh))]), body: Column(children: [Padding(padding: const EdgeInsets.all(12), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter logs'), onChanged: (v) => setState(() => filter = v)),), Expanded(child: logs.isEmpty ? const Center(child: Text('No logs yet')) : ListView.builder(itemCount: logs.length, itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: SelectableText(logs[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11)))))]));
  }
}

Future<void> _addDialog(BuildContext context, VpnController c) async {
  final choice = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (sheet) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [const Padding(padding: EdgeInsets.all(16), child: Text('Add server', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20))), ListTile(leading: const Icon(Icons.terminal), title: const Text('SSH Tunnel'), subtitle: const Text('SSH, payload, TLS/SNI and WebSocket'), onTap: () => Navigator.pop(sheet, 'ssh')), ListTile(leading: const Icon(Icons.public), title: const Text('Xray'), subtitle: const Text('VLESS, VMess, Trojan, Shadowsocks or raw Xray JSON'), onTap: () => Navigator.pop(sheet, 'xray')), ListTile(leading: const Icon(Icons.alt_route), title: const Text('Proxy chain'), subtitle: const Text('Chain two TCP-based Xray profiles'), onTap: () => Navigator.pop(sheet, 'chain')), ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Failover group'), subtitle: const Text('Try selected SSH/Xray servers in order'), onTap: () => Navigator.pop(sheet, 'group')), ListTile(leading: const Icon(Icons.content_paste), title: const Text('Import link / config'), onTap: () => Navigator.pop(sheet, 'import'))])));
  if (choice == null || !context.mounted) return;
  if (choice == 'import') { await _importDialog(context, c); return; }
  final kind = switch (choice) { 'ssh' => ProfileKind.ssh, 'chain' => ProfileKind.chain, 'group' => ProfileKind.group, _ => ProfileKind.xray };
  final Map<String, dynamic> data = switch (kind) { ProfileKind.ssh => {'host':'','port':'22','username':'','password':'','privateKey':'','keyPassphrase':'','payload':'','tls':false,'sni':'','websocket':false,'wsPath':'/','wsHost':'','proxyHost':'','proxyPort':'8080','proxyUser':'','proxyPassword':'','udpgwPort':'7300'}, ProfileKind.xray => {'link':'','json':''}, ProfileKind.chain => {'entry':'','exit':''}, ProfileKind.group => {'members': <String>[]}};
  final profile = ServerProfile(id: makeId(), name: 'New ${kind.label}', kind: kind, data: Map<String, dynamic>.from(data));
  await Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileEditorPage(controller: c, profile: profile)));
}

Future<void> _importDialog(BuildContext context, VpnController c) async {
  final text = TextEditingController();
  final clipboard = await Clipboard.getData('text/plain');
  text.text = clipboard?.text ?? '';
  if (!context.mounted) { text.dispose(); return; }
  final value = await showDialog<String>(context: context, builder: (dialog) => AlertDialog(title: const Text('Import profiles'), content: SizedBox(width: 500, child: TextField(controller: text, minLines: 5, maxLines: 10, decoration: const InputDecoration(hintText: 'Paste ssh://, vless://, vmess://, trojan://, ss://, Xray JSON, a profile backup, or a subscription URL'))), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialog, text.text), child: const Text('Import'))]));
  text.dispose();
  if (value == null || !context.mounted) return;
  try {
    final trimmed = value.trim();
    if (trimmed.startsWith('https://') || trimmed.startsWith('http://')) {
      try { await c.addSubscription(trimmed); if (context.mounted) _toast(context, 'Subscription saved and refreshed'); } catch (e) { if (context.mounted) _toast(context, 'Subscription failed: $e'); }
    } else {
      final count = await c.importMany(trimmed);
      if (context.mounted) _toast(context, 'Imported $count profile(s)');
    }
  } catch (e) { if (context.mounted) _toast(context, 'Import failed: $e'); }
}

Future<void> _backupDialog(BuildContext context, VpnController c) async {
  final text = TextEditingController(text: c.exportBackup());
  final result = await showDialog<String>(context: context, builder: (dialog) => AlertDialog(title: const Text('Backup & restore'), content: SizedBox(width: 520, child: TextField(controller: text, minLines: 5, maxLines: 12, decoration: const InputDecoration(labelText: 'Backup JSON'))), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close')), TextButton(onPressed: () async { await Clipboard.setData(ClipboardData(text: c.exportBackup())); if (dialog.mounted) Navigator.pop(dialog); }, child: const Text('Copy backup')), FilledButton(onPressed: () => Navigator.pop(dialog, text.text), child: const Text('Restore'))]));
  text.dispose();
  if (result == null || !context.mounted) return;
  try { final count = await c.importMany(result); if (context.mounted) _toast(context, 'Restored/imported $count profile(s)'); } catch (e) { if (context.mounted) _toast(context, 'Restore failed: $e'); }
}

Future<void> _profileAction(BuildContext context, VpnController c, ServerProfile p, String action) async {
  switch (action) {
    case 'connect':
      try { await c.connect(p); } catch (e) { if (context.mounted) _toast(context, e.toString()); }
      break;
    case 'edit':
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileEditorPage(controller: c, profile: p)));
      break;
    case 'duplicate':
      await c.upsert(ServerProfile(id: makeId(), name: '${p.name} copy', kind: p.kind, data: Map<String, dynamic>.from(p.data)));
      break;
    case 'copy':
      final text = p.kind == ProfileKind.xray && p.text('link').isNotEmpty ? p.text('link') : const JsonEncoder.withIndent('  ').convert(p.toJson());
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) _toast(context, 'Profile copied');
      break;
    case 'qr':
      final text = p.kind == ProfileKind.xray && p.text('link').isNotEmpty ? p.text('link') : const JsonEncoder.withIndent('  ').convert(p.toJson());
      await Navigator.push(context, MaterialPageRoute(builder: (_) => QrSharePage(title: p.name, value: text)));
      break;
    case 'delete':
      final yes = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(title: Text('Delete ${p.name}?'), content: const Text('This profile will be removed from secure local storage.'), actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Delete'))]));
      if (yes == true) await c.removeProfile(p.id);
      break;
  }
}

Future<void> _shareDialog(BuildContext context, VpnController c) async {
  final p = c.selectedProfile;
  if (p == null) { _toast(context, 'Select a profile first'); return; }
  await _profileAction(context, c, p, 'qr');
}

class QrSharePage extends StatelessWidget {
  const QrSharePage({super.key, required this.title, required this.value});
  final String title;
  final String value;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title)), body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Card(child: Padding(padding: const EdgeInsets.all(18), child: QrImageView(data: value, size: 270))), const SizedBox(height: 12), Text('${value.length} characters'), const SizedBox(height: 12), FilledButton.icon(onPressed: () async { await Clipboard.setData(ClipboardData(text: value)); if (context.mounted) _toast(context, 'Copied'); }, icon: const Icon(Icons.copy), label: const Text('Copy value')), const SizedBox(height: 8), const Text('QR content may include credentials. Only share it with people you trust.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12))]))));
}

Future<void> _openLogs(BuildContext context, VpnController c) async { await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => LogsPage(controller: c))); }
Future<void> _run(BuildContext context, Future<void> Function() task) async { try { await task(); if (context.mounted) _toast(context, 'Operation completed; check logs for the result'); } catch (e) { if (context.mounted) _toast(context, e.toString()); } }
void _toast(BuildContext context, String message) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating)); }
String _stateTitle(ConnectionStateKind state) => switch (state) { ConnectionStateKind.disconnected => 'Disconnected', ConnectionStateKind.connecting => 'Connecting', ConnectionStateKind.connected => 'Connected', ConnectionStateKind.disconnecting => 'Disconnecting', ConnectionStateKind.failed => 'Connection failed' };
String _rate(int bytes) => bytes < 1024 ? '$bytes B/s' : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB/s' : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB/s';
String _bytes(int bytes) => bytes < 1024 ? '$bytes B' : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
String _duration(Duration duration) => '${duration.inHours.toString().padLeft(2, '0')}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
