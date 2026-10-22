import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_info.dart';
import 'controller.dart';
import 'edit_page.dart';
import 'format.dart';
import 'logs_page.dart';
import 'models.dart';
import 'settings_page.dart';
import 'subs_page.dart';
import 'theme.dart';
import 'tools_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final c = VpnController();
  await c.init();
  runApp(XrayApp(c));
}

class XrayApp extends StatelessWidget {
  const XrayApp(this.ctrl, {super.key});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (_, __) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (ctrl.settings.themeMode) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        },
        home: HomePage(ctrl),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage(this.ctrl, {super.key});
  final VpnController ctrl;

  void _go(BuildContext c, Widget w) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => w));

  Future<void> _newProfile(BuildContext c, ProfileType t) async {
    final p = Profile(
      id: newId(),
      name: switch (t) {
        ProfileType.ssh => 'New SSH',
        ProfileType.v2ray => 'New Xray',
        ProfileType.wireguard => 'New WireGuard',
        ProfileType.group => 'New Group',
      },
      type: t,
    );
    _go(c, EditPage(ctrl: ctrl, profile: p, isNew: true));
  }

  Future<void> _paste(BuildContext c) async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text ?? '';
    if (text.trim().isEmpty) {
      if (c.mounted) toast(c, 'Clipboard is empty');
      return;
    }
    // A pasted subscription URL is offered as a subscription, not a profile.
    final lines = text.trim().split(RegExp(r'[\r\n]+'));
    final single = lines.length == 1 ? lines.first.trim() : '';
    if (single.startsWith('http://') || single.startsWith('https://')) {
      if (c.mounted) _go(c, SubsPage(ctrl: ctrl, prefillUrl: single));
      return;
    }
    var n = 0;
    for (final l in lines) {
      if (await ctrl.importText(l) != null) n++;
    }
    if (n == 0 && (text.trim().startsWith('{') || text.contains('[Interface]'))) {
      n = await ctrl.importText(text) != null ? 1 : 0;
    }
    if (c.mounted) toast(c, n == 0 ? 'No supported profile found in clipboard' : 'Imported $n profile(s)');
  }

  void _addSheet(BuildContext c) {
    showModalBottomSheet<void>(
      context: c,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in <(IconData, String, String, ProfileType)>[
            (Icons.terminal, 'SSH tunnel', 'Payload, SNI/TLS, WebSocket, proxy', ProfileType.ssh),
            (Icons.bolt, 'Xray', 'VLESS, VMess, Trojan, Shadowsocks, Hysteria2, JSON', ProfileType.v2ray),
            (Icons.vpn_key, 'WireGuard', 'Paste a wg-quick config', ProfileType.wireguard),
            (Icons.account_tree, 'Failover group', 'Try several profiles in order', ProfileType.group),
          ])
            ListTile(
              leading: Icon(e.$1),
              title: Text(e.$2),
              subtitle: Text(e.$3),
              onTap: () {
                Navigator.pop(ctx);
                _newProfile(c, e.$4);
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('Paste from clipboard'),
            subtitle: const Text('Share links, ssh://, WireGuard, JSON, subscription URL'),
            onTap: () {
              Navigator.pop(ctx);
              _paste(c);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: const Text(kAppName, style: TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              IconButton(
                tooltip: 'Test latency',
                onPressed: ctrl.busy || ctrl.pinging ? null : ctrl.pingAll,
                icon: ctrl.pinging
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.speed),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'subs':
                      _go(context, SubsPage(ctrl: ctrl));
                    case 'tools':
                      _go(context, ToolsPage(ctrl: ctrl));
                    case 'logs':
                      _go(context, LogsPage(ctrl: ctrl));
                    case 'settings':
                      _go(context, SettingsPage(ctrl: ctrl));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'subs', child: Text('Subscriptions')),
                  PopupMenuItem(value: 'tools', child: Text('Tools')),
                  PopupMenuItem(value: 'logs', child: Text('Logs')),
                  PopupMenuItem(value: 'settings', child: Text('Settings')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addSheet(context),
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              _Hero(ctrl: ctrl),
              const SizedBox(height: 16),
              if (ctrl.profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No profiles yet.\nTap Add to create one, or paste a link / subscription from the clipboard.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final p in ctrl.profiles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ProfileTile(ctrl: ctrl, p: p, onEdit: () => _go(context, EditPage(ctrl: ctrl, profile: p))),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.ctrl});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final st = ctrl.state;
    final color = switch (st) {
      ConnState.connected => kGood,
      ConnState.connecting => kWarn,
      ConnState.disconnected => scheme.primary,
    };
    final label = switch (st) {
      ConnState.connected => 'Connected',
      ConnState.connecting => 'Connecting…',
      ConnState.disconnected => 'Tap to connect',
    };
    final sel = ctrl.selected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(children: [
          GestureDetector(
            onTap: () {
              if (st == ConnState.disconnected) {
                if (sel == null) {
                  toast(context, 'Add or select a profile first');
                  return;
                }
                ctrl.connect();
              } else {
                ctrl.disconnect();
              }
            },
            child: SizedBox(
              width: 156,
              height: 156,
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.14),
                    border: Border.all(color: color, width: 3),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 26)],
                  ),
                  child: Icon(Icons.power_settings_new, size: 56, color: color),
                ),
                if (st == ConnState.connecting)
                  SizedBox(
                    width: 156,
                    height: 156,
                    child: CircularProgressIndicator(strokeWidth: 3, color: color),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 4),
          Text(
            st == ConnState.disconnected ? (sel?.name ?? 'No profile selected') : ctrl.activeName,
            style: TextStyle(color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
          if (ctrl.error != null && st != ConnState.connected) ...[
            const SizedBox(height: 10),
            Text(ctrl.error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error, fontSize: 13)),
          ],
          if (st == ConnState.connected) ...[
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _Stat(Icons.timer_outlined, ctrl.duration, 'Time'),
              _Stat(Icons.arrow_downward, fmtSpeed(ctrl.downSpeed), fmtBytes(ctrl.downTotal)),
              _Stat(Icons.arrow_upward, fmtSpeed(ctrl.upSpeed), fmtBytes(ctrl.upTotal)),
              if (ctrl.lastDelay != null) _Stat(Icons.network_ping, '${ctrl.lastDelay} ms', 'Delay'),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.value, this.sub);
  final IconData icon;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(children: [
      Icon(icon, size: 18, color: muted),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      Text(sub, style: TextStyle(fontSize: 11, color: muted)),
    ]);
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.ctrl, required this.p, required this.onEdit});
  final VpnController ctrl;
  final Profile p;
  final VoidCallback onEdit;

  IconData get _icon => switch (p.type) {
        ProfileType.ssh => Icons.terminal,
        ProfileType.v2ray => Icons.bolt,
        ProfileType.wireguard => Icons.vpn_key,
        ProfileType.group => Icons.account_tree,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sel = ctrl.selectedId == p.id;
    final ping = ctrl.pings[p.id];
    final ep = p.endpoint;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: sel ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5), width: sel ? 2 : 1),
      ),
      child: ListTile(
        onTap: ctrl.busy ? null : () => ctrl.select(p.id),
        leading: Icon(_icon, color: sel ? scheme.primary : null),
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          ep == null ? p.typeLabel : '${p.typeLabel} · ${ep.host}:${ep.port}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (ping != null)
            Text(
              ping < 0 ? 'timeout' : '$ping ms',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ping < 0 ? scheme.error : (ping < 300 ? kGood : kWarn),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') onEdit();
              if (v == 'dup') await ctrl.duplicate(p);
              if (v == 'del') {
                if (ctrl.busy && ctrl.selectedId == p.id) {
                  toast(context, 'Disconnect first');
                } else {
                  await ctrl.remove(p.id);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'dup', child: Text('Duplicate')),
              PopupMenuItem(value: 'del', child: Text('Delete')),
            ],
          ),
        ]),
      ),
    );
  }
}
