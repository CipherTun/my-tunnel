import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'tools_page.dart';

class EditPage extends StatefulWidget {
  const EditPage({super.key, required this.profile, required this.all, required this.ctrl});
  final Profile profile;
  final List<Profile> all;
  final VpnController ctrl;
  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.name);
  late final TextEditingController _payload =
      TextEditingController(text: widget.profile.s('payload'));
  late final Map<String, dynamic> _d = Map<String, dynamic>.from(widget.profile.data);

  Profile get p => widget.profile;

  // ---- field helpers ----
  Widget tf(String k, String label,
      {int lines = 1,
      bool obscure = false,
      TextInputType? type,
      String def = '',
      String? hint,
      bool mono = false}) {
    if (def.isNotEmpty) _d.putIfAbsent(k, () => def);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey('f_$k'),
        initialValue: _d[k]?.toString() ?? '',
        onChanged: (v) => _d[k] = v,
        obscureText: obscure,
        keyboardType: type,
        minLines: lines,
        maxLines: obscure ? 1 : lines,
        style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
        decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: label,
            hintText: hint,
            alignLabelWithHint: true),
      ),
    );
  }

  Widget dd(String k, String label, List<String> opts, String def) {
    final cur = opts.contains(_d[k]) ? _d[k] as String : def;
    _d[k] = cur;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('d_${k}_$cur'),
        initialValue: cur,
        items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(o))],
        onChanged: (v) => setState(() => _d[k] = v),
        decoration: InputDecoration(border: const OutlineInputBorder(), labelText: label),
      ),
    );
  }

  Widget sw(String k, String title, [String? sub]) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        value: _d[k] == true,
        onChanged: (v) => setState(() => _d[k] = v),
      );

  Widget swd(String k, String title, [String? sub]) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        value: _d[k] != false, // default ON
        onChanged: (v) => setState(() => _d[k] = v),
      );

  // ---- per type ----
  List<Widget> _ssh() => [
        tf('host', 'SSH host / IP'),
        tf('port', 'SSH port', type: TextInputType.number, def: '22'),
        tf('user', 'Username'),
        tf('pass', 'Password', obscure: true),
        tf('keyPem', 'Private key (PEM, optional)', lines: 4, mono: true),
        tf('keyPass', 'Key passphrase', obscure: true),
        swd('pinHostKey', 'Pin server host key',
            'Remembers the SSH server key on first connect and refuses a different one later'),
        if (widget.ctrl.hasPinnedKey(p))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.key_off),
              label: const Text('Forget pinned host key'),
              onPressed: () async {
                await widget.ctrl.resetPinnedKey(p);
                if (mounted) setState(() {});
              },
            ),
          ),
        const Divider(),
        sw('dnstt', 'DNSTT (SlowDNS) tunnel',
            'SSH carried inside DNS queries. Leave the SSH host empty (the server is reached '
                'through the tunnel). TLS, proxy, payload and WebSocket below are ignored while this is on.'),
        if (_d['dnstt'] == true) ...[
          tf('dnsttDomain', 'Tunnel domain (NS record)', hint: 't.example.com'),
          tf('dnsttKey', 'Server public key (64 hex characters)',
              mono: true, lines: 2, hint: 'from "dnstt-server -gen-key"'),
          dd('dnsttMode', 'DNS transport', const ['udp', 'doh', 'dot'], 'udp'),
          tf('dnsttResolver', 'DNS resolver',
              def: '8.8.8.8:53',
              hint: 'udp / dot: host:port     doh: https://1.1.1.1/dns-query'),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
                'The server side must run dnstt-server forwarding to its SSH port. Plain UDP needs '
                'a resolver that answers from your network (often your operator DNS). DoH / DoT: '
                'use an IP-based endpoint such as https://1.1.1.1/dns-query or 1.1.1.1:853, '
                'because the engine cannot use the phone\'s DNS settings.',
                style: TextStyle(fontSize: 12)),
          ),
        ],
        const Divider(),
        sw('tls', 'SSL / TLS tunnel (SNI)', 'SSH wrapped in TLS, e.g. stunnel or nginx stream'),
        if (_d['tls'] == true) ...[
          tf('sni', 'SNI', hint: 'cdn.example.com   or   [random=a.com,b.com]  [rotate=...]'),
          swd('allowInsecure', 'Accept any TLS certificate',
              'Needed for domain fronting (certificate never matches the SNI). Turn off to verify the certificate.'),
        ],
        tf('proxyHost', 'Upstream proxy host (optional)'),
        tf('proxyPort', 'Upstream proxy port', type: TextInputType.number, def: '8080'),
        dd('proxyType', 'Upstream proxy type', const ['http', 'socks5'], 'http'),
        tf('proxyUser', 'Proxy username (optional)'),
        tf('proxyPass', 'Proxy password', obscure: true),
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
              'The SSH connection reaches the server through this proxy. With TLS enabled above, '
              'the TLS handshake (and its SNI) is done with the proxy first.',
              style: TextStyle(fontSize: 12)),
        ),
        const Divider(),
        Row(children: [
          Expanded(
              child: Text('Custom payload', style: Theme.of(context).textTheme.titleSmall)),
          TextButton.icon(
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Generator'),
            onPressed: () async {
              final r = await Navigator.push<String>(context,
                  MaterialPageRoute(builder: (_) => const PayloadGeneratorPage(pick: true)));
              if (r != null) setState(() => _payload.text = r);
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _payload,
            minLines: 5,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                labelText: 'Payload (blank = none)',
                hintText: 'GET / [protocol][crlf]Host: [host][crlf]'
                    'Upgrade: websocket[crlf][crlf]'),
          ),
        ),
        sw('ws', 'WebSocket framing after upgrade',
            'Enable only if the server is a framed WS→SSH gateway'),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            icon: _testing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: const Text('Test connection'),
            onPressed: _testing ? null : _testSsh,
          ),
        ),
        if (_testResult.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(_testResult,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        const Divider(),
        tf('udpgwPort', 'UDP gateway port (badvpn-udpgw)',
            type: TextInputType.number,
            def: '7300',
            hint: '7300, or 0 to disable UDP'),
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
              'UDP (DNS, QUIC, VoIP, games) is carried over SSH only if the server runs '
              '"badvpn-udpgw --listen-addr 127.0.0.1:<port>". Without it, set 0.',
              style: TextStyle(fontSize: 12)),
        ),
      ];

  bool _testing = false;
  String _testResult = '';

  Future<void> _testSsh() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final tmp = Profile(
        id: p.id, name: p.name, type: p.type, data: {..._d, 'payload': _payload.text});
    final r = await widget.ctrl.testSshProfile(tmp);
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = r;
      });
    }
  }

  List<Widget> _proxy() {
    final kind = ['http', 'https', 'socks5'].contains(_d['kind']) ? _d['kind'] as String : 'http';
    return [
      dd('kind', 'Proxy type', const ['http', 'https', 'socks5'], 'http'),
      tf('address', 'Proxy host / IP'),
      tf('port', 'Port', type: TextInputType.number, def: '8080'),
      tf('user', 'Username (optional)'),
      tf('pass', 'Password', obscure: true),
      if (kind == 'https') ...[
        tf('sni', 'TLS server name (SNI)', hint: 'proxy.example.com'),
        tf('pin', 'Pinned certificate SHA-256 (optional)',
            hint: 'for self-signed proxies; certificate verification stays on'),
      ],
      if (kind != 'socks5')
        tf('headers', 'Extra request headers (one per line)',
            lines: 4,
            mono: true,
            hint: 'Host: example.com\nX-Online-Host: example.com'),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
            kind == 'socks5'
                ? 'Traffic is relayed over SOCKS5 (TCP; UDP only if the proxy server supports it).'
                : kind == 'http'
                    ? 'Plain HTTP proxies are unencrypted and carry TCP only. Use them for payload / header tricks, not for privacy.'
                    : 'HTTPS proxy: the connection to the proxy is encrypted with TLS. TCP only.',
            style: const TextStyle(fontSize: 12)),
      ),
      tf('connectAddr', 'Connect address override (optional)',
          hint: 'dial this IP instead of the proxy host'),
    ];
  }

  static const _protos = ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'socks'];

  List<Widget> _v2() {
    final mode = _d['mode'] == 'link' || _d['mode'] == 'json' ? _d['mode'] as String : 'gui';
    _d['mode'] = mode;
    return [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'gui', label: Text('Manual')),
          ButtonSegment(value: 'link', label: Text('Link')),
          ButtonSegment(value: 'json', label: Text('JSON')),
        ],
        selected: {mode},
        onSelectionChanged: (s) => setState(() => _d['mode'] = s.first),
      ),
      const SizedBox(height: 16),
      if (mode == 'link')
        tf('link', 'vmess:// vless:// trojan:// ss:// hysteria2:// socks:// link', lines: 6, mono: true),
      if (mode == 'json')
        tf('json', 'Full Xray JSON config', lines: 16, mono: true),
      if (mode == 'gui') ..._v2gui(),
      if (mode != 'json') ...[
        const Divider(),
        tf('connectAddr', 'Connect address override (optional)',
            hint: 'CDN clean IP, e.g. 104.16.1.1',
            type: TextInputType.url),
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
              'Dials this IP/host instead of the server address. SNI and Host header keep the '
              'real domain. Find a fast IP with Tools > Clean IP scanner.',
              style: TextStyle(fontSize: 12)),
        ),
      ],
    ];
  }

  List<Widget> _dnstt() => [
        tf('domain', 'DNSTT tunnel domain', hint: 't.example.com'),
        tf('pubKey', 'DNSTT server public key (64 hex characters)', lines: 2, mono: true),
        dd('mode', 'DNS transport', const ['udp', 'doh', 'dot'], 'udp'),
        tf('resolver', 'Resolver (host:port or DoH URL)', def: '8.8.8.8:53', hint: '8.8.8.8:53 or https://1.1.1.1/dns-query'),
        const Text('The DNSTT server must forward its TCP tunnel to a SOCKS-compatible endpoint for full VPN routing.', style: TextStyle(fontSize: 12)),
      ];

  List<Widget> _slipstream() => [
        tf('domain', 'Slipstream tunnel domain', hint: 's.example.com'),
        dd('mode', 'DNS mode', const ['resolver', 'authoritative'], 'resolver'),
        tf('resolver', 'Resolver / authoritative endpoint (host:port)', def: '1.1.1.1:53', hint: '1.1.1.1:53'),
        tf('certPem', 'Optional pinned server certificate (PEM)', lines: 5, mono: true, hint: '-----BEGIN CERTIFICATE-----'),
        const Text('Slipstream transports TCP to the remote service. Configure the server to forward this tunnel to a SOCKS-compatible endpoint. Supplying the server certificate enables strict leaf pinning.', style: TextStyle(fontSize: 12)),
      ];

  List<Widget> _openconnect() => [
        tf('gateway', 'OpenConnect gateway URL', hint: 'https://vpn.example.com'),
        tf('user', 'Username'),
        tf('pass', 'Password', obscure: true),
        tf('group', 'Gateway group / realm (optional)'),
        tf('token', 'One-time token / OTP (optional)', obscure: true),
        tf('serverCert', 'Expected server certificate SHA-256 (optional)', mono: true, hint: 'Pin only when supplied by your administrator'),
        tf('caCertPem', 'Custom CA certificate PEM (optional)', lines: 5, mono: true),
        sw('noDtls', 'Disable DTLS (TCP only)', 'Use only if UDP/DTLS is blocked by the network'),
        const Text('Requires the native OpenConnect Android engine. This profile does not silently fall back to Xray or OpenVPN.', style: TextStyle(fontSize: 12)),
      ];

  List<Widget> _psiphon() => [
        tf('configJson', 'Psiphon client configuration JSON', lines: 12, mono: true, hint: '{ ... official Psiphon SDK config ... }'),
        tf('embeddedServerEntries', 'Embedded server entries (optional)', lines: 5, mono: true),
        tf('region', 'Preferred egress region (optional)', hint: 'e.g. US, CA, GB'),
        tf('upstreamProxy', 'Upstream proxy (optional)', hint: 'socks5://127.0.0.1:1080'),
        const Text('Requires the official Psiphon Android library in its own Android process because it embeds a Go runtime. Use configuration and server entries supplied by a legitimate Psiphon deployment; this app does not invent server entries.', style: TextStyle(fontSize: 12)),
      ];

  List<Widget> _openvpn() => [
        tf('config', '.ovpn file content', lines: 14, mono: true),
        tf('user', 'Username (auth-user-pass, optional)'),
        tf('pass', 'Password', obscure: true),
        tf('keyPass', 'Private key passphrase (if encrypted)', obscure: true),
        sw('singleRemote', 'Use one random remote only',
            'Avoids freezes on configs with many remote lines'),
        const Text('OpenVPN uses its own engine (ics-openvpn). UDP and TCP remotes are supported.',
            style: TextStyle(fontSize: 12)),
      ];

  Widget _pick(String k, String label, List<Profile> opts) {
    final ids = opts.map((e) => e.id).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('c_${k}_${_d[k]}'),
        initialValue: ids.contains(_d[k]) ? _d[k] as String : null,
        isExpanded: true,
        items: [for (final o in opts) DropdownMenuItem(value: o.id, child: Text(o.name, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() => _d[k] = v),
        decoration: InputDecoration(border: const OutlineInputBorder(), labelText: label),
      ),
    );
  }

  List<Widget> _chain() {
    final opts = widget.all
        .where((e) => e.type == ProfileType.v2ray && e.s('mode') != 'json')
        .toList();
    if (opts.length < 2) {
      return [const Text('A chain needs at least two V2Ray profiles (link or manual mode).')];
    }
    return [
      const Text('Traffic goes: this phone → entry server → exit server → internet. '
          'The exit server sees your traffic, the entry server sees only who you are. '
          'Both must be TCP-based (VLESS, VMess, Trojan, Shadowsocks, SOCKS).'),
      const SizedBox(height: 12),
      _pick('entry', 'Entry server (first hop)', opts),
      _pick('exit', 'Exit server (last hop)', opts),
    ];
  }

  List<Widget> _v2gui() {
    final proto = _protos.contains(_d['proto']) ? _d['proto'] as String : 'vless';
    final net = (_d['network'] ?? 'tcp') as String;
    final sec = (_d['security'] ?? 'none') as String;
    final web = proto == 'vless' || proto == 'vmess' || proto == 'trojan';
    return [
      dd('proto', 'Protocol', _protos, 'vless'),
      tf('address', 'Server address'),
      tf('port', 'Port', type: TextInputType.number, def: '443'),
      if (proto == 'socks') tf('user', 'Username (optional)'),
      tf('id', proto == 'vless' || proto == 'vmess' ? 'UUID' : 'Password / auth'),
      if (proto == 'vless') ...[
        tf('encryption', 'VLESS encryption', def: 'none'),
        dd('flow', 'Flow', ['none', 'xtls-rprx-vision'], 'none'),
      ],
      if (proto == 'vmess') ...[
        dd('scy', 'VMess security', ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'none'], 'auto'),
        tf('aid', 'Alter ID', type: TextInputType.number, def: '0'),
      ],
      if (proto == 'shadowsocks')
        dd('method', 'Cipher', [
          'aes-256-gcm',
          'aes-128-gcm',
          'chacha20-ietf-poly1305',
          '2022-blake3-aes-128-gcm',
          '2022-blake3-aes-256-gcm',
          '2022-blake3-chacha20-poly1305',
        ], 'aes-256-gcm'),
      if (web) ...[
        dd('network', 'Transport', ['tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'kcp'], 'tcp'),
        if (net == 'ws' || net == 'httpupgrade' || net == 'xhttp') ...[
          tf('host', 'Host header'),
          tf('path', 'Path', def: '/'),
        ],
        if (net == 'grpc') tf('path', 'gRPC service name'),
        if (net == 'kcp') tf('path', 'mKCP seed (optional)'),
        dd('security', 'Security', ['none', 'tls', 'reality'], 'none'),
        if (sec != 'none') ...[
          tf('sni', 'SNI / server name'),
          dd('fp', 'uTLS fingerprint',
              ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'randomized', 'none'], 'chrome'),
          tf('alpn', 'ALPN (e.g. h2,http/1.1)'),
          tf('pcs', 'Pinned cert SHA-256 (optional)'),
        ],
        if (sec == 'reality') ...[
          tf('pbk', 'REALITY public key'),
          tf('sid', 'REALITY short ID'),
          tf('spx', 'REALITY spiderX'),
        ],
      ],
      if (proto == 'hysteria2') ...[
        tf('sni', 'SNI'),
        tf('obfsPass', 'Salamander obfs password (optional)'),
        tf('mport', 'Port hopping range (e.g. 20000-30000)'),
        tf('pcs', 'Pinned cert SHA-256 (optional)'),
      ],
    ];
  }

  List<Widget> _group() {
    final members = ((_d['members'] as List?) ?? []).map((e) => e.toString()).toList();
    final others = widget.all.where((e) => e.type != ProfileType.group && e.id != p.id);
    if (others.isEmpty) return [const Text('Create some profiles first.')];
    return [
      const Text('Tick servers in the order they should be tried. If one fails, the next is used.'),
      for (final o in others)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: members.contains(o.id),
          title: Text(o.name),
          subtitle: Text(o.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          secondary: members.contains(o.id) ? Text('#${members.indexOf(o.id) + 1}') : null,
          onChanged: (v) => setState(() {
            v == true ? members.add(o.id) : members.remove(o.id);
            _d['members'] = members;
          }),
        ),
    ];
  }

  void _save() {
    final t = _name.text.trim();
    if (t.isNotEmpty) p.name = t;
    if (p.type == ProfileType.ssh) _d['payload'] = _payload.text;
    p.data = _d;
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(typeLabel(p.type)),
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'Profile name'),
          ),
          const SizedBox(height: 12),
          ...switch (p.type) {
            ProfileType.ssh => _ssh(),
            ProfileType.v2ray => _v2(),
            ProfileType.proxy => _proxy(),
            ProfileType.wireguard => [
                tf('config', 'WireGuard config (wg-quick format)', lines: 14, mono: true)
              ],
            ProfileType.openvpn => _openvpn(),
            ProfileType.dnstt => _dnstt(),
            ProfileType.slipstream => _slipstream(),
            ProfileType.openconnect => _openconnect(),
            ProfileType.psiphon => _psiphon(),
            ProfileType.chain => _chain(),
            ProfileType.group => _group(),
          },
        ]),
      );
}
