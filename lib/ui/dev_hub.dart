/// Temporary launcher for the two on-device harnesses.
///
/// Replaced by `status_screen.dart` in the UI phase. Both targets need a real
/// device — the widget can only be judged on a home screen, and the Gemma gate
/// needs the LiteRT-LM engine loaded on real hardware — so they cannot be
/// exercised from unit tests.
library;

import 'package:flutter/material.dart';
import 'package:heads_up/ui/spike_a_screen.dart';
import 'package:heads_up/ui/theme.dart';
import 'package:heads_up/ui/widget_lab.dart';

class DevHub extends StatelessWidget {
  const DevHub({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Heads Up')),
      body: ListView(
        padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
        children: [
          Text(
            'Temporary development hub. Replaced by the setup and status '
            'screens once the mail pipeline exists.',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: HeadsUpSpacing.rowGap),
          _tile(
            context,
            title: 'Widget lab',
            subtitle: 'Push fabricated rows to the home screen widget',
            icon: Icons.widgets_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WidgetLab()),
            ),
          ),
          const SizedBox(height: 8),
          _tile(
            context,
            title: 'Spike A — Gemma',
            subtitle: 'Download the model and measure on-device latency',
            icon: Icons.speed_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SpikeAScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: HeadsUpColors.textSecondary),
      ),
    );
  }
}