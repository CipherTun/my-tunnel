import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'native_bridge.dart';
import 'legacy_vmess.dart';
import 'ssh_engine.dart';
import 'xray_config.dart';

enum ConnectionStateKind { disconnected, connecting, connected, disconnecting, failed }

class VpnController extends ChangeNotifier {
  VpnController({NativeVpnBridge? bridge, SecureStore? store})
      : bridge = bridge ?? NativeVpnBridge(),
        store = store ?? SecureStore() {
    _eventSubscription = this.bridge.events.listen(_onNativeEvent, onError: (Object e) => log('Native event channel error: $e'));
  }

  final NativeVpnBridge bridge;
  final SecureStore store;
  final List<ServerProfile> profiles = <ServerProfile>[];
  final List<SubscriptionSource> subscriptions = <SubscriptionSource>[];
  final List<String> logs = <String>[];
  final List<Map<String, dynamic>> usageHistory = <Map<String, dynamic>>[];
  AppPreferences preferences = AppPreferences();
  ConnectionStateKind state = ConnectionStateKind.disconnected;
  String statusMessage = 'Disconnected';
  String? selectedProfileId;
  int uploadBytes = 0;
  int downloadBytes = 0;
  int uploadSpeed = 0;
  int downloadSpeed = 0;
  DateTime? connectedAt;
  SshSessionHandle? _ssh;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  Timer? _healthTimer;
  Timer? _reconnectTimer;
  Timer? _subscriptionTimer;
  ServerProfile? _activeProfile;
  bool _sessionRecorded = false;
  bool _tryingGroup = false;
  Completer<void>? _connectionCompleter;
  int _reconnectAttempts = 0;
  bool _initialized = false;
  String? _pendingIncomingLink;

