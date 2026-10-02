/// The deterministic rules engine: decides which emails matter.
///
/// Specification: rules.md (all sections). This file is the heart of the
/// product, and it obeys one absolute rule from rules.md §1:
///
/// > Gemma decides nothing about importance. Rules decide. Gemma only rewrites.
///
/// Three design decisions worth stating:
///
/// 1. **Pure core, no IMAP.** [score] takes an [EmailFacts] value object rather
///    than a `MimeMessage`, so the whole engine is unit-testable offline
///    against `test/fixtures/fake_emails/` with no network. [EmailFacts]
///    carries the adapter for real messages.
/// 2. **Injectable clock.** [now] is a constructor argument rather than an
///    inline `DateTime.now()`. rules.md §4.2/§4.3 resolve deadlines relative to
///    the current time, so an injected clock is the only way to assert on them
///    deterministically.
/// 3. **Whole-word action-word matching.** rules.md §3 states matching should
///    use "whole-word matching where practical", but the snippet below it uses
///    a bare `contains`. That snippet would score "information" and "platform"
///    as hits for the action word "form". The prose is followed here, because
///    false positives are the expensive error here (rules.md §1: prefer missing
///    something over spamming him).
library;

import 'dart:math' as math;

import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Everything the rules engine needs from an email, and nothing else.
///
/// Deliberately decoupled from `MimeMessage` so the engine stays pure.
class EmailFacts {
  const EmailFacts({
    required this.uid,
    required this.receivedAt,
    required this.senderName,
    required this.senderAddress,
    required this.subject,
    required this.body,
    this.listUnsubscribe,
    this.precedence,
    this.xMailer,
    this.inReplyTo,
    this.toAddresses = const [],
    this.ccAddresses = const [],
    this.bccAddresses = const [],
  });

  final int uid;
  final DateTime receivedAt;
  final String senderName;
  final String senderAddress;
  final String subject;

  /// Already cleaned by [Cleaner] — never re-cleaned here.
  final String body;

  final String? listUnsubscribe;
  final String? precedence;
  final String? xMailer;
  final String? inReplyTo;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final List<String> bccAddresses;

  /// Stable item id (architecture.md §5.1).
  String get itemId => '${uid}_INBOX';
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// A deadline found by regex, plus how it should be worded for the reader.
class ExtractedDeadline {
  const ExtractedDeadline({required this.date, required this.label});

  final DateTime date;

  /// Plain-language form: "today", "tomorrow", "Friday", "Oct 10", "was Oct 5"
  /// (rules.md §4.4).
  final String label;

  @override
  String toString() => 'ExtractedDeadline($date, "$label")';
}

/// Result of scoring one email (rules.md §7).
class ScoringResult {
  const ScoringResult({
    required this.item,
    required this.deadline,
  });

  final MailItem item;

  /// Null when no in-window deadline was found.
  final ExtractedDeadline? deadline;

  /// Whether this item should be handed to Gemma.
  bool passesThreshold(int threshold) => item.score >= threshold;

