import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_info.dart';
import 'controller.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.ctrl, required this.onPickProfile});
  final VpnController ctrl;
  final VoidCallback onPickProfile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final st = ctrl.state;
        final color = switch (st) {
          ConnState.connected => kGood,
          ConnState.connecting => kWarn,
          ConnState.disconnected => scheme.primary,
        };
        final sel = ctrl.selected;
        return Scaffold(
          appBar: AppBar(title: const Text(kAppName, style: TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            _ConnectCard(ctrl: ctrl, color: color),
            const SizedBox(height: 14),
            _ProfileCard(ctrl: ctrl, onTap: ctrl.busy ? null : onPickProfile, selectedExists: sel != null),
            const SizedBox(height: 14),
            if (st == ConnState.connected) ...[
              GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.9,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  StatCard(icon: Icons.arrow_downward_rounded, label: 'Download', value: fmtSpeed(ctrl.downSpeed), sub: fmtBytes(ctrl.downTotal), color: kGood),
                  StatCard(icon: Icons.arrow_upward_rounded, label: 'Upload', value: fmtSpeed(ctrl.upSpeed), sub: fmtBytes(ctrl.upTotal), color: kAccent),
                  StatCard(icon: Icons.timer_outlined, label: 'Session', value: ctrl.duration),
                  StatCard(
                    icon: Icons.network_ping,
                    label: 'Latency',
                    value: ctrl.lastDelay == null ? 'Pending' : '${ctrl.lastDelay} ms',
                    sub: ctrl.lastDelay == null ? 'next health check' : 'through tunnel',
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (ctrl.localSocks != null && st == ConnState.connected) _ProxyCard(ctrl: ctrl),
            if (ctrl.error != null && st != ConnState.connected) ...[Notice(ctrl.error!, error: true), const SizedBox(height: 14)],
            SectionCard(
              title: 'MODE',
              subtitle: ctrl.proxyMode
                  ? 'Only a local SOCKS5 proxy is exposed. No VPN permission needed.'
                  : 'The whole device is routed through the tunnel.',
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'vpn', icon: Icon(Icons.vpn_lock), label: Text('VPN')),
                    ButtonSegment(value: 'proxy', icon: Icon(Icons.lan_outlined), label: Text('Proxy only')),
                  ],
                  selected: {ctrl.settings.vpnMode},
                  onSelectionChanged: ctrl.busy
                      ? null
                      : (s) {
                          ctrl.settings.vpnMode = s.first;
                          ctrl.saveSettings();
                        },
                ),
                if (ctrl.proxyMode)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('OpenVPN always runs as a VPN.', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ]),
        );
      },
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.ctrl, required this.color});
  final VpnController ctrl;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final st = ctrl.state;
    final label = switch (st) {
      ConnState.connected => 'Protected',
      ConnState.connecting => 'Connecting',
      ConnState.disconnected => 'Not connected',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
        child: Column(children: [
          Semantics(
            button: true,
            label: st == ConnState.disconnected ? 'Connect' : 'Disconnect',
            child: GestureDetector(
              onTap: () {
                if (st == ConnState.disconnected) {
                  if (ctrl.selected == null) {
                    toast(context, 'Add or select a profile first');
                    return;
                  }
                  ctrl.connect();
                } else {
                  ctrl.disconnect();
                }
              },
              child: SizedBox(
                width: 170,
                height: 170,
                child: Stack(alignment: Alignment.center, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.13),
                      border: Border.all(color: color, width: 3),
                      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.30), blurRadius: 28)],
                    ),
                    child: Icon(st == ConnState.connected ? Icons.lock_rounded : Icons.power_settings_new_rounded, size: 58, color: color),
                  ),
                  if (st == ConnState.connecting) SizedBox(width: 170, height: 170, child: CircularProgressIndicator(strokeWidth: 3, color: color)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 4),
          Text(
            st == ConnState.disconnected ? 'Tap the button to connect' : (st == ConnState.connected ? 'via ${ctrl.activeType}' : 'Using ${ctrl.activeType.isEmpty ? 'selected profile' : ctrl.activeType}'),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ]),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.ctrl, required this.onTap, required this.selectedExists});
  final VpnController ctrl;
  final VoidCallback? onTap;
  final bool selectedExists;

  @override
  Widget build(BuildContext context) {
    final p = ctrl.selected;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: p == null ? const CircleAvatar(child: Icon(Icons.add)) : TypeAvatar(p.type),
        title: Text(p == null ? 'No profile yet' : (ctrl.busy && ctrl.activeName.isNotEmpty ? ctrl.activeName : p.name), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          p == null ? 'Open Profiles to add one' : (p.endpoint == null ? p.typeLabel : '${p.typeLabel} · ${p.endpoint!.host}:${p.endpoint!.port}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: onTap == null ? null : Icon(Icons.swap_horiz, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({required this.ctrl});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    final addr = 'socks5://127.0.0.1:${ctrl.localSocks}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: const Text('Local SOCKS5 proxy', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(ctrl.localShared ? '$addr (also reachable on your hotspot)' : addr),
          trailing: IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: addr));
              if (context.mounted) toast(context, 'Copied $addr');
            },
          ),
        ),
      ),
    );
  }
}
