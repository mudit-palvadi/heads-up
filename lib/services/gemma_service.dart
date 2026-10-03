/// On-device rewriting of a flagged email into WHAT / DO / BY.
///
/// Specification: architecture.md §6.3, prd.md §4, rules.md §1.
///
/// The single most important property of this file is that **Gemma never gets to
/// decide a deadline**. The rules engine extracts it by regex
/// (rules.md §4), passes it into the prompt verbatim, and then this file
/// *rejects* the output if `BY:` disagrees or names a date that was never given.
/// A 1B model will occasionally invent one, and an invented deadline is worse
/// than no deadline: the friend would act on a date that does not exist.
///
/// The pure parts — prompt construction, parsing and validation — are static and
/// side-effect free so they can be unit tested without the ~529 MB model. Only
/// [rewrite] touches the inference engine.
library;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:intl/intl.dart';

/// Result of one rewrite.
class GemmaOutput {
  const GemmaOutput({required this.what, required this.doIt, this.by});

  /// What the email is. One short line.
  final String what;

  /// The one thing the reader must do. One short line.
  final String doIt;

  /// Plain-language deadline, or null. Only ever a value the rules engine gave us.
  final String? by;
}

/// Why a rewrite was rejected, for the pipeline log and the write-up.
///
/// Tracking this matters: `phases.md` asks for a Gemma fallback rate, and the
/// only honest way to measure it is to count rejections by reason.
enum GemmaRejection {
  /// Output did not contain all three WHAT / DO / BY lines.
  malformedShape,

  /// Gemma produced a BY that was not the deadline the rules engine supplied.
  inventedDate,

  /// A line was too long to be readable on the widget (prd.md §7).
  tooLong,

  /// The model is not loaded, or inference threw.
  unavailable,
}

class GemmaResult {
  const GemmaResult({required this.output, this.rejected});

  /// Never null: on rejection [output] is the fallback template.
  final GemmaOutput output;

  /// Null when the rewrite was accepted.
  final GemmaRejection? rejected;

  bool get usedFallback => rejected != null;
}

class GemmaService {
  const GemmaService({this.maxLineLength = 80});

  /// architecture.md §6.3 rejects lines longer than this.
  final int maxLineLength;

  /// Longest context we will hand the model (Cleaner truncates to this too).
  static const int inputCharLimit = 1500;

  // --- Prompt (architecture.md §6.3) ----------------------------------------

  /// Builds the rewrite prompt.
  ///
  /// [rulesDeadline] must be the rules engine's output, never a guess. Passing
  /// null tells the model explicitly that there is no deadline, which is the
  /// only reliable way to get `BY: NONE` out of a small model.
  String buildPrompt(
    String cleanedText,
    String senderName,
    String? rulesDeadline,
  ) {
    final text = cleanedText.length > inputCharLimit
        ? cleanedText.substring(0, inputCharLimit)
        : cleanedText;

    return '''
You rewrite emails for a reader with dyslexia.
Rules:
- Use very short sentences and common, simple words.
- No jargon. No long words if a short one works.
- Do not add anything not in the email.
- Do not guess dates. Only use the deadline given below.
- Maximum 20 words per line.

Reply in exactly this format and nothing else:
WHAT: <what this email is, one short line>
DO: <the one thing the reader must do, one short line>
BY: <deadline or NONE>

Deadline from rules: ${rulesDeadline ?? 'NONE'}
Sender: $senderName
Email:
"""
$text
"""
''';
  }

  // --- Parsing and validation (architecture.md §6.3) -------------------------

