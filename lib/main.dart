import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'core_config.dart';
import 'edit_page.dart';
import 'models.dart';
import 'native.dart';
import 'qr_page.dart';
import 'settings_page.dart';
import 'subscription.dart' show shareSchemes;
import 'usage_page.dart';
import 'tools_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VpnApp());
}

class VpnApp extends StatefulWidget {
  const VpnApp({super.key});
  @override
  State<VpnApp> createState() => _VpnAppState();
}

class _VpnAppState extends State<VpnApp> {
  final ctrl = VpnController();

  @override
  void initState() {
    super.initState();
    ctrl.init();
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  static const _seed = Color(0xFF0F766E);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => MaterialApp(
          title: 'XRay Vpn',
          debugShowCheckedModeBanner: false,
          themeMode: switch (ctrl.settings.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
          darkTheme: ThemeData(
              colorSchemeSeed: _seed, brightness: Brightness.dark, useMaterial3: true),
          home: HomePage(ctrl: ctrl),
        ),
      );
}

IconData typeIcon(ProfileType t) => switch (t) {
      ProfileType.ssh => Icons.terminal,
      ProfileType.v2ray => Icons.rocket_launch,
      ProfileType.wireguard => Icons.vpn_key,
      ProfileType.openvpn => Icons.security,
      ProfileType.chain => Icons.link,
      ProfileType.group => Icons.layers,
    };

String fmtBytes(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  VpnController get ctrl => widget.ctrl;
  String _lastOffered = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.setLinkHandler(_onLink);
    Native.takeLink().then((l) {
      if (l != null && mounted) _onLink(l);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  /// A vless:// vmess:// ... link opened from a browser or chat app.
  Future<void> _onLink(String link) async {
    if (!mounted) return;
    final p = importProfile(link);
    if (p == null) return _snack('Unsupported link');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import server?'),
        content: Text('${p.name}\n${p.subtitle}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok == true) await ctrl.upsert(p);
  }

  /// Offers to import a share link that is sitting in the clipboard.
  Future<void> _checkClipboard() async {
    if (ctrl.state != ConnState.disconnected) return;
    String t;
    try {
      t = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
    } catch (_) {
      return;
    }
    if (t.isEmpty || t == _lastOffered || t.length > 8000 || t.contains('\n')) return;
    if (!t.contains('://') || !shareSchemes.contains(t.split('://').first.toLowerCase())) return;
    final p = importProfile(t);
    if (p == null || !mounted) return;
    _lastOffered = t;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Link in clipboard: ${p.name}'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'IMPORT', onPressed: () => ctrl.upsert(p)),
    ));
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _add() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final t in ProfileType.values)
              ListTile(
                leading: Icon(typeIcon(t)),
                title: Text(typeLabel(t)),
                onTap: () => Navigator.pop(context, t),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste share link / config'),
              onTap: () => Navigator.pop(context, 'import'),
            ),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('Add subscription URL'),
              onTap: () => Navigator.pop(context, 'sub'),
            ),
          ]),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'import') return _import();
    if (choice == 'sub') {
      await Navigator.push(
          context, MaterialPageRoute(builder: (_) => SubscriptionsPage(ctrl: ctrl, addNow: true)));
      return;
    }
    final type = choice as ProfileType;
    await _edit(Profile(id: newId(), name: 'New ${typeLabel(type)}', type: type));
  }

  Future<void> _import() async {
    final c = TextEditingController(text: (await Clipboard.getData('text/plain'))?.text ?? '');
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import'),
        content: TextField(
          controller: c,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
              hintText: 'vmess:// vless:// trojan:// ss:// hysteria2:// ssh:// link(s),\n'
                  'wg-quick config, Xray JSON, exported profile or backup'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Import')),
        ],
      ),
    );
    if (text == null) return;
    final t = text.trim();
    try {
      if (t.startsWith('{') && t.contains('"xray-vpn"')) {
        final n = await ctrl.importAll(t);
        return _snack('Backup restored ($n profiles)');
      }
      // several links pasted at once
      final lines = t.split(RegExp(r'[\r\n]+')).where((e) => e.contains('://')).toList();
      if (lines.length > 1 && !t.startsWith('{')) {
        var n = 0;
        for (final l in lines) {
          final p = importProfile(l, id: newId());
          if (p != null) {
            await ctrl.upsert(p);
            n++;
          }
        }
        return _snack('Imported $n profiles');
      }
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => SubscriptionsPage(ctrl: ctrl, addNow: true, initialUrl: t)));
        return;
      }
    } catch (e) {
      return _snack('Import failed: $e');
    }
    final p = importProfile(t);
    if (p == null) return _snack('Not recognised');
    await ctrl.upsert(p);
  }

  Future<void> _edit(Profile p) async {
    final r = await Navigator.push<Profile>(context,
        MaterialPageRoute(builder: (_) => EditPage(profile: p, all: ctrl.profiles, ctrl: ctrl)));
    if (r != null) await ctrl.upsert(r);
  }

  Future<void> _menu(String v, Profile p) async {
    switch (v) {
      case 'edit':
        return _edit(p);
      case 'ping':
        return ctrl.ping(p);
      case 'sort':
        await ctrl.sortGroupByLatency(p);
        return _snack('Group sorted by latency');
      case 'dup':
        final j = p.toJson();
        await ctrl.upsert(Profile.fromJson({
          ...j,
          'id': newId(),
          'name': '${p.name} copy',
          'data': Map<String, dynamic>.from(p.data),
        }));
        return;
      case 'export':
        final enc = const JsonEncoder.withIndent('  ');
        await Clipboard.setData(ClipboardData(text: enc.convert(p.toJson()..remove('id'))));
        return _snack('Config copied to clipboard');
      case 'qr':
        final link = shareLinkOf(p);
        if (link == null) return _snack('QR is available for share-link profiles only');
        if (!mounted) return;
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => QrPage(title: p.name, data: link)));
        return;
      case 'del':
        return ctrl.remove(p.id);
    }
  }

  Widget _latency(Profile p) {
    final v = ctrl.latency[p.id];
    if (v == null) return const SizedBox.shrink();
    if (v == -2) {
      return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (v == -3) return const Text('UDP', style: TextStyle(fontSize: 12));
    if (v < 0) return const Text('✕', style: TextStyle(color: Colors.red));
    final c = v < 300 ? Colors.green : (v < 800 ? Colors.orange : Colors.red);
    return Text('$v ms', style: TextStyle(color: c, fontSize: 12));
  }

  Widget _statusCard(ColorScheme cs) {
    final connected = ctrl.state == ConnState.connected;
    final label = switch (ctrl.state) {
      ConnState.connected => 'CONNECTED',
      ConnState.connecting => 'CONNECTING…',
      ConnState.disconnected => 'DISCONNECTED',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(children: [
        Icon(connected ? Icons.shield : Icons.shield_outlined,
            size: 64, color: connected ? Colors.green : cs.outline),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        if (connected) ...[
          Text(ctrl.duration, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _stat(Icons.arrow_upward, '${fmtBytes(ctrl.upSpeed)}/s', fmtBytes(ctrl.upTotal)),
            _stat(Icons.arrow_downward, '${fmtBytes(ctrl.downSpeed)}/s', fmtBytes(ctrl.downTotal)),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            ActionChip(
              avatar: const Icon(Icons.speed, size: 16),
              label: Text(ctrl.tunnelDelay > 0
                  ? '${ctrl.tunnelDelay} ms'
                  : ctrl.tunnelDelay < 0
                      ? 'Test failed'
                      : 'Test tunnel'),
              onPressed: ctrl.testTunnel,
            ),
            ActionChip(
              avatar: const Icon(Icons.public, size: 16),
              label: Text(ctrl.exitIp.isEmpty ? 'Show exit IP' : ctrl.exitIp),
              onPressed: ctrl.checkIp,
            ),
            ActionChip(
              avatar: const Icon(Icons.download, size: 16),
              label: Text(ctrl.speedRunning
                  ? 'Testing…'
                  : ctrl.speedMbps > 0
                      ? '${ctrl.speedMbps.toStringAsFixed(1)} Mbps'
                      : ctrl.speedMbps < 0
                          ? 'Speed test failed'
                          : 'Speed test'),
              onPressed: ctrl.speedRunning ? null : ctrl.runSpeedTest,
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _stat(IconData i, String speed, String total) => Column(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 16),
          const SizedBox(width: 4),
          Text(speed),
        ]),
        Text('total $total', style: Theme.of(context).textTheme.bodySmall),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final connected = ctrl.state == ConnState.connected;
        final busy = ctrl.state == ConnState.connecting;
        final locked = ctrl.state != ConnState.disconnected;
        return PopScope(
          // While connected, Back sends the app to the background instead of
          // destroying the activity (which would also kill the Dart SSH tunnel).
          canPop: !locked,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) Native.moveToBack();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('XRay Vpn'),
              actions: [
                IconButton(
                    tooltip: 'Test latency of all profiles',
                    icon: const Icon(Icons.network_ping),
                    onPressed: locked ? null : ctrl.pingAll),
                IconButton(
                    tooltip: 'Sort by latency',
                    icon: const Icon(Icons.sort),
                    onPressed: locked ? null : ctrl.sortProfilesByLatency),
                IconButton(
                    tooltip: 'Data usage',
                    icon: const Icon(Icons.data_usage),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => UsagePage(ctrl: ctrl)))),
                IconButton(
                    tooltip: 'Tools',
                    icon: const Icon(Icons.build_outlined),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => ToolsPage(ctrl: ctrl)))),
                IconButton(
                    tooltip: 'Logs',
                    icon: const Icon(Icons.article_outlined),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => LogsPage(ctrl: ctrl)))),
                IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: locked
                        ? null
                        : () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => SettingsPage(ctrl: ctrl)))),
              ],
            ),
            floatingActionButton:
                locked ? null : FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
            body: SafeArea(
              child: Column(children: [
                _statusCard(cs),
                Expanded(
                  child: ctrl.profiles.isEmpty
                      ? const Center(child: Text('Tap + to create a profile'))
                      : ListView(children: [
                          for (final p in ctrl.profiles)
                            ListTile(
                              selected: p.id == ctrl.selectedId,
                              selectedTileColor: cs.primaryContainer.withValues(alpha: 0.4),
                              leading: Icon(typeIcon(p.type)),
                              title: Text(p.name),
                              subtitle:
                                  Text(p.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: locked ? null : () => ctrl.select(p.id),
                              trailing: locked
                                  ? null
                                  : Row(mainAxisSize: MainAxisSize.min, children: [
                                      _latency(p),
                                      PopupMenuButton<String>(
                                        onSelected: (v) => _menu(v, p),
                                        itemBuilder: (_) => [
                                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                                          const PopupMenuItem(
                                              value: 'ping', child: Text('Test latency')),
                                          if (p.type == ProfileType.group)
                                            const PopupMenuItem(
                                                value: 'sort', child: Text('Sort by latency')),
                                          const PopupMenuItem(
                                              value: 'dup', child: Text('Duplicate')),
                                          const PopupMenuItem(
                                              value: 'export', child: Text('Export')),
                                          if (p.type == ProfileType.v2ray)
                                            const PopupMenuItem(
                                                value: 'qr', child: Text('Show QR code')),
                                          const PopupMenuItem(value: 'del', child: Text('Delete')),
                                        ],
                                      ),
                                    ]),
                            ),
                        ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: ctrl.selected == null
                          ? null
                          : (locked ? ctrl.disconnect : ctrl.connect),
                      child: Text(busy
                          ? 'Connecting… (tap to cancel)'
                          : connected
                              ? 'Disconnect'
                              : 'Connect'),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  bool _core = false;
  List<String> _coreLines = const [];

  Future<void> _loadCore() async {
    final l = await widget.ctrl.coreLogs();
    if (mounted) setState(() => _coreLines = l);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Logs'), actions: [
          TextButton(
              onPressed: () {
                setState(() => _core = !_core);
                if (_core) _loadCore();
              },
              child: Text(_core ? 'App' : 'Core')),
          IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(
                  text: (_core ? _coreLines : widget.ctrl.logs).join('\n')))),
          IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => widget.ctrl.logs.clear())),
        ]),
        body: ListenableBuilder(
          listenable: widget.ctrl,
          builder: (_, __) {
            final lines = _core ? _coreLines : widget.ctrl.logs;
            return ListView(padding: const EdgeInsets.all(12), children: [
              SelectableText(
                lines.isEmpty ? 'No logs yet.' : lines.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ]);
          },
        ),
      );
}
