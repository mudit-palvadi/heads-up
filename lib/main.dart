/// Heads Up — app entry point.
///
/// Specification: architecture.md §8.
///
/// The service graph is built once here and handed to the screens, so there is a
/// single place that knows how the pieces fit together. Secrets are read from
/// the KeyStore on demand, never held here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:heads_up/background/callback_dispatcher.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:heads_up/services/gemma_runtime.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/pipeline.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/ui/rules_screen.dart';
import 'package:heads_up/ui/setup_screen.dart';
import 'package:heads_up/ui/status_screen.dart';
import 'package:heads_up/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must happen before runApp: a widget tap arriving before this is registered
  // has nowhere to go, which looks exactly like a dead play button.
  await registerWidgetCallbacks();

  final store = Store();
  await registerBackgroundSync(store: store);

  runApp(HeadsUpApp(store: store));
}

class HeadsUpApp extends StatelessWidget {
  const HeadsUpApp({super.key, required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heads Up',
      debugShowCheckedModeBanner: false,
      theme: buildHeadsUpTheme(),
      home: _Root(store: store),
    );
  }
}

/// Chooses the first screen.
///
/// prd.md §6.1 makes setup a *first-run* flow: the friend should not have to
/// find the settings screen to get started, and equally should not be shown
/// credential fields after they are already set up.
class _Root extends StatefulWidget {
  const _Root({required this.store});

  final Store store;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _decided = false;
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    unawaited(_decide());
  }

  Future<void> _decide() async {
    final password =
        await widget.store.readSecret(SecretKeys.imapPassword);
    final needsSetup = password == null || password.isEmpty;
    if (!mounted) return;
    setState(() {
      _needsSetup = needsSetup;
      _decided = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_decided) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_needsSetup) return const SetupScreen();

    final mail = MailService();
    return StatusScreen(
      store: widget.store,
      runtime: GemmaRuntime(widget.store),
      mail: mail,
      pipeline: Pipeline(store: widget.store, mail: mail),
      onOpenSetup: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SetupScreen()),
        );
        await _decide();
      },
      onOpenRules: () async {
        final base = await _loadBaseRules(widget.store);
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RulesScreen(store: widget.store, base: base),
          ),
        );
      },
    );
  }

  static Future<RulesConfig> _loadBaseRules(Store store) async {
    // Fall back to an empty config: the screen only uses the base lists to
    // populate its own fields and to power "Reset to defaults".
    try {
      final raw = await rootBundle.loadString('assets/default_rules.json');
      return RulesConfig.fromJsonString(raw);
    } catch (_) {
      return const RulesConfig();
    }
  }
}