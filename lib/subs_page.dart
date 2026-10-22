import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

class SubsPage extends StatefulWidget {
  const SubsPage({super.key, required this.ctrl, this.prefillUrl});
  final VpnController ctrl;
  final String? prefillUrl;

  @override
  State<SubsPage> createState() => _SubsPageState();
}

class _SubsPageState extends State<SubsPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefillUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _add(widget.prefillUrl));
    }
  }

  Future<void> _run(Future<int> Function() job, String okPrefix) async {
    setState(() => _busy = true);
    try {
      final n = await job();
      if (mounted) toast(context, '$okPrefix: $n profiles');
    } catch (e) {
      if (mounted) toast(context, 'Failed: ${errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add([String? url]) async {
    final n = TextEditingController();
    final u = TextEditingController(text: url ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add subscription'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, decoration: const InputDecoration(labelText: 'Name (optional)')),
          const SizedBox(height: 12),
          TextField(controller: u, decoration: const InputDecoration(labelText: 'URL'), keyboardType: TextInputType.url),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && u.text.trim().isNotEmpty) {
      await _run(() => widget.ctrl.addSubscription(n.text, u.text), 'Imported');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) {
        final subs = widget.ctrl.subs;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Subscriptions'),
            actions: [
              if (subs.isNotEmpty)
                IconButton(
                  tooltip: 'Update all',
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            var t = 0;
                            for (final s in List<Subscription>.of(subs)) {
                              t += await widget.ctrl.updateSubscription(s);
                            }
                            return t;
                          }, 'Updated'),
                  icon: const Icon(Icons.sync),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton(onPressed: _busy ? null : _add, child: const Icon(Icons.add)),
          body: Column(children: [
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: subs.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Add a subscription URL to import and refresh a list of servers.', textAlign: TextAlign.center),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final s in subs)
                          Card(
                            child: ListTile(
                              title: Text(s.name),
                              subtitle: Text(
                                '${widget.ctrl.profiles.where((p) => p.subId == s.id).length} profiles · '
                                '${s.updated == null ? 'never updated' : 'updated ${s.updated!.toLocal().toString().substring(0, 16)}'}',
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                  icon: const Icon(Icons.refresh),
                                  onPressed: _busy ? null : () => _run(() => widget.ctrl.updateSubscription(s), 'Updated'),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          final ok = await showDialog<bool>(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              title: Text('Delete "${s.name}"?'),
                                              content: const Text('Its imported profiles are removed too.'),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                                              ],
                                            ),
                                          );
                                          if (ok == true) await widget.ctrl.removeSubscription(s);
                                        },
                                ),
                              ]),
                            ),
                          ),
                      ],
                    ),
            ),
          ]),
        );
      },
    );
  }
}
