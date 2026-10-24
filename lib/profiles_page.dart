import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'edit_page.dart';
import 'models.dart';
import 'subs_page.dart';
import 'theme.dart';
import 'widgets.dart';

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  String _q = '';
  ProfileType? _filter;

  VpnController get c => widget.ctrl;

  void _go(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  void _create(ProfileType t) {
    final p = Profile(id: newId(), name: 'New ${typeName(t)}', type: t);
    _go(EditPage(ctrl: c, profile: p, isNew: true));
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (d?.text ?? '').trim();
    if (text.isEmpty) {
      if (mounted) toast(context, 'Clipboard is empty');
      return;
    }
    final lines = text.split(RegExp(r'[\r\n]+'));
    final single = lines.length == 1 ? lines.first.trim() : '';
    if (single.startsWith('http://') || single.startsWith('https://')) {
      if (mounted) _go(SubsPage(ctrl: c, prefillUrl: single));
      return;
    }
    // Whole-text formats first (WireGuard, OpenVPN, JSON), then one link per line.
    var n = 0;
    final whole = importProfile(text);
    if (whole != null && (lines.length > 1 || whole.type != ProfileType.v2ray)) {
      await c.upsert(whole);
      n = 1;
    } else {
      for (final l in lines) {
        if (await c.importText(l) != null) n++;
      }
    }
    if (mounted) toast(context, n == 0 ? 'No supported profile found in clipboard' : 'Imported $n profile(s)');
  }

  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in <(ProfileType, String)>[
              (ProfileType.ssh, 'Payload, SNI/TLS, WebSocket, HTTP proxy hop'),
              (ProfileType.inject, 'HTTP proxy tunnel with payload injection'),
              (ProfileType.v2ray, 'VLESS, VMess, Trojan, Shadowsocks, Hysteria2, JSON'),
              (ProfileType.openvpn, 'Import an .ovpn configuration'),
              (ProfileType.wireguard, 'Paste a wg-quick config'),
              (ProfileType.proxy, 'HTTP, HTTPS or SOCKS5 upstream proxy'),
              (ProfileType.group, 'Try several profiles in order'),
            ])
              ListTile(
                leading: TypeAvatar(e.$1, size: 40),
                title: Text(typeName(e.$1), style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(e.$2),
                onTap: () {
                  Navigator.pop(ctx);
                  _create(e.$1);
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.content_paste)),
              title: const Text('Paste from clipboard', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Share links, ssh://, socks5://, .ovpn, WireGuard, JSON or a subscription URL'),
              onTap: () {
                Navigator.pop(ctx);
                _paste();
              },
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final q = _q.toLowerCase();
        final present = <ProfileType>{for (final p in c.profiles) p.type};
        final list = c.profiles.where((p) {
          if (_filter != null && p.type != _filter) return false;
          if (q.isEmpty) return true;
          final ep = p.endpoint;
          return p.name.toLowerCase().contains(q) ||
              p.typeLabel.toLowerCase().contains(q) ||
              (ep != null && ep.host.toLowerCase().contains(q));
        }).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text('Profiles (${c.profiles.length})', style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              IconButton(
                tooltip: c.settings.testMode == 'real' ? 'Test delay (core)' : 'Test latency (TCP)',
                onPressed: c.busy || c.pinging ? null : c.pingAll,
                icon: c.pinging
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.speed),
              ),
              IconButton(tooltip: 'Subscriptions', onPressed: () => _go(SubsPage(ctrl: c)), icon: const Icon(Icons.rss_feed)),
              IconButton(tooltip: 'Paste', onPressed: _paste, icon: const Icon(Icons.content_paste)),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(onPressed: _addSheet, icon: const Icon(Icons.add), label: const Text('Add')),
          body: Column(children: [
            if (c.profiles.length > 4 || _q.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search profiles'),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            if (present.length > 1)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(label: const Text('All'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null)),
                    ),
                    for (final t in ProfileType.values)
                      if (present.contains(t))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: Icon(typeIcon(t), size: 16),
                            label: Text(typeName(t)),
                            selected: _filter == t,
                            onSelected: (_) => setState(() => _filter = _filter == t ? null : t),
                          ),
                        ),
                  ],
                ),
              ),
            Expanded(
              child: c.profiles.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.dns_outlined, size: 56, color: scheme.onSurfaceVariant),
                          const SizedBox(height: 12),
                          const Text('No profiles yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text('Create a profile, or paste a link, configuration or subscription URL.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 16),
                          FilledButton.icon(onPressed: _addSheet, icon: const Icon(Icons.add), label: const Text('Add profile')),
                        ]),
                      ),
                    )
                  : list.isEmpty
                      ? const Center(child: Text('Nothing matches'))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) => _Tile(ctrl: c, p: list[i], onEdit: () => _go(EditPage(ctrl: c, profile: list[i]))),
                        ),
            ),
          ]),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.ctrl, required this.p, required this.onEdit});
  final VpnController ctrl;
  final Profile p;
  final VoidCallback onEdit;

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
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        leading: TypeAvatar(p.type),
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(ep == null ? p.typeLabel : '${p.typeLabel} · ${ep.host}:${ep.port}', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (ping != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (ping < 0 ? scheme.error : (ping < 300 ? kGood : kWarn)).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                ping < 0 ? 'timeout' : '$ping ms',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ping < 0 ? scheme.error : (ping < 300 ? kGood : kWarn)),
              ),
            ),
          if (sel) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.check_circle, color: scheme.primary, size: 20)),
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
