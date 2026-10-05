/// First-run setup: credentials, model download, and the read-only proof.
///
/// Specification: prd.md §6.1.
///
/// This is a real product screen, not a debug harness — it is what the friend
/// sees on first launch. It is also where the Spike B verification lives,
/// because "Test connection" is exactly when the read-only guarantee should be
/// demonstrated rather than merely claimed.
///
/// Secrets go to the Android KeyStore via `flutter_secure_storage` and are never
/// written to the database, to logs, or to the repository (prd.md §8).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heads_up/services/gemma_runtime.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/ui/theme.dart';

/// Which stage of the read-only proof was actually reached.
///
/// Explicit because the counters default to reassuring values: on every failure
/// path `newlyReadAfterExamine` and `newlyReadAfterBodyFetch` are both 0, which
/// is indistinguishable from a clean run unless we also record whether the diff
/// was *measured*. The first live run rendered "Read-only: verified" in green
/// while simultaneously reporting that the check had failed.
enum ProofStage {
  /// Never ran, or failed before the flags probe produced a snapshot.
  notRun,

  /// Signed in, and both FLAGS probes came back with no change.
  flagsVerified,

  /// Signed in; EXAMINE was inert, but the BODY.PEEK[] stage has not finished.
  examineVerified,

  /// Every stage completed.
  fullyVerified,
}

/// Outcome of the read-only proof run.
class ReadOnlyProof {
  const ReadOnlyProof({
    required this.connected,
    required this.stage,
    required this.messagesProbed,
    required this.alreadyReadBefore,
    required this.newlyReadAfterExamine,
    required this.bodyFetchSucceeded,
    required this.messagesFetched,
    required this.newlyReadAfterBodyFetch,
    this.error,
    this.errorDetail,
  });

  final bool connected;

  /// How far the proof actually got. Drives the verdict — never the counters.
  final ProofStage stage;

  /// How many messages the flags probe covered.
  final int messagesProbed;

  /// How many were already marked read before we did anything. Expected to be
  /// non-zero — it just must not *change*.
  final int alreadyReadBefore;

  /// Messages that became read purely from EXAMINE. Must be zero.
  final int newlyReadAfterExamine;

  final bool bodyFetchSucceeded;
  final int messagesFetched;

  /// Messages that became read from the BODY.PEEK[] fetch. Must be zero.
  final int newlyReadAfterBodyFetch;

  final String? error;

  /// The underlying error verbatim, shown beneath the friendly [error].
  ///
  /// `_translate` puts the real IMAP text in `MailException.message`; rendering
  /// only the friendly copy threw away the single most useful clue. The first
  /// live run reported "Something went wrong reading your mail" and nothing
  /// else, which made the cause unrecoverable without guessing.
  final String? errorDetail;

  /// The whole guarantee in one boolean: nothing we did marked anything read.
  ///
  /// Requires a *measured* stage, never just zero counters. A run that failed
  /// early leaves both counters at 0, and treating that as a pass is exactly
  /// the false positive this guards against.
  bool get isReadOnly => switch (stage) {
        ProofStage.fullyVerified || ProofStage.examineVerified ||
        ProofStage.flagsVerified =>
          connected &&
              newlyReadAfterExamine == 0 &&
              newlyReadAfterBodyFetch == 0,
        ProofStage.notRun => false,
      };

  /// Nothing was measured, so nothing can be claimed either way.
  bool get isUnverified => stage == ProofStage.notRun;

  /// Heading. Three states, never two — a failed run must not read as a pass.
  String get verdict => switch (stage) {
        ProofStage.fullyVerified => 'Read-only: verified',
        ProofStage.examineVerified => 'Read-only: partly verified',
        ProofStage.flagsVerified => 'Read-only: EXAMINE verified only',
        ProofStage.notRun =>
          connected ? 'Read-only: not checked' : 'Read-only: not checked',
      };