  /// Extracts a single `FIELD: value` line.
  static String? field(String raw, String name) {
    final match = RegExp(
      '^\\s*$name\\s*:\\s*(.+)\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw);
    return match?.group(1)?.trim();
  }

  /// Parses and validates raw model output.
  ///
  /// Returns null when the output must not be trusted; the caller then uses
  /// [fallback]. [rulesDeadline] is the only deadline the model was allowed to
  /// use, so any disagreement is a rejection.
  GemmaOutput? parseOutput(String raw, String? rulesDeadline) {
    final what = field(raw, 'WHAT');
    final doIt = field(raw, 'DO');
    final by = field(raw, 'BY');

    // All three lines are required. A missing DO is the dangerous case: the
    // widget would render "WHAT" with no action, which is useless to the reader.
    if (what == null || doIt == null || by == null) return null;

    // Length guard (prd.md §7 — the widget shows at most two short lines).
    if (what.length > maxLineLength || doIt.length > maxLineLength) return null;

    final byIsNone = _isNone(by);
    // Display form keeps the model's own casing — the widget must read
    // "Oct 10", never "oct 10". Normalisation is for *comparison* only.
    final displayBy = byIsNone ? null : _tidyForDisplay(by);

    // Rule 1: if the rules engine found no deadline, the model may not name one.
    if (rulesDeadline == null && displayBy != null) return null;

    // Rule 2: if there *is* a deadline, the model must reproduce it. A model
    // that paraphrases "Oct 10" as "next Friday" has invented a date, even
    // though one was supplied.
    if (rulesDeadline != null) {
      if (displayBy == null) return null;
      if (!_sameDeadline(displayBy, rulesDeadline)) return null;
    }

    return GemmaOutput(what: what, doIt: doIt, by: displayBy);
  }

  /// Classifies why [parseOutput] rejected something, for logging.
  GemmaRejection? classifyRejection(String raw, String? rulesDeadline) {
    final what = field(raw, 'WHAT');
    final doIt = field(raw, 'DO');
    final by = field(raw, 'BY');
    if (what == null || doIt == null || by == null) {
      return GemmaRejection.malformedShape;
    }
    if (what.length > maxLineLength || doIt.length > maxLineLength) {
      return GemmaRejection.tooLong;
    }
    final displayBy = _isNone(by) ? null : _tidyForDisplay(by);
    if (rulesDeadline == null && displayBy != null) {
      return GemmaRejection.inventedDate;
    }
    if (rulesDeadline != null &&
        !_sameDeadline(displayBy ?? '', rulesDeadline)) {
      return GemmaRejection.inventedDate;
    }
    return null;
  }

  /// Wraps a rejection in the template from architecture.md §6.3.
  ///
  /// The friend must never see an empty row, so this is deliberately dull and
  /// always actionable.
  GemmaOutput fallback(MailItem item) => GemmaOutput(
        what: 'Email from ${item.senderName}',
        doIt: 'Check this message',
        by: item.deadline == null
            ? null
            : DateFormat('EEE, MMM d').format(item.deadline!),
      );

  /// Builds the text that gets spoken and sent to ElevenLabs (prd.md §4).
  ///
  /// Always ends in a full stop so speech does not run two sentences together.
  static String buildSpeechText(GemmaOutput output) {
    final parts = <String>[
      if (output.what.isNotEmpty) _terminate(output.what),
      if (output.doIt.isNotEmpty) _terminate(output.doIt),
      if (output.by != null && output.by!.isNotEmpty) 'By ${output.by}.',
    ];
    return parts.join(' ');
  }

  // --- Inference (needs the model on device) --------------------------------

  /// True once the engine has a model loaded.
  ///
  /// `getActiveModel()` returns a non-nullable model and *throws* when none is
  /// loaded, so absence is detected by catching rather than by a null check.
  Future<bool> isModelLoaded() async {
    try {
      await FlutterGemma.getActiveModel();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Rewrites one email on device.
  ///
  /// Never throws: any failure — model missing, inference error, unparseable
  /// output — comes back as [GemmaResult] with the fallback template, because a
  /// widget row must never be blank and there is no UI here to show an error on.
  Future<GemmaResult> rewrite({
    required MailItem item,
    required String cleanedText,
    required String? rulesDeadline,
  }) async {
    try {
      if (!await isModelLoaded()) {
        return GemmaResult(
          output: fallback(item),
          rejected: GemmaRejection.unavailable,
        );
      }

      final prompt = buildPrompt(cleanedText, item.senderName, rulesDeadline);

      final model = await FlutterGemma.getActiveModel(maxTokens: 512);

      final session = await model.createSession();
      final buffer = StringBuffer();
      try {
        // flutter_gemma 1.11.3 takes the prompt as a Message chunk, then streams
        // tokens from a separate call. architecture.md §6.3 shows a single
        // `session.getResponseStream(prompt: prompt)`; no such method exists —
        // it is `addQueryChunk` followed by `getResponseAsync()`.
        await session.addQueryChunk(Message.text(text: prompt, isUser: true));
        await for (final chunk in session.getResponseAsync()) {
          buffer.write(chunk);
        }
      } finally {
        await session.close();
      }

      final raw = buffer.toString();
      final parsed = parseOutput(raw, rulesDeadline);
      if (parsed == null) {
        return GemmaResult(
          output: fallback(item),
          rejected: classifyRejection(raw, rulesDeadline) ??
              GemmaRejection.malformedShape,
        );
      }

      return GemmaResult(output: parsed);
    } catch (_) {
      return GemmaResult(
        output: fallback(item),
        rejected: GemmaRejection.unavailable,
      );
    }
  }

  // --- Deadline comparison helpers -------------------------------------------

  static bool _isNone(String value) {
    final v = value.trim().toUpperCase();
    return v == 'NONE' || v == 'N/A' || v == 'NO DEADLINE' || v.isEmpty;
  }

  /// Strips a leading "by " and trailing punctuation for display, preserving case.
  ///
  /// "by Oct 10." becomes "Oct 10" so the widget reads naturally, but unlike the
  /// comparison form the original capitalisation survives.
  static String _tidyForDisplay(String value) {
    var v = value.trim();
    v = v.replaceFirst(RegExp(r'^by\s+', caseSensitive: false), '');
    v = v.replaceAll(RegExp(r'[.,;]+$'), '');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Reduces a deadline to a comparable form: "Friday", "friday." and
  /// "by Friday" must all count as the same date the rules engine found.
  static String _normaliseDeadline(String value) =>
      _tidyForDisplay(value).toLowerCase();

  /// Compares two deadline strings leniently.
  ///
  /// Exact match after normalisation, or both parse to the same calendar date.
  /// The second case matters because a model may render the same date the rules
  /// engine gave us as "Oct 10" versus "10 Oct" — same date, not an invention.
  static bool _sameDeadline(String a, String b) {
    if (_normaliseDeadline(a) == _normaliseDeadline(b)) return true;

    final dateA = _tryParseDeadline(a);
    final dateB = _tryParseDeadline(b);
    if (dateA != null && dateB != null) {
      return dateA.year == dateB.year &&
          dateA.month == dateB.month &&
          dateA.day == dateB.day;
    }
    return false;
  }

  static DateTime? _tryParseDeadline(String value) {
    final tidy = _tidyForDisplay(value);
    if (tidy.isEmpty) return null;

    // intl's parseStrict wants a properly cased month ("Oct"), so a normalised
    // lowercase string is offered alongside the original.
    for (final candidate in {tidy, _capitaliseMonths(tidy)}) {
      for (final pattern in ['MMM d', 'MMMM d', 'd MMM', 'd MMMM']) {
        try {
          return DateFormat(pattern, 'en_US').parseStrict(candidate);
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  /// "10 oct" -> "10 Oct". Only month-shaped words are touched.
  static String _capitaliseMonths(String value) => value.replaceAllMapped(
        RegExp(r'[a-zA-Z]{3,9}'),
        (m) => m[0]![0].toUpperCase() + m[0]!.substring(1).toLowerCase(),
      );

  static String _terminate(String sentence) {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.endsWith('.') ? trimmed : '$trimmed.';
  }
}