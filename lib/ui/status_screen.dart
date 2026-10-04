/// Status screen — the app's home.
///
/// Specification: prd.md §6.2.
///
/// Shows the same three items as the widget, plus "Refresh now", model status,
/// and the last few pipeline events. prd.md §2 is explicit that the friend opens
/// this rarely, so it stays a single scrollable column with one primary action.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/settings.dart';
import 'package:heads_up/services/gemma_runtime.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/pipeline.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/ui/relative_time.dart';
import 'package:heads_up/ui/theme.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({
    super.key,
    required this.pipeline,
    required this.store,
    required this.runtime,
    required this.mail,
    this.onOpenSetup,
    this.onOpenRules,
  });

  final Pipeline pipeline;
  final Store store;
  final GemmaRuntime runtime;
  final MailService mail;

  /// Re-opens credential entry. Needed after first run, e.g. to rotate a key.
  final Future<void> Function()? onOpenSetup;

  /// The VIP rules screen — the hand-over step in prd.md §9.
  final Future<void> Function()? onOpenRules;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  List<MailItem> _items = const [];
  AppSettings _settings = AppSettings();
  List<PipelineEvent> _log = const [];
  String? _friendlyError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    _settings = await widget.store.loadSettings();
    _items = await widget.store.getTopItems();
    _log = widget.pipeline.log;
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _friendlyError = null;
    });

    try {
      // Connect only for the duration of the run: a persistent socket to
      // Gmail in the background is not something this app should hold.
      final password =
          await widget.store.readSecret(SecretKeys.imapPassword);
      if (password == null || password.isEmpty) {
        setState(() {
          _friendlyError =
              'No app password yet. Add one on the Set up screen first.';
          _busy = false;
        });
        return;
      }

      await widget.mail.connect(
        host: _settings.imapHost,
        port: _settings.imapPort,
        user: _settings.imapUser,
        password: password,
      );

      final result = await widget.pipeline.runFull();

      _items = await widget.store.getTopItems();
      _settings = await widget.store.loadSettings();
      _log = result.log;

      if (!mounted) return;
      setState(() {
        if (!result.succeeded) {
          _friendlyError = 'The last check did not finish. See the log below.';
        }
        _busy = false;
      });
    } on MailException catch (e) {
      if (!mounted) return;
      setState(() {
        _friendlyError = e.userFacing;
        _busy = false;
      });
    } finally {
      await widget.mail.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modelLabel = switch (widget.runtime.state.status) {
      ModelStatus.ready => ModelLabel.ready,
      ModelStatus.downloading => ModelLabel.downloading,
      ModelStatus.notDownloaded => ModelLabel.notDownloaded,
      ModelStatus.failed => ModelLabel.unknown,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Heads Up'),
        actions: [
          IconButton(
            onPressed: widget.onOpenRules == null
                ? null
                : () => unawaited(widget.onOpenRules!()),
            icon: const Icon(Icons.people_outline),
            tooltip: 'Who matters to you',
          ),
          IconButton(
            onPressed: widget.onOpenSetup == null
                ? null
                : () => unawaited(widget.onOpenSetup!()),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
          children: [
            Text(
              formatLastChecked(_settings.lastCheckAt),
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: HeadsUpSpacing.rowGap),

            if (_friendlyError != null) ...[
              _errorPanel(theme),
              const SizedBox(height: HeadsUpSpacing.rowGap),
            ],

            // Same three items as the widget (prd.md §6.2).
            Text(
              formatItemCountHeader(_items.length),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            if (_items.isEmpty)
              Text(
                'Nothing flagged yet. Pull down to check.',
                style: theme.textTheme.labelSmall,
              )
            else
              for (final item in _items) _itemTile(theme, item),

            const SizedBox(height: HeadsUpSpacing.rowGap),
            FilledButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_busy ? 'Checking…' : 'Refresh now'),
            ),

            const SizedBox(height: HeadsUpSpacing.rowGap),
            Text(
              formatModelLabel(
                modelLabel,
                progress: widget.runtime.state.progress,
              ),
              style: theme.textTheme.labelSmall,
            ),

            if (_log.isNotEmpty) ...[
              const Divider(height: HeadsUpSpacing.gutter * 2),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Recent activity',
                      style: theme.textTheme.bodyMedium),
                  children: [
                    for (final event in _log.reversed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${event.timeLabel}  ${event.message}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: event.isError
                                ? HeadsUpColors.urgent
                                : HeadsUpColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _itemTile(ThemeData theme, MailItem item) {
    final lines = [
      item.what ?? '',
      if (item.doIt != null) item.doIt!,
      if (item.by != null) 'By ${item.by}',
    ].join('\n');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HeadsUpColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.isUrgent
              ? HeadsUpColors.urgent
              : HeadsUpColors.textSecondary,
        ),
      ),
      child: Row(
        children: [
          Icon(
            item.audioSource == AudioSource.elevenlabs
                ? Icons.graphic_eq
                : Icons.record_voice_over_outlined,
            color: item.isUrgent
                ? HeadsUpColors.urgent
                : HeadsUpColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              clampToWordBudget(lines, maxWords: 24),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: item.isUrgent
                    ? HeadsUpColors.urgent
                    : HeadsUpColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorPanel(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HeadsUpColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HeadsUpColors.urgent),
      ),
      child: Text(
        _friendlyError!,
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}