  String summary() {
    if (error != null) return 'Failed: $error';
    if (!connected) return 'Could not connect.';

    // Stage-driven, not counter-driven. A partial run must not print "PASS":
    // the guarantee has two halves and only one of them was measured.
    final verdict = switch (stage) {
      ProofStage.fullyVerified => isReadOnly ? 'PASS' : 'FAIL',
      ProofStage.examineVerified => isReadOnly ? 'EXAMINE PASS' : 'FAIL',
      ProofStage.flagsVerified => isReadOnly ? 'EXAMINE PASS' : 'FAIL',
      ProofStage.notRun => 'NOT CHECKED',
    };

    return '$verdict — examined $messagesProbed messages, '
        '$alreadyReadBefore already read; '
        'EXAMINE marked $newlyReadAfterExamine read, '
        'BODY.PEEK marked $newlyReadAfterBodyFetch read. '
        'Both must be 0.';
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _store = Store();
  final _runtime = GemmaRuntime(Store());

  final _host = TextEditingController(text: 'imap.gmail.com');
  final _port = TextEditingController(text: '993');
  final _user = TextEditingController();
  final _appPassword = TextEditingController();
  final _elevenLabsKey = TextEditingController();
  final _hfToken = TextEditingController();

  ModelState _modelState = const ModelState(status: ModelStatus.notDownloaded);
  ReadOnlyProof? _proof;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _runtime.changes.listen((state) {
      if (mounted) setState(() => _modelState = state);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in [
      _host,
      _port,
      _user,
      _appPassword,
      _elevenLabsKey,
      _hfToken,
    ]) {
      c.dispose();
    }
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await _store.loadSettings();
    _host.text = settings.imapHost;
    _port.text = '${settings.imapPort}';
    _user.text = settings.imapUser;

    // Show only whether a secret exists, never the secret itself.
    final hasPassword =
        (await _store.readSecret(SecretKeys.imapPassword))?.isNotEmpty ?? false;
    final hasKey =
        (await _store.readSecret(SecretKeys.elevenLabs))?.isNotEmpty ?? false;
    final hasToken =
        (await _store.readSecret(SecretKeys.hfToken))?.isNotEmpty ?? false;

    await _runtime.initialise();
    final ready = await _runtime.isReady();

    if (!mounted) return;
    setState(() {
      if (hasPassword) _appPassword.text = _savedPlaceholder;
      if (hasKey) _elevenLabsKey.text = _savedPlaceholder;
      if (hasToken) _hfToken.text = _savedPlaceholder;
      if (ready) {
        _modelState = const ModelState(status: ModelStatus.ready, progress: 1);
      }
    });
  }

  /// Shown instead of a stored secret, so the field is never pre-filled with
  /// the real value and cannot be read over someone's shoulder or captured in
  /// a screenshot.
  static const String _savedPlaceholder = '•••••••• saved';

  bool _isPlaceholder(TextEditingController c) =>
      c.text.trim() == _savedPlaceholder;

  /// Persists credentials. Placeholder values are skipped so re-saving a form
  /// never destroys the stored secret.
  Future<void> _saveAll() async {
    final settings = await _store.loadSettings();
    await _store.saveSettings(
      settings.copyWith(
        imapHost: _host.text.trim(),
        imapPort: int.tryParse(_port.text.trim()) ?? 993,
        imapUser: _user.text.trim(),
      ),
    );

    if (!_isPlaceholder(_appPassword)) {
      final value = _appPassword.text.trim();
      if (value.isNotEmpty) {
        await _store.writeSecret(SecretKeys.imapPassword, value);
      }
    }
    if (!_isPlaceholder(_elevenLabsKey)) {
      final value = _elevenLabsKey.text.trim();
      if (value.isNotEmpty) {
        await _store.writeSecret(SecretKeys.elevenLabs, value);
      }
    }
    if (!_isPlaceholder(_hfToken)) {
      final value = _hfToken.text.trim();
      if (value.isNotEmpty) {
        await _store.writeSecret(SecretKeys.hfToken, value);
      }
    }

    // Clear the fields and the clipboard: a credential should not linger in
    // either once it is safely in the KeyStore.
    for (final c in [_appPassword, _elevenLabsKey, _hfToken]) {
      c.clear();
    }
    await Clipboard.setData(const ClipboardData(text: ''));
  }

  /// The staged read-only verification (Spike B).
  ///
  /// Deliberately runs the harmless probe twice before it will fetch any body at
  /// all, so that a mistake in the EXAMINE path is discovered before any message
  /// content is touched.
  Future<void> _testConnection() async {
    setState(() {
      _busy = true;
      _proof = null;
    });

    // Everything is inside the try, and _busy is reset in the finally.
    //
    // Previously _saveAll() and the secret read sat *outside* the try, so any
    // throw there — a sqflite or KeyStore error — left _busy stuck true. The
    // buttons stayed greyed out with no message and no way forward, on the one
    // screen that has to work. A hang here is indistinguishable, to the friend
    // using it, from a broken app.
    MailService? service;

    // Whether the IMAP login actually completed. Tracked separately so a
    // failure *after* a successful login is not reported as "could not
    // connect" — which is what the first live run did: the app password was
    // accepted, and the panel implied otherwise.
    var connected = false;
    try {
      await _saveAll();

      service = MailService();
      final password = await _store.readSecret(SecretKeys.imapPassword) ?? '';

      await service.connect(
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 993,
        user: _user.text.trim(),
        password: password,
      );
      connected = true;

      // Stage 1 — flags only. Cannot mark anything read by definition.
      final before = await service.probeFlags();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // Stage 2 — repeat. Any difference is our fault, not the user's.
      final afterExamine = await service.probeFlags();
      final markedByExamine = before.newlySeen(afterExamine).length;

      // Past this point the EXAMINE half of the guarantee is *measured*, so a
      // later failure can honestly say "EXAMINE verified" rather than
      // "not checked".
      const stageAfterExamine = ProofStage.examineVerified;

      // Stage 3 — now, and only now, fetch bodies with BODY.PEEK[].
      var fetched = 0;
      var bodyOk = false;
      var markedByBody = 0;
      try {
        final messages = await service.fetchNew(lastUid: 0, take: 5);
        fetched = messages.length;
        bodyOk = true;
        final afterBody = await service.probeFlags();
        markedByBody = before.newlySeen(afterBody).length;
      } on MailException catch (e) {
        // A read-only violation throws here; record it rather than crashing.
        // e.message now carries the exact command that was sent, so the next
        // failure of this kind is diagnosable from the panel alone.
        if (!mounted) return;
        setState(() {
          _proof = ReadOnlyProof(
            connected: true,
            stage: stageAfterExamine,
            messagesProbed: before.count,
            alreadyReadBefore: before.count,
            newlyReadAfterExamine: markedByExamine,
            bodyFetchSucceeded: false,
            messagesFetched: 0,
            newlyReadAfterBodyFetch: 0,
            error: e.userFacing,
            errorDetail: 'during the BODY.PEEK[] fetch:\n${e.message}',
          );
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _proof = ReadOnlyProof(
          connected: true,
          stage: ProofStage.fullyVerified,
          messagesProbed: before.count,
          alreadyReadBefore: before.count,
          newlyReadAfterExamine: markedByExamine,
          bodyFetchSucceeded: bodyOk,
          messagesFetched: fetched,
          newlyReadAfterBodyFetch: markedByBody,
        );
      });
    } on MailException catch (e) {
      // Thrown by connect() or by one of the two FLAGS probes. `connected`
      // distinguishes them, and errorDetail keeps the raw IMAP text.
      if (!mounted) return;
      setState(() {
        _proof = ReadOnlyProof(
          connected: connected,
          stage: ProofStage.notRun,
          messagesProbed: 0,
          alreadyReadBefore: 0,
          newlyReadAfterExamine: 0,
          bodyFetchSucceeded: false,
          messagesFetched: 0,
          newlyReadAfterBodyFetch: 0,
          error: e.userFacing,
          errorDetail: connected
              ? 'during the FLAGS probe: ${e.message}'
              : 'during sign-in: ${e.message}',
        );
      });
    } catch (e) {
      // Not a MailException: a socket, TLS, or platform error. It still has to
      // land in the panel rather than becoming a silently stuck button.
      //
      // The message distinguishes the two cases, because they need different
      // fixes: before the login it is a credentials/network problem, after it
      // is our bug.
      if (!mounted) return;
      setState(() {
        _proof = ReadOnlyProof(
          connected: connected,
          stage: ProofStage.notRun,
          messagesProbed: 0,
          alreadyReadBefore: 0,
          newlyReadAfterExamine: 0,
          bodyFetchSucceeded: false,
          messagesFetched: 0,
          newlyReadAfterBodyFetch: 0,
          error: connected
              ? 'Signed in fine, but the read-only check failed.'
              : 'Could not finish the check.',
          errorDetail: connected
              ? 'after sign-in: $e'
              : 'during sign-in: $e',
        );
      });
    } finally {
      // Best effort: a failing disconnect must not mask the real result, and
      // must never be the reason the UI stays disabled.
      try {
        await service?.disconnect();
      } catch (_) {
        // Socket is going away regardless.
      }
      // The single place _busy returns to false. Every path above can throw;
      // this cannot.
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadModel() async {
    setState(() => _busy = true);
    // Same reasoning as _testConnection: a throw from either call must not
    // leave the screen permanently disabled.
    try {
      await _saveAll();
      await _runtime.ensureModelInstalled();
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelState = ModelState(
            status: ModelStatus.failed,
            progress: 0,
            message: 'Could not download the model: $e',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up Heads Up')),
      body: ListView(
        padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
        children: [
          _privacyNote(theme),
          const SizedBox(height: HeadsUpSpacing.rowGap),
          _sectionLabel(theme, 'Your Gmail account'),
          TextField(
            controller: _host,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'IMAP host'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _user,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email address'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _appPassword,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'App password (16 characters)',
              helperText: 'Google Account → Security → App passwords',
            ),
          ),

          const SizedBox(height: HeadsUpSpacing.rowGap),
          _sectionLabel(theme, 'Voice (optional)'),
          TextField(
            controller: _elevenLabsKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'ElevenLabs API key',
              helperText: 'Leave empty to use this phone\'s own voice.',
            ),
          ),

          const SizedBox(height: HeadsUpSpacing.rowGap),
          _sectionLabel(theme, 'Language model'),
          TextField(
            controller: _hfToken,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'HuggingFace read token',
              helperText: 'Needed once, to download the model.',
            ),
          ),
          const SizedBox(height: 8),
          _modelRow(theme),

          const SizedBox(height: HeadsUpSpacing.rowGap),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _testConnection,
                  child: const Text('Test connection'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _downloadModel,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          if (_proof != null) ...[
            const SizedBox(height: HeadsUpSpacing.rowGap),
            _proofPanel(theme, _proof!),
          ],
        ],
      ),
    );
  }

  /// prd.md §6.1 marks this privacy note non-negotiable and always visible.
  Widget _privacyNote(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HeadsUpColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HeadsUpColors.textSecondary),
      ),
      child: Text(
        'This app reads your emails on this phone. Only short summaries are '
        'sent to ElevenLabs for voice. Your full emails never leave the phone.',
        style: theme.textTheme.labelSmall,
      ),
    );
  }

