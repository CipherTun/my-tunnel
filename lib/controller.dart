import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart' as ovpn;
import 'package:permission_handler/permission_handler.dart';

import 'config_tweaks.dart' show parseOvpnRemote;
import 'core_config.dart';
import 'models.dart';
import 'native.dart';
import 'ssh_tunnel.dart';
import 'subscription.dart';
import 'usage.dart';

enum ConnState { disconnected, connecting, connected }

const _testUrl = 'https://cp.cloudflare.com/generate_204';

class VpnController extends ChangeNotifier {
  /// Lets the global error hooks in main.dart write into the app log.
  static VpnController? current;

  final List<Profile> profiles = [];
  final List<Subscription> subs = [];
  final List<String> logs = [];
  AppSettings settings = AppSettings();
  String? selectedId;
  ConnState state = ConnState.disconnected;

  // live stats (from the core)
  int upSpeed = 0, downSpeed = 0, upTotal = 0, downTotal = 0;
  String duration = '00:00:00';

  /// profile id -> latency ms; -1 = failed, -2 = testing
  final Map<String, int> latency = {};
  String exitIp = '';
  int tunnelDelay = 0; // ms of the last in-tunnel test, -1 = failed

  // speed test
  bool speedRunning = false;
  double speedMbps = 0; // <0 = failed
  String speedMsg = '';

  final UsageStore usage = UsageStore();
  int _prevUp = 0, _prevDown = 0;
  Timer? _usageTimer;

  // OpenVPN runs in its own engine/process
  late final ovpn.OpenVPN _ovpn = ovpn.OpenVPN(onVpnStageChanged: _onOvpnStage, onVpnStatusChanged: _onOvpnStatus);
  bool _ovpnActive = false;
  Completer<void>? _ovpnUp;

  Profile? _root;
  Profile? _active; // the leaf profile currently running
  bool _userStopped = true;
  bool _dropping = false;
  int _gen = 0;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _health;
  int _failStreak = 0;
  int _lastCheckDown = -1;
  Completer<void>? _up;
  Map<String, String> _hosts = {};
  final SshTunnel _ssh = SshTunnel();
  late final V2ray _v2 = V2ray(onStatusChanged: _onV2);

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  Profile? byId(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  void log(String m) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    logs.add('[$t] $m');
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    notifyListeners();
  }

  Future<void> init() async {
    current = this;
    Store.onError = log;
    profiles
      ..clear()
      ..addAll(await Store.loadProfiles());
    subs
      ..clear()
      ..addAll(await Store.loadSubs());
    _hosts = await Store.loadHosts();
    settings = await Store.loadSettings();
    selectedId = await Store.loadSelected() ?? (profiles.isNotEmpty ? profiles.first.id : null);
    if (selected == null && profiles.isNotEmpty) selectedId = profiles.first.id;
    try {
      await _v2.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
      // A previous run may have left the VPN service up without its Dart-side
      // SSH tunnel (activity destroyed). Never show "disconnected" over a live
      // but dead tunnel: start clean.
      await _v2.stopV2Ray();
    } catch (e) {
      log('Core init failed: $e');
    }
    try {
      await _ovpn.initialize(
        localizedDescription: 'XRay Vpn',
        lastStage: (ovpn.VPNStage s) {
          // OpenVPN lives in its own process; clean up a tunnel we no longer control.
          if (_root == null && (s.isConnected || s.isConnecting)) unawaited(_ovpn.disconnect());
        },
      );
    } catch (e) {
      log('OpenVPN engine init failed: $e');
    }
    try {
      await Permission.notification.request(); // Android 13+: foreground notification
    } catch (_) {}
    await usage.load();
    _usageTimer = Timer.periodic(const Duration(seconds: 60), (_) => usage.save());
    notifyListeners();
    if (settings.autoUpdateSubs) await _autoUpdateSubs();
    if (settings.autoConnect && selected != null) {
      unawaited(connect());
    }
  }

  // ---------- profiles & settings ----------
  Future<void> upsert(Profile p) async {
    final i = profiles.indexWhere((e) => e.id == p.id);
    i >= 0 ? profiles[i] = p : profiles.add(p);
    selectedId ??= p.id;
    await _persist();
  }

  Future<void> _persist() async {
    await Store.saveProfiles(profiles);
    await Store.saveSelected(selectedId);
    notifyListeners();
  }

