import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

import 'app_info.dart';
import 'core_config.dart';
import 'models.dart';
import 'native.dart';
import 'ssh_tunnel.dart';
import 'subscriptions.dart';

enum ConnState { disconnected, connecting, connected }

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

class VpnController extends ChangeNotifier {
  final Store _store = Store();
  final SshTunnel ssh = SshTunnel();
  late final V2ray _v2 = V2ray(onStatusChanged: _onV2);

  List<Profile> profiles = [];
  List<Subscription> subs = [];
  AppSettings settings = AppSettings();
  String? selectedId;

  ConnState state = ConnState.disconnected;
  String? error;
  String activeName = '';
  String duration = '00:00:00';
  int upSpeed = 0;
  int downSpeed = 0;
  int upTotal = 0;
  int downTotal = 0;
  int? lastDelay;

  final Map<String, int> pings = {};
  bool pinging = false;
  final List<String> logs = [];

  Profile? _root;
  bool _userStopped = false;
  bool _dropping = false;
  int _gen = 0;
  int _retries = 0;
  Completer<void>? _up;
  Timer? _retryTimer;
  Timer? _watch;
  int _watchFails = 0;

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  bool get busy => state != ConnState.disconnected;

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
      log('Core init failed: ${errText(e)}');
    }
    try {
      final v = await _v2.getCoreVersion();
      log('Xray core $v');
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
    final s = Subscription(id: newId(), name: name.trim().isEmpty ? Uri.parse(url).host : name.trim(), url: url.trim());
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
        'version': 3,
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

  Future<void> pingAll() async {
    if (busy || pinging) return;
    pinging = true;
    pings.clear();
    notifyListeners();
    final targets = profiles.where((p) => p.endpoint != null).toList();
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        final p = targets[next++];
        final ep = p.endpoint!;
        pings[p.id] = await tcpPing(ep.host, ep.port);
        notifyListeners();
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
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
    duration = '00:00:00';
    upSpeed = downSpeed = upTotal = downTotal = 0;
    lastDelay = null;
    activeName = '';
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
      log('Connecting: ${leaf.name} (${leaf.typeLabel})');
      notifyListeners();
      try {
        await _start(leaf, g);
        return; // success: _onV2 flips state to connected
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
      notifyListeners();
      await _stopCore();
      await _retryOrStop(g);
    } finally {
      _dropping = false;
    }
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
        final cfg = applyNetwork(buildSocksConfig(port), settings, tcpOnly: true);
        await _launch(leaf.name, cfg, excludeSelf: true);
        break;
      case ProfileType.v2ray:
        var cfg = buildV2rayConfig(leaf);
        if (leaf.data['mode'] != 'json') cfg = applyNetwork(cfg, settings);
        await _launch(leaf.name, cfg);
        break;
      case ProfileType.wireguard:
        await _launch(leaf.name, applyNetwork(buildWireGuardConfig(leaf), settings));
        break;
      case ProfileType.group:
        throw 'Nested group';
    }
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
      keepAlive: settings.sshKeepAlive,
      socksPort: settings.socksPort,
      shareHotspot: settings.shareHotspot,
    );
  }

  Future<void> _launch(String remark, String config, {bool excludeSelf = false}) async {
    final c = Completer<void>();
    _up = c;
    if (!await _v2.requestPermission()) throw 'VPN permission was denied';
    // In SSH mode the SSH socket lives in this app. It must bypass the VPN or
    // its own traffic would be routed back into the tunnel it carries.
    final apps = <String>[...settings.blockedApps, if (excludeSelf) kAppId];
    await _v2.startV2Ray(
      remark: remark,
      config: config,
      blockedApps: apps.isEmpty ? null : apps,
      bypassSubnets: settings.bypassLan ? lanBypassSubnets : null,
      proxyOnly: false,
    );
    try {
      await c.future.timeout(const Duration(seconds: 25), onTimeout: () {
        throw 'Tunnel did not come up within 25s';
      });
    } finally {
      if (identical(_up, c)) _up = null;
    }
  }

  void _cancelWait() {
    final u = _up;
    _up = null;
    if (u != null && !u.isCompleted) u.completeError('cancelled');
  }

  Future<void> _stopCore() async {
    _cancelWait();
    try {
      await ssh.stop();
    } catch (_) {}
    try {
      await _v2.stopV2Ray();
    } catch (_) {}
  }

  void _onV2(V2RayStatus st) {
    if (_root == null) return;
    final s = st.state.toString().toUpperCase();
    if (s.contains('CONNECTED') && !s.contains('DIS')) {
      if (state != ConnState.connected) {
        state = ConnState.connected;
        _retries = 0;
        error = null;
        log('Connected');
        final u = _up;
        if (u != null && !u.isCompleted) u.complete();
        _startWatch(_gen);
      }
      duration = st.duration;
      upSpeed = st.uploadSpeed;
      downSpeed = st.downloadSpeed;
      upTotal = st.upload;
      downTotal = st.download;
      notifyListeners();
    } else if (s.contains('DISCONNECTED')) {
      if (state == ConnState.connected && !_userStopped) {
        // Stopped from the notification, or another VPN took over.
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
    }
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

  /// Round-trip through the running tunnel to the health-check URL, in ms.
  /// Returns -1 on failure.
  Future<int> connectedDelay() async {
    try {
      return await _v2.getConnectedServerDelay(url: settings.watchdogUrl);
    } catch (_) {
      return -1;
    }
  }

  Future<List<String>> coreLogs() async {
    try {
      final l = await _v2.getLogs();
      return [for (final e in l) e.toString()];
    } catch (e) {
      return ['Could not read core logs: ${errText(e)}'];
    }
  }
}