  /// Needs bottom padding: a [TextField]'s floating label is drawn above the
  /// field's own box, so with no gap here the two labels overlap on screen.
  /// Found by screenshotting the running app, not by a widget test — the
  /// overflow is a paint-time layout, invisible to `flutter test`.
  Widget _sectionLabel(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: theme.textTheme.bodyMedium),
      );

  Widget _modelRow(ThemeData theme) {
    final label = switch (_modelState.status) {
      ModelStatus.notDownloaded => 'Model: not downloaded',
      ModelStatus.downloading =>
        'Downloading… ${(_modelState.progress * 100).toStringAsFixed(0)}%',
      ModelStatus.ready => 'Model: ready',
      ModelStatus.failed => 'Model: failed',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        if (_modelState.status == ModelStatus.downloading)
          LinearProgressIndicator(value: _modelState.progress),
        if (_modelState.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_modelState.message!, style: theme.textTheme.labelSmall),
          ),
      ],
    );
  }

  Widget _proofPanel(ThemeData theme, ReadOnlyProof proof) {
    // Three states, never two. Green is only ever shown for a run that
    // actually measured both diffs; an unmeasured run is neutral grey, so it
    // can never be mistaken for a pass.
    final (colour, icon) = switch (proof.stage) {
      ProofStage.fullyVerified => (HeadsUpColors.calm, Icons.verified_outlined),
      ProofStage.examineVerified || ProofStage.flagsVerified => (
          HeadsUpColors.textSecondary,
          Icons.help_outline,
        ),
      ProofStage.notRun => (HeadsUpColors.urgent, Icons.error_outline),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HeadsUpColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colour),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colour),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  proof.verdict,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colour),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            proof.summary(),
            style: theme.textTheme.labelSmall,
          ),

          // The raw IMAP text. Without this the panel said only "something went
          // wrong", which made the first live failure unrecoverable without
          // guessing. Selectable so it can be copied into a bug report.
          if (proof.errorDetail != null) ...[
            const SizedBox(height: 8),
            Text(
              'Details',
              style: theme.textTheme.labelSmall?.copyWith(
                color: HeadsUpColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              proof.errorDetail!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: HeadsUpColors.textSecondary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}