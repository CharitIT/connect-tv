import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/common.dart';
import 'ui/home_shell.dart';
import 'ui/setup_wizard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  runApp(ConnectTvApp(state: state));
}

class ConnectTvApp extends StatefulWidget {
  final AppState state;
  const ConnectTvApp({super.key, required this.state});

  @override
  State<ConnectTvApp> createState() => _ConnectTvAppState();
}

class _ConnectTvAppState extends State<ConnectTvApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.state.onboarded) widget.state.autoConnect();
    widget.state.startWatching();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.stopWatching();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Reconnect when the app comes back to the foreground, and keep checking while it's open.
    if (s == AppLifecycleState.resumed) {
      if (widget.state.onboarded) widget.state.autoConnect();
      widget.state.startWatching();
    } else if (s == AppLifecycleState.paused) {
      widget.state.stopWatching();
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7C4DFF);
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Connect TV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
        home: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => widget.state.onboarded ? const HomeShell() : const SetupWizard(),
        ),
      ),
    );
  }
}
