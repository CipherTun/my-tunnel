import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'theme.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.ctrl});
  final VpnController ctrl;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  bool _core = false;
  String _q = '';
  List<String> _coreLines = [];

  Future<void> _loadCore() async {
    final l = await widget.ctrl.coreLogs();
    if (mounted) setState(() => _coreLines = l);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) {
        final all = _core ? _coreLines : widget.ctrl.logs;
        final q = _q.toLowerCase();
        final lines = all.where((e) => q.isEmpty || e.toLowerCase().contains(q)).toList().reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Logs'),
            actions: [
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: all.join('\n')));
                  if (context.mounted) toast(context, 'Copied ${all.length} lines');
                },
              ),
              if (!_core)
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: widget.ctrl.clearLogs,
                ),
              if (_core) IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: _loadCore),
            ],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('App')),
                    ButtonSegment(value: true, label: Text('Core')),
                  ],
                  selected: {_core},
                  onSelectionChanged: (s) {
                    setState(() => _core = s.first);
                    if (_core) _loadCore();
                  },
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter'),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: lines.isEmpty
                  ? const Center(child: Text('No log lines'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ),
                    ),
            ),
          ]),
        );
      },
    );
  }
}
