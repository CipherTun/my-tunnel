import 'dart:convert';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'core_config.dart';
import 'models.dart';
import 'ssh_tunnel.dart';
import 'theme.dart';

const _payloadPresets = <String, String>{
  'WebSocket upgrade': 'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
  'HTTP CONNECT': 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf]',
  'CONNECT + WebSocket (split)':
      'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf][split]GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
};

class EditPage extends StatefulWidget {
  const EditPage({super.key, required this.ctrl, required this.profile, this.isNew = false});
  final VpnController ctrl;
  final Profile profile;
  final bool isNew;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final Map<String, dynamic> _d = Map<String, dynamic>.from(widget.profile.data);
  late String _name = widget.profile.name;
  late List<String> _members = [for (final m in (widget.profile.data['members'] as List? ?? const [])) '$m'];
  int _rev = 0;

  Profile get _p => widget.profile;

  String _s(String k, [String def = '']) => (_d[k] ?? def).toString();

  Widget _tf(String k, String label, {String? hint, bool obscure = false, int lines = 1, TextInputType? kb, String def = ''}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey('$k-$_rev'),
        initialValue: _s(k, def),
        obscureText: obscure,
        maxLines: obscure ? 1 : lines,
        keyboardType: kb,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: (v) => _d[k] = v,
      ),
    );
  }

  Widget _sw(String k, String label, {String? sub, bool def = false}) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12)),
        value: _d[k] is bool ? _d[k] as bool : def,
        onChanged: (v) => setState(() => _d[k] = v),
      );

  Widget _dd(String k, String label, List<String> items, String def) {
    final cur = items.contains(_s(k, def)) ? _s(k, def) : def;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$k-dd-$cur'),
        initialValue: cur,
        decoration: InputDecoration(labelText: label),
        items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i.isEmpty ? '(none)' : i))],
        onChanged: (v) => setState(() => _d[k] = v ?? def),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 10),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );

  List<Widget> _ssh() => [
        _section('Server'),
        _tf('host', 'Host / IP', kb: TextInputType.url),
        _tf('port', 'Port', kb: TextInputType.number, def: '22'),
        _tf('user', 'Username'),
        _tf('pass', 'Password', obscure: true),
        _tf('key', 'Private key (PEM, optional)', lines: 4),
        _tf('keyPass', 'Key passphrase', obscure: true),
        _section('Transport'),
        Align(
          alignment: Alignment.centerLeft,
          child: PopupMenuButton<String>(
            onSelected: (k) => setState(() {
              _d['payload'] = _payloadPresets[k];
              _rev++;
            }),
            itemBuilder: (_) => [for (final k in _payloadPresets.keys) PopupMenuItem(value: k, child: Text(k))],
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.auto_fix_high, size: 18), SizedBox(width: 6), Text('Payload templates')]),
            ),
          ),
        ),
        _tf('payload', 'Payload', lines: 4, hint: '[host] [port] [host_port] [crlf] [split]'),
        _tf('proxyHost', 'HTTP proxy host (optional)'),
        _tf('proxyPort', 'HTTP proxy port', kb: TextInputType.number, def: '8080'),
        _sw('tls', 'TLS / SNI wrapper', sub: 'Wrap the connection in TLS before the payload'),
        if (_d['tls'] == true) _tf('sni', 'SNI (server name)', hint: 'defaults to host'),
        _sw('ws', 'WebSocket framing', sub: 'Use after a 101 Switching Protocols response'),
        _section('Security'),
        _sw('legacy', 'Allow legacy SSH algorithms',
            sub: 'Needed by old Dropbear/OpenSSH servers. Modern algorithms are still preferred.', def: true),
        _sw('verifyHost', 'Verify server host key',
            sub: 'Pins the key on first connect and refuses changes (blocks MITM)'),
        if (_s('hostKey').isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _d.remove('hostKey')),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset pinned host key'),
            ),
          ),
        if (_d['tls'] == true) ...[
          _sw('verifyTls', 'Validate TLS certificate', sub: 'Off by default: SNI-fronted hosts rarely match'),
          _tf('pin', 'Pin certificate SHA-256 (optional)', hint: 'hex fingerprint'),
        ],
      ];

  static const _protos = ['vless', 'vmess', 'trojan', 'ss', 'hysteria2'];

  List<Widget> _v2() {
    final mode = _s('mode', 'link');
    final proto = _s('proto', 'vless');
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'link', label: Text('Link')),
            ButtonSegment(value: 'gui', label: Text('Guided')),
            ButtonSegment(value: 'json', label: Text('JSON')),
          ],
          selected: {mode},
          onSelectionChanged: (s) => setState(() => _d['mode'] = s.first),
        ),
      ),
      if (mode == 'link') _tf('link', 'Share link', lines: 4, hint: 'vless:// vmess:// trojan:// ss:// hysteria2://'),
      if (mode == 'json') _tf('json', 'Xray JSON config', lines: 12),
      if (mode == 'gui') ...[
        _dd('proto', 'Protocol', _protos, 'vless'),
        _tf('address', 'Server address', kb: TextInputType.url),
        _tf('port', 'Port', kb: TextInputType.number, def: '443'),
        _tf('id', proto == 'vless' || proto == 'vmess' ? 'UUID' : 'Password', obscure: false),
        if (proto == 'ss') _tf('method', 'Cipher', def: 'aes-256-gcm'),
        if (proto == 'vless') _tf('encryption', 'Encryption', def: 'none'),
        if (proto != 'ss' && proto != 'hysteria2') ...[
          _dd('net', 'Transport', const ['tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp'], 'tcp'),
          _dd('security', 'Security', const ['tls', 'reality', 'none'], 'tls'),
          _tf('host', 'Host header'),
          _tf('path', 'Path / service name'),
        ],
        if (proto != 'ss') _tf('sni', 'SNI'),
        if (proto != 'ss' && proto != 'hysteria2') ...[
          _dd('fp', 'Fingerprint', const ['', 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random'], ''),
          _tf('alpn', 'ALPN', hint: 'h2,http/1.1'),
        ],
        if (proto == 'vless') ...[
          _tf('flow', 'Flow', hint: 'xtls-rprx-vision'),
          if (_s('security') == 'reality') ...[
            _tf('pbk', 'Reality public key'),
            _tf('sid', 'Reality short id'),
            _tf('spx', 'Reality spiderX'),
          ],
        ],
        if (proto == 'hysteria2') ...[
          _tf('obfs', 'Obfuscation', hint: 'salamander'),
          _tf('obfsPassword', 'Obfuscation password'),
          _tf('mport', 'Port hopping range', hint: '20000-30000'),
        ],
        _tf('pcs', 'Pinned certificate SHA-256 (optional)'),
      ],
    ];
  }

  List<Widget> _group() {
    final others = widget.ctrl.profiles.where((e) => e.type != ProfileType.group && e.id != _p.id).toList();
    String nameOf(String id) {
      for (final e in widget.ctrl.profiles) {
        if (e.id == id) return e.name;
      }
      return id;
    }

    return [
      _section('Order (drag to reorder) - tried top to bottom'),
      if (_members.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('No members yet')),
      ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: true,
        onReorder: (a, b) => setState(() {
          if (b > a) b--;
          _members.insert(b, _members.removeAt(a));
        }),
        children: [
          for (final id in _members)
            ListTile(
              key: ValueKey('m-$id'),
              dense: true,
              leading: const Icon(Icons.drag_handle),
              title: Text(nameOf(id)),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _members.remove(id))),
            ),
        ],
      ),
      _section('Available profiles'),
      for (final e in others.where((e) => !_members.contains(e.id)))
        ListTile(
          dense: true,
          title: Text(e.name),
          subtitle: Text(e.typeLabel),
          trailing: const Icon(Icons.add_circle_outline),
          onTap: () => setState(() => _members.add(e.id)),
        ),
    ];
  }

  Future<void> _save() async {
    final name = _name.trim();
    if (name.isEmpty) {
      toast(context, 'Name is required');
      return;
    }
    final err = _validate();
    if (err != null) {
      toast(context, err);
      return;
    }
    _p.name = name;
    _p.data = Map<String, dynamic>.from(_d);
    if (_p.type == ProfileType.group) _p.data['members'] = _members;
    await widget.ctrl.upsert(_p);
    if (mounted) Navigator.pop(context);
  }

  String? _validate() {
    switch (_p.type) {
      case ProfileType.ssh:
        if (_s('host').trim().isEmpty) return 'Host is required';
        if (_s('user').trim().isEmpty) return 'Username is required';
        final port = int.tryParse(_s('port', '22'));
        if (port == null || port < 1 || port > 65535) return 'Port must be 1-65535';
        if (_s('pass').isEmpty && _s('key').trim().isEmpty) return 'Enter a password or a private key';
        return null;
      case ProfileType.v2ray:
        final mode = _s('mode', 'link');
        if (mode == 'link' && !_s('link').contains('://')) return 'Paste a valid share link';
        if (mode == 'json') {
          try {
            jsonDecode(_s('json'));
          } catch (_) {
            return 'JSON is not valid';
          }
        }
        if (mode == 'gui') {
          try {
            final tmp = Profile(id: _p.id, name: _name, type: ProfileType.v2ray, data: Map<String, dynamic>.from(_d));
            buildShareLink(tmp);
          } catch (e) {
            return errText(e);
          }
        }
        return null;
      case ProfileType.wireguard:
        final c = _s('conf');
        if (!c.contains('[Interface]') || !c.contains('[Peer]')) return 'Config needs [Interface] and [Peer]';
        return null;
      case ProfileType.group:
        return _members.isEmpty ? 'Add at least one member' : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _p.type;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New ${_p.typeLabel}' : 'Edit profile'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            initialValue: _name,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (v) => _name = v,
          ),
          const SizedBox(height: 12),
          if (t == ProfileType.ssh) ..._ssh(),
          if (t == ProfileType.v2ray) ..._v2(),
          if (t == ProfileType.wireguard) _tf('conf', 'WireGuard config', lines: 12),
          if (t == ProfileType.group) ..._group(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Used by the payload preview in Tools.
String previewPayload(String raw, String host, int port) {
  final parts = renderPayload(raw, host, port);
  return parts.map((e) => e.replaceAll('\r', '\\r').replaceAll('\n', '\\n\n')).join('\n---- split ----\n');
}
