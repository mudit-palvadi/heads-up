/// Heads Up — app entry point.
///
/// Specification: architecture.md §8.
///
/// Thin on purpose. The heavy wiring (WorkManager periodic task, Gemma model
/// load) is added in the phases that build those services — registering a
/// callback against a service that does not exist yet crashes on first launch.
library;

import 'package:flutter/material.dart';
import 'package:heads_up/background/callback_dispatcher.dart';
import 'package:heads_up/ui/theme.dart';
import 'package:heads_up/ui/widget_lab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must happen before runApp: a widget tap arriving before this is registered
  // has nowhere to go, which looks exactly like a dead play button.
  await registerWidgetCallbacks();
  await registerBackgroundSync();

  runApp(const HeadsUpApp());
}

class HeadsUpApp extends StatelessWidget {
  const HeadsUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heads Up',
      debugShowCheckedModeBanner: false,
      theme: buildHeadsUpTheme(),
      // Temporary: replaced by status_screen.dart in the UI phase. The widget
      // lab exists because the widget can only be verified on a real device, and
      // the mail pipeline is not built yet.
      home: const WidgetLab(),
    );
  }
}