  /// Whether this item is ready to show on the widget.
  ///
  /// The widget only ever displays fully processed items (architecture.md §8),
  /// so a scored-but-not-rewritten item must stay invisible.
  bool get isDisplayable => item.isProcessed;
}

// ---------------------------------------------------------------------------
// Patterns (rules.md §5)
// ---------------------------------------------------------------------------

const List<String> _noReplyPatterns = [
  'noreply@',
  'no-reply@',
  'donotreply@',
  'do-not-reply@',
  'notifications@',
  'mailer@',
  'bounce@',
  'auto@',
  'automated@',
];

const List<String> _promoSubjectPatterns = [
  r'\d+%\s*off',
  r'don.t miss',
  r'limited time',
  r'special offer',
  r'buy now',
  r'shop now',
  r'sale ends',
  r'flash sale',
  r'exclusive deal',
  r'save \$?\d+',
];

const List<String> _espMarkers = [
  'mailchimp',
  'sendgrid',
  'hubspot',
  'klaviyo',
  'constant contact',
  'campaignmonitor',
  'mailerlite',
  'brevo',
  'sendinblue',
];

// --- Deadline patterns, priority order (rules.md §4.1) ---

/// Month token: "oct", "October", "Sept.", and so on.
const String _monthToken = r'(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|'
    r'dec)\w*\.?';

/// Either orientation of "month day" / "day month", with ordinal suffixes:
/// "October 10", "10th October", "Oct 10", "10 Oct".
///
/// Built with `+` rather than interpolation because `$_monthToken` inside a raw
/// string (`r'...'`) is literal text, not a substitution — a mistake that
/// silently produces a regex matching nothing.
// ignore_for_file: prefer_interpolation_to_compose_strings
const String _monthDayPattern = '(?:' + _monthToken +
    r'\s+\d{1,2}(?:st|nd|rd|th)?)'
    r'|\d{1,2}(?:st|nd|rd|th)?\s+(?:' + _monthToken + ')';

/// Pattern 1: "by October 10", "by Oct 10", "by 10th October".
final RegExp _explicitDatePhrase = RegExp(
  r'\bby\s+(' + _monthDayPattern + ')',
  caseSensitive: false,
);

/// Pattern 2: "10/10/2026", "10-10-2026", "2026-10-10".
final RegExp _fullDate = RegExp(
  r'\b(\d{1,2}[/\-]\d{1,2}[/\-]\d{4}|\d{4}[/\-]\d{2}[/\-]\d{2})\b',
);

/// Pattern 3: "Oct 10", "October 10", "10 Oct".
final RegExp _shortMonthDay = RegExp(
  r'\b(' + _monthDayPattern + r')\b',
  caseSensitive: false,
);

/// Pattern 4: "by Friday", "before Monday", "next Tuesday".
///
/// Two alternatives. The first is rules.md §4.1 verbatim (a preposition is
/// required). The second accepts a bare `next/this <weekday>` with no
/// preposition, which §4.1 misses but fixture `12_interview_offer` depends on —
/// that fixture says "scheduled for next Monday", where "for" is not in the
/// spec's preposition list. Without this the fixture's expected deadline is
/// unreachable.
///
/// A weekday with neither a preposition nor a qualifier ("meet Monday
/// afternoons") is still *not* matched, which is deliberate: plenty of mail
/// mentions weekdays without setting a deadline.
final RegExp _relativeWeekday = RegExp(
  r'\b(?:by|before|until|on)\s+(?:(?:this|next)\s+)?'
      r'(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b'
      r'|\b(?:this|next)\s+'
      r'(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
  caseSensitive: false,
);

/// Pattern 5: "by tonight", "by tomorrow", "by EOD", "by end of week".
final RegExp _namedRelative = RegExp(
  r'\b(by|before|until)\s+'
  r'(tonight|today|tomorrow|eod|end of day|end of week|this week)\b',
  caseSensitive: false,
);

/// Pattern 6: "within 3 days", "in 2 days", "within 24 hours".
final RegExp _duration = RegExp(
  r'\bwithin\s+(\d+)\s+(hours?|days?|weeks?)\b',
  caseSensitive: false,
);

const List<String> _weekdayNames = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

const List<String> _monthNames = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

class RulesEngine {
  RulesEngine(this.config, {DateTime? now})
      : now = now ?? DateTime.now();

  final RulesConfig config;

  /// Injected clock. Every relative deadline decision reads this, never
  /// `DateTime.now()`, so tests are deterministic.
  final DateTime now;

  // --- Scoring entry point (rules.md §7) ---

