import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'core_config.dart';
import 'models.dart';
import 'ssh_tunnel.dart';
import 'theme.dart';
import 'widgets.dart';

const _payloadTemplates = <String, String>{
  'WebSocket upgrade': 'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
  'HTTP CONNECT': 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host_port][crlf][crlf]',
  'CONNECT with proxy auth': 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host_port][crlf][auth][crlf]',
  'Host-header front (GET)': 'GET / HTTP/1.1[crlf]Host: [host][crlf]User-Agent: [ua][crlf]Connection: keep-alive[crlf][crlf]',
  'CONNECT then WebSocket (split)':
      'CONNECT [host_port] HTTP/1.1[crlf]Host: [host_port][crlf][crlf][split]GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
  'Rotating Host header': 'GET / HTTP/1.1[crlf]Host: [rotate=a.example.com;b.example.com][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
};

const _payloadTokens = [
  '[host_port]', '[host]', '[port]', '[crlf]', '[split]', '[delay=300]', '[ua]', '[auth]', '[random]', '[rotate=a;b]',
];

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
  late final List<String> _members = [for (final m in (widget.profile.data['members'] as List? ?? const [])) '$m'];
  late final TextEditingController _payload = TextEditingController(text: (widget.profile.data['payload'] ?? '').toString());
  late final TextEditingController _ovpn = TextEditingController(text: (widget.profile.data['config'] ?? '').toString());
  int _rev = 0;

  Profile get _p => widget.profile;

  @override
  void initState() {
    super.initState();
    _payload.addListener(() => _d['payload'] = _payload.text);
    _ovpn.addListener(() => _d['config'] = _ovpn.text);
  }

  @override
  void dispose() {
    _payload.dispose();
    _ovpn.dispose();
    super.dispose();
  }

  String _s(String k, [String def = '']) => (_d[k] ?? def).toString();

  // ----------------------------------------------------------------- inputs

  Widget _tf(String k, String label, {String? hint, bool obscure = false, int lines = 1, TextInputType? kb, String def = '', bool mono = false}) {
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
        style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
        decoration: InputDecoration(labelText: label, hintText: hint, alignLabelWithHint: lines > 1),
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

  Widget _dd(String k, String label, List<String> items, String def, {Map<String, String>? names}) {
    final cur = items.contains(_s(k, def)) ? _s(k, def) : def;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$k-dd-$cur'),
        initialValue: cur,
        decoration: InputDecoration(labelText: label),
        items: [for (final i in items) DropdownMenuItem(value: i, child: Text(names?[i] ?? (i.isEmpty ? '(none)' : i)))],
        onChanged: (v) => setState(() => _d[k] = v ?? def),
      ),
    );
  }

  // --------------------------------------------------------- payload editor

  void _insert(String t) {
    final sel = _payload.selection;
    final text = _payload.text;
    final a = sel.isValid ? sel.start : text.length;
    final b = sel.isValid ? sel.end : text.length;
    _payload.value = TextEditingValue(text: text.replaceRange(a, b, t), selection: TextSelection.collapsed(offset: a + t.length));
  }

  void _previewPayload() {
    var host = _s('host', 'example.com');
    var port = int.tryParse(_s('port', '443')) ?? 443;
    if (_p.type == ProfileType.inject) {
      final t = _s('target', 'www.gstatic.com:443').split(':');
      host = t.first.isEmpty ? 'www.gstatic.com' : t.first;
      port = t.length > 1 ? int.tryParse(t[1]) ?? 443 : 443;
    }
    final text = previewPayload(_payload.text, host, port, authUser: _s('authUser'), authPass: _s('authPass'));
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What will be sent'),
        content: SingleChildScrollView(child: SelectableText(text.isEmpty ? '(empty)' : text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _payloadEditor() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _payload,
        maxLines: 6,
        minLines: 4,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(labelText: 'Payload', alignLabelWithHint: true),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, children: [
        for (final t in _payloadTokens) ActionChip(label: Text(t, style: const TextStyle(fontSize: 12)), onPressed: () => _insert(t), visualDensity: VisualDensity.compact),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        PopupMenuButton<String>(
          onSelected: (k) => _payload.text = _payloadTemplates[k]!,
          itemBuilder: (_) => [for (final k in _payloadTemplates.keys) PopupMenuItem(value: k, child: Text(k))],
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.auto_fix_high, size: 18), SizedBox(width: 6), Text('Templates')]),
          ),
        ),
        const SizedBox(width: 12),
        TextButton.icon(onPressed: _previewPayload, icon: const Icon(Icons.visibility_outlined, size: 18), label: const Text('Preview')),
      ]),
    ]);
  }

  // ------------------------------------------------------------ type forms

  List<Widget> _ssh() => [
        SectionCard(title: 'SERVER', children: [
          _tf('host', 'Host / IP', kb: TextInputType.url),
          _tf('port', 'Port', kb: TextInputType.number, def: '22'),
          _tf('user', 'Username'),
          _tf('pass', 'Password', obscure: true),
          _tf('key', 'Private key (PEM, optional)', lines: 4, mono: true),
          _tf('keyPass', 'Key passphrase', obscure: true),
        ]),
        SectionCard(title: 'TRANSPORT', subtitle: 'How the connection reaches the SSH server', children: [
          _tf('proxyHost', 'HTTP proxy / CDN host (optional)'),
          _tf('proxyPort', 'Proxy port', kb: TextInputType.number, def: '8080'),
          _sw('tls', 'TLS / SNI wrapper', sub: 'Wrap the connection in TLS before the payload'),
          if (_d['tls'] == true) _tf('sni', 'SNI (server name)', hint: 'defaults to the host'),
          _sw('ws', 'WebSocket framing', sub: 'Use after a 101 Switching Protocols response'),
          const SizedBox(height: 8),
          _payloadEditor(),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: _payload,
            builder: (_, __) => _payload.text.contains('[auth]')
                ? Column(children: [
                    _tf('authUser', 'Proxy username (for [auth])'),
                    _tf('authPass', 'Proxy password (for [auth])', obscure: true),
                  ])
                : const SizedBox.shrink(),
          ),
          _sw('lenient', 'Accept any payload response', sub: 'Do not reject non-2xx answers from the proxy'),
        ]),
        SectionCard(title: 'SECURITY', children: [
          _sw('legacy', 'Allow legacy SSH algorithms', sub: 'Needed by old Dropbear/OpenSSH servers. Modern algorithms are still preferred.', def: true),
          _sw('verifyHost', 'Verify server host key', sub: 'Pins the key on first connect and refuses changes'),
          if (_s('hostKey').isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => setState(() => _d.remove('hostKey')), icon: const Icon(Icons.restart_alt), label: const Text('Reset pinned host key')),
            ),
          if (_d['tls'] == true) ...[
            _sw('verifyTls', 'Validate TLS certificate', sub: 'Off by default: SNI-fronted hosts rarely match'),
            _tf('pin', 'Pin certificate SHA-256 (optional)', hint: 'hex fingerprint'),
          ],
        ]),
      ];

  List<Widget> _inject() => [
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Notice('Each connection sends your payload to the proxy with [host_port] set to its destination, then relays once the proxy answers 2xx or 101. TCP only.'),
        ),
        SectionCard(title: 'PROXY / CDN', subtitle: 'Where the payload is sent', children: [
          _tf('proxyHost', 'Host / IP', kb: TextInputType.url),
          _tf('proxyPort', 'Port', kb: TextInputType.number, def: '80'),
          _sw('tls', 'TLS / SNI wrapper'),
          if (_d['tls'] == true) _tf('sni', 'SNI (server name)', hint: 'defaults to the host'),
          _sw('ws', 'WebSocket framing'),
        ]),
        SectionCard(title: 'PAYLOAD', children: [
          _payloadEditor(),
          const SizedBox(height: 12),
          _tf('target', 'Probe target', hint: 'www.gstatic.com:443', def: 'www.gstatic.com:443'),
          _tf('authUser', 'Proxy username (for [auth])'),
          _tf('authPass', 'Proxy password (for [auth])', obscure: true),
          _sw('lenient', 'Accept any payload response', sub: 'Do not reject non-2xx answers from the proxy'),
        ]),
        if (_d['tls'] == true)
          SectionCard(title: 'SECURITY', children: [
            _sw('verifyTls', 'Validate TLS certificate'),
            _tf('pin', 'Pin certificate SHA-256 (optional)', hint: 'hex fingerprint'),
          ]),
      ];

  static const _protos = ['vless', 'vmess', 'trojan', 'ss', 'hysteria2'];

  List<Widget> _v2() {
    final mode = _s('mode', 'link');
    final proto = _s('proto', 'vless');
    return [
      SectionCard(title: 'CONFIGURATION', children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'link', label: Text('Link')),
              ButtonSegment(value: 'gui', label: Text('Guided')),
              ButtonSegment(value: 'json', label: Text('JSON')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => _d['mode'] = s.first),
          ),
        ),
        if (mode == 'link') _tf('link', 'Share link', lines: 4, hint: 'vless:// vmess:// trojan:// ss:// hysteria2://', mono: true),
        if (mode == 'json') _tf('json', 'Xray JSON config', lines: 12, mono: true),
        if (mode == 'gui') ...[
          _dd('proto', 'Protocol', _protos, 'vless'),
          _tf('address', 'Server address', kb: TextInputType.url),
          _tf('port', 'Port', kb: TextInputType.number, def: '443'),
          _tf('id', proto == 'vless' || proto == 'vmess' ? 'UUID' : 'Password'),
          if (proto == 'ss') _tf('method', 'Cipher', def: 'aes-256-gcm'),
          if (proto == 'vless') _tf('encryption', 'Encryption', def: 'none'),
        ],
      ]),
      if (mode == 'gui' && proto != 'ss' && proto != 'hysteria2')
        SectionCard(title: 'TRANSPORT & TLS', children: [
          _dd('net', 'Transport', const ['tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp'], 'tcp'),
          _dd('security', 'Security', const ['tls', 'reality', 'none'], 'tls'),
          _tf('host', 'Host header'),
          _tf('path', 'Path / service name'),
          _tf('sni', 'SNI'),
          _dd('fp', 'Fingerprint', const ['', 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random'], ''),
          _tf('alpn', 'ALPN', hint: 'h2,http/1.1'),
          if (proto == 'vless') _tf('flow', 'Flow', hint: 'xtls-rprx-vision'),
          if (proto == 'vless' && _s('security') == 'reality') ...[
            _tf('pbk', 'Reality public key'),
            _tf('sid', 'Reality short id'),
            _tf('spx', 'Reality spiderX'),
          ],
          _tf('pcs', 'Pinned certificate SHA-256 (optional)'),
        ]),
      if (mode == 'gui' && proto == 'hysteria2')
        SectionCard(title: 'HYSTERIA2', children: [
          _tf('sni', 'SNI'),
          _tf('obfs', 'Obfuscation', hint: 'salamander'),
          _tf('obfsPassword', 'Obfuscation password'),
          _tf('mport', 'Port hopping range', hint: '20000-30000'),
          _tf('pcs', 'Pinned certificate SHA-256 (optional)'),
        ]),
    ];
  }

  Future<void> _pasteOvpn() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text == null || d!.text!.trim().isEmpty) {
      if (mounted) toast(context, 'Clipboard is empty');
      return;
    }
    _ovpn.text = d.text!;
  }

  List<Widget> _openvpn() => [
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Notice('Paste the full .ovpn file. Certificates and keys must be embedded (<ca>, <cert>, <key>) because the app cannot read other files.'),
        ),
        SectionCard(title: 'CONFIGURATION', children: [
          TextField(
            controller: _ovpn,
            maxLines: 12,
            minLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(labelText: '.ovpn configuration', alignLabelWithHint: true),
          ),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _pasteOvpn, icon: const Icon(Icons.content_paste, size: 18), label: const Text('Paste from clipboard'))),
        ]),
        SectionCard(title: 'CREDENTIALS', subtitle: 'Only for configs with auth-user-pass or an encrypted key', children: [
          _tf('user', 'Username'),
          _tf('pass', 'Password', obscure: true),
          _tf('keyPass', 'Private key passphrase', obscure: true),
        ]),
      ];

  List<Widget> _proxy() {
    final kind = _s('kind', 'socks5');
    return [
      SectionCard(title: 'UPSTREAM PROXY', subtitle: 'Carried by the Xray core. HTTP and HTTPS proxies are TCP only.', children: [
        _dd('kind', 'Type', const ['socks5', 'http', 'https'], 'socks5', names: const {'socks5': 'SOCKS5', 'http': 'HTTP (CONNECT)', 'https': 'HTTPS (TLS to the proxy)'}),
        _tf('host', 'Host / IP', kb: TextInputType.url),
        _tf('port', 'Port', kb: TextInputType.number, def: kind == 'socks5' ? '1080' : '8080'),
        _tf('user', 'Username (optional)'),
        _tf('pass', 'Password', obscure: true),
        if (kind == 'https') _tf('sni', 'SNI (server name)', hint: 'defaults to the host'),
      ]),
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
      SectionCard(title: 'ORDER', subtitle: 'Tried top to bottom. Drag to reorder.', padding: EdgeInsets.zero, children: [
        if (_members.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No members yet')),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
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
      ]),
      SectionCard(title: 'AVAILABLE PROFILES', padding: EdgeInsets.zero, children: [
        if (others.where((e) => !_members.contains(e.id)).isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Everything is already in the group')),
        for (final e in others.where((e) => !_members.contains(e.id)))
          ListTile(
            dense: true,
            leading: TypeAvatar(e.type, size: 34),
            title: Text(e.name),
            subtitle: Text(e.typeLabel),
            trailing: const Icon(Icons.add_circle_outline),
            onTap: () => setState(() => _members.add(e.id)),
          ),
      ]),
    ];
  }

  // -------------------------------------------------------------- validation

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

  String? _portErr(String k, String def) {
    final port = int.tryParse(_s(k, def));
    return (port == null || port < 1 || port > 65535) ? 'Port must be 1-65535' : null;
  }

  String? _validate() {
    switch (_p.type) {
      case ProfileType.ssh:
        if (_s('host').trim().isEmpty) return 'Host is required';
        if (_s('user').trim().isEmpty) return 'Username is required';
        if (_portErr('port', '22') != null) return _portErr('port', '22');
        if (_s('proxyHost').trim().isNotEmpty && _portErr('proxyPort', '8080') != null) return _portErr('proxyPort', '8080');
        if (_s('pass').isEmpty && _s('key').trim().isEmpty) return 'Enter a password or a private key';
        return null;
      case ProfileType.inject:
        if (_s('proxyHost').trim().isEmpty) return 'Proxy host is required';
        if (_portErr('proxyPort', '80') != null) return _portErr('proxyPort', '80');
        if (_s('payload').trim().isEmpty) return 'Payload is required';
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
            buildShareLink(Profile(id: _p.id, name: _name, type: ProfileType.v2ray, data: Map<String, dynamic>.from(_d)));
          } catch (e) {
            return errText(e);
          }
        }
        return null;
      case ProfileType.wireguard:
        final c = _s('conf');
        if (!c.contains('[Interface]') || !c.contains('[Peer]')) return 'Config needs [Interface] and [Peer]';
        return null;
      case ProfileType.openvpn:
        if (!RegExp(r'^\s*remote\s+\S+', multiLine: true).hasMatch(_s('config'))) return 'Config needs a "remote" line';
        return null;
      case ProfileType.proxy:
        if (_s('host').trim().isEmpty) return 'Host is required';
        return _portErr('port', _s('kind', 'socks5') == 'socks5' ? '1080' : '8080');
      case ProfileType.group:
        return _members.isEmpty ? 'Add at least one member' : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _p.type;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New ${typeName(t)}' : 'Edit ${typeName(t)}'),
        actions: [Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton(onPressed: _save, child: const Text('Save')))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SectionCard(title: 'NAME', children: [
            TextFormField(initialValue: _name, decoration: const InputDecoration(labelText: 'Profile name'), onChanged: (v) => _name = v),
          ]),
          if (t == ProfileType.ssh) ..._ssh(),
          if (t == ProfileType.inject) ..._inject(),
          if (t == ProfileType.v2ray) ..._v2(),
          if (t == ProfileType.openvpn) ..._openvpn(),
          if (t == ProfileType.proxy) ..._proxy(),
          if (t == ProfileType.wireguard) SectionCard(title: 'CONFIGURATION', children: [_tf('conf', 'WireGuard config', lines: 12, mono: true)]),
          if (t == ProfileType.group) ..._group(),
        ],
      ),
    );
  }
}

/// Renders a payload exactly as it would be sent, for the previews.
String previewPayload(String raw, String host, int port, {String authUser = '', String authPass = ''}) {
  final steps = renderPayload(raw, host, port, authUser: authUser, authPass: authPass);
  return steps
      .map((e) => '${e.data.replaceAll('\r', '\\r').replaceAll('\n', '\\n\n')}${e.delayMs > 0 ? '\n---- wait ${e.delayMs} ms ----' : ''}')
      .join('\n');
}
