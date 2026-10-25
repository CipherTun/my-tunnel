import 'dart:math';

import 'package:flutter/material.dart';

import 'models.dart';

String fmtBytes(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtSpeed(int bytesPerSecond) => '${fmtBytes(bytesPerSecond)}/s';

IconData typeIcon(ProfileType t) => switch (t) {
      ProfileType.ssh => Icons.terminal,
      ProfileType.v2ray => Icons.rocket_launch_outlined,
      ProfileType.proxy => Icons.swap_horiz,
      ProfileType.wireguard => Icons.vpn_key_outlined,
      ProfileType.openvpn => Icons.security,
      ProfileType.dnstt => Icons.dns_outlined,
      ProfileType.slipstream => Icons.waves_outlined,
      ProfileType.openconnect => Icons.vpn_lock,
      ProfileType.psiphon => Icons.public,
      ProfileType.chain => Icons.link,
      ProfileType.group => Icons.layers_outlined,
    };

String typeShort(ProfileType t) => switch (t) {
      ProfileType.ssh => 'SSH',
      ProfileType.v2ray => 'Xray',
      ProfileType.proxy => 'Proxy',
      ProfileType.wireguard => 'WireGuard',
      ProfileType.openvpn => 'OpenVPN',
      ProfileType.dnstt => 'DNSTT',
      ProfileType.slipstream => 'Slipstream',
      ProfileType.openconnect => 'OpenConnect',
      ProfileType.psiphon => 'Psiphon',
      ProfileType.chain => 'Chain',
      ProfileType.group => 'Group',
    };

String typeBlurb(ProfileType t) => switch (t) {
      ProfileType.ssh => 'SSH tunnel with payload, SNI, WebSocket, upstream proxy and UDP',
      ProfileType.v2ray => 'VMess, VLESS, Trojan, Shadowsocks, Hysteria2 via link, form or JSON',
      ProfileType.proxy => 'HTTP, HTTPS or SOCKS5 proxy with login and custom headers',
      ProfileType.wireguard => 'Paste a wg-quick configuration',
      ProfileType.openvpn => 'Paste a .ovpn file (UDP or TCP)',
      ProfileType.dnstt => 'SlowDNS TCP tunnel via UDP DNS, DoH or DoT',
      ProfileType.slipstream => 'QUIC-over-DNS transport through a local TCP tunnel',
      ProfileType.openconnect => 'Cisco AnyConnect-compatible SSL VPN; requires the native OpenConnect engine',
      ProfileType.psiphon => 'Psiphon circumvention tunnel; requires the isolated official Psiphon Android library',
      ProfileType.chain => 'Entry server → exit server',
      ProfileType.group => 'Try several servers in order until one works',
    };

/// Rounded surface used for every grouped block of content.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.children, this.padding});
  final String? title;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(title!,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
            ),
          ...children,
        ]),
      ),
    );
  }
}

class TypeAvatar extends StatelessWidget {
  const TypeAvatar(this.type, {super.key, this.size = 40});
  final ProfileType type;
  final double size;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(size / 3)),
      child: Icon(typeIcon(type), size: size * 0.55, color: cs.onSecondaryContainer),
    );
  }
}

/// Latency badge. [ms]: null = untested, -1 = failed, -2 = testing, -3 = n/a (UDP).
class LatencyBadge extends StatelessWidget {
  const LatencyBadge(this.ms, {super.key});
  final int? ms;
  @override
  Widget build(BuildContext context) {
    final v = ms;
    if (v == null) return const SizedBox.shrink();
    if (v == -2) {
      return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final cs = Theme.of(context).colorScheme;
    String text;
    Color bg, fg;
    if (v == -3) {
      text = 'UDP';
      bg = cs.surfaceContainerHighest;
      fg = cs.onSurfaceVariant;
    } else if (v < 0) {
      text = 'Offline';
      bg = cs.errorContainer;
      fg = cs.onErrorContainer;
    } else {
      text = '$v ms';
      final good = v < 300, mid = v < 800;
      bg = good ? const Color(0xFFD7F5E3) : (mid ? const Color(0xFFFFEFC7) : cs.errorContainer);
      fg = good ? const Color(0xFF0B5B31) : (mid ? const Color(0xFF6B4A00) : cs.onErrorContainer);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.label, required this.value, this.sub});
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(label, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      if (sub != null) Text(sub!, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
    ]);
  }
}

/// Live throughput chart. Draws only real samples taken once per second
/// (up to 60); with fewer samples the line starts at the right edge.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.down, required this.up, this.height = 96});
  final List<int> down;
  final List<int> up;
  final double height;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter([down, up], [cs.primary, cs.tertiary], cs.outlineVariant.withValues(alpha: 0.5)),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.series, this.colors, this.grid);
  final List<List<int>> series;
  final List<Color> colors;
  final Color grid;

  static const int slots = 60;

  @override
  void paint(Canvas canvas, Size size) {
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gp);
    }
    var maxV = 1024;
    for (final s in series) {
      for (final v in s) {
        maxV = max(maxV, v);
      }
    }
    final step = size.width / (slots - 1);
    for (var k = 0; k < series.length; k++) {
      final d = series[k];
      if (d.length < 2) continue;
      final off = slots - d.length;
      final path = Path();
      for (var i = 0; i < d.length; i++) {
        final x = (off + i) * step;
        final y = size.height - (d[i] / maxV) * (size.height - 6) - 3;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(off * step, size.height)
        ..close();
      canvas.drawPath(fill, Paint()..color = colors[k].withValues(alpha: 0.12));
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[k]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => true;
}