  ScoringResult score(EmailFacts facts) {
    final reasons = <String>[];
    var score = 0;

    final sender = facts.senderAddress.trim().toLowerCase();
    final subject = facts.subject;

    // VIP first — it changes how penalties are applied (rules.md §2.3).
    final isVipAddress = matchesVipAddress(sender, config.vipAddresses);
    final isVipDomain = matchesVipDomain(sender, config.vipDomains);
    final isVip = isVipAddress || isVipDomain;

    if (isVipAddress) {
      score += 50;
      reasons.add('VIP sender');
    }
    if (isVipDomain) {
      score += 30;
      reasons.add('VIP domain');
    }

    // Ignore list is absolute and short-circuits everything else
    // (rules.md §5.4) — even action words cannot rescue it.
    if (isIgnored(sender, config)) {
      return ScoringResult(
        item: _buildItem(
          facts,
          score: -100,
          reasons: ['ignored by user'],
          deadline: null,
          isVip: isVip,
        ),
        deadline: null,
      );
    }

    // --- Penalties (rules.md §2.2) ---
    if (facts.listUnsubscribe != null) {
      score -= 100;
      reasons.add('newsletter');
    }
    final precedence = facts.precedence?.trim().toLowerCase() ?? '';
    if (precedence == 'bulk' || precedence == 'list') {
      score -= 80;
      reasons.add('bulk mail');
    }
    if (!isVip && isNoReply(sender)) {
      score -= 60;
      reasons.add('noreply sender');
    }
    if (matchesPromoSubject(subject)) {
      score -= 30;
      reasons.add('promo subject');
    }
    if (isEspMailer(facts.xMailer)) {
      score -= 40;
      reasons.add('marketing platform');
    }

    // --- Boosts (rules.md §2.1) ---
    if (matchesAnyKeyword(subject, config.vipKeywords)) {
      score += 40;
      reasons.add('VIP keyword');
    }

    // Subject beats body: a single +40 rather than a +40 and a +20.
    if (containsActionWord(subject, config.actionWords)) {
      score += 40;
      reasons.add('action word in subject');
    } else if (containsActionWord(facts.body, config.actionWords)) {
      score += 20;
      reasons.add('action word in body');
    }

    final deadline = extractDeadline('${facts.body} $subject', facts.receivedAt);
    if (deadline != null) {
      // rules.md §4.3: a *past* deadline is still reported (it may be fixable,
      // and it powers the missed list) but earns no boost.
      //
      // Note: rules.md §7's pseudocode adds +30 whenever daysAway >= -2, which
      // would boost already-missed deadlines. §4.3 is the more specific rule
      // and is followed here: only future deadlines boost.
      if (!deadline.date.isBefore(now)) {
        score += 30;
        reasons.add('deadline within window');
      } else {
        reasons.add('deadline passed');
      }
    }

    if (facts.inReplyTo != null && !isNoReply(sender)) {
      score += 15;
      reasons.add('direct reply');
    }

    if (_isSingleRecipient(facts)) {
      score += 10;
      reasons.add('sent to you alone');
    }

    // rules.md §2.3: VIP is a hard floor at the threshold.
    if (isVip && score < config.scoreThreshold) {
      score = config.scoreThreshold;
      reasons.add('VIP override');
    }

    return ScoringResult(
      item: _buildItem(
        facts,
        score: score,
        reasons: reasons,
        deadline: deadline?.date,
        isVip: isVip,
      ),
      deadline: deadline,
    );
  }

  MailItem _buildItem(
    EmailFacts facts, {
    required int score,
    required List<String> reasons,
    required DateTime? deadline,
    required bool isVip,
  }) {
    return MailItem(
      id: facts.itemId,
      receivedAt: facts.receivedAt,
      senderName: facts.senderName.isEmpty
          ? facts.senderAddress
          : facts.senderName,
      senderAddress: facts.senderAddress,
      subject: facts.subject,
      score: score,
      reasons: reasons,
      deadline: deadline,
      isVip: isVip,
      status: ItemStatus.fresh,
      audioSource: AudioSource.none,
      processedAt: now,
    );
  }

  bool _isSingleRecipient(EmailFacts facts) =>
      facts.toAddresses.length == 1 &&
      facts.ccAddresses.isEmpty &&
      facts.bccAddresses.isEmpty;

  // --- Matching helpers, public so tests can target them (rules.md §9) ---

  /// Whole-word, case-insensitive match (rules.md §3 "where practical").
  bool containsActionWord(String text, List<String> actionWords) =>
      matchesAnyKeyword(text, actionWords);

  /// Shared whole-word matcher for action words and VIP keywords.
  bool matchesAnyKeyword(String text, List<String> words) {
    if (text.isEmpty || words.isEmpty) return false;
    final haystack = text.toLowerCase();
    return words.any((word) {
      final needle = word.trim().toLowerCase();
      if (needle.isEmpty) return false;
      return RegExp(
        r'\b' + RegExp.escape(needle) + r'\b',
      ).hasMatch(haystack);
    });
  }

  /// Exact address match (rules.md §2.1).
  bool matchesVipAddress(String senderAddress, List<String> vipAddresses) {
    final sender = senderAddress.trim().toLowerCase();
    return vipAddresses.any((v) => v.trim().toLowerCase() == sender);
  }

  /// Domain match, allowing subdomains (rules.md §2.1).
  bool matchesVipDomain(String senderAddress, List<String> vipDomains) {
    final at = senderAddress.lastIndexOf('@');
    if (at == -1) return false;
    final domain = senderAddress.substring(at + 1).trim().toLowerCase();
    return vipDomains.any((v) {
      final candidate = v.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
      return domain == candidate || domain.endsWith('.$candidate');
    });
  }

  /// User ignore list — exact address or domain suffix (rules.md §5.4).
  bool isIgnored(String senderAddress, RulesConfig config) {
    final sender = senderAddress.trim().toLowerCase();
    final at = sender.lastIndexOf('@');
    final domain = at == -1 ? '' : sender.substring(at + 1);
    return config.ignoreAddresses.any((v) {
      final candidate = v.trim().toLowerCase();
      return candidate == sender ||
          (domain.isNotEmpty && (candidate == domain ||
              domain.endsWith('.$candidate')));
    }) ||
        config.ignoreDomains.any((v) {
          final candidate = v.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
          return domain.isNotEmpty &&
              (domain == candidate || domain.endsWith('.$candidate'));
        });
  }

