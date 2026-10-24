import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions.dart';
import 'controller.dart';
import 'home_tab.dart';
import 'models.dart';
import 'native.dart';
import 'servers_tab.dart';
import 'settings_tab.dart';
import 'subscription.dart' show shareSchemes;
import 'tools_tab.dart';

/// Bottom-navigation shell: Home, Servers, Tools, Settings.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.ctrl});
  final VpnController ctrl;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  VpnController get ctrl => widget.ctrl;
  int _tab = 0;
  String _lastOffered = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.setLinkHandler(_onLink);
    Native.takeLink().then((l) {
      if (l != null && mounted) _onLink(l);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  /// A vless:// vmess:// ... link opened from a browser or chat app.
  Future<void> _onLink(String link) async {
    if (!mounted) return;
    final p = importProfile(link);
    if (p == null) {
      toast(context, 'Unsupported link');
      return;
    }
    final ok = await confirm(context, 'Import server?', '${p.name}\n${p.subtitle}', action: 'Import');
    if (ok) {
      await ctrl.upsert(p);
      if (mounted) setState(() => _tab = 1);
    }
  }

  /// Offers to import a share link that is sitting in the clipboard.
  Future<void> _checkClipboard() async {
    if (ctrl.state != ConnState.disconnected) return;
    String t;
    try {
      t = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
    } catch (_) {
      return;
    }
    if (t.isEmpty || t == _lastOffered || t.length > 8000 || t.contains('\n')) return;
    if (!t.contains('://') || !shareSchemes.contains(t.split('://').first.toLowerCase())) return;
    final p = importProfile(t);
    if (p == null || !mounted) return;
    _lastOffered = t;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Link in clipboard: ${p.name}'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'IMPORT', onPressed: () => ctrl.upsert(p)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final locked = ctrl.state != ConnState.disconnected;
        return PopScope(
          // Back: other tab -> Home; Home while connected -> background (a destroyed
          // activity would also kill the Dart-hosted SSH tunnel); Home otherwise -> exit.
          canPop: _tab == 0 && !locked,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_tab != 0) {
              setState(() => _tab = 0);
            } else {
              Native.moveToBack();
            }
          },
          child: Scaffold(
            body: IndexedStack(index: _tab, children: [
              HomeTab(ctrl: ctrl, openServers: () => setState(() => _tab = 1)),
              ServersTab(ctrl: ctrl),
              ToolsTab(ctrl: ctrl),
              SettingsTab(ctrl: ctrl),
            ]),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                const NavigationDestination(
                    icon: Icon(Icons.shield_outlined), selectedIcon: Icon(Icons.shield), label: 'Home'),
                NavigationDestination(
                  icon: Badge(
                      isLabelVisible: ctrl.profiles.isNotEmpty,
                      label: Text('${ctrl.profiles.length}'),
                      child: const Icon(Icons.dns_outlined)),
                  selectedIcon: const Icon(Icons.dns),
                  label: 'Servers',
                ),
                const NavigationDestination(
                    icon: Icon(Icons.handyman_outlined), selectedIcon: Icon(Icons.handyman), label: 'Tools'),
                const NavigationDestination(
                    icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
              ],
            ),
          ),
        );
      },
    );
  }
}
