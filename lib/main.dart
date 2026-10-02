/// Heads Up — app entry point.
///
/// Deliberately thin. Per `architecture.md` §8 the heavy wiring (WorkManager,
/// Gemma init, HomeWidget callbacks) is added in Phase 5/Phase "Widget" once
/// those services exist — registering callbacks against services that are not
/// built yet would crash on first launch.
library;

import 'package:flutter/material.dart';
import 'package:heads_up/ui/theme.dart';

void main() {
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
      home: const _Scaffold(),
    );
  }
}

/// Placeholder shown until `status_screen.dart` lands (phases.md, Afternoon).
class _Scaffold extends StatelessWidget {
  const _Scaffold();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Heads Up')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // PRD §3.2: the empty state is calm and high contrast on purpose.
              Text(
                'Nothing needs you today',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HeadsUpSpacing.rowGap),
              Text(
                'Setup and the mail pipeline land in the next build.',
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}