  void _pruneGroups() {
    final ids = profiles.map((e) => e.id).toSet();
    for (final g in profiles.where((e) => e.type == ProfileType.group)) {
      final m = g.members.where(ids.contains).toList();
      g.data['members'] = m;
    }
    if (selectedId != null && !ids.contains(selectedId)) {
      selectedId = profiles.isNotEmpty ? profiles.first.id : null;
    }
  }

  Future<void> remove(String id) async {
    profiles.removeWhere((e) => e.id == id);
    latency.remove(id);
    _pruneGroups();
    await _persist();
  }

  Future<void> select(String id) async {
    selectedId = id;
    await Store.saveSelected(id);
    notifyListeners();
  }

  Future<void> saveSettings(AppSettings s) async {
    settings = s;
    await Store.saveSettings(s);
    notifyListeners();
  }

  Future<void> resetPinnedKey(Profile p) async {
    _hosts.remove(p.hostKey);
    await Store.saveHosts(_hosts);
    log('Pinned host key cleared for ${p.hostKey}');
  }

  bool hasPinnedKey(Profile p) => _hosts.containsKey(p.hostKey);

  Future<void> clearAllPinnedKeys() async {
    _hosts.clear();
    await Store.saveHosts(_hosts);
    notifyListeners();
  }

  // ---------- subscriptions ----------
  Future<int> addSubscription(String name, String url) async {
    final u = url.trim();
    final host = Uri.tryParse(u)?.host ?? '';
    final sub = Subscription(id: newId(), name: name.trim().isEmpty ? host : name.trim(), url: u);
    final n = await _syncSub(sub);
    subs.add(sub);
    await Store.saveSubs(subs);
    notifyListeners();
    return n;
  }

  Future<int> updateSubscription(String id) async {
    final sub = subs.firstWhere((s) => s.id == id);
    final n = await _syncSub(sub);
    await Store.saveSubs(subs);
    notifyListeners();
    return n;
  }

  Future<void> removeSubscription(String id, {bool withProfiles = true}) async {
    subs.removeWhere((s) => s.id == id);
    if (withProfiles) {
      profiles.removeWhere((p) => p.subId == id);
      _pruneGroups();
    }
    await Store.saveSubs(subs);
    await _persist();
  }

  Future<int> _syncSub(Subscription sub) async {
    final body = await fetchSubscription(sub.url);
    final links = parseSubscriptionBody(body);
    if (links.isEmpty) throw 'No supported links found in the subscription';
    final wasSelected = selected;
    final keepName = wasSelected != null && wasSelected.subId == sub.id ? wasSelected.name : null;
    profiles.removeWhere((p) => p.subId == sub.id);
    final added = <Profile>[];
    for (final l in links) {
      final p = importProfile(l, id: newId());
      if (p == null) continue;
      p.data['sub'] = sub.id;
      added.add(p);
    }
    profiles.addAll(added);
    _pruneGroups();
    if (keepName != null) {
      final same = added.where((p) => p.name == keepName);
      if (same.isNotEmpty) selectedId = same.first.id;
    }
    if (selected == null && added.isNotEmpty) selectedId = added.first.id;
    sub.updated = DateTime.now().millisecondsSinceEpoch;
    await Store.saveProfiles(profiles);
    await Store.saveSelected(selectedId);
    return added.length;
  }

  Future<void> clearUsage() async {
    await usage.clear();
    notifyListeners();
  }

