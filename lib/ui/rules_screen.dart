/// VIP Rules screen — the friend decides who matters.
///
/// Specification: prd.md §6.3, and the hand-over step in prd.md §9:
/// "Let him add people he cares about to the VIP list himself."
///
/// This screen is therefore a *product* surface, not settings chrome. It is
/// deliberately plain: large tap targets, one list per rule type, and a
/// "Reset to defaults" escape hatch so a mis-tap is never permanent.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/ui/theme.dart';

/// The editable rule groups (prd.md §6.3).
enum RuleList { vipAddresses, vipDomains, vipKeywords, ignorePatterns }

/// Bridges this screen's enum to the model, so the storage keys are defined in
/// exactly one place.
extension RuleListBridge on RuleList {
  RuleListKind get kind => switch (this) {
        RuleList.vipAddresses => RuleListKind.vipAddresses,
        RuleList.vipDomains => RuleListKind.vipDomains,
        RuleList.vipKeywords => RuleListKind.vipKeywords,
        RuleList.ignorePatterns => RuleListKind.ignorePatterns,
      };

  List<String> valuesIn(RulesConfig config) => config.valuesFor(kind);
}

extension RuleListMeta on RuleList {
  String get title => switch (this) {
        RuleList.vipAddresses => 'People who always matter',
        RuleList.vipDomains => 'Domains that always matter',
        RuleList.vipKeywords => 'Words that mean it is important',
        RuleList.ignorePatterns => 'Never show me',
      };

  String get hint => switch (this) {
        RuleList.vipAddresses => 'For example dad@gmail.com',
        RuleList.vipDomains => 'For example university.edu',
        RuleList.vipKeywords => 'For example deadline, urgent',
        RuleList.ignorePatterns =>
          'For example newsletter@shop.example — skip this sender completely',
      };

  String get explanation => switch (this) {
        RuleList.vipAddresses =>
          'Email from these people always shows up, even if it looks like a '
              'newsletter.',
        RuleList.vipDomains =>
          'Anything from these domains always shows up.',
        RuleList.vipKeywords =>
          'If the subject contains one of these words, it counts as important.',
        RuleList.ignorePatterns =>
          'Email from these senders is never shown, even if it says '
              '"urgent".',
      };

  String get key => switch (this) {
        RuleList.vipAddresses => 'vipAddresses',
        RuleList.vipDomains => 'vipDomains',
        RuleList.vipKeywords => 'vipKeywords',
        RuleList.ignorePatterns => 'ignorePatterns',
      };
}

class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, required this.store, required this.base});

  final Store store;

  /// The bundled defaults, so the UI can show what is already in force.
  final RulesConfig base;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late Map<RuleList, List<String>> _lists;

  @override
  void initState() {
    super.initState();
    _lists = {
      RuleList.vipAddresses: [...widget.base.vipAddresses],
      RuleList.vipDomains: [...widget.base.vipDomains],
      RuleList.vipKeywords: [...widget.base.vipKeywords],
      RuleList.ignorePatterns: [...RuleList.ignorePatterns.valuesIn(widget.base)],
    };
    unawaited(_load());
  }

  Future<void> _load() async {
    final override = await widget.store.loadRulesOverride();
    if (override == null || !mounted) return;

    setState(() {
      for (final list in RuleList.values) {
        final value = override[list.key];
        if (value is List) {
          _lists[list] =
              value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
        }
      }
    });
  }

  Future<void> _persist() async {
    await widget.store.saveRulesOverride({
      for (final list in RuleList.values) list.key: _lists[list],
    });
    // The threshold lives in the same override blob so a single write updates
    // both (rules.md §6: user overrides append/replace over the defaults).
    final settings = await widget.store.loadSettings();
    await widget.store.saveRulesOverride({
      for (final list in RuleList.values) list.key: _lists[list],
      'scoreThreshold': settings.scoreThreshold,
    });
  }

  Future<void> _add(RuleList list) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add to ${list.title.toLowerCase()}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: list == RuleList.vipAddresses
              ? TextInputType.emailAddress
              : TextInputType.text,
          decoration: InputDecoration(hintText: list.hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;

    // Case-insensitive dedupe: "Dad@x.com" and "dad@x.com" are one person, and
    // a duplicate would silently double-score their email.
    final exists = _lists[list]!
        .any((e) => e.toLowerCase() == trimmed.toLowerCase());
    if (exists) return;

    setState(() => _lists[list]!.add(trimmed));
    await _persist();
  }

  Future<void> _remove(RuleList list, String value) async {
    setState(() => _lists[list]!.remove(value));
    await _persist();
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset to defaults?'),
        content: const Text(
          'This removes everything you added here. The built-in word list '
          'stays as it is.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      for (final list in RuleList.values) {
        _lists[list] = [...list.valuesIn(widget.base)];
      }
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('What matters to you')),
      body: ListView(
        padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
        children: [
          Text(
            'These rules decide what appears on your home screen. You can '
            'change them whenever you like.',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: HeadsUpSpacing.rowGap),
          for (final list in RuleList.values) ...[
            _section(theme, list),
            const SizedBox(height: HeadsUpSpacing.rowGap),
          ],
          const Divider(height: HeadsUpSpacing.rowGap),
          OutlinedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset to defaults'),
          ),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, RuleList list) {
    final entries = _lists[list]!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HeadsUpColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HeadsUpColors.textSecondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(list.title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(list.explanation, style: theme.textTheme.labelSmall),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Text('Nothing added yet.', style: theme.textTheme.labelSmall)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in entries)
                  InputChip(
                    label: Text(entry),
                    onDeleted: () => _remove(list, entry),
                    deleteButtonTooltipMessage: 'Remove $entry',
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _add(list),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}