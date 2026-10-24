import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions.dart';
import 'controller.dart';
import 'models.dart';
import 'usage.dart';
import 'widgets.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.ctrl, required this.openServers});
  final VpnController ctrl;
  final VoidCallback openServers;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        final connected = ctrl.state == ConnState.connected;
        final connecting = ctrl.state == ConnState.connecting;
        final sel = ctrl.selected;
        return SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('XRay Vpn', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    connected
                        ? (ctrl.settings.proxyOnly ? 'Proxy mode active' : 'Your traffic is tunnelled')
                        : connecting
                            ? 'Establishing the tunnel'
                            : 'Not connected',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ]),
              ),
              if (ctrl.state == ConnState.disconnected)
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('VPN')),
                    ButtonSegment(value: true, label: Text('Proxy')),
                  ],
                  selected: {ctrl.settings.proxyOnly},
                  onSelectionChanged: (s) {
                    ctrl.settings.proxyOnly = s.first;
                    ctrl.saveSettings(ctrl.settings);
                  },
                ),
            ]),
            const SizedBox(height: 20),
            Center(child: _ConnectButton(ctrl: ctrl)),
            const SizedBox(height: 8),
            Center(child: _StatusLine(ctrl: ctrl)),
            const SizedBox(height: 20),
            _ServerCard(ctrl: ctrl, profile: sel, openServers: openServers),
            if (ctrl.proxyEndpoint.isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(title: 'Local proxy', children: [
                ListTile(
                  title: Text(ctrl.proxyEndpoint, style: const TextStyle(fontFamily: 'monospace')),
                  subtitle: const Text('Point other apps or devices (hotspot) at this address'),
                  trailing: IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: ctrl.proxyEndpoint));
                      toast(context, 'Copied');
                    },
                  ),
                ),
              ]),
            ],
            if (connected) ...[
              const SizedBox(height: 12),
              SectionCard(padding: const EdgeInsets.all(16), children: [
                Row(children: [
                  Expanded(
                    child: StatTile(
                        icon: Icons.south,
                        label: 'Download',
                        value: fmtSpeed(ctrl.downSpeed),
                        sub: 'total ${fmtBytes(ctrl.downTotal)}'),
                  ),
                  Expanded(
                    child: StatTile(
                        icon: Icons.north,
                        label: 'Upload',
                        value: fmtSpeed(ctrl.upSpeed),
                        sub: 'total ${fmtBytes(ctrl.upTotal)}'),
                  ),
                ]),
                const SizedBox(height: 16),
                Sparkline(down: ctrl.downHistory, up: ctrl.upHistory),
                const SizedBox(height: 4),
                Row(children: [
                  _Legend(color: cs.primary, label: 'Download'),
                  const SizedBox(width: 16),
                  _Legend(color: cs.tertiary, label: 'Upload'),
                  const Spacer(),
                  Text('last 60 s', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ]),
              const SizedBox(height: 12),
              SectionCard(title: 'Diagnostics', children: [
                _DiagTile(
                  icon: Icons.speed,
                  title: 'Tunnel latency',
                  value: ctrl.tunnelDelay > 0
                      ? '${ctrl.tunnelDelay} ms'
                      : ctrl.tunnelDelay < 0
                          ? 'Test failed'
                          : 'Not tested',
                  onTap: ctrl.testTunnel,
                ),
                _DiagTile(
                  icon: Icons.public,
                  title: 'Exit IP address',
                  value: ctrl.exitIp.isEmpty ? 'Tap to check' : ctrl.exitIp,
                  onTap: ctrl.checkIp,
                ),
                _DiagTile(
                  icon: Icons.download,
                  title: 'Speed test',
                  value: ctrl.speedRunning
                      ? 'Running…'
                      : ctrl.speedMbps > 0
                          ? '${ctrl.speedMbps.toStringAsFixed(1)} Mbps  ·  ${ctrl.speedMsg}'
                          : ctrl.speedMbps < 0
                              ? 'Failed: ${ctrl.speedMsg}'
                              : 'Tap to run (about 10 s)',
                  onTap: ctrl.speedRunning ? null : ctrl.runSpeedTest,
                ),
              ]),
            ],
            const SizedBox(height: 12),
            _UsageCard(usage: ctrl.usage),
          ]),
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _DiagTile extends StatelessWidget {
  const _DiagTile({required this.icon, required this.title, required this.value, this.onTap});
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value),
        trailing: onTap == null ? null : const Icon(Icons.refresh, size: 20),
        onTap: onTap,
      );
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.ctrl});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = ctrl.state == ConnState.connected;
    final connecting = ctrl.state == ConnState.connecting;
    const size = 168.0;
    final enabled = ctrl.selected != null;
    final label = connected ? 'Disconnect' : (connecting ? 'Cancel' : 'Connect');
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          if (connecting)
            const SizedBox(width: size, height: size, child: CircularProgressIndicator(strokeWidth: 5))
          else
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: connected ? const Color(0xFF2E9E5B) : cs.outlineVariant, width: 5),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Material(
              shape: const CircleBorder(),
              color: connected ? cs.primary : cs.surfaceContainerHighest,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: !enabled ? null : (ctrl.state == ConnState.disconnected ? ctrl.connect : ctrl.disconnect),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.power_settings_new,
                        size: 48, color: connected ? cs.onPrimary : (enabled ? cs.onSurface : cs.outline)),
                    const SizedBox(height: 4),
                    Text(label,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: connected ? cs.onPrimary : (enabled ? cs.onSurface : cs.outline))),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Real information only: the duration while connected, the latest connection
