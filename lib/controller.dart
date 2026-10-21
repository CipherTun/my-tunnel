import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';

import 'core_config.dart';
import 'models.dart';
import 'ssh_tunnel.dart';
import 'singbox_config.dart';

enum ConnState { disconnected, connecting, connected }

class VpnController extends ChangeNotifier {
  final List<Profile> profiles = [];
  final List<String> logs = [];
  AppSettings settings = AppSettings();
  String? selectedId;
  ConnState state = ConnState.disconnected;

  Profile? _root;
  bool _userStopped = true;
  int _retries = 0;
  Timer? _retryTimer;
  Completer<void>? _up;
  final SshTunnel _ssh = SshTunnel();
  late final V2ray _v2 = V2ray(onStatusChanged: _onV2);
  final SingboxClient _singbox = SingboxClient();
  StreamSubscription<dynamic>? _singboxStateSub;

  Profile? get selected {
    for (final p in profiles) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  void log(String m) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    logs.add('[$t] $m');
    if (logs.length > 400) logs.removeRange(0, logs.length - 400);
    notifyListeners();
  }

  Future<void> init() async {
    profiles
      ..clear()
      ..addAll(await Store.loadProfiles());
    settings = await Store.loadSettings();
    selectedId = await Store.loadSelected() ??
        (profiles.isNotEmpty ? profiles.first.id : null);
    try {
      await _v2.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
    } catch (e) {
      log('Xray core init failed: $e');
    }
    try {
      await _singbox.initialize();
      _singboxStateSub ??= _singbox.serviceStateStream.listen((dynamic event) {
        final value = event.toString().toLowerCase();
        if ((value.contains('stopped') || value.contains('disconnected') || value.contains('failed')) &&
            state == ConnState.connected && !_userStopped) {
          // Move out of CONNECTED before stopping so the stop event cannot
          // recursively trigger another drop handler.
          state = ConnState.connecting;
          _dropped();
        }
      }, onError: (Object error) {
        log('sing-box status stream error: $error');
      });
      log('Independent sing-box engine initialized');
    } catch (e) {
      log('sing-box core init failed: $e');
    }
    notifyListeners();
  }

  // ---------- profiles & settings ----------
  Future<void> upsert(Profile p) async {
    final i = profiles.indexWhere((e) => e.id == p.id);
    i >= 0 ? profiles[i] = p : profiles.add(p);
    selectedId ??= p.id;
    await Store.saveProfiles(profiles);
    await Store.saveSelected(selectedId);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    // Do not leave a running tunnel attached to a profile that was deleted.
    final active = _root;
    if (state != ConnState.disconnected &&
        (active?.id == id || active?.members.contains(id) == true)) {
      await disconnect();
    }
    profiles.removeWhere((e) => e.id == id);
    for (final g in profiles.where((e) => e.type == ProfileType.group)) {
      (g.data['members'] as List?)?.remove(id);
    }
    if (selectedId == id) selectedId = profiles.isNotEmpty ? profiles.first.id : null;
    await Store.saveProfiles(profiles);
    await Store.saveSelected(selectedId);
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (!profiles.any((p) => p.id == id)) {
      throw ArgumentError.value(id, 'id', 'Profile does not exist');
    }
    selectedId = id;
    await Store.saveSelected(id);
    notifyListeners();
  }

  Future<void> saveSettings(AppSettings s) async {
    settings = s;
    await Store.saveSettings(s);
    notifyListeners();
  }

  // ---------- core status ----------
  void _onV2(V2RayStatus st) {
    if (_root == null) return;
    switch (st.state.toString().toUpperCase()) {
      case 'CONNECTED':
        state = ConnState.connected;
        _retries = 0;
        final u = _up;
        if (u != null && !u.isCompleted) u.complete();
        log('Tunnel up');
        break;
      case 'CONNECTING':
        if (state != ConnState.connected) state = ConnState.connecting;
        break;
      case 'DISCONNECTED':
        if (state == ConnState.connected && !_userStopped) {
          _dropped();
          return;
        }
        break;
    }
    notifyListeners();
  }

  // ---------- connect / disconnect ----------
  Future<void> connect() async {
    final p = selected;
    if (p == null || state != ConnState.disconnected) return;
    _root = p;
    _userStopped = false;
    _retries = 0;
    bumpRotation();
    await _run();
  }

  Future<void> disconnect() async {
    _userStopped = true;
    _retryTimer?.cancel();
    log('Disconnecting');
    await _stopCore();
    _root = null;
    state = ConnState.disconnected;
    notifyListeners();
  }

