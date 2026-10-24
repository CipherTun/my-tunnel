import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'native.dart';

/// Picker for apps that bypass the VPN. Returns the chosen package names.
class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.selected});
  final Set<String> selected;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  late final Set<String> _sel = {...widget.selected};
  final Map<String, Future<Uint8List?>> _icons = {};
  List<AppInfo>? _apps;
  String _q = '';

  @override
  void initState() {
    super.initState();
    Native.listApps().then((l) {
      if (mounted) setState(() => _apps = l);
    });
  }

  Future<void> _addManual() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add package name'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'com.example.app')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (v != null && v.contains('.')) setState(() => _sel.add(v));
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    final known = {for (final a in apps ?? const <AppInfo>[]) a.package};
    final extra = _sel.where((p) => !known.contains(p)).toList();
    final q = _q.toLowerCase();
    final list = [
      ...extra.map((p) => AppInfo(p, p)),
      ...?apps,
    ].where((a) => q.isEmpty || a.label.toLowerCase().contains(q) || a.package.toLowerCase().contains(q)).toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _sel);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Bypass apps (${_sel.length})'),
          actions: [IconButton(icon: const Icon(Icons.add), tooltip: 'Add package', onPressed: _addManual)],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search apps'),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: apps == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? const Center(child: Text('No apps found'))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final a = list[i];
                          final on = _sel.contains(a.package);
                          return CheckboxListTile(
                            value: on,
                            title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(a.package, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                            secondary: SizedBox(
                              width: 40,
                              height: 40,
                              child: FutureBuilder<Uint8List?>(
                                future: _icons.putIfAbsent(a.package, () => Native.icon(a.package)),
                                builder: (_, s) => s.data == null
                                    ? const Icon(Icons.android)
                                    : Image.memory(s.data!, gaplessPlayback: true),
                              ),
                            ),
                            onChanged: (v) => setState(() => v == true ? _sel.add(a.package) : _sel.remove(a.package)),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
