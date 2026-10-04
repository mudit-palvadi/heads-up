/// Orchestrates the mail pipeline: fetch → score → rewrite → speak → store → widget.
///
/// Specification: architecture.md §6.5 and §8.
///
/// Two entry points, and the split is the important design decision:
///
/// * [runLight] — IMAP + rules only. Runs in the WorkManager background isolate.
///   Cheap, no model, no network beyond IMAP. Scores an email but cannot rewrite
///   it, so it is *not* displayable (architecture.md §8).
/// * [runFull] — the whole chain. Runs when the app opens or "Refresh now" is
///   tapped. Gemma is deliberately absent from the background path because
///   Android's Low Memory Killer will kill the process mid-inference, and
///   because several seconds of heavy CPU in a background job drains the battery.
///
/// Every dependency is injected so the whole pipeline can be tested offline with
/// fakes — which is how the "light results never reach the widget" rule gets
/// tested without a device or a mailbox.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:heads_up/services/cleaner.dart';
import 'package:heads_up/services/gemma_service.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/rules_engine.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/services/voice_service.dart';
import 'package:heads_up/services/widget_sync.dart';
import 'package:intl/intl.dart';

/// One line in the status screen's pipeline log (prd.md §6.2).
class PipelineEvent {
  const PipelineEvent(this.at, this.message, {this.isError = false});

  final DateTime at;
  final String message;
  final bool isError;

