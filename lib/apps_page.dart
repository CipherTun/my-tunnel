import 'package:flutter/material.dart';

import 'native.dart';

/// Lets the user tick installed apps that should bypass the VPN.
class AppsPickerPage extends StatefulWidget {
  const AppsPickerPage({super.key, required this.selected});
  final Set<String> selected;
  @override
  State<AppsPickerPage> createState() => _AppsPickerPageState();
}

class _AppsPickerPageState extends State<AppsPickerPage> {
  late final Set<String> _sel = {...widget.selected};
  List<AppInfo>? _apps;
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    Native.installedApps().then((l) {
      if (mounted) setState(() => _apps = l);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    final shown = apps == null
        ? const <AppInfo>[]
        : apps
            .where((a) =>
                _q.isEmpty ||
                a.label.toLowerCase().contains(_q) ||
                a.package.toLowerCase().contains(_q))
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Bypass apps (${_sel.length})'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, _sel), child: const Text('Done')),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : apps == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                          labelText: 'Search'),
                      onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final a = shown[i];
                        return CheckboxListTile(
                          value: _sel.contains(a.package),
                          title: Text(a.label),
                          subtitle: Text(a.package, style: const TextStyle(fontSize: 11)),
                          onChanged: (v) => setState(() {
                            v == true ? _sel.add(a.package) : _sel.remove(a.package);
                          }),
                        );
                      },
                    ),
                  ),
                ]),
    );
  }
}
