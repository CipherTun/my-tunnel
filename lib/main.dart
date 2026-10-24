import 'package:flutter/material.dart';

import 'app_info.dart';
import 'controller.dart';
import 'home_page.dart';
import 'profiles_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'tools_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final c = VpnController();
  await c.init();
  runApp(XrayApp(c));
}

class XrayApp extends StatelessWidget {
  const XrayApp(this.ctrl, {super.key});
  final VpnController ctrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (_, __) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (ctrl.settings.themeMode) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        },
        home: AppShell(ctrl),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell(this.ctrl, {super.key});
  final VpnController ctrl;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: [
          HomePage(ctrl: c, onPickProfile: () => setState(() => _tab = 1)),
          ProfilesPage(ctrl: c),
          ToolsPage(ctrl: c),
          SettingsPage(ctrl: c),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.shield_outlined), selectedIcon: Icon(Icons.shield), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns), label: 'Profiles'),
            NavigationDestination(icon: Icon(Icons.build_circle_outlined), selectedIcon: Icon(Icons.build_circle), label: 'Tools'),
            NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
