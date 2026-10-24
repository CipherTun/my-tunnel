import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions.dart';
import 'controller.dart';
import 'logs_page.dart';
import 'tools2_page.dart';
import 'tools_page.dart';
import 'usage_page.dart';
import 'widgets.dart';

class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key, required this.ctrl});
  final VpnController ctrl;

  Widget _item(BuildContext context, IconData icon, String title, String sub, Widget page) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
      );

  Widget _section(BuildContext context, String title, List<Widget> kids) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SectionCard(title: title, children: kids),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tools')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          _section(context, 'Servers', [
            _item(context, Icons.rss_feed, 'Subscriptions', 'Import and refresh server lists from a URL',
                SubscriptionsPage(ctrl: ctrl)),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Copy full backup'),
              subtitle: const Text('Servers, subscriptions and settings as JSON (contains secrets)'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: ctrl.exportAll()));
                if (context.mounted) toast(context, 'Backup copied to the clipboard');
              },
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restore backup from clipboard'),
              onTap: () async {
                final t = (await Clipboard.getData('text/plain'))?.text ?? '';
                String msg;
                try {
                  msg = 'Restored ${await ctrl.importAll(t)} servers';
                } catch (e) {
                  msg = 'Restore failed: $e';
                }
                if (context.mounted) toast(context, msg);
              },
            ),
          ]),
          _section(context, 'Network tools', [
            _item(context, Icons.radar, 'Clean IP scanner', 'Find the fastest CDN IP for your server',
                ScannerPage(ctrl: ctrl)),
            _item(context, Icons.travel_explore, 'Host checker', 'Test a host, SNI and payload',
                const HostCheckerPage()),
            _item(context, Icons.auto_fix_high, 'Payload generator',
                'Front/back inject, query, dual CONNECT, split', const PayloadGeneratorPage()),
            _item(context, Icons.dns_outlined, 'SSH server setup', 'Commands for the UDP gateway (badvpn-udpgw)',
                const ServerGuidePage()),
          ]),
          _section(context, 'Insights', [
            _item(context, Icons.data_usage, 'Data usage', 'Today, 7 and 30 days, per server',
                UsagePage(ctrl: ctrl)),
            _item(context, Icons.article_outlined, 'Logs', 'App log and Xray core log', LogsPage(ctrl: ctrl)),
          ]),
        ]),
      );
}
