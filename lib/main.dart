import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'shell.dart';
import 'theme.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      VpnController.current?.log('UI error: ${details.exceptionAsString()}');
    };
    runApp(const VpnApp());
  }, (error, stack) {
    VpnController.current?.log('Unhandled error: $error');
  });
}

class VpnApp extends StatefulWidget {
  const VpnApp({super.key});
  @override
  State<VpnApp> createState() => _VpnAppState();
}

class _VpnAppState extends State<VpnApp> {
  final ctrl = VpnController();

  @override
  void initState() {
    super.initState();
    ctrl.init();
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => MaterialApp(
          title: 'XRay Vpn',
          debugShowCheckedModeBanner: false,
          themeMode: switch (ctrl.settings.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: AppShell(ctrl: ctrl),
        ),
      );
}