  String get timeLabel {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// What a pipeline run did.
class PipelineResult {
  const PipelineResult({
    required this.fetched,
    required this.scored,
    required this.aboveThreshold,
    required this.rewritten,
    required this.fellBack,
    required this.voiced,
    required this.skippedByCap,
    required this.duration,
    required this.log,
    this.error,
  });

  final int fetched;
  final int scored;

  /// Emails that passed the rules threshold and were sent on to Gemma.
  final int aboveThreshold;

  /// Emails Gemma produced usable WHAT/DO for.
  final int rewritten;

  /// Emails that fell back to the template. `phases.md` asks for this rate.
  final int fellBack;

  /// Items that ended up with a cloud mp3.
  final int voiced;

  /// Items dropped because the per-run Gemma cap was hit.
  final int skippedByCap;

  final Duration duration;
  final List<PipelineEvent> log;
  final String? error;

  bool get succeeded => error == null;

  /// Fraction of rewrites that needed the fallback template.
  double get fallbackRate {
    final attempted = rewritten + fellBack;
    if (attempted == 0) return 0;
    return fellBack / attempted;
  }

  @override
  String toString() => 'PipelineResult(fetched: $fetched, scored: $scored, '
      'above: $aboveThreshold, rewritten: $rewritten, '
      'fellBack: $fellBack, voiced: $voiced)';
}

class Pipeline {
  Pipeline({
    required Store store,
    required MailService mail,
    Cleaner cleaner = const Cleaner(),
    GemmaService? gemma,
    VoiceService? voice,
    WidgetSync? widgetSync,
    RulesConfigBuilder? configBuilder,
  // ignore: prefer_initializing_formals
  })  : _store = store,
        // ignore: prefer_initializing_formals
        _mail = mail,
        // ignore: prefer_initializing_formals
        _cleaner = cleaner,
        _gemma = gemma ?? const GemmaService(),
        _voice = voice ?? VoiceService(),
        _widget = widgetSync ?? const WidgetSync(),
        _configBuilder = configBuilder ?? _defaultConfigBuilder;

  final Store _store;
  final MailService _mail;
  final Cleaner _cleaner;
  final GemmaService _gemma;
  final VoiceService _voice;
  final WidgetSync _widget;

  /// Builds the rules config from bundled defaults plus the user's overrides.
  final RulesConfigBuilder _configBuilder;

  static Future<RulesConfig> _defaultConfigBuilder(Store store) async {
    // The bundled asset is the base; the user's VIP edits layer on top.
    final merged = <String, Object?>{
      ...await _loadBundledRules(),
      ...?await store.loadRulesOverride(),
    };
    return RulesConfig.fromJsonString(jsonEncode(merged));
  }

  static Future<Map<String, Object?>> _loadBundledRules() async {
    try {
      final raw = await rootBundle.loadString('assets/default_rules.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      // A missing asset must not break the pipeline; empty rules simply mean a
      // lower hit rate rather than a crash.
    }
    return const {};
  }

  /// Keeps only the last few events, per prd.md §6.2.
  static const int maxLogEvents = 5;

  List<PipelineEvent> _log = const [];

  /// Recent pipeline history, newest last, capped at [maxLogEvents].
  List<PipelineEvent> get log => List.unmodifiable(_log);

  void _note(String message, {bool isError = false}) {
    _log = [
      ..._log,
      PipelineEvent(DateTime.now(), message, isError: isError),
    ];
    if (_log.length > maxLogEvents) {
      _log = _log.sublist(_log.length - maxLogEvents);
    }
  }

  /// The full pipeline. Call when the app opens or "Refresh now" is tapped.
  Future<PipelineResult> runFull({int? lastUidOverride}) async {
    final stopwatch = Stopwatch()..start();
    _log = const [];

    var fetched = 0;
    var scored = 0;
    var above = 0;
    var rewritten = 0;
    var fellBack = 0;
    var voiced = 0;

    try {
      final settings = await _store.loadSettings();
      final config = await _configBuilder(_store);
      final checkpoint = await _store.loadMailCheckpoint();

      // UIDVALIDITY guards against a server-side mailbox rebuild: if it changed,
      // our stored UIDs are meaningless and we must start over rather than skip
      // the whole inbox.
      final uidValidity = await _mail.inboxUidValidity();
      final effectiveLastUid =
          lastUidOverride ?? _checkpointFor(checkpoint, uidValidity);

      final messages = await _mail.fetchNew(lastUid: effectiveLastUid);
      fetched = messages.length;
      _note('Fetched $fetched new message${fetched == 1 ? '' : 's'}.');

      // Score everything first, so the cap picks the *best* rather than the
      // newest (rules.md §2.4).
      // Scored item kept paired with the mail it came from, so the rewrite step never
      // has to re-look-up by parsing an id.
      final candidates = <_Candidate>[];
      for (final mail in messages) {
        final cleaned = _cleaner.clean(mail.plainText, mail.htmlText);
        final result = _scoreOf(config, mail, cleaned);
        scored++;
        if (result.item.score >= settings.scoreThreshold) {
          candidates.add(_Candidate(result.item, cleaned));
        }
      }
      above = candidates.length;
      _note('$above of $scored scored above threshold.');

      final engine = RulesEngine(config, now: DateTime.now());
      final capped = engine
          .capToTopScoring(
            [
              for (final c in candidates)
                ScoringResult(item: c.item, deadline: null),
            ],
            config.maxItemsPerRun,
          )
          .map((r) => candidates.firstWhere((c) => identical(c.item, r.item)))
          .toList();
      final skipped = candidates.length - capped.length;
      if (skipped > 0) _note('Skipped $skipped beyond the Gemma cap.');

      final apiKey = settings.cloudVoiceEnabled
          ? await _store.readSecret(SecretKeys.elevenLabs)
          : null;

      for (final candidate in capped) {
        final scoredItem = candidate.item;
        final rulesDeadline = _deadlineLabel(scoredItem.deadline);
        final result = await _gemma.rewrite(
          item: scoredItem,
          cleanedText: candidate.cleanedBody,
          rulesDeadline: rulesDeadline,
        );

        if (result.usedFallback) {
          fellBack++;
        } else {
          rewritten++;
        }

        scoredItem
          ..what = result.output.what
          ..doIt = result.output.doIt
          ..by = result.output.by
          ..speechText = GemmaService.buildSpeechText(result.output);

        if (scoredItem.speechText != null) {
          if (apiKey != null && apiKey.isNotEmpty) {
            try {
              final voice = await _voice.generate(
                itemId: scoredItem.id,
                speechText: scoredItem.speechText!,
                voiceId: settings.elevenLabsVoiceId,
                apiKey: apiKey,
              );
              scoredItem
                ..audioPath = voice.path
                ..audioSource = voice.source;
              if (voice.hasCloudAudio) voiced++;
            } on VoiceException catch (e) {
              // Degrade rather than fail the whole run: the ▶ button falls back
              // to on-device speech.
              scoredItem
                ..audioPath = null
                ..audioSource = AudioSource.offlineTts;
              _note(VoiceService.explain(e.failure), isError: true);
            }
          } else {
            scoredItem.audioSource = AudioSource.offlineTts;
          }
        }

        await _store.saveItem(scoredItem);
      }

      final newestUid = messages.isEmpty
          ? effectiveLastUid
          : messages.map((m) => m.uid).reduce((a, b) => a > b ? a : b);

      await _store.saveMailCheckpoint(
        lastUid: newestUid > effectiveLastUid ? newestUid : effectiveLastUid,
        uidValidity: uidValidity,
      );
      await _syncWidget();

      stopwatch.stop();
      _note('Done in ${stopwatch.elapsedMilliseconds} ms.');

      return PipelineResult(
        fetched: fetched,
        scored: scored,
        aboveThreshold: above,
        rewritten: rewritten,
        fellBack: fellBack,
        voiced: voiced,
        skippedByCap: skipped,
        duration: stopwatch.elapsed,
        log: log,
      );
    } catch (e) {
      stopwatch.stop();
      _note('Stopped: $e', isError: true);
      return PipelineResult(
        fetched: fetched,
        scored: scored,
        aboveThreshold: above,
        rewritten: rewritten,
        fellBack: fellBack,
        voiced: voiced,
        skippedByCap: 0,
        duration: stopwatch.elapsed,
        log: log,
        error: e.toString(),
      );
    }
  }

  /// IMAP + rules only. Safe for the background isolate (architecture.md §8).
  ///
  /// Deliberately stores *unprocessed* items. They are invisible to the widget
  /// because [WidgetSync.visibleItems] filters on `isProcessed`.
  Future<PipelineResult> runLight({int? lastUidOverride}) async {
    final stopwatch = Stopwatch()..start();
    _log = const [];

    var fetched = 0;
    var scored = 0;
    var above = 0;

    try {
      final settings = await _store.loadSettings();
      final config = await _configBuilder(_store);
      final checkpoint = await _store.loadMailCheckpoint();

      final uidValidity = await _mail.inboxUidValidity();
      final effectiveLastUid =
          lastUidOverride ?? _checkpointFor(checkpoint, uidValidity);

      final messages = await _mail.fetchNew(lastUid: effectiveLastUid);
      fetched = messages.length;

      var stored = 0;
      for (final mail in messages) {
        final cleaned = _cleaner.clean(mail.plainText, mail.htmlText);
        final result = _scoreOf(config, mail, cleaned);
        scored++;
        if (result.item.score >= settings.scoreThreshold) {
          await _store.saveItem(result.item);
          above++;
          stored++;
        }
      }

      final newestUid = messages.isEmpty
          ? effectiveLastUid
          : messages.map((m) => m.uid).reduce((a, b) => a > b ? a : b);

      await _store.saveMailCheckpoint(
        lastUid: newestUid > effectiveLastUid ? newestUid : effectiveLastUid,
        uidValidity: uidValidity,
        checkedAt: DateTime.now(),
      );

      // Refresh anyway: it may retire items the user has marked done.
      await _syncWidget();
      stopwatch.stop();
      _note('Background check: $stored flagged, awaiting rewrite.');

      return PipelineResult(
        fetched: fetched,
        scored: scored,
        aboveThreshold: above,
        rewritten: 0,
        fellBack: 0,
        voiced: 0,
        skippedByCap: 0,
        duration: stopwatch.elapsed,
        log: log,
      );
    } catch (e) {
      stopwatch.stop();
      _note('Background check stopped: $e', isError: true);
      return PipelineResult(
        fetched: fetched,
        scored: scored,
        aboveThreshold: above,
        rewritten: 0,
        fellBack: 0,
        voiced: 0,
        skippedByCap: 0,
        duration: stopwatch.elapsed,
        log: log,
        error: e.toString(),
      );
    }
  }

  ScoringResult _scoreOf(
    RulesConfig config,
    FetchedMail mail,
    String cleaned,
  ) {
    // The engine is built per call so its injected clock is fresh; cheap, since
    // it holds no resources.
    final engine = RulesEngine(config, now: DateTime.now());
    return engine.score(mail.toFacts(cleaned));
  }

  /// A UIDVALIDITY change means the server rebuilt the mailbox, so every UID we
  /// remembered is stale. Restart from 0 rather than skipping the entire inbox.
  int _checkpointFor(
    ({int lastUid, int? uidValidity}) checkpoint,
    int currentUidValidity,
  ) {
    if (checkpoint.uidValidity == null) return checkpoint.lastUid;
    if (currentUidValidity != 0 && checkpoint.uidValidity != currentUidValidity) {
      debugPrint('Heads Up: UIDVALIDITY changed '
          '(${checkpoint.uidValidity} -> $currentUidValidity); restarting scan.');
      return 0;
    }
    return checkpoint.lastUid;
  }

  /// Formats a deadline the way `prd.md` §4.4 wants it read aloud.
  ///
  /// Duplicates `RulesEngine.formatDeadlineLabel` deliberately: this one works
  /// from the wall clock at run time, whereas the engine's takes an injected
  /// clock. Both follow the same table so spoken text and widget text agree.
  String? _deadlineLabel(DateTime? deadline) {
    if (deadline == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(deadline.year, deadline.month, deadline.day);
    final diff = day.difference(today).inDays;
    if (diff < 0) return 'was ${DateFormat('MMM d').format(deadline)}';
    if (diff == 0) return 'today';
    if (diff == 1) return 'tomorrow';
    if (diff < 7) return DateFormat('EEEE').format(day);
    return DateFormat('MMM d').format(deadline);
  }

  Future<void> _syncWidget() async {
    final items = await _store.getTopItems();
    await _widget.sync(items);
  }
}

/// Builds a [RulesConfig] from the store. Injectable for tests.
typedef RulesConfigBuilder = Future<RulesConfig> Function(Store store);

/// A scored item paired with the cleaned body it came from.
class _Candidate {
  const _Candidate(this.item, this.cleanedBody);

  final MailItem item;
  final String cleanedBody;
}
