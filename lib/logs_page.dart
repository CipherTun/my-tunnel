import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';

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