  /// rules.md §5.1.
  bool isNoReply(String address) {
    final lower = address.trim().toLowerCase();
    return _noReplyPatterns.any((p) => lower.startsWith(p) || lower.contains(p));
  }

  /// rules.md §5.2.
  bool matchesPromoSubject(String subject) {
    final lower = subject.toLowerCase();
    return _promoSubjectPatterns.any((p) => RegExp(p, caseSensitive: false).hasMatch(lower));
  }

  /// rules.md §5.3.
  bool isEspMailer(String? xMailer) {
    if (xMailer == null || xMailer.isEmpty) return false;
    final lower = xMailer.toLowerCase();
    return _espMarkers.any(lower.contains);
  }

  // --- Deadline extraction (rules.md §4) ---

  /// Finds a deadline and words it for the reader.
  ///
  /// Returns null when nothing matches or the resolved date falls outside the
  /// reporting window (rules.md §4.3).
  ExtractedDeadline? extractDeadline(String text, DateTime receivedAt) {
    for (final candidate in _deadlineCandidates(text, receivedAt)) {
      if (candidate == null) continue;
      final daysAway = _daysUntil(candidate.date);
      const gracePastDays = 2;
      if (daysAway < -gracePastDays) continue;
      if (daysAway > config.deadlineWindowDays) continue;
      return candidate;
    }
    return null;
  }

  /// Resolved dates for every pattern that matched, in priority order.
  ///
  /// Exposed for testing: it reports every match rather than only the first, so
  /// a test can assert that priority order is respected.
  List<ExtractedDeadline?> _deadlineCandidates(String text, DateTime src) {
    return [
      _matchExplicitDate(text, src),
      _matchFullDate(text, src),
      _matchShortMonthDay(text, src),
      _matchWeekday(text, src),
      _matchNamedRelative(text, src),
      _matchDuration(text, src),
    ];
  }

  ExtractedDeadline? _matchExplicitDate(String text, DateTime src) {
    final m = _explicitDatePhrase.firstMatch(text);
    if (m == null) return null;
    final resolved = _resolveMonthDay(m.group(1)!, src);
    return resolved == null ? null : _label(resolved);
  }

  ExtractedDeadline? _matchFullDate(String text, DateTime src) {
    final m = _fullDate.firstMatch(text);
    if (m == null) return null;
    final parts = m.group(1)!.split(RegExp(r'[/\-]')).map(int.parse).toList();
    final DateTime date;
    if (parts.first > 31) {
      // ISO order: yyyy-mm-dd
      date = DateTime(parts[0], parts[1], parts[2]);
    } else if (parts.first == parts[1] && parts.first > 12) {
      // dd/mm/yyyy
      date = DateTime(parts[2], parts[1], parts[0]);
    } else {
      // mm/dd/yyyy
      date = DateTime(parts[2], parts[0], parts[1]);
    }
    if (date.year < 1970 || date.year > 2200) return null;
    return _label(date);
  }

  ExtractedDeadline? _matchShortMonthDay(String text, DateTime src) {
    final m = _shortMonthDay.firstMatch(text);
    if (m == null) return null;
    final resolved = _resolveMonthDay(m.group(1)!, src);
    return resolved == null ? null : _label(resolved);
  }

  ExtractedDeadline? _matchWeekday(String text, DateTime src) {
    final m = _relativeWeekday.firstMatch(text);
    if (m == null) return null;

    // Two alternatives, each with its own weekday capture: group 1 for the
    // preposition form, group 2 for the bare "this/next <weekday>" form.
    final weekdayName = (m.group(1) ?? m.group(2))!.toLowerCase();
    final listIndex = _weekdayNames.indexOf(weekdayName);
    if (listIndex == -1) return null;

    // `_weekdayNames` is 0-based from Monday; `DateTime.weekday` is 1-based
    // from Monday. Comparing them directly is an off-by-one that made
    // "by Friday" resolve to the day it was sent.
    final target = DateTime.monday + listIndex;

    // Dart's `%` returns a non-negative result for a positive divisor, so this
    // wraps correctly across the Sunday boundary too.
    final daysAhead = (target - src.weekday) % 7;

    // "this"/"next" is deliberately NOT shifted by a further week. On a
    // Thursday, "next Monday" almost always means the Monday in three days, not
    // the one in ten — and inventing a later deadline is the worse error for a
    // reader who might otherwise miss it.
    final day = _dateOnly(src).add(Duration(days: daysAhead));
    // "by Friday" implies end of that day.
    return _label(DateTime(day.year, day.month, day.day, 23, 59));
  }

