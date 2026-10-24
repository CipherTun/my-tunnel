import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

IconData typeIcon(ProfileType t) => switch (t) {
      ProfileType.ssh => Icons.terminal_rounded,
      ProfileType.v2ray => Icons.bolt_rounded,
      ProfileType.wireguard => Icons.vpn_key_rounded,
      ProfileType.openvpn => Icons.shield_rounded,
      ProfileType.proxy => Icons.swap_horiz_rounded,
      ProfileType.inject => Icons.http_rounded,
      ProfileType.group => Icons.account_tree_rounded,
    };

Color typeColor(ProfileType t) => switch (t) {
      ProfileType.ssh => const Color(0xFF3FB7A8),
      ProfileType.v2ray => const Color(0xFF2F7EFF),
      ProfileType.wireguard => const Color(0xFFE5645B),
      ProfileType.openvpn => const Color(0xFFF08A3C),
      ProfileType.proxy => const Color(0xFF8C6FF0),
      ProfileType.inject => const Color(0xFFD9A93A),
      ProfileType.group => const Color(0xFF7D8DA6),
    };

String typeName(ProfileType t) => switch (t) {
      ProfileType.ssh => 'SSH',
      ProfileType.v2ray => 'Xray',
      ProfileType.wireguard => 'WireGuard',
      ProfileType.openvpn => 'OpenVPN',
      ProfileType.proxy => 'Proxy',
      ProfileType.inject => 'HTTP Payload',
      ProfileType.group => 'Group',
    };

/// Rounded square avatar tinted with the protocol colour.
class TypeAvatar extends StatelessWidget {
  const TypeAvatar(this.type, {super.key, this.size = 44});
  final ProfileType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = typeColor(type);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(typeIcon(type), color: c, size: size * 0.5),
    );
  }
}

/// A titled card that groups related form fields or settings.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.subtitle, this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 12)});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.4, color: scheme.primary)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
          Padding(padding: padding, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
        ]),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.icon, required this.label, required this.value, this.sub, this.color});
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (sub != null) Text(sub!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Inline message strip for errors and notes.
class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.error = false, this.icon});
  final String text;
  final bool error;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = error ? scheme.error : kAccent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? (error ? Icons.error_outline : Icons.info_outline), size: 18, color: c),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}