  Future<void> _autoUpdateSubs() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in List<Subscription>.of(subs)) {
      if (state != ConnState.disconnected) return;
      if (now - s.updated < 24 * 3600 * 1000) continue;
      try {
        final n = await updateSubscription(s.id);
        log('Subscription "${s.name}" refreshed: $n servers');
      } catch (e) {
        log('Subscription "${s.name}" refresh failed: $e');
      }
    }
  }

  /// Lowest tested latency first; untested / failed profiles go last.
  Future<void> sortProfilesByLatency() async {
    int v(Profile p) {
      final m = latency[p.id] ?? -1;
      return m > 0 ? m : (m == -3 ? 1 << 29 : 1 << 30);
    }

    profiles.sort((a, b) => v(a).compareTo(v(b)));
    await _persist();
  }

  // ---------- backup ----------
  String exportAll() => const JsonEncoder.withIndent('  ').convert({
        'app': 'xray-vpn',
        'version': 1,
        'settings': settings.toJson(),
        'profiles': profiles.map((e) => e.toJson()).toList(),
        'subscriptions': subs.map((e) => e.toJson()).toList(),
      });

  /// Merges a backup made by [exportAll]. Returns the number of profiles read.
  Future<int> importAll(String text) async {
    final j = jsonDecode(text.trim());
    if (j is! Map || j['app'] != 'xray-vpn') throw 'Not an XRay Vpn backup';
    var n = 0;
    for (final e in (j['profiles'] as List? ?? const [])) {
      final p = Profile.fromJson(Map<String, dynamic>.from(e as Map));
      final i = profiles.indexWhere((x) => x.id == p.id);
      i >= 0 ? profiles[i] = p : profiles.add(p);
      n++;
    }
    for (final e in (j['subscriptions'] as List? ?? const [])) {
      final s = Subscription.fromJson(Map<String, dynamic>.from(e as Map));
      if (!subs.any((x) => x.id == s.id)) subs.add(s);
    }
    if (j['settings'] is Map) {
      settings = AppSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map));
      await Store.saveSettings(settings);
    }
    selectedId ??= profiles.isNotEmpty ? profiles.first.id : null;
    await Store.saveSubs(subs);
    await _persist();
    return n;
  }

  // ---------- latency / diagnostics ----------
  List<Profile> _leaves(Profile root) => root.type == ProfileType.group
      ? [
          for (final id in root.members)
            ...profiles.where((p) => p.id == id && p.type != ProfileType.group)
        ]
      : [root];

  Future<int> _measure(Profile p) async {
    try {
      switch (p.type) {
        case ProfileType.ssh:
          final proxy = p.s('proxyHost').trim();
          return await tcpPing(
              proxy.isNotEmpty ? proxy : p.s('host').trim(),
              int.tryParse(proxy.isNotEmpty ? p.s('proxyPort') : p.s('port')) ??
                  (proxy.isNotEmpty ? 8080 : 22));
        case ProfileType.v2ray:
          return await _v2.getServerDelay(config: buildXrayConfig(p, settings), url: _testUrl);
        case ProfileType.proxy:
          return await tcpPing(p.s('address').trim(),
              int.tryParse(p.s('port')) ?? (p.s('kind') == 'socks5' ? 1080 : 8080));
        case ProfileType.wireguard:
          return await _v2.getServerDelay(
              config: buildWireguardConfig(p.s('config'), settings), url: _testUrl);
        case ProfileType.openvpn:
          final r = parseOvpnRemote(p.s('config'));
          if (r == null) return -1;
          if (r.proto == 'udp') return -3; // UDP cannot be probed with a TCP connect
          return await tcpPing(r.host, r.port);
        case ProfileType.chain:
          final e = byId(p.s('entry')), x = byId(p.s('exit'));
          if (e == null || x == null) return -1;
          return await _v2.getServerDelay(config: buildChainConfig(e, x, settings), url: _testUrl);
        case ProfileType.group:
          var best = -1;
          for (final l in _leaves(p)) {
            final m = await _measure(l);
            if (m > 0 && (best < 0 || m < best)) best = m;
          }
          return best;
      }
    } catch (_) {
      return -1;
    }
  }

  Future<void> ping(Profile p) async {
    if (state != ConnState.disconnected) return;
    latency[p.id] = -2;
    notifyListeners();
    final ms = await _measure(p);
    latency[p.id] = ms == -3 ? -3 : (ms <= 0 ? -1 : ms);
    notifyListeners();
  }

  bool pinging = false;

  Future<void> pingAll() async {
    if (pinging) return;
    pinging = true;
    notifyListeners();
    try {
      for (final p in List<Profile>.of(profiles)) {
        if (state != ConnState.disconnected) return;
        await ping(p);
      }
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  /// Tests every server, selects the one with the lowest latency, connects.
  Future<void> connectFastest() async {
    if (state != ConnState.disconnected || pinging) return;
    await pingAll();
    Profile? best;
    var bestMs = 1 << 30;
    for (final p in profiles) {
      final m = latency[p.id] ?? -1;
      if (p.type != ProfileType.group && m > 0 && m < bestMs) {
        best = p;
        bestMs = m;
      }
    }
    if (best == null) {
      log('Connect fastest: no server answered the latency test');
      return;
    }
    log('Fastest server: ${best.name} ($bestMs ms)');
    await select(best.id);
    await connect();
  }

  /// Re-orders a failover group so the lowest-latency server is tried first.
  Future<void> sortGroupByLatency(Profile g) async {
    final leaves = _leaves(g);
    for (final l in leaves) {
      await ping(l);
    }
    final ids = leaves.map((e) => e.id).toList()
      ..sort((a, b) {
        int v(String id) {
          final m = latency[id] ?? -1;
          return m <= 0 ? 1 << 30 : m;
        }

        return v(a).compareTo(v(b));
      });
    g.data['members'] = ids;
    await _persist();
  }

  /// Real HTTPS request through the running tunnel.
  Future<void> testTunnel() async {
    if (state != ConnState.connected) return;
    tunnelDelay = 0;
    notifyListeners();
    try {
      final int ms;
      if (_active?.type == ProfileType.openvpn) {
        ms = await _httpProbe();
      } else if (_active?.type == ProfileType.ssh && settings.proxyOnly) {
        final sw = Stopwatch()..start();
        await _ssh.httpGet('cp.cloudflare.com', '/generate_204');
        ms = sw.elapsedMilliseconds;
      } else {
        ms = await _v2.getConnectedServerDelay(url: _testUrl);
      }
      tunnelDelay = ms <= 0 ? -1 : ms;
    } catch (_) {
      tunnelDelay = -1;
    }
    notifyListeners();
  }

  /// Plain HTTPS request timing (used where the Xray delay test does not apply).
  Future<int> _httpProbe() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final sw = Stopwatch()..start();
    try {
      final req = await c.getUrl(Uri.parse(_testUrl));
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      c.close(force: true);
    }
  }

  /// Downloads [AppSettings.speedUrl] through the tunnel for up to 10 s.
  Future<void> runSpeedTest() async {
    if (state != ConnState.connected || speedRunning) return;
    speedRunning = true;
    speedMbps = 0;
    speedMsg = '';
    notifyListeners();
    try {
      final uri = Uri.parse(settings.speedUrl.trim());
      final sw = Stopwatch()..start();
      var bytes = 0;
      if (_active?.type == ProfileType.ssh) {
        if (uri.scheme != 'http') throw 'SSH mode needs an http:// speed-test URL';
        final path = uri.path.isEmpty ? '/' : uri.path + (uri.hasQuery ? '?${uri.query}' : '');
        bytes = await _ssh.httpDownload(uri.host, uri.hasPort ? uri.port : 80, path);
      } else {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        try {
          final req = await c.getUrl(uri);
          final res = await req.close().timeout(const Duration(seconds: 10));
          if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
          await for (final d in res) {
            bytes += d.length;
            if (bytes >= 30 * 1024 * 1024 || sw.elapsed.inSeconds >= 10) break;
          }
        } finally {
          c.close(force: true);
        }
      }
      sw.stop();
      final secs = max(sw.elapsedMilliseconds, 1) / 1000;
      speedMbps = bytes * 8 / 1e6 / secs;
      speedMsg = '${(bytes / 1048576).toStringAsFixed(1)} MB in ${secs.toStringAsFixed(1)} s';
    } catch (e) {
      speedMbps = -1;
      speedMsg = '$e';
    } finally {
      speedRunning = false;
      notifyListeners();
    }
  }

  Future<void> checkIp() async {
    if (state != ConnState.connected) return;
    exitIp = '…';
    notifyListeners();
    try {
      String body;
      if (_active?.type == ProfileType.ssh) {
        // This app is excluded from the VPN in SSH mode, so ask through SSH.
        body = await _ssh.httpGet('api.ipify.org', '/');
      } else {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        try {
          final req = await c.getUrl(Uri.parse('https://api.ipify.org'));
          final res = await req.close().timeout(const Duration(seconds: 8));
          body = await utf8.decodeStream(res);
        } finally {
          c.close(force: true);
        }
      }
      final ip = body.trim();
      exitIp = RegExp(r'^[0-9a-fA-F:.]{3,45}$').hasMatch(ip) ? ip : 'unavailable';
    } catch (e) {
      exitIp = 'unavailable';
    }
    notifyListeners();
  }

  Future<String> coreVersion() async {
    try {
      return await _v2.getCoreVersion();
    } catch (_) {
      return 'unknown';
    }
  }

  Future<List<String>> coreLogs() async {
    try {
      return await _v2.getLogs();
    } catch (_) {
      return const [];
    }
  }

  // ---------- core status ----------
  void _onV2(V2RayStatus st) {
    if (_root == null) return;
    upSpeed = st.uploadSpeed;
    downSpeed = st.downloadSpeed;
    upTotal = st.upload;
    downTotal = st.download;
    duration = st.duration;
    _account(st.upload, st.download);
    _pushHistory();
    switch (st.state.toString().toUpperCase()) {
      case 'CONNECTED':
        if (state != ConnState.connected) {
          state = ConnState.connected;
          _retries = 0;
          log('Tunnel up');
          _startHealth();
        }
        final u = _up;
        if (u != null && !u.isCompleted) u.complete();
        break;
      case 'CONNECTING':
        if (state != ConnState.connected) state = ConnState.connecting;
        break;
      case 'DISCONNECTED':
        if (state == ConnState.connected && !_userStopped) {
          unawaited(_dropped());
          return;
        }
        break;
    }
    notifyListeners();
  }

  /// Adds the growth since the last status update to the usage log.
  void _account(int up, int down) {
    final name = _root?.name;
    if (name == null) return;
    usage.add(name, up >= _prevUp ? up - _prevUp : up, down >= _prevDown ? down - _prevDown : down);
    _prevUp = up;
    _prevDown = down;
  }

  // ---------- OpenVPN callbacks ----------
  void _onOvpnStage(ovpn.VPNStage stage, String raw) {
    if (_root == null || !_ovpnActive) return;
    final r = raw.toLowerCase();
    final stageName = stage.toString().split('.').last.toLowerCase();
    final failed = RegExp(
      r'auth_failed|auth-failed|authentication failed|denied|error|failed|failure',
    ).hasMatch('$stageName $r');
    if (stage.isConnected) {
      if (state != ConnState.connected) {
        state = ConnState.connected;
        _retries = 0;
        log('OpenVPN connected');
      }
      final u = _ovpnUp;
      if (u != null && !u.isCompleted) u.complete();
    } else if (failed) {
      final why = RegExp(
        r'auth_failed|auth-failed|authentication failed',
      ).hasMatch('$stageName $r')
          ? 'OpenVPN authentication failed (check username / password / certificate)'
          : RegExp(r'denied').hasMatch('$stageName $r')
              ? 'VPN permission denied'
              : 'OpenVPN error: ${raw.isEmpty ? stageName : raw}';
      final u = _ovpnUp;
      if (u != null && !u.isCompleted) {
        u.completeError(why);
      } else if (state == ConnState.connected && !_userStopped) {
        log(why);
        unawaited(_dropped());
      }
    } else if (stage.isDisconnected) {
      if (state == ConnState.connected && !_userStopped) unawaited(_dropped());
    } else if (stage.isConnecting) {
      if (state != ConnState.connected) state = ConnState.connecting;
    }
    notifyListeners();
  }

  void _onOvpnStatus(ovpn.VpnStatus? s) {
    if (s == null || _root == null || !_ovpnActive) return;
    final up = int.tryParse('${s.byteOut}') ?? 0;
    final down = int.tryParse('${s.byteIn}') ?? 0;
    upTotal = up;
    downTotal = down;
    upSpeed = int.tryParse('${s.speedOut}') ?? 0;
    downSpeed = int.tryParse('${s.speedIn}') ?? 0;
    duration = '${s.duration ?? '00:00:00'}';
    _account(up, down);
    _pushHistory();
    notifyListeners();
  }

  void _resetStats() {
    upHistory.clear();
    downHistory.clear();
    _prevUp = _prevDown = 0;
    speedMbps = 0;
    speedMsg = '';
    upSpeed = downSpeed = upTotal = downTotal = 0;
    duration = '00:00:00';
    exitIp = '';
    tunnelDelay = 0;
    _failStreak = 0;
    _lastCheckDown = -1;
  }

  // ---------- connect / disconnect ----------
  Future<void> connect() async {
    final p = selected;
    if (p == null || state != ConnState.disconnected) return;
    _root = p;
    _userStopped = false;
    _retries = 0;
    _gen++;
    _resetStats();
    bumpRotation();
    await _run(_gen);
  }

  Future<void> disconnect() async {
    _userStopped = true;
    _gen++;
    _retryTimer?.cancel();
    _health?.cancel();
    log('Disconnecting');
    await _stopCore();
    unawaited(usage.save());
    _root = null;
    _active = null;
    state = ConnState.disconnected;
    _resetStats();
    notifyListeners();
  }

  Future<void> _run(int gen) async {
    final root = _root;
    if (root == null || gen != _gen) return;
    state = ConnState.connecting;
    log('Connecting: ${root.name} (${typeLabel(root.type)})');
    try {
      final leaves = _leaves(root);
      if (leaves.isEmpty) throw 'Group has no servers';
      Object? last;
      for (final leaf in leaves) {
        if (_userStopped || gen != _gen) return;
        try {
          if (leaves.length > 1) log('Trying ${leaf.name}');
          await _start(leaf);
          if (gen != _gen) return;
          _active = leaf;
          return;
        } catch (e) {
          last = e;
          if (_userStopped || gen != _gen) return;
          log('${leaf.name} failed: $e');
          await _stopCore();
        }
      }
      throw last ?? 'Connection failed';
    } catch (e) {
      if (_userStopped || gen != _gen) return;
      log('Error: $e');
      await _retryOrStop();
    }
  }

  Future<void> _retryOrStop() async {
    if (_userStopped) return;
    if (settings.autoReconnect && _retries < settings.reconnectMax) {
      _retries++;
      final wait = min(2 << _retries, 30);
      log('Reconnecting in ${wait}s (attempt $_retries/${settings.reconnectMax})');
      state = ConnState.connecting;
      notifyListeners();
      final gen = _gen;
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(seconds: wait), () {
        if (!_userStopped && gen == _gen) unawaited(_run(gen));
      });
    } else {
      await _stopCore();
      _root = null;
      _active = null;
      state = ConnState.disconnected;
      _resetStats();
      notifyListeners();
    }
  }

  Future<void> _dropped() async {
    if (_dropping || _userStopped) return;
    _dropping = true;
    try {
      log('Connection lost');
      _health?.cancel();
      await _stopCore();
      await _retryOrStop();
    } finally {
      _dropping = false;
    }
  }

  /// Periodic liveness check: catches tunnels that are "connected" but dead
  /// (network switch, server restart) which the core never reports.
  void _startHealth() {
    _health?.cancel();
    _failStreak = 0;
    if (!settings.healthCheck) return;
    _health = Timer.periodic(const Duration(seconds: 45), (_) async {
      if (state != ConnState.connected || _userStopped || _dropping) return;
      if (_active?.type == ProfileType.openvpn) return; // the engine has its own keepalive
      if (_active?.type == ProfileType.ssh && !_ssh.alive) {
        unawaited(_dropped());
        return;
      }
      if (_active?.type == ProfileType.ssh && settings.proxyOnly) return; // alive-check above is enough
      // Bytes still arriving means the tunnel is alive; no need to probe.
      if (_lastCheckDown >= 0 && downTotal > _lastCheckDown) {
        _lastCheckDown = downTotal;
        _failStreak = 0;
        return;
      }
      _lastCheckDown = downTotal;
      var ok = false;
      try {
        ok = (await _v2.getConnectedServerDelay(url: _testUrl)) > 0;
      } catch (_) {}
      _failStreak = ok ? 0 : _failStreak + 1;
      if (_failStreak >= 3) {
        log('Health check failed 3 times, reconnecting');
        unawaited(_dropped());
      }
    });
  }

  Future<void> _stopCore() async {
    _proxyTimer?.cancel();
    final u = _up;
    _up = null;
    if (u != null && !u.isCompleted) u.completeError('stopped');
    if (_ovpnActive) {
      _ovpnActive = false;
      final ou = _ovpnUp;
      _ovpnUp = null;
      if (ou != null && !ou.isCompleted) ou.completeError('stopped');
      try {
        await _ovpn.disconnect();
      } catch (_) {}
    }
    try {
      await _ssh.stop();
    } catch (_) {}
    try {
      await _v2.stopV2Ray();
    } catch (_) {}
  }

  Future<void> _start(Profile p) async {
    switch (p.type) {
      case ProfileType.ssh:
        return _startSsh(p);
      case ProfileType.v2ray:
        return _launch(p.name, buildXrayConfig(p, settings), ssh: false);
      case ProfileType.proxy:
        return _launch(p.name, buildProxyConfig(p, settings), ssh: false);
      case ProfileType.wireguard:
        return _launch(p.name, buildWireguardConfig(p.s('config'), settings), ssh: false);
      case ProfileType.openvpn:
        return _startOpenVpn(p);
      case ProfileType.chain:
        final e = byId(p.s('entry')), x = byId(p.s('exit'));
        if (e == null || x == null) throw 'Chain needs an entry and an exit server';
        return _launch(p.name, buildChainConfig(e, x, settings), ssh: false);
      case ProfileType.group:
        throw 'Nested groups are not supported';
    }
  }

  Future<void> _startOpenVpn(Profile p) async {
    var cfg = p.s('config');
    if (cfg.trim().isEmpty) throw 'The OpenVPN config is empty';
    if (p.b('singleRemote')) cfg = await ovpn.OpenVPN.filteredConfig(cfg) ?? cfg;
    final up = Completer<void>();
    unawaited(up.future.catchError((Object _) {}));
    _ovpnUp = up;
    _ovpnActive = true;
    final user = p.s('user'), pass = p.s('pass'), kp = p.s('keyPass');
    final bool started;
    try {
      started = await _ovpn.connect(
        cfg,
        p.name,
        username: user.isEmpty ? null : user,
        password: pass.isEmpty ? null : pass,
        privateKeyPassword: kp.isEmpty ? null : kp,
        bypassPackages: settings.blockedApps.isEmpty ? null : settings.blockedApps,
      );
    } catch (e) {
      _ovpnActive = false;
      throw 'OpenVPN: $e';
    }
    if (!started) {
      _ovpnActive = false;
      throw 'VPN permission denied';
    }
    await up.future.timeout(const Duration(seconds: 45),
        onTimeout: () => throw 'OpenVPN did not connect within 45s');
  }

  Future<bool> Function(String, Uint8List) _verifier(Profile p) => (type, fp) async {
        final hex = fp.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
        final seen = '$type $hex';
        final known = _hosts[p.hostKey];
        if (known == null) {
          _hosts[p.hostKey] = seen;
          await Store.saveHosts(_hosts);
          log('Pinned SSH host key for ${p.hostKey}: $seen');
          return true;
        }
        if (known == seen) return true;
        log('SSH HOST KEY CHANGED for ${p.hostKey}! Expected $known, got $seen. '
            'Refusing to connect. If the server was reinstalled, edit the profile and '
            'tap "Forget pinned host key".');
        return false;
      };

  /// SSH connection options for a profile ([pin] = enforce host-key pinning).
  SshOptions optionsFor(Profile p, {bool pin = true}) => SshOptions(
        host: p.s('host').trim(),
        port: int.tryParse(p.s('port')) ?? 22,
        user: p.s('user').trim(),
        pass: p.s('pass'),
        keyPem: p.s('keyPem'),
        keyPass: p.s('keyPass'),
        payload: p.s('payload'),
        proxyHost: p.s('proxyHost').trim(),
        proxyPort: int.tryParse(p.s('proxyPort')) ?? 8080,
        proxyType: p.s('proxyType') == 'socks5' ? 'socks5' : 'http',
        proxyUser: p.s('proxyUser'),
        proxyPass: p.s('proxyPass'),
        useTls: p.b('tls'),
        sni: p.s('sni').trim(),
        allowInsecure: p.data['allowInsecure'] != false,
        wsFraming: p.b('ws'),
        keepAlive: settings.sshKeepalive,
        udpgwPort: (int.tryParse(p.s('udpgwPort')) ?? 0).clamp(0, 65535).toInt(),
        shareHotspot: settings.shareHotspot,
        hotspotUser: settings.hotspotUser,
        hotspotPass: settings.hotspotPass,
        verifyHostKey: pin && p.data['pinHostKey'] != false ? _verifier(p) : null,
      );

  /// "Test connection" in the SSH editor: transport + payload + SSH banner.
  Future<String> testSshProfile(Profile p) => testTransport(optionsFor(p, pin: false));

  Future<void> _startSsh(Profile p) async {
    final opts = optionsFor(p);
    if (opts.host.isEmpty || opts.user.isEmpty) throw 'Host and username are required';
    if (opts.shareHotspot && opts.hotspotUser.isEmpty) {
      log('Hotspot sharing is ON without a username/password: anyone on the hotspot can use this tunnel');
    }

    _ssh.onClosed = () {
      if (!_userStopped && state == ConnState.connected) unawaited(_dropped());
    };
    final port = await _ssh.start(opts, log, socksPort: settings.socksPort);
    if (settings.proxyOnly) {
      // Proxy mode: no VPN service and no Xray core, just the SSH-backed SOCKS5 server.
      state = ConnState.connected;
      _retries = 0;
      _proxyStarted = DateTime.now();
      log('Proxy mode: SOCKS5 on ${settings.shareHotspot ? '0.0.0.0' : '127.0.0.1'}:$port');
      _startProxyStats();
      _startHealth();
      notifyListeners();
      return;
    }
    await _launch(p.name, buildSocksConfig(port, settings), ssh: true);
  }

  // ---------- proxy-only mode (no VPN) ----------
  Timer? _proxyTimer;
  DateTime? _proxyStarted;
  int _pu = 0, _pd = 0;

  /// "SOCKS5 127.0.0.1:10808" while connected in proxy mode, else ''.
  String get proxyEndpoint => state == ConnState.connected && settings.proxyOnly
      ? 'SOCKS5 ${settings.shareHotspot ? '0.0.0.0' : '127.0.0.1'}:${settings.socksPort}'
      : '';

  void _startProxyStats() {
    _proxyTimer?.cancel();
    _pu = _ssh.txBytes;
    _pd = _ssh.rxBytes;
    _proxyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state != ConnState.connected) return;
      final up = _ssh.txBytes, down = _ssh.rxBytes;
      upSpeed = max(0, up - _pu);
      downSpeed = max(0, down - _pd);
      _pu = up;
      _pd = down;
      upTotal = up;
      downTotal = down;
      final d = DateTime.now().difference(_proxyStarted ?? DateTime.now());
      String two(int v) => v.toString().padLeft(2, '0');
      duration = '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
      _account(up, down);
      _pushHistory();
      notifyListeners();
    });
  }

  // ---------- throughput history (real samples, for the live chart) ----------
  final List<int> upHistory = [];
  final List<int> downHistory = [];

  void _pushHistory() {
    upHistory.add(upSpeed);
    downHistory.add(downSpeed);
    if (upHistory.length > 60) upHistory.removeAt(0);
    if (downHistory.length > 60) downHistory.removeAt(0);
  }

  Future<void> _launch(String remark, String config, {required bool ssh}) async {
    final up = Completer<void>();
    unawaited(up.future.catchError((Object _) {}));
    _up = up;
    try {
      if (!settings.proxyOnly && !await _v2.requestPermission()) {
        throw 'VPN permission denied';
      }
      // In SSH mode our own sockets (the SSH connection itself) must NOT be routed
      // into the VPN, or the tunnel would loop into itself.
      final apps =
          <String>{...settings.blockedApps, if (ssh) Native.ownPackage}.toList();
      await _v2.startV2Ray(
        remark: remark,
        config: config,
        blockedApps: apps.isEmpty ? null : apps,
        bypassSubnets: settings.bypassLan ? lanBypassSubnets : null,
        proxyOnly: settings.proxyOnly,
      );
      try {
        await up.future.timeout(const Duration(seconds: 25));
      } on TimeoutException {
        log('Core did not report a connected state within 25 seconds; '
            'collecting core diagnostics');
        final diagnosticLogs = await coreLogs();
        if (diagnosticLogs.isEmpty) {
          log('Core diagnostics are empty or unavailable');
        } else {
          final start = diagnosticLogs.length > 80
              ? diagnosticLogs.length - 80
              : 0;
          for (final line in diagnosticLogs.skip(start)) {
            log('Core: $line');
          }
        }
        throw 'Tunnel did not come up within 25s (see core log entries above)';
      }
    } finally {
      if (identical(_up, up)) _up = null;
    }
  }

  @override
  void dispose() {
    _usageTimer?.cancel();
    _retryTimer?.cancel();
    _health?.cancel();
    super.dispose();
  }
}
