import 'package:flutter/material.dart';

import 'actions.dart';
import 'controller.dart';
import 'models.dart';
import 'widgets.dart';

class ServersTab extends StatefulWidget {
  const ServersTab({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<ServersTab> createState() => _ServersTabState();
}

class _ServersTabState extends State<ServersTab> {
  String _q = '';
  ProfileType? _filter;

  VpnController get ctrl => widget.ctrl;

  bool _matches(Profile p) {
    if (_filter != null && p.type != _filter) return false;
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return p.name.toLowerCase().contains(q) || p.subtitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final locked = ctrl.state != ConnState.disconnected;
        final types = {for (final p in ctrl.profiles) p.type}.toList()
          ..sort((a, b) => a.index.compareTo(b.index));
        final shown = ctrl.profiles.where(_matches).toList();

        // Manual servers first, then one section per subscription.
        final sections = <String, List<Profile>>{};
        for (final p in shown) {
          final key = p.subId;
          sections.putIfAbsent(key, () => []).add(p);
        }
        final keys = sections.keys.toList()
          ..sort((a, b) => a.isEmpty ? -1 : (b.isEmpty ? 1 : a.compareTo(b)));
        String titleOf(String id) {
          if (id.isEmpty) return 'My servers';
          for (final s in ctrl.subs) {
            if (s.id == id) return s.name;
          }
          return 'Subscription';
        }

        return Scaffold(
          appBar: AppBar(
            title: Text('Servers (${ctrl.profiles.length})'),
            actions: [
              IconButton(
                tooltip: 'Test latency of all servers',
                onPressed: locked || ctrl.pinging ? null : ctrl.pingAll,
                icon: ctrl.pinging
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_ping),
              ),
              IconButton(
                tooltip: 'Sort by latency',
                onPressed: locked ? null : ctrl.sortProfilesByLatency,
                icon: const Icon(Icons.sort),
              ),
            ],
          ),
          floatingActionButton: locked
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => addServerFlow(context, ctrl),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchBar(
                hintText: 'Search servers',
                elevation: WidgetStateProperty.all(0),
                leading: const Icon(Icons.search),
                onChanged: (v) => setState(() => _q = v.trim()),
              ),
            ),
            if (types.length > 1)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: const Text('All'),
                        selected: _filter == null,
                        onSelected: (_) => setState(() => _filter = null),
                      ),
                    ),
                    for (final t in types)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(typeShort(t)),
                          selected: _filter == t,
                          onSelected: (v) => setState(() => _filter = v ? t : null),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ctrl.profiles.isEmpty
                  ? _Empty(onAdd: () => addServerFlow(context, ctrl))
                  : shown.isEmpty
                      ? const Center(child: Text('No server matches your search'))
                      : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
                          for (final k in keys) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                              child: Text(titleOf(k),
                                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.w700)),
                            ),
                            for (final p in sections[k]!)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _ServerTile(ctrl: ctrl, profile: p, locked: locked),
                              ),
                          ],
                        ]),
            ),
          ]),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.dns_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('No servers yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Add a server by hand, paste a link or import a subscription.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add server')),
          ]),
        ),
      );
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.ctrl, required this.profile, required this.locked});
  final VpnController ctrl;
  final Profile profile;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = profile;
    final selected = p.id == ctrl.selectedId;
    final tile = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: selected ? cs.primaryContainer.withValues(alpha: 0.45) : cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: selected ? cs.primary : Colors.transparent, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: locked
            ? () => toast(context, 'Disconnect first to switch servers')
            : () => ctrl.select(p.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            TypeAvatar(p.type),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${typeShort(p.type)}  ·  ${p.subtitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            LatencyBadge(ctrl.latency[p.id]),
            if (!locked)
              PopupMenuButton<ProfileAction>(
                tooltip: 'More',
                onSelected: (a) => profileAction(context, ctrl, p, a),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: ProfileAction.edit, child: Text('Edit')),
                  const PopupMenuItem(value: ProfileAction.ping, child: Text('Test latency')),
                  if (p.type == ProfileType.group)
                    const PopupMenuItem(value: ProfileAction.sort, child: Text('Sort by latency')),
                  const PopupMenuItem(value: ProfileAction.duplicate, child: Text('Duplicate')),
                  const PopupMenuItem(value: ProfileAction.copy, child: Text('Copy link / config')),
                  if (p.type == ProfileType.v2ray)
                    const PopupMenuItem(value: ProfileAction.qr, child: Text('Show QR code')),
                  const PopupMenuItem(value: ProfileAction.delete, child: Text('Delete')),
                ],
              )
            else
              const SizedBox(width: 12),
          ]),
        ),
      ),
    );
    if (locked) return tile;
    return Dismissible(
      key: ValueKey('dismiss_${p.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      confirmDismiss: (_) => confirm(context, 'Delete "${p.name}"?', 'This cannot be undone.'),
      onDismissed: (_) => ctrl.remove(p.id),
      child: tile,
    );
  }
}
