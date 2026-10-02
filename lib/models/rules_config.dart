/// Deterministic rules configuration — the brain of "what matters".
///
/// Specification: rules.md §6. This type is pure data with no Flutter
/// dependency so the rules engine stays testable offline (rules.md §1:
///
/// > Rules must be testable offline using the fake email fixtures in
/// > `test/fixtures/fake_emails/`.
///
/// The bundled defaults ship as `assets/default_rules.json`; the friend's own
/// VIP entries arrive as a partial override which is layered on top by
/// [mergeWith].
library;

import 'dart:convert';

class RulesConfig {
  final List<String> actionWords;
  final List<String> vipAddresses;
  final List<String> vipDomains;
  final List<String> vipKeywords;
  final List<String> ignoreAddresses;
  final List<String> ignoreDomains;

  /// Emails scoring at or above this go to Gemma (rules.md §2.4).
  final int scoreThreshold;

  /// Deadlines further out than this are ignored entirely (rules.md §4.3).
  final int deadlineWindowDays;

  /// Upper bound on Gemma calls per pipeline run (rules.md §2.4).
  final int maxItemsPerRun;

  const RulesConfig({
    this.actionWords = const [],
    this.vipAddresses = const [],
    this.vipDomains = const [],
    this.vipKeywords = const [],
    this.ignoreAddresses = const [],
    this.ignoreDomains = const [],
    this.scoreThreshold = 30,
    this.deadlineWindowDays = 14,
    this.maxItemsPerRun = 5,
  });

  factory RulesConfig.fromJsonString(String source) {
    final decoded = _decode(source);
    return RulesConfig(
      actionWords: _stringList(decoded['actionWords']),
      vipAddresses: _stringList(decoded['vipAddresses']),
      vipDomains: _stringList(decoded['vipDomains']),
      vipKeywords: _stringList(decoded['vipKeywords']),
      ignoreAddresses: _stringList(decoded['ignoreAddresses']),
      ignoreDomains: _stringList(decoded['ignoreDomains']),
      scoreThreshold: _int(decoded['scoreThreshold'], 30),
      deadlineWindowDays: _int(decoded['deadlineWindowDays'], 14),
      maxItemsPerRun: _int(decoded['maxItemsPerRun'], 5),
    );
  }

  /// Layers a user override on top of the bundled defaults (rules.md §6:
  /// "default config provides the base, user overrides append/replace").
  ///
  /// Lists *append* — a friend adding `university.edu` to VIP domains must not
  /// lose the action-word list. Scalars are replaced whenever present, which is
  /// how the score threshold in Settings takes effect.
  RulesConfig mergeWith(Map<String, Object?> overrides) {
    if (overrides.isEmpty) return this;
    return RulesConfig(
      actionWords: _append(actionWords, _stringList(overrides['actionWords'])),
      vipAddresses:
          _append(vipAddresses, _stringList(overrides['vipAddresses'])),
      vipDomains: _append(vipDomains, _stringList(overrides['vipDomains'])),
      vipKeywords: _append(vipKeywords, _stringList(overrides['vipKeywords'])),
      ignoreAddresses:
          _append(ignoreAddresses, _stringList(overrides['ignoreAddresses'])),
      ignoreDomains:
          _append(ignoreDomains, _stringList(overrides['ignoreDomains'])),
      scoreThreshold: _int(overrides['scoreThreshold'], scoreThreshold),
      deadlineWindowDays:
          _int(overrides['deadlineWindowDays'], deadlineWindowDays),
      maxItemsPerRun: _int(overrides['maxItemsPerRun'], maxItemsPerRun),
    );
  }

  RulesConfig copyWith({
    List<String>? vipAddresses,
    List<String>? vipDomains,
    List<String>? vipKeywords,
    List<String>? ignoreAddresses,
    List<String>? ignoreDomains,
    int? scoreThreshold,
  }) {
    return RulesConfig(
      actionWords: actionWords,
      vipAddresses: vipAddresses ?? this.vipAddresses,
      vipDomains: vipDomains ?? this.vipDomains,
      vipKeywords: vipKeywords ?? this.vipKeywords,
      ignoreAddresses: ignoreAddresses ?? this.ignoreAddresses,
      ignoreDomains: ignoreDomains ?? this.ignoreDomains,
      scoreThreshold: scoreThreshold ?? this.scoreThreshold,
      deadlineWindowDays: deadlineWindowDays,
      maxItemsPerRun: maxItemsPerRun,
    );
  }

  Map<String, Object?> toOverrideJson() => {
        'vipAddresses': vipAddresses,
        'vipDomains': vipDomains,
        'vipKeywords': vipKeywords,
        'ignoreAddresses': ignoreAddresses,
        'ignoreDomains': ignoreDomains,
        'scoreThreshold': scoreThreshold,
      };

  static Map<String, Object?> _decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('rules config must be a JSON object');
    }
    return decoded.cast<String, Object?>();
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }

  static int _int(Object? raw, int fallback) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

  static List<String> _append(List<String> base, List<String> extra) {
    if (extra.isEmpty) return base;
    final seen = base.map((e) => e.toLowerCase()).toSet();
    return [
      ...base,
      ...extra.where((e) => seen.add(e.toLowerCase())),
    ];
  }
}