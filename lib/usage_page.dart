import 'package:flutter/material.dart';

import 'controller.dart';

String _fmt(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final u = ctrl.usage;
        final rows = [
          ('Today', u.total(days: 1)),
          ('Last 7 days', u.total(days: 7)),
          ('Last 30 days', u.total(days: 30)),
        ];
        final per = u.byProfile(days: 30).entries.toList()
          ..sort((a, b) => (b.value[0] + b.value[1]).compareTo(a.value[0] + a.value[1]));
        return Scaffold(
          appBar: AppBar(title: const Text('Data usage'), actions: [
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_outline),
              onPressed: ctrl.clearUsage,
            ),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            for (final r in rows)
              Card(
                child: ListTile(
                  title: Text(r.$1),
                  subtitle: Text('↑ ${_fmt(r.$2[0])}    ↓ ${_fmt(r.$2[1])}'),
                  trailing: Text(_fmt(r.$2[0] + r.$2[1]),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
            const SizedBox(height: 12),
            Text('By profile (30 days)', style: Theme.of(context).textTheme.titleSmall),
            if (per.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Nothing recorded yet.')),
            for (final e in per)
              ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: Text('↑ ${_fmt(e.value[0])}    ↓ ${_fmt(e.value[1])}'),
                trailing: Text(_fmt(e.value[0] + e.value[1])),
              ),
          ]),
        );
      },
    );
  }
}
