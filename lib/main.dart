import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'edit_page.dart';
import 'models.dart';
import 'settings_page.dart';
import 'tools_page.dart';

void main() => runApp(const VpnApp());

class VpnApp extends StatelessWidget {
  const VpnApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'XRay Vpn',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const HomePage(),
      );
}

IconData typeIcon(ProfileType t) => switch (t) {
      ProfileType.ssh => Icons.terminal,
      ProfileType.v2ray => Icons.rocket_launch,
      ProfileType.wireguard => Icons.vpn_key,
      ProfileType.group => Icons.layers,
    };

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _add() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => SafeArea(
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
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'import') return _import();
    final type = choice as ProfileType;
    await _edit(Profile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: 'New ${typeLabel(type)}',
      type: type,
    ));
  }

  Future<void> _import() async {
    final c = TextEditingController(
        text: (await Clipboard.getData('text/plain'))?.text ?? '');
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
              hintText: 'vmess:// vless:// trojan:// ss:// hysteria2:// ssh:// link,\n'
                  'wg-quick config, Xray JSON, or an exported profile'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Import')),
        ],
      ),
    );
    if (text == null) return;
    final p = importProfile(text);
    if (p == null) return _snack('Not recognised');
    await ctrl.upsert(p);
  }

  Future<void> _edit(Profile p) async {
    final r = await Navigator.push<Profile>(
        context,
        MaterialPageRoute(
            builder: (_) => EditPage(profile: p, all: ctrl.profiles)));
    if (r != null) await ctrl.upsert(r);
  }

  Future<void> _menu(String v, Profile p) async {
    switch (v) {
      case 'edit':
        return _edit(p);
      case 'dup':
        final j = p.toJson();
        await ctrl.upsert(Profile.fromJson({
          ...j,
          'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'name': '${p.name} copy',
          'data': Map<String, dynamic>.from(p.data),
        }));
        return;
      case 'export':
        await Clipboard.setData(ClipboardData(text: _exportJson(p)));
        return _snack('Config copied to clipboard');
      case 'del':
        return ctrl.remove(p.id);
    }
  }

  String _exportJson(Profile p) {
    final enc = const JsonEncoderIndented();
    return enc.convert(p.toJson()..remove('id'));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final connected = ctrl.state == ConnState.connected;
        final busy = ctrl.state == ConnState.connecting;
        final locked = ctrl.state != ConnState.disconnected;
        return Scaffold(
          appBar: AppBar(
            title: const Text('XRay Vpn'),
            actions: [
              IconButton(
                  icon: const Icon(Icons.build_outlined),
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const ToolsPage()))),
              IconButton(
                  icon: const Icon(Icons.article_outlined),
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => LogsPage(ctrl: ctrl)))),
              IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: locked
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => SettingsPage(ctrl: ctrl)))),
            ],
          ),
          floatingActionButton: locked
              ? null
              : FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
          body: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(children: [
                  Icon(connected ? Icons.shield : Icons.shield_outlined,
                      size: 72, color: connected ? Colors.green : cs.outline),
                  const SizedBox(height: 4),
                  Text(ctrl.state.name.toUpperCase(),
                      style: Theme.of(context).textTheme.titleSmall),
                ]),
              ),
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
                            subtitle: Text(p.subtitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: locked ? null : () => ctrl.select(p.id),
                            trailing: locked
                                ? null
                                : PopupMenuButton<String>(
                                    onSelected: (v) => _menu(v, p),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                                      PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                                      PopupMenuItem(value: 'export', child: Text('Export')),
                                      PopupMenuItem(value: 'del', child: Text('Delete')),
                                    ],
                                  ),
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
        );
      },
    );
  }
}

class JsonEncoderIndented {
  const JsonEncoderIndented();
  String convert(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
}

class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Logs'), actions: [
          IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: ctrl.logs.join('\n')))),
        ]),
        body: ListenableBuilder(
          listenable: ctrl,
          builder: (_, __) => ListView(padding: const EdgeInsets.all(12), children: [
            SelectableText(
              ctrl.logs.isEmpty ? 'No logs yet.' : ctrl.logs.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ]),
        ),
      );
}