  Future<void> _run() async {
    final root = _root;
    if (root == null) return;
    state = ConnState.connecting;
    log('Connecting: ${root.name} (${typeLabel(root.type)})');
    try {
      final leaves = root.type == ProfileType.group
          ? [
              for (final id in root.members)
                ...profiles.where((p) => p.id == id && p.type != ProfileType.group)
            ]
          : [root];
      if (leaves.isEmpty) throw 'Group has no servers';
      Object? last;
      for (final leaf in leaves) {
        if (_userStopped) return;
        try {
          if (leaves.length > 1) log('Trying ${leaf.name}');
          await _start(leaf);
          return;
        } catch (e) {
          last = e;
          log('${leaf.name} failed: $e');
          await _stopCore();
        }
      }
      throw last ?? 'Connection failed';
    } catch (e) {
      log('Error: $e');
      if (!_userStopped) await _retryOrStop();
    }
  }

  Future<void> _retryOrStop() async {
    if (settings.autoReconnect && _retries < settings.reconnectMax) {
      _retries++;
      final wait = min(2 << _retries, 30);
      log('Reconnecting in ${wait}s (attempt $_retries/${settings.reconnectMax})');
      state = ConnState.connecting;
      notifyListeners();
      _retryTimer = Timer(Duration(seconds: wait), () {
        if (!_userStopped) _run();
      });
    } else {
      await _stopCore();
      _root = null;
      state = ConnState.disconnected;
      notifyListeners();
    }
  }

  Future<void> _dropped() async {
    log('Connection lost');
    await _stopCore();
    await _retryOrStop();
  }

  Future<void> _stopCore() async {
    _up = null;
    try {
      await _ssh.stop();
    } catch (_) {}
    try {
      await _v2.stopV2Ray();
    } catch (_) {}
    try {
      await _singbox.disconnect();
    } catch (_) {}
  }

  Future<void> _start(Profile p) async {
    // SSH payload mode retains the existing SSH transport and routes its local
    // SOCKS listener through Xray. Standard links can use either independent core.
    if (settings.coreEngine == 'singbox' && p.type != ProfileType.ssh) {
      return _launchSingbox(p);
    }
    switch (p.type) {
      case ProfileType.ssh:
        return _startSsh(p);
      case ProfileType.v2ray:
        return _launch(p.name, buildXrayConfig(p, settings));
      case ProfileType.wireguard:
        return _launch(p.name, buildWireguardConfig(p.s('config'), settings));
      case ProfileType.group:
        throw 'Nested groups are not supported';
    }
  }

  Future<void> _launchSingbox(Profile p) async {
    state = ConnState.connecting;
    notifyListeners();
    final config = buildSingboxConfig(p, settings);
    if (!await _singbox.requestVPNPermission()) throw 'VPN permission denied';
    await _singbox.checkConfig(config);
    await _singbox.connect(SessionOptions(
      config: config,
      networkMode: NetworkMode.vpn,
      notification: NotificationConfig(
        title: 'XRay Vpn',
        showTrafficStats: true,
        showStopButton: true,
        stopButtonLabel: 'Disconnect',
      ),
    ));
    if (_userStopped) {
      await _singbox.disconnect();
      return;
    }
    state = ConnState.connected;
    _retries = 0;
    log('sing-box tunnel started: ${p.name}');
    notifyListeners();
  }

  Future<void> _startSsh(Profile p) async {
    final opts = SshOptions(
      host: p.s('host').trim(),
      port: int.tryParse(p.s('port')) ?? 22,
      user: p.s('user').trim(),
      pass: p.s('pass'),
      keyPem: p.s('keyPem'),
      keyPass: p.s('keyPass'),
      payload: p.s('payload'),
      proxyHost: p.s('proxyHost').trim(),
      proxyPort: int.tryParse(p.s('proxyPort')) ?? 8080,
      useTls: p.b('tls'),
      sni: p.s('sni').trim(),
      wsFraming: p.b('ws'),
      keepAlive: settings.sshKeepalive,
      shareHotspot: settings.shareHotspot,
      shareUsername: settings.shareUsername,
      sharePassword: settings.sharePassword,
    );
    if (opts.host.isEmpty || opts.user.isEmpty) throw 'Host and username are required';
    validatePort(opts.port, 'SSH port');
    if (opts.proxyHost.isNotEmpty) validatePort(opts.proxyPort, 'Proxy port');

    _ssh.onClosed = () {
      if (!_userStopped && state == ConnState.connected) _dropped();
    };
    final port = await _ssh.start(opts, log, socksPort: settings.socksPort);
    await _launch(p.name, buildSocksConfig(port, settings));
  }

  Future<void> _launch(String remark, String config) async {
    _up = Completer<void>();
    if (!await _v2.requestPermission()) throw 'VPN permission denied';
    final apps = settings.blockedApps;
    await _v2.startV2Ray(
      remark: remark,
      config: config,
      blockedApps: apps.isEmpty ? null : apps,
      bypassSubnets: settings.bypassLan ? lanBypassSubnets : null,
      proxyOnly: false,
    );
    await _up!.future.timeout(const Duration(seconds: 25),
        onTimeout: () => throw 'Tunnel did not come up within 25s');
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _singboxStateSub?.cancel();
    super.dispose();
  }
}