  ExtractedDeadline? _matchNamedRelative(String text, DateTime src) {
    final m = _namedRelative.firstMatch(text);
    if (m == null) return null;
    final day = _dateOnly(src);
    switch (m.group(2)!.toLowerCase()) {
      case 'tonight':
      case 'today':
      case 'eod':
      case 'end of day':
        return _label(DateTime(day.year, day.month, day.day, 23, 59));
      case 'tomorrow':
        final t = day.add(const Duration(days: 1));
        return _label(DateTime(t.year, t.month, t.day, 23, 59));
      case 'end of week':
      case 'this week':
        // End of the coming Sunday.
        final untilSunday = (DateTime.sunday - day.weekday) % 7;
        final sunday = day.add(Duration(days: untilSunday));
        return _label(DateTime(sunday.year, sunday.month, sunday.day, 23, 59));
      default:
        return null;
    }
  }

  ExtractedDeadline? _matchDuration(String text, DateTime src) {
    final m = _duration.firstMatch(text);
    if (m == null) return null;
    final amount = int.tryParse(m.group(1)!);
    if (amount == null) return null;
    final unit = m.group(2)!.toLowerCase();
    final duration = switch (unit) {
      'hour' || 'hours' => Duration(hours: amount),
      'day' || 'days' => Duration(days: amount),
      _ => Duration(days: amount * 7),
    };
    return _label(src.add(duration));
  }

  /// Parses "October 10", "Oct 10", "10th October", "10 Oct" against [src]'s year.
  DateTime? _resolveMonthDay(String raw, DateTime src) {
    final cleaned = raw
        .replaceAll(RegExp(r'(\d{1,2})(st|nd|rd|th)', caseSensitive: false), r'$1')
        .replaceAll('.', '')
        .trim();
    final parts = cleaned
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length != 2) return null;

    int? month;
    int? day;
    for (final part in parts) {
      final lower = part.toLowerCase();
      // Require at least three letters so "ma" cannot resolve to "march".
      final monthIndex = lower.length >= 3
          ? _monthNames.indexWhere((m) => m.startsWith(lower))
          : -1;
      final asInt = int.tryParse(lower);
      if (monthIndex != -1) {
        month = monthIndex + 1;
      } else if (asInt != null) {
        day = asInt;
      }
    }
    if (month == null || day == null) return null;
    if (day < 1 || day > 31) return null;

    var year = src.year;
    // A month already well past us means next year ("by 3 January" in October).
    if (month < src.month) year += 1;
    return DateTime(year, month, day, 23, 59);
  }

  /// Words a deadline for a dyslexic reader (rules.md §4.4).
  ExtractedDeadline _label(DateTime deadline) =>
      ExtractedDeadline(date: deadline, label: formatDeadlineLabel(deadline));

  String formatDeadlineLabel(DateTime deadline) {
    final today = _dateOnly(now);
    final target = _dateOnly(deadline);
    final daysAway = target.difference(today).inDays;

    if (daysAway < 0) {
      return 'was ${DateFormat('MMM d').format(target)}';
    }
    if (daysAway == 0) return 'today';
    if (daysAway == 1) return 'tomorrow';
    if (daysAway < 7) return DateFormat('EEEE').format(target);
    return DateFormat('MMM d').format(target);
  }

  int _daysUntil(DateTime target) =>
      _dateOnly(target).difference(_dateOnly(now)).inDays;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Convenience for pipelines that must cap Gemma calls (rules.md §2.4):
  /// "If more than 5 score above threshold, take the top 5 by score."
  List<ScoringResult> capToTopScoring(
    List<ScoringResult> results,
    int max,
  ) {
    final sorted = [...results]
      // Highest score first. Ties broken by oldest email, so the cap favours
      // whichever item has been waiting longest.
      ..sort((a, b) {
        final byScore = b.item.score.compareTo(a.item.score);
        if (byScore != 0) return byScore;
        return a.item.receivedAt.compareTo(b.item.receivedAt);
      });
    return sorted.take(max).toList();
  }

  /// Maximum score any result in [results] reached, for logging.
  int maxScoreOf(Iterable<ScoringResult> results) =>
      results.fold(0, (best, r) => math.max(best, r.item.score));
}