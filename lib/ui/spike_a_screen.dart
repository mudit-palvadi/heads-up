/// Spike A harness — measures on-device Gemma latency and output quality.
///
/// Specification: phases.md Phase 4. This is a **gate**, not a feature: the
/// numbers decide whether the product keeps Gemma 3 1B or falls back to
/// 270M, and they go straight into the DEV post.
///
/// The measurements this screen is required to capture (phases.md
/// "What to Measure and Capture"):
///   * per-email inference latency, via [Stopwatch]
///   * the raw model output alongside the parsed WHAT/DO/BY, so a rejection can
///     be attributed to `malformedShape` vs `inventedDate`
///   * the Gemma fallback rate
///
/// Removed once the gate is closed and the pipeline exists.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/cleaner.dart';
import 'package:heads_up/services/gemma_runtime.dart';
import 'package:heads_up/services/gemma_service.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/ui/theme.dart';

/// Synthetic sample, matching `test/fixtures/fake_emails/01_college_form_deadline.txt`
/// in shape and deadline. Invented content only — prd.md §8 forbids real email
/// content in anything that gets shared.
const String _sampleSubject = 'URGENT: Enrollment Form Due Oct 10';

const String _sampleBody = '''
Dear Student,

Your enrollment form for the upcoming semester must be submitted by October 10, 2026.
Please upload your ID proof and the signed declaration on the student portal.

Failure to submit by the deadline will result in cancellation of your enrollment.

Student Services
''';

/// Fixed clock so the rules engine's deadline resolution is deterministic and
/// the gate number can be reproduced.
final DateTime _spikeNow = DateTime(2026, 10, 1, 9);

class SpikeAScreen extends StatefulWidget {
  const SpikeAScreen({super.key});

  @override
  State<SpikeAScreen> createState() => _SpikeAScreenState();
}

class _SpikeAScreenState extends State<SpikeAScreen> {
  final _gemma = const GemmaService();
  late final GemmaRuntime _runtime = GemmaRuntime(Store());
  late final Store _store = Store();

  final _tokenController = TextEditingController();