/// step while connecting, or the current reconnection status.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.ctrl});
  final VpnController ctrl;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    String text;
    switch (ctrl.state) {
      case ConnState.connected:
        text = ctrl.duration;
        break;
      case ConnState.connecting:
        final last = ctrl.logs.isEmpty ? '' : ctrl.logs.last.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '');
        text = last;
        break;
      case ConnState.disconnected:
        text = ctrl.selected == null ? 'Add a server to get started' : '';
        break;
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Text(text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ctrl.state == ConnState.connected
              ? t.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])
              : t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.ctrl, required this.profile, required this.openServers});
  final VpnController ctrl;
  final Profile? profile;
  final VoidCallback openServers;
  @override
  Widget build(BuildContext context) {
    final p = profile;
    if (p == null) {
      return SectionCard(children: [
        ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text('Add your first server'),
          subtitle: const Text('SSH, Xray, proxy, WireGuard, OpenVPN or a subscription'),
          onTap: () => addServerFlow(context, ctrl),
        ),
      ]);
    }
    final locked = ctrl.state != ConnState.disconnected;
    return SectionCard(children: [
      ListTile(
        leading: TypeAvatar(p.type, size: 44),
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${typeShort(p.type)}  ·  ${p.subtitle}', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: locked ? LatencyBadge(null) : Row(mainAxisSize: MainAxisSize.min, children: [
          LatencyBadge(ctrl.latency[p.id]),
          const Icon(Icons.chevron_right),
        ]),
        onTap: locked ? null : openServers,
      ),
      if (!locked && ctrl.profiles.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: ctrl.pinging ? null : ctrl.connectFastest,
              icon: ctrl.pinging
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt),
              label: Text(ctrl.pinging ? 'Testing servers…' : 'Connect to the fastest server'),
            ),
          ),
        ),
    ]);
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage});
  final UsageStore usage;
  @override
  Widget build(BuildContext context) {
    final today = usage.total(days: 1);
    final week = usage.total(days: 7);
    return SectionCard(title: 'Data used', padding: const EdgeInsets.fromLTRB(0, 8, 0, 12), children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(child: StatTile(icon: Icons.today, label: 'Today', value: fmtBytes(today[0] + today[1]))),
          Expanded(child: StatTile(icon: Icons.date_range, label: '7 days', value: fmtBytes(week[0] + week[1]))),
        ]),
      ),
    ]);
  }
}
