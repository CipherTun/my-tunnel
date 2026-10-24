import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import 'app_info.dart';
import 'core_config.dart';
import 'models.dart';
import 'native.dart';
import 'ssh_tunnel.dart';
import 'subscriptions.dart';

enum ConnState { disconnected, connecting, connected }

enum _Engine { none, xray, ovpn, local }

Future<int> tcpPing(String host, int port) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
    sw.stop();
    s.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  }
}

String errText(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

String _fmtDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

class VpnController extends ChangeNotifier {
  final Store _store = Store();
  final SshTunnel ssh = SshTunnel();
  final PayloadProxy payloadProxy = PayloadProxy();
  late final V2ray _v2 = V2ray(onStatusChanged: _onV2);
  late final OpenVPN _ovpn = OpenVPN(
    onVpnStageChanged: _onOvpnStage,
    onVpnStatusChanged: _onOvpnStatus,
  );
  bool _ovpnReady = false;

  List<Profile> profiles = [];
  List<Subscription> subs = [];
  AppSettings settings = AppSettings();
  String? selectedId;

  ConnState state = ConnState.disconnected;
  String? error;
  String activeName = '';
  String activeType = '';
  String duration = '00:00:00';
  int upSpeed = 0;
  int downSpeed = 0;
  int upTotal = 0;
  int downTotal = 0;
  int? lastDelay;

  /// Local SOCKS5 port while a proxy-style session is up (SSH, payload,
  /// proxy-only mode). Null in full-VPN mode with a native engine.
  int? localSocks;
  bool localShared = false;

  final Map<String, int> pings = {};
  bool pinging = false;
  final List<String> logs = [];

  Profile? _root;
  _Engine _engine = _Engine.none;
  bool _userStopped = false;
  bool _dropping = false;
  int _gen = 0;
  int _retries = 0;
  Completer<void>? _up;
  Timer? _retryTimer;
  Timer? _watch;
  Timer? _ticker;
  Stopwatch? _sw;
  int _watchFails = 0;

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  bool get busy => state != ConnState.disconnected;
  bool get proxyMode => settings.vpnMode == 'proxy';

  // ------------------------------------------------------------------ logging

  void log(String m) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    logs.add('${two(n.hour)}:${two(n.minute)}:${two(n.second)}  $m');
    if (logs.length > 600) logs.removeRange(0, logs.length - 600);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  // --------------------------------------------------------------------- init

  Future<void> init() async {
    await _store.init();
    profiles = _store.loadProfiles();
    subs = _store.loadSubs();
    settings = _store.loadSettings();
    selectedId = _store.loadSelected();
    if (selected == null) selectedId = profiles.isEmpty ? null : profiles.first.id;
    try {
      await _v2.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_stat_vpn',
      );
    } catch (e) {
      log('Xray init failed: ${errText(e)}');
    }
    try {
      log('Xray core ${await _v2.getCoreVersion()}');
    } catch (_) {}
    Native.requestNotifications();
    notifyListeners();
    if (settings.autoConnect && selected != null) {
      log('Auto-connect on launch');
      unawaited(connect());
    }
  }

  // ----------------------------------------------------------------- profiles

  Future<void> saveProfiles() => _store.saveProfiles(profiles);

  Future<void> saveSettings() async {
    await _store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (busy) return;
    selectedId = id;
    await _store.saveSelected(id);
    notifyListeners();
  }

  Future<void> upsert(Profile p) async {
    final i = profiles.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      profiles[i] = p;
    } else {
      profiles.add(p);
    }
    selectedId ??= p.id;
    await saveProfiles();
    await _store.saveSelected(selectedId);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    profiles.removeWhere((e) => e.id == id);
    for (final g in profiles.where((e) => e.type == ProfileType.group)) {
      (g.data['members'] as List?)?.remove(id);
    }
    pings.remove(id);
    if (selectedId == id) selectedId = profiles.isEmpty ? null : profiles.first.id;
    await saveProfiles();
    await _store.saveSelected(selectedId);
    notifyListeners();
  }

  Future<Profile?> importText(String text) async {
    final p = importProfile(text);
    if (p == null) return null;
    await upsert(p);
    return p;
  }

  Future<void> duplicate(Profile p) async {
    final c = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>)
      ..id = newId()
      ..name = '${p.name} copy'
      ..subId = null;
    c.data.remove('hostKey');
    await upsert(c);
  }

  // ------------------------------------------------------------ subscriptions

  Future<int> addSubscription(String name, String url) async {
    final s = Subscription(
      id: newId(),
      name: name.trim().isEmpty ? Uri.parse(url.trim()).host : name.trim(),
      url: url.trim(),
    );
    final n = await _refresh(s);
    subs.add(s);
    await _store.saveSubs(subs);
    notifyListeners();
    return n;
  }

  Future<int> updateSubscription(Subscription s) async {
    final n = await _refresh(s);
    await _store.saveSubs(subs);
    notifyListeners();
    return n;
  }

  Future<void> removeSubscription(Subscription s, {bool withProfiles = true}) async {
    subs.removeWhere((e) => e.id == s.id);
    if (withProfiles) {
      final ids = profiles.where((p) => p.subId == s.id).map((p) => p.id).toList();
      for (final id in ids) {
        await remove(id);
      }
    } else {
      for (final p in profiles.where((p) => p.subId == s.id)) {
        p.subId = null;
      }
      await saveProfiles();
    }
    await _store.saveSubs(subs);
    notifyListeners();
  }

  Future<int> _refresh(Subscription s) async {
    final body = await fetchSubscription(s.url);
    final fresh = parseSubscription(body, s.id);
    if (fresh.isEmpty) throw 'No supported links found in this subscription';
    final old = {for (final p in profiles.where((p) => p.subId == s.id)) profileKey(p): p};
    final keep = <Profile>[];
    for (final p in fresh) {
      keep.add(old[profileKey(p)] ?? p);
    }
    final keepIds = keep.map((e) => e.id).toSet();
    profiles.removeWhere((p) => p.subId == s.id && !keepIds.contains(p.id));
    for (final p in keep) {
      if (!profiles.any((e) => e.id == p.id)) profiles.add(p);
    }
    if (selected == null && profiles.isNotEmpty) selectedId = profiles.first.id;
    s.updated = DateTime.now();
    await saveProfiles();
    log('Subscription "${s.name}": ${keep.length} profiles');
    return keep.length;
  }

  // ------------------------------------------------------------------- backup

  String exportBackup() => const JsonEncoder.withIndent('  ').convert({
        'app': kAppId,
        'version': 4,
        'profiles': [for (final p in profiles) p.toJson()],
        'subscriptions': [for (final s in subs) s.toJson()],
        'settings': settings.toJson(),
      });

  /// Merges a backup; returns the number of profiles added.
  Future<int> importBackup(String text) async {
    final j = jsonDecode(text) as Map<String, dynamic>;
    var added = 0;
    for (final e in (j['profiles'] as List? ?? const [])) {
      final p = Profile.fromJson(Map<String, dynamic>.from(e as Map));
      if (!profiles.any((x) => x.id == p.id)) {
        profiles.add(p);
        added++;
      }
    }
    for (final e in (j['subscriptions'] as List? ?? const [])) {
      final s = Subscription.fromJson(Map<String, dynamic>.from(e as Map));
      if (!subs.any((x) => x.id == s.id)) subs.add(s);
    }
    if (j['settings'] is Map) settings.applyJson(Map<String, dynamic>.from(j['settings'] as Map));
    if (selected == null && profiles.isNotEmpty) selectedId = profiles.first.id;
    await saveProfiles();
    await _store.saveSubs(subs);
    await _store.saveSettings(settings);
    await _store.saveSelected(selectedId);
    notifyListeners();
    return added;
  }

  // --------------------------------------------------------------------- ping

  String? _configFor(Profile p) {
    try {
      switch (p.type) {
        case ProfileType.v2ray:
          return buildV2rayConfig(p);
        case ProfileType.wireguard:
          return buildWireGuardConfig(p);
        case ProfileType.proxy:
          return buildProxyConfig(p);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  Future<int> _measure(Profile p) async {
    if (settings.testMode == 'real') {
      final cfg = _configFor(p);
      if (cfg != null) {
        try {
          final d = await _v2.getServerDelay(config: cfg);
          return d > 0 && d < 8000 ? d : -1;
        } catch (_) {
          return -1;
        }
      }
    }
    final ep = p.endpoint;
    return ep == null ? -1 : tcpPing(ep.host, ep.port);
  }

  Future<void> pingAll() async {
    if (busy || pinging) return;
    pinging = true;
    pings.clear();
    notifyListeners();
    final targets = profiles.where((p) => p.type != ProfileType.group && (p.endpoint != null || _configFor(p) != null)).toList();
    var next = 0;
    final workers = settings.testMode == 'real' ? 3 : 5;
    Future<void> worker() async {
      while (next < targets.length) {
        final p = targets[next++];
        pings[p.id] = await _measure(p);
        notifyListeners();
      }
    }

    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    pinging = false;
    notifyListeners();
  }

  // --------------------------------------------------------------- connection

  List<Profile> _leaves(Profile p, [Set<String>? seen]) {
    if (p.type != ProfileType.group) return [p];
    seen ??= {p.id};
    final out = <Profile>[];
    for (final id in (p.data['members'] as List? ?? const [])) {
      if (!seen.add('$id')) continue;
      for (final c in profiles) {
        if (c.id == id) out.addAll(_leaves(c, seen));
      }
    }
    return out;
  }

  Future<void> connect() async {
    final p = selected;
    if (p == null || state != ConnState.disconnected) return;
    _root = p;
    _userStopped = false;
    _retries = 0;
    error = null;
    final g = ++_gen;
    await _run(g);
  }

  Future<void> disconnect() async {
    _userStopped = true;
    _gen++;
    _retryTimer?.cancel();
    _stopWatch();
    if (state != ConnState.disconnected) log('Disconnecting');
    await _stopCore();
    _root = null;
    _resetStats();
    state = ConnState.disconnected;
    notifyListeners();
  }

  void _resetStats() {
    _ticker?.cancel();
    _ticker = null;
    _sw = null;
    duration = '00:00:00';
    upSpeed = downSpeed = upTotal = downTotal = 0;
    lastDelay = null;
    activeName = '';
    activeType = '';
    localSocks = null;
    localShared = false;
  }

  Future<void> _run(int g) async {
    final root = _root;
    if (root == null) return;
    state = ConnState.connecting;
    notifyListeners();
    final leaves = _leaves(root);
    if (leaves.isEmpty) {
      error = 'This group has no usable members';
      log(error!);
      await disconnect();
      return;
    }
    String? lastErr;
    for (final leaf in leaves) {
      if (_userStopped || g != _gen) return;
      activeName = leaf.name;
      activeType = leaf.typeLabel;
      log('Connecting: ${leaf.name} (${leaf.typeLabel})');
      notifyListeners();
      try {
        await _start(leaf, g);
        return; // success: engine callbacks flip state to connected
      } catch (e) {
        lastErr = errText(e);
        if (_userStopped || g != _gen) return;
        log('${leaf.name} failed: $lastErr');
        await _stopCore();
      }
    }
    if (_userStopped || g != _gen) return;
    error = lastErr;
    await _retryOrStop(g);
  }

  Future<void> _retryOrStop(int g) async {
    if (g != _gen || _userStopped) return;
    if (!settings.autoReconnect || _retries >= settings.reconnectMax) {
      log(settings.autoReconnect ? 'Giving up after $_retries retries' : 'Connection failed');
      await disconnect();
      return;
    }
    _retries++;
    final wait = Duration(seconds: (_retries * 3).clamp(3, 20).toInt());
    log('Retry $_retries/${settings.reconnectMax} in ${wait.inSeconds}s');
    state = ConnState.connecting;
    notifyListeners();
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (!_userStopped && g == _gen) _run(g);
    });
  }

  Future<void> _dropped(int g) async {
    if (g != _gen || _userStopped || _dropping) return;
    _dropping = true;
    try {
      log('Connection lost');
      state = ConnState.connecting;
      _stopWatch();
      _ticker?.cancel();
      notifyListeners();
      await _stopCore();
      await _retryOrStop(g);
    } finally {
      _dropping = false;
    }
  }

  /// Called by any engine when the tunnel is up.
  void _setConnected() {
    if (state == ConnState.connected) return;
    state = ConnState.connected;
    _retries = 0;
    error = null;
    log(localSocks != null ? 'Connected (SOCKS5 127.0.0.1:$localSocks)' : 'Connected');
    final u = _up;
    if (u != null && !u.isCompleted) u.complete();
    if (_engine == _Engine.xray) _startWatch(_gen);
    if (_engine == _Engine.local) {
      _sw = Stopwatch()..start();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        duration = _fmtDuration(_sw!.elapsed);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _start(Profile leaf, int g) async {
    switch (leaf.type) {
      case ProfileType.ssh:
        final o = _sshOptions(leaf);
        ssh.onClosed = (r) {
          log(r);
          _dropped(g);
        };
        final port = await ssh.start(o, log);
        await _afterLocalProxy(leaf, port, o.shareHotspot);
        break;
      case ProfileType.inject:
        final o = _injectOptions(leaf);
        final d = leaf.data;
        final probe = '${d['target'] ?? 'www.gstatic.com:443'}'.split(':');
        final port = await payloadProxy.start(
          o,
          log,
          probeHost: probe.first.trim().isEmpty ? 'www.gstatic.com' : probe.first.trim(),
          probePort: probe.length > 1 ? int.tryParse(probe[1]) ?? 443 : 443,
        );
        await _afterLocalProxy(leaf, port, o.shareHotspot);
        break;
      case ProfileType.v2ray:
        var cfg = buildV2rayConfig(leaf);
        if (leaf.data['mode'] != 'json') cfg = applyNetwork(cfg, settings);
        await _launchXray(leaf.name, cfg);
        break;
      case ProfileType.wireguard:
        await _launchXray(leaf.name, applyNetwork(buildWireGuardConfig(leaf), settings));
        break;
      case ProfileType.proxy:
        final kind = '${leaf.data['kind'] ?? 'socks5'}';
        await _launchXray(
          leaf.name,
          applyNetwork(buildProxyConfig(leaf), settings, tcpOnly: kind != 'socks5'),
        );
        break;
      case ProfileType.openvpn:
        await _startOpenVpn(leaf);
        break;
      case ProfileType.group:
        throw 'Nested group';
    }
  }

  /// SSH and payload tunnels expose a local SOCKS5 server. In VPN mode the
  /// Xray core turns the device's traffic into connections to that server; in
  /// proxy-only mode the SOCKS5 server itself is the product.
  Future<void> _afterLocalProxy(Profile leaf, int port, bool shared) async {
    if (proxyMode) {
      _engine = _Engine.local;
      localSocks = port;
      localShared = shared;
      _setConnected();
      return;
    }
    final cfg = applyNetwork(buildSocksConfig(port), settings, tcpOnly: true);
    await _launchXray(leaf.name, cfg, excludeSelf: true);
    localSocks = port;
    localShared = shared;
  }

  SshOptions _sshOptions(Profile p) {
    final d = p.data;
    String s(String k) => (d[k] ?? '').toString().trim();
    final host = s('host');
    if (host.isEmpty) throw 'SSH host is empty';
    if (s('user').isEmpty) throw 'SSH username is empty';
    return SshOptions(
      host: host,
      port: int.tryParse(s('port')) ?? 22,
      user: s('user'),
      pass: (d['pass'] ?? '').toString(),
      keyPem: (d['key'] ?? '').toString(),
      keyPass: (d['keyPass'] ?? '').toString(),
      payload: (d['payload'] ?? '').toString(),
      proxyHost: s('proxyHost'),
      proxyPort: int.tryParse(s('proxyPort')) ?? 8080,
      useTls: d['tls'] == true,
      sni: s('sni'),
      ws: d['ws'] == true,
      legacy: d['legacy'] != false,
      verifyHostKey: d['verifyHost'] == true,
      hostKey: s('hostKey'),
      onHostKey: (v) {
        p.data['hostKey'] = v;
        saveProfiles();
      },
      verifyTls: d['verifyTls'] == true,
      pin: s('pin'),
      lenient: d['lenient'] == true,
      authUser: s('authUser'),
      authPass: (d['authPass'] ?? '').toString(),
      keepAlive: settings.sshKeepAlive,
      socksPort: settings.socksPort,
      shareHotspot: settings.shareHotspot,
    );
  }

  SshOptions _injectOptions(Profile p) {
    final d = p.data;
    String s(String k) => (d[k] ?? '').toString().trim();
    if (s('proxyHost').isEmpty) throw 'Proxy host is empty';
    if (s('payload').isEmpty) throw 'Payload is empty';
    return SshOptions(
      host: '',
      port: 0,
      user: '',
      payload: (d['payload'] ?? '').toString(),
      proxyHost: s('proxyHost'),
      proxyPort: int.tryParse(s('proxyPort')) ?? 80,
      useTls: d['tls'] == true,
      sni: s('sni'),
      ws: d['ws'] == true,
      verifyTls: d['verifyTls'] == true,
      pin: s('pin'),
      lenient: d['lenient'] == true,
      authUser: s('authUser'),
      authPass: (d['authPass'] ?? '').toString(),
      socksPort: settings.socksPort,
      shareHotspot: settings.shareHotspot,
    );
  }

  // -------------------------------------------------------------------- Xray

  Future<void> _launchXray(String remark, String config, {bool excludeSelf = false}) async {
    _engine = _Engine.xray;
    final c = Completer<void>();
    _up = c;
    final proxyOnly = proxyMode && !excludeSelf;
    if (!proxyOnly && !await _v2.requestPermission()) throw 'VPN permission was denied';
    // In SSH/payload mode the transport sockets live in this app. They must
    // bypass the VPN or their traffic would loop back into the tunnel.
    final apps = <String>[...settings.blockedApps, if (excludeSelf) kAppId];
    await _v2.startV2Ray(
      remark: remark,
      config: config,
      blockedApps: apps.isEmpty ? null : apps,
      bypassSubnets: settings.bypassLan ? lanBypassSubnets : null,
      proxyOnly: proxyOnly,
    );
    if (proxyOnly) localSocks = kReservedPort;
    try {
      await c.future.timeout(const Duration(seconds: 25), onTimeout: () {
        throw 'Tunnel did not come up within 25s';
      });
    } finally {
      if (identical(_up, c)) _up = null;
    }
  }

  void _onV2(V2RayStatus st) {
    if (_root == null || _engine != _Engine.xray) return;
    final s = st.state.toString().toUpperCase();
    if (s.contains('CONNECTED') && !s.contains('DIS')) {
      _setConnected();
      duration = st.duration;
      upSpeed = st.uploadSpeed;
      downSpeed = st.downloadSpeed;
      upTotal = st.upload;
      downTotal = st.download;
      notifyListeners();
    } else if (s.contains('DISCONNECTED')) {
      _externalStop();
    }
  }

  /// The engine reported a stop we did not ask for (notification button,
  /// another VPN app taking over). Do not fight it with a reconnect.
  void _externalStop() {
    if (state != ConnState.connected || _userStopped) return;
    log('VPN stopped outside the app');
    _gen++;
    _stopWatch();
    _stopCore().whenComplete(() {
      _root = null;
      _resetStats();
      state = ConnState.disconnected;
      notifyListeners();
    });
  }

  // ----------------------------------------------------------------- OpenVPN

  Future<void> _startOpenVpn(Profile leaf) async {
    final d = leaf.data;
    String s(String k) => (d[k] ?? '').toString();
    final cfg = s('config');
    if (cfg.trim().isEmpty) throw 'OpenVPN config is empty';
    _engine = _Engine.ovpn;
    final c = Completer<void>();
    _up = c;
    if (!_ovpnReady) {
      await _ovpn.initialize();
      _ovpnReady = true;
    }
    final apps = settings.blockedApps;
    bool started;
    try {
      started = await _ovpn.connect(
        cfg,
        leaf.name,
        username: s('user').trim().isEmpty ? null : s('user').trim(),
        password: s('pass').isEmpty ? null : s('pass'),
        privateKeyPassword: s('keyPass').isEmpty ? null : s('keyPass'),
        bypassPackages: apps.isEmpty ? null : apps,
      );
    } catch (e) {
      throw 'OpenVPN rejected the config: ${errText(e)}';
    }
    if (!started) throw 'VPN permission was denied';
    try {
      await c.future.timeout(const Duration(seconds: 60), onTimeout: () {
        throw 'OpenVPN did not connect within 60s';
      });
    } catch (e) {
      String? why;
      try {
        why = await _ovpn.lastError();
      } catch (_) {}
      throw (why == null || why.isEmpty) ? e : '${errText(e)} ($why)';
    } finally {
      if (identical(_up, c)) _up = null;
    }
  }

  void _onOvpnStage(VPNStage stage, String raw) {
    if (_root == null || _engine != _Engine.ovpn) return;
    final r = raw.toLowerCase();
    if (stage.isConnected) {
      _setConnected();
      return;
    }
    if (r == 'denied' || r == 'auth_failed' || r == 'error') {
      final u = _up;
      if (u != null && !u.isCompleted) {
        u.completeError(r == 'auth_failed'
            ? 'Authentication failed (check username and password)'
            : r == 'denied'
                ? 'VPN permission was denied'
                : 'OpenVPN reported an error');
      } else if (state == ConnState.connected && !_userStopped) {
        _dropped(_gen);
      }
      return;
    }
    if (stage.isDisconnected) _externalStop();
  }

  void _onOvpnStatus(VpnStatus st) {
    if (_root == null || _engine != _Engine.ovpn || state != ConnState.connected) return;
    final d = st.duration;
    if (d != null && d.isNotEmpty) duration = d;
    downTotal = int.tryParse('${st.byteIn}') ?? downTotal;
    upTotal = int.tryParse('${st.byteOut}') ?? upTotal;
    downSpeed = (num.tryParse('${st.speedIn}') ?? 0).toInt();
    upSpeed = (num.tryParse('${st.speedOut}') ?? 0).toInt();
    notifyListeners();
  }

  // ----------------------------------------------------------------- shutdown

  void _cancelWait() {
    final u = _up;
    _up = null;
    if (u != null && !u.isCompleted) u.completeError('cancelled');
  }

  Future<void> _stopCore() async {
    _cancelWait();
    final engine = _engine;
    _engine = _Engine.none;
    try {
      await ssh.stop();
    } catch (_) {}
    try {
      await payloadProxy.stop();
    } catch (_) {}
    if (engine == _Engine.ovpn) {
      try {
        await _ovpn.disconnect();
      } catch (_) {}
    } else {
      try {
        await _v2.stopV2Ray();
      } catch (_) {}
    }
    localSocks = null;
  }

  // ----------------------------------------------------------------- watchdog

  void _startWatch(int g) {
    _stopWatch();
    if (!settings.watchdog) return;
    _watchFails = 0;
    _watch = Timer.periodic(Duration(seconds: settings.watchdogInterval), (_) async {
      if (state != ConnState.connected || g != _gen) return;
      final d = await connectedDelay();
      if (state != ConnState.connected || g != _gen) return;
      if (d > 0 && d < 8000) {
        _watchFails = 0;
        lastDelay = d;
        notifyListeners();
      } else {
        _watchFails++;
        log('Health check failed ($_watchFails/${settings.watchdogFails})');
        if (_watchFails >= settings.watchdogFails) {
          _watchFails = 0;
          _dropped(g);
        }
      }
    });
  }

  void _stopWatch() {
    _watch?.cancel();
    _watch = null;
  }

  /// Round-trip through the running Xray tunnel to the health-check URL, in ms.
  /// Returns -1 on failure or when no Xray core is running.
  Future<int> connectedDelay() async {
    if (_engine != _Engine.xray) return -1;
    try {
      return await _v2.getConnectedServerDelay(url: settings.watchdogUrl);
    } catch (_) {
      return -1;
    }
  }

  Future<List<String>> coreLogs() async {
    final out = <String>[];
    try {
      out.addAll([for (final e in await _v2.getLogs()) 'xray  ${e.toString()}']);
    } catch (e) {
      out.add('xray  could not read logs: ${errText(e)}');
    }
    if (_ovpnReady) {
      try {
        final l = await _ovpn.getLogs();
        out.addAll([for (final e in (l as Iterable)) 'ovpn  ${e.toString()}']);
      } catch (_) {}
    }
    return out;
  }
}