  ModelState _modelState = const ModelState(status: ModelStatus.notDownloaded);
  String _output = '';
  bool _busy = false;
  bool _initialised = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _runtime.changes.listen((state) {
      if (mounted) setState(() => _modelState = state);
    });
    final existing = await _store.readSecret(SecretKeys.hfToken);
    if (mounted && (existing?.isNotEmpty ?? false)) {
      _tokenController.text = existing!;
    }
    await _runtime.initialise();
    if (mounted) {
      setState(() => _initialised = true);
    }
    // install() is idempotent, so this only reports readiness if already
    // downloaded — it must never trigger a 529 MB download without intent.
    final ready = await _runtime.isReady();
    if (mounted && ready) {
      setState(() => _modelState =
          const ModelState(status: ModelStatus.ready, progress: 1));
    }
  }

  Future<void> _saveToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    await _store.writeSecret(SecretKeys.hfToken, token);
    // Keep it off screen and out of the keyboard's history.
    _tokenController.clear();
    final clipboardFree = await Clipboard.getData('clipboard');
    if (clipboardFree != null) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token saved to the Android KeyStore')),
      );
    }
  }

  Future<void> _download() async {
    setState(() => _busy = true);
    await _runtime.ensureModelInstalled();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _runInference() async {
    setState(() {
      _busy = true;
      _output = 'Running…';
    });

    const cleaner = Cleaner();
    final body = cleaner.clean(_sampleBody, null);

    // The rules engine owns the deadline; Gemma is only handed its text.
    const rulesDeadline = 'Oct 10';
    final prompt = _gemma.buildPrompt(body, 'Admissions', rulesDeadline);

    final stopwatch = Stopwatch()..start();
    String raw;
    try {
      raw = await _rawInference(prompt);
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _output = 'Inference threw after '
            '${stopwatch.elapsedMilliseconds}ms:\n$e';
        _busy = false;
      });
      return;
    }
    stopwatch.stop();

    final parsed = _gemma.parseOutput(raw, rulesDeadline);
    final rejection = _gemma.classifyRejection(raw, rulesDeadline);

    final buffer = StringBuffer()
      ..writeln('Latency: ${stopwatch.elapsedMilliseconds} ms '
          '(${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} s)')
      ..writeln('--- raw model output ---')
      ..writeln(raw.trim())
      ..writeln('--- parsed ---');
    if (parsed != null) {
      buffer
        ..writeln('WHAT: ${parsed.what}')
        ..writeln('DO:   ${parsed.doIt}')
        ..writeln('BY:   ${parsed.by ?? 'NONE'}');
    } else {
      buffer
        ..writeln('REJECTED (${rejection?.name})')
        ..writeln('fallback speechText: '
            '${GemmaService.buildSpeechText(_gemma.fallback(_stubItem()))}');
    }

    setState(() {
      _output = buffer.toString();
      _busy = false;
    });
  }

  /// Runs the engine directly so the raw text can be shown, which the parsed
  /// path hides. Uses the same session flow as `GemmaService.rewrite`.
  Future<String> _rawInference(String prompt) async {
    final model = await FlutterGemma.getActiveModel(maxTokens: 512);
    final session = await model.createSession();
    final buffer = StringBuffer();
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      await for (final chunk in session.getResponseAsync()) {
        buffer.write(chunk);
      }
    } finally {
      await session.close();
    }
    return buffer.toString();
  }

  /// A synthetic item, used only to render what the fallback template would say.
  MailItem _stubItem() => MailItem(
        id: 'spike_1_INBOX',
        receivedAt: _spikeNow,
        senderName: 'Admissions',
        senderAddress: 'admissions@university.edu',
        subject: _sampleSubject,
        score: 110,
        reasons: const ['spike'],
        deadline: DateTime(2026, 10, 10),
        isVip: false,
        processedAt: _spikeNow,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Spike A — Gemma')),
      body: ListView(
        padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
        children: [
          Text('Gemma 3 1B-IT on-device latency and output quality.',
              style: theme.textTheme.labelSmall),
          const SizedBox(height: HeadsUpSpacing.rowGap),

          TextField(
            controller: _tokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'HuggingFace read token (hf_…)',
              helperText: 'Stored in the Android KeyStore, never logged.',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _saveToken,
                  child: const Text('Save token'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _download,
                  child: const Text('Download model'),
                ),
              ),
            ],
          ),

          const SizedBox(height: HeadsUpSpacing.rowGap),
          _statusLine(theme),

          const SizedBox(height: HeadsUpSpacing.rowGap),
          FilledButton.icon(
            onPressed: _busy || _modelState.status != ModelStatus.ready
                ? null
                : _runInference,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run one inference'),
          ),

          if (_output.isNotEmpty) ...[
            const SizedBox(height: HeadsUpSpacing.rowGap),
            SelectableText(
              _output,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusLine(ThemeData theme) {
    final state = _modelState;
    final label = switch (state.status) {
      ModelStatus.notDownloaded => 'Model: not downloaded',
      ModelStatus.downloading =>
        'Downloading… ${(state.progress * 100).toStringAsFixed(0)}%',
      ModelStatus.ready => 'Model: ready',
      ModelStatus.failed => 'Model: failed',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Engine ${_initialised ? 'started' : 'starting…'}',
            style: theme.textTheme.labelSmall),
        Text(label, style: theme.textTheme.bodyMedium),
        if (state.status == ModelStatus.downloading)
          LinearProgressIndicator(value: state.progress),
        if (state.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(state.message!, style: theme.textTheme.labelSmall),
          ),
      ],
    );
  }
}

/// Kept separate so the speech fallback can be shown without a loaded model.