  ServerProfile? get selectedProfile {
    for (final profile in profiles) {
      if (profile.id == selectedProfileId) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  bool get isConnected => state == ConnectionStateKind.connected;
  Duration get connectedDuration => connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  Future<void> init() async {
    try {
      profiles.addAll(await store.loadProfiles());
      subscriptions.addAll(await store.loadSubscriptions());
      usageHistory.addAll(await store.loadUsageHistory());
      preferences = await store.loadPreferences();
      selectedProfileId ??= profiles.isEmpty ? null : profiles.first.id;
      log('Secure local storage loaded (${profiles.length} profiles)');
      _initialized = true;
      final initialLink = await bridge.takeInitialLink();
      final link = initialLink ?? _pendingIncomingLink;
      _pendingIncomingLink = null;
      if (link != null && link.isNotEmpty) {
        try { await importText(link); } catch (e) { log('Could not import incoming share link: $e'); }
      }
      if (preferences.autoUpdateSubscriptions && subscriptions.isNotEmpty) {
        unawaited(refreshAllSubscriptions());
        _subscriptionTimer = Timer.periodic(const Duration(hours: 12), (_) { if (preferences.autoUpdateSubscriptions) unawaited(refreshAllSubscriptions()); });
      }
      if (preferences.autoConnect && selectedProfile != null) {
        unawaited(connect(selectedProfile!));
      }
    } catch (e) {
      log('Storage initialization failed: $e');
    }
    notifyListeners();
  }

  void log(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    logs.add(line);
    if (logs.length > 1500) logs.removeRange(0, logs.length - 1500);
    notifyListeners();
  }

  Future<void> savePreferences() async {
    await store.savePreferences(preferences);
    if (preferences.autoUpdateSubscriptions && subscriptions.isNotEmpty && _subscriptionTimer == null) {
      _subscriptionTimer = Timer.periodic(const Duration(hours: 12), (_) { if (preferences.autoUpdateSubscriptions) unawaited(refreshAllSubscriptions()); });
    } else if (!preferences.autoUpdateSubscriptions) {
      _subscriptionTimer?.cancel();
      _subscriptionTimer = null;
    }
    notifyListeners();
  }

  Future<void> upsert(ServerProfile profile) async {
    final index = profiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    selectedProfileId ??= profile.id;
    await store.saveProfiles(profiles);
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (!profiles.any((profile) => profile.id == id)) return;
    selectedProfileId = id;
    await savePreferences();
    notifyListeners();
  }

  Future<void> removeProfile(String id) async {
    if (selectedProfileId == id && state != ConnectionStateKind.disconnected) await disconnect();
    profiles.removeWhere((profile) => profile.id == id);
    for (final profile in profiles.where((profile) => profile.kind == ProfileKind.group)) {
      final members = (profile.data['members'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
      members.removeWhere((memberId) => memberId == id);
      profile.data['members'] = members;
    }
    for (final profile in profiles.where((profile) => profile.kind == ProfileKind.chain)) {
      if (profile.text('entry') == id) profile.data['entry'] = '';
      if (profile.text('exit') == id) profile.data['exit'] = '';
    }
    if (selectedProfileId == id) selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
    await store.saveProfiles(profiles);
    notifyListeners();
  }

  Future<ServerProfile?> importText(String text) async {
    final direct = parseSimpleProfile(text);
    if (direct != null) {
      if (direct.kind == ProfileKind.xray) {
        direct.name = legacyVmessDisplayName(text) ?? (direct.name.length > 64 ? 'VMess server' : direct.name);
      }
      final identity = _profileIdentity(direct);
      final existingIndex = profiles.indexWhere((item) => _profileIdentity(item) == identity);
      if (existingIndex >= 0) {
        final existing = profiles[existingIndex];
        existing.name = direct.name;
        existing.data = Map<String, dynamic>.from(direct.data);
        await store.saveProfiles(profiles);
        notifyListeners();
        log('Updated existing ${existing.kind.label} profile: ${existing.name}');
        return existing;
      }
      await upsert(direct);
      log('Imported ${direct.kind.label} profile: ${direct.name}');
      return direct;
    }
    final response = await bridge.invokeLibXray('convertShareLinksToXrayJson', {'text': text.trim()});
    final data = Map<String, dynamic>.from(response['data'] as Map);
    final outbounds = data['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) throw const FormatException('No supported Xray outbound was found');
    final jsonText = jsonEncode({'outbounds': outbounds});
    final profile = ServerProfile(id: makeId(), name: 'Imported Xray server', kind: ProfileKind.xray, data: {'json': jsonText});
    await upsert(profile);
    log('Imported Xray share link using official libXray parser');
    return profile;
  }

  Future<int> importMany(String text) async {
    final trimmed = text.trim();
    if (trimmed.startsWith('{')) {
      final value = jsonDecode(trimmed);
      if (value is Map && value['xray-vpn-backup'] == 1 && value['profiles'] is List) {
        var count = 0;
        for (final entry in value['profiles'] as List) {
          if (entry is Map) {
            await upsert(ServerProfile.fromJson(Map<String, dynamic>.from(entry)));
            count++;
          }
        }
        if (value['preferences'] is Map) {
          preferences = AppPreferences.fromJson(Map<String, dynamic>.from(value['preferences'] as Map));
          await store.savePreferences(preferences);
        }
        if (value['subscriptions'] is List) {
          subscriptions.clear();
          subscriptions.addAll((value['subscriptions'] as List).whereType<Map>().map((item) => SubscriptionSource.fromJson(Map<String, dynamic>.from(item))));
          await store.saveSubscriptions(subscriptions);
        }
        if (value['usageHistory'] is List) {
          usageHistory.clear();
          usageHistory.addAll((value['usageHistory'] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)));
          await store.saveUsageHistory(usageHistory);
        }
        await savePreferences();
        notifyListeners();
        return count;
      }
      final p = await importText(trimmed);
      return p == null ? 0 : 1;
    }
    final lines = trimmed.split(RegExp(r'[\r\n]+')).map((line) => line.trim()).where((line) => line.isNotEmpty);
    var count = 0;
    for (final line in lines) {
      try {
        final profile = await importText(line);
        if (profile != null) count++;
      } catch (e) {
        log('Skipped one unsupported import line: $e');
      }
    }
    return count;
  }

  String _profileIdentity(ServerProfile profile) {
    if (profile.kind == ProfileKind.group) return 'group|${profile.name}|${(profile.data['members'] as List?)?.join(',') ?? ''}';
    if (profile.kind == ProfileKind.chain) return 'chain|${profile.text('entry')}|${profile.text('exit')}|${profile.name}';
    if (profile.kind == ProfileKind.ssh) {
      return 'ssh|${profile.text('host').toLowerCase()}|${profile.text('port', '22')}|${profile.text('username')}|${profile.text('payload')}|${profile.text('proxyHost')}|${profile.text('proxyPort')}|${profile.text('udpgwPort')}|${profile.text('wsHost')}|${profile.flag('websocket')}|${profile.flag('tls')}';
    }
    final link = profile.text('link').trim();
    return link.isNotEmpty ? 'xray-link|$link' : 'xray-json|${profile.text('json').trim()}';
  }

  Future<SubscriptionSource> addSubscription(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('Subscription URL must be a valid HTTP(S) URL');
    }
    SubscriptionSource? existing;
    for (final source in subscriptions) { if (source.url == uri.toString()) { existing = source; break; } }
    if (existing != null) {
      await refreshSubscription(existing.id);
      return existing;
    }
    final source = SubscriptionSource(id: makeId(), name: uri.host, url: uri.toString());
    subscriptions.add(source);
    await store.saveSubscriptions(subscriptions);
    if (preferences.autoUpdateSubscriptions && _subscriptionTimer == null) {
      _subscriptionTimer = Timer.periodic(const Duration(hours: 12), (_) { if (preferences.autoUpdateSubscriptions) unawaited(refreshAllSubscriptions()); });
    }
    notifyListeners();
    await refreshSubscription(source.id);
    return source;
  }

  Future<void> refreshAllSubscriptions() async {
    for (final source in subscriptions.toList()) {
      try { await refreshSubscription(source.id); }
      catch (e) { log('Subscription refresh failed for ${source.name}: $e'); }
    }
  }

  Future<void> refreshSubscription(String id) async {
    final index = subscriptions.indexWhere((source) => source.id == id);
    if (index < 0) return;
    final source = subscriptions[index];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (isConnected) client.findProxy = (_) => 'PROXY 127.0.0.1:10809';
    try {
      final request = await client.getUrl(Uri.parse(source.url)).timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('Subscription returned HTTP ${response.statusCode}');
      var body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 30));
      if (!body.contains('://') && RegExp(r'^[A-Za-z0-9+/=\r\n]+$').hasMatch(body.trim())) {
        try { body = utf8.decode(base64.decode(base64.normalize(body.trim()))); } catch (_) {}
      }
      final count = await importMany(body);
      source.lastRefresh = DateTime.now();
      source.profileCount = count;
      await store.saveSubscriptions(subscriptions);
      log('Subscription ${source.name} refreshed: $count supported entries');
      notifyListeners();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> removeSubscription(String id) async {
    subscriptions.removeWhere((source) => source.id == id);
    await store.saveSubscriptions(subscriptions);
    notifyListeners();
  }

  String exportBackup() => const JsonEncoder.withIndent('  ').convert({
        'xray-vpn-backup': 1,
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
        'usageHistory': usageHistory,
        'preferences': preferences.toJson(),
      });

  Future<void> connect([ServerProfile? requested]) async {
    if (state == ConnectionStateKind.connecting || state == ConnectionStateKind.connected) return;
    final profile = requested ?? selectedProfile;
    if (profile == null) throw StateError('Add an SSH/Xray profile, failover group, or proxy chain first');
    if (profile.kind == ProfileKind.group) { await _connectGroup(profile); return; }
    selectedProfileId = profile.id;
    _activeProfile = profile;
    _sessionRecorded = false;
    _connectionCompleter = Completer<void>();
    final connectionReady = _connectionCompleter!.future;
    state = ConnectionStateKind.connecting;
    statusMessage = 'Preparing ${profile.kind.label}';
    uploadBytes = downloadBytes = uploadSpeed = downloadSpeed = 0;
    notifyListeners();
    log('Starting ${profile.kind.label}: ${profile.name}');
    try {
      String config;
      if (profile.kind == ProfileKind.ssh) {
        final engine = SshEngine(
          log: log,
          readHostPins: store.loadHostPins,
          saveHostPin: store.saveHostPin,
        );
        _ssh = await engine.connect(profile, socksPort: preferences.socksPort, keepAliveSeconds: preferences.sshKeepaliveSeconds, shareProxy: preferences.shareProxy, hotspotUser: preferences.hotspotUser, hotspotPassword: preferences.hotspotPassword);
        config = jsonEncode(buildXrayVpnConfig(profile: profile, preferences: preferences, importedOutbounds: const [], useTun: !preferences.proxyOnly));
      } else if (profile.kind == ProfileKind.chain) {
        final outbounds = await _buildChainOutbounds(profile);
        config = jsonEncode(buildXrayVpnConfig(profile: profile, preferences: preferences, importedOutbounds: outbounds, useTun: !preferences.proxyOnly));
      } else if (profile.kind == ProfileKind.xray) {
        final raw = profile.text('json').trim();
        if (raw.isNotEmpty) {
          config = normalizeRawXrayJson(raw, preferences, useTun: !preferences.proxyOnly);
        } else {
          final link = profile.text('link').trim();
          if (link.isEmpty) throw const FormatException('Xray profile has no share link or JSON configuration');
          final legacy = legacyVmessToXrayJson(link);
          final response = legacy == null ? await bridge.invokeLibXray('convertShareLinksToXrayJson', {'text': link}) : <String, dynamic>{'data': jsonDecode(legacy)};
          final data = Map<String, dynamic>.from(response['data'] as Map);
          final outbounds = data['outbounds'];
          if (outbounds is! List || outbounds.isEmpty) throw const FormatException('libXray did not produce an outbound');
          config = jsonEncode(buildXrayVpnConfig(profile: profile, preferences: preferences, importedOutbounds: outbounds, useTun: !preferences.proxyOnly));
        }
      } else {
        throw StateError('Unsupported profile kind: ${profile.kind.name}');
      }
      if (!preferences.proxyOnly) {
        final authorized = await bridge.prepareVpn();
        if (!authorized) throw StateError('Android VPN permission was denied or cancelled');
      }
      await bridge.startVpn(config: config, excludeApp: profile.kind == ProfileKind.ssh && !preferences.proxyOnly, bypassApps: preferences.appBypassList, useTun: !preferences.proxyOnly);
      nativeStarted = true;
      await connectionReady.timeout(const Duration(seconds: 45), onTimeout: () => throw TimeoutException('Native VPN engine did not report a startup result within 45 seconds'));
      if (state != ConnectionStateKind.connected) throw StateError(statusMessage.isEmpty ? 'Native VPN engine failed to start' : statusMessage);
      _connectionCompleter = null;
      notifyListeners();
    } catch (e) {
      _connectionCompleter = null;
      if (nativeStarted && state != ConnectionStateKind.failed) { try { await bridge.stopVpn(); } catch (_) {} }
      log('Connection failed: $e');
      state = ConnectionStateKind.failed;
      statusMessage = e.toString();
      await _ssh?.close();
      _ssh = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (state == ConnectionStateKind.disconnected) return;
    state = ConnectionStateKind.disconnecting;
    statusMessage = 'Disconnecting';
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    notifyListeners();
    try {
      await bridge.stopVpn();
    } catch (e) {
      log('Native disconnect reported: $e');
    }
    await _ssh?.close();
    _ssh = null;
    await _recordCurrentSession();
    state = ConnectionStateKind.disconnected;
    statusMessage = 'Disconnected';
    connectedAt = null;
    uploadSpeed = downloadSpeed = 0;
    log('VPN disconnected');
    notifyListeners();
  }

  Future<void> _connectGroup(ServerProfile group) async {
    final ids = (group.data['members'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    final members = ids.map((id) { for (final profile in profiles) { if (profile.id == id) return profile; } return null; }).whereType<ServerProfile>().toList();
    if (members.isEmpty) throw StateError('Failover group has no valid members; edit the group and select at least one server');
    final failures = <String>[];
    _tryingGroup = true;
    for (final member in members) {
      try {
        log('Failover group ${group.name}: trying ${member.name}');
        await connect(member);
        selectedProfileId = group.id;
        _activeProfile = member;
        statusMessage = 'Connected via ${member.name} (${group.name})';
        _tryingGroup = false;
        notifyListeners();
        return;
      } catch (error) {
        failures.add('${member.name}: $error');
        state = ConnectionStateKind.disconnected;
        connectedAt = null;
        log('Failover member failed: ${member.name}: $error');
      }
    }
    _tryingGroup = false;
    selectedProfileId = group.id;
    state = ConnectionStateKind.failed;
    statusMessage = 'All ${members.length} failover members failed';
    notifyListeners();
    if (preferences.autoReconnect) _scheduleReconnect();
    throw StateError(failures.join('\n'));
  }

  Future<List<Map<String, dynamic>>> _outboundsForChainMember(ServerProfile profile) async {
    if (profile.kind != ProfileKind.xray) throw StateError('Proxy chains currently require Xray profiles for both hops');
    final raw = profile.text('json').trim();
    dynamic decoded;
    if (raw.isNotEmpty) {
      decoded = jsonDecode(raw);
    } else {
      final link = profile.text('link').trim();
      if (link.isEmpty) throw StateError('Chain member ${profile.name} has no Xray link or JSON');
      final legacy = legacyVmessToXrayJson(link);
      if (legacy != null) {
        decoded = jsonDecode(legacy);
      } else {
        final response = await bridge.invokeLibXray('convertShareLinksToXrayJson', {'text': link});
        decoded = response['data'];
      }
    }
    if (decoded is! Map || decoded['outbounds'] is! List) throw StateError('Could not parse Xray outbound for ${profile.name}');
    final outbounds = (decoded['outbounds'] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    final usable = outbounds.where((item) => !{'freedom', 'blackhole', 'dns'}.contains(item['protocol'])).toList();
    if (usable.length != 1) throw StateError('Chain member ${profile.name} must resolve to exactly one proxy outbound');
    final outbound = usable.single;
    if (!{'vless', 'vmess', 'trojan', 'shadowsocks', 'socks', 'http'}.contains(outbound['protocol'])) {
      throw StateError('Chain member ${profile.name} uses unsupported chain transport ${outbound['protocol']}');
    }
    return [outbound];
  }

  Future<List<Map<String, dynamic>>> _buildChainOutbounds(ServerProfile chain) async {
    final entryId = chain.text('entry');
    final exitId = chain.text('exit');
    if (entryId.isEmpty || exitId.isEmpty || entryId == exitId) throw StateError('Choose two different Xray profiles for the entry and exit hops');
    ServerProfile? entry;
    ServerProfile? exit;
    for (final profile in profiles) { if (profile.id == entryId) entry = profile; if (profile.id == exitId) exit = profile; }
    if (entry == null || exit == null) throw StateError('A proxy chain member no longer exists; edit the chain');
    final entryOutbound = (await _outboundsForChainMember(entry)).single;
    final exitOutbound = (await _outboundsForChainMember(exit)).single;
    entryOutbound['tag'] = 'chain-entry';
    entryOutbound.remove('proxySettings');
    exitOutbound['tag'] = 'chain-exit';
    exitOutbound['proxySettings'] = {'tag': 'chain-entry'};
    log('Built Xray proxy chain: ${entry.name} → ${exit.name}');
    // Put the exit first so it becomes the default outbound; its connection is dialed through the entry.
    return [exitOutbound, entryOutbound];
  }

  Future<void> connectFastest() async {
    if (profiles.isEmpty) throw StateError('Add at least one profile first');
    final results = <({ServerProfile profile, int ms})>[];
    for (final profile in profiles.where((profile) => profile.kind == ProfileKind.ssh || profile.kind == ProfileKind.xray)) {
      try {
        final host = profile.kind == ProfileKind.ssh ? (profile.text('proxyHost').trim().isNotEmpty ? profile.text('proxyHost').trim() : profile.text('host')) : _hostFromXray(profile);
        final port = profile.kind == ProfileKind.ssh ? (profile.text('proxyHost').trim().isNotEmpty ? (int.tryParse(profile.text('proxyPort', '8080')) ?? 8080) : (int.tryParse(profile.text('port', '22')) ?? 22)) : _portFromXray(profile);
        if (host.isEmpty) continue;
        final watch = Stopwatch()..start();
        final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
        watch.stop();
        socket.destroy();
        results.add((profile: profile, ms: watch.elapsedMilliseconds));
      } catch (_) {}
    }
    if (results.isEmpty) throw StateError('No profile endpoint responded to a TCP latency check');
    log('Fastest profile selection is based on TCP reachability/latency only; it does not authenticate or validate a full tunnel.');
    results.sort((a, b) => a.ms.compareTo(b.ms));
    await connect(results.first.profile);
  }

  Future<void> runSpeedTest() async {
    if (!isConnected) throw StateError('Connect the VPN before running a speed test');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    client.findProxy = (_) => 'PROXY 127.0.0.1:10809';
    final watch = Stopwatch()..start();
    var bytes = 0;
    try {
      final request = await client.getUrl(Uri.parse(preferences.speedTestUrl)).timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(const Duration(seconds: 20));
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes += chunk.length;
        if (bytes >= 10 * 1024 * 1024) break;
      }
      watch.stop();
      log('Speed test: ${_formatBytes(bytes)} in ${watch.elapsedMilliseconds} ms (observed via app request)');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> checkExitIp() async {
    if (!isConnected) throw StateError('Connect the VPN first');
    if (selectedProfile?.kind == ProfileKind.ssh) {
      log('Exit-IP check is routed through the local Xray HTTP diagnostic inbound (127.0.0.1:10809).');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = (_) => 'PROXY 127.0.0.1:10809';
    try {
      final request = await client.getUrl(Uri.parse('https://api.ipify.org')).timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final ip = (await utf8.decoder.bind(response).join()).trim();
      log('Exit IP request result via local Xray HTTP diagnostic proxy: $ip');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _onNativeEvent(Map<String, dynamic> event) async {
    final type = (event['type'] ?? '').toString();
    if (type == 'link') {
      final link = (event['url'] ?? '').toString();
      if (!_initialized) { _pendingIncomingLink = link; return; }
      try { await importText(link); } catch (e) { log('Could not import incoming share link: $e'); }
      return;
    }
    if (type == 'log') {
      log((event['message'] ?? '').toString());
    } else if (type == 'state') {
      final value = (event['state'] ?? '').toString();
      statusMessage = (event['message'] ?? value).toString();
      if (value == 'connected') {
        state = ConnectionStateKind.connected;
        if (connectedAt == null) _sessionRecorded = false;
        connectedAt ??= DateTime.now();
        _reconnectAttempts = 0;
        if (_connectionCompleter != null && !_connectionCompleter!.isCompleted) _connectionCompleter!.complete();
        _startHealthCheck();
      } else if (value == 'failed') {
        await _recordCurrentSession();
        connectedAt = null;
        state = ConnectionStateKind.failed;
        if (_connectionCompleter != null && !_connectionCompleter!.isCompleted) _connectionCompleter!.complete();
        await _ssh?.close();
        _ssh = null;
        if (preferences.autoReconnect && !_tryingGroup) _scheduleReconnect();
      } else if (value == 'disconnected') {
        await _recordCurrentSession();
        connectedAt = null;
        state = ConnectionStateKind.disconnected;
        connectedAt = null;
        _healthTimer?.cancel();
      }
      notifyListeners();
    } else if (type == 'stats') {
      uploadSpeed = (event['uploadSpeed'] as num?)?.toInt() ?? 0;
      downloadSpeed = (event['downloadSpeed'] as num?)?.toInt() ?? 0;
      uploadBytes = (event['uploadBytes'] as num?)?.toInt() ?? uploadBytes;
      downloadBytes = (event['downloadBytes'] as num?)?.toInt() ?? downloadBytes;
      notifyListeners();
    }
  }

  Future<void> _recordCurrentSession() async {
    if (_sessionRecorded || connectedAt == null) return;
    final profile = _activeProfile ?? selectedProfile;
    if (profile == null) return;
    final ended = DateTime.now();
    usageHistory.add({
      'profileId': profile.id,
      'profileName': profile.name,
      'kind': profile.kind.name,
      'startedAt': connectedAt!.toIso8601String(),
      'endedAt': ended.toIso8601String(),
      'durationSeconds': ended.difference(connectedAt!).inSeconds,
      'uploadBytes': uploadBytes,
      'downloadBytes': downloadBytes,
    });
    if (usageHistory.length > 500) usageHistory.removeRange(0, usageHistory.length - 500);
    _sessionRecorded = true;
    try { await store.saveUsageHistory(usageHistory); } catch (e) { log('Could not save usage history: $e'); }
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    if (!preferences.healthCheck) return;
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!isConnected) return;
      try {
        final result = await bridge.invokeLibXray('getXrayState');
        final data = result['data'];
        final running = data is Map ? data['running'] == true : false;
        if (!running) {
          log('Health check: libXray reports the core stopped');
          await bridge.stopVpn();
        }
      } catch (e) {
        log('Health check error: $e');
      }
    });
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive == true || _reconnectAttempts >= preferences.maxReconnectAttempts) return;
    final profile = selectedProfile;
    if (profile == null) return;
    _reconnectAttempts++;
    final delay = Duration(seconds: min(30, 2 * _reconnectAttempts));
    log('Reconnect attempt $_reconnectAttempts/${preferences.maxReconnectAttempts} in ${delay.inSeconds}s');
    _reconnectTimer = Timer(delay, () async {
      try {
        state = ConnectionStateKind.disconnected;
        await connect(profile);
      } catch (e) {
        log('Reconnect failed: $e');
        _scheduleReconnect();
      }
    });
  }

  String _hostFromXray(ServerProfile profile) {
    final legacy = legacyVmessToXrayJson(profile.text('link'));
    if (legacy != null) {
      try { return (((jsonDecode(legacy) as Map)['outbounds'] as List).first as Map)['settings']['vnext'][0]['address'].toString(); } catch (_) {}
    }
    try {
      final link = Uri.parse(profile.text('link'));
      return link.host;
    } catch (_) {
      return '';
    }
  }

  int _portFromXray(ServerProfile profile) {
    final legacy = legacyVmessToXrayJson(profile.text('link'));
    if (legacy != null) {
      try { return (((jsonDecode(legacy) as Map)['outbounds'] as List).first as Map)['settings']['vnext'][0]['port'] as int; } catch (_) {}
    }
    try {
      final uri = Uri.parse(profile.text('link'));
      return uri.hasPort ? uri.port : 443;
    } catch (_) {
      return 443;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscriptionTimer?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_ssh?.close());
    super.dispose();
  }
}
