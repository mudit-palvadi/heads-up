/// App configuration and user-editable rules.
///
/// Architecture: architecture.md §5.2
///
/// Secrets (IMAP app password, ElevenLabs key, HF token) are deliberately NOT
/// fields here — they live in flutter_secure_storage / Android KeyStore
/// (prd.md §8, architecture.md §10).
library;

class AppSettings {
  String imapHost;
  int imapPort;
  String imapUser;

  List<String> vipAddresses;
  List<String> vipDomains;
  List<String> vipKeywords;
  List<String> ignorePatterns;

  int checkIntervalMinutes;
  bool cloudVoiceEnabled;
  String elevenLabsVoiceId;
  int scoreThreshold;

  /// Highest IMAP UID processed so far. Persisted between sessions.
  int lastProcessedUid;

  /// IMAP UIDVALIDITY at the time of the last run. If the server reports a
  /// different value, UIDs have been reset and we start from scratch.
  int? lastProcessedUidValidity;

  DateTime? lastCheckAt;

  AppSettings({
    this.imapHost = 'imap.gmail.com',
    this.imapPort = 993,
    this.imapUser = '',
    this.vipAddresses = const [],
    this.vipDomains = const [],
    this.vipKeywords = const [],
    this.ignorePatterns = const [],
    this.checkIntervalMinutes = 60,
    this.cloudVoiceEnabled = true,
    this.elevenLabsVoiceId = 'EXAVITQu4vr4xnSDxMaL', // Bella — calm
    this.scoreThreshold = 30,
    this.lastProcessedUid = 0,
    this.lastProcessedUidValidity,
    this.lastCheckAt,
  });

  AppSettings copyWith({
    String? imapHost,
    int? imapPort,
    String? imapUser,
    List<String>? vipAddresses,
    List<String>? vipDomains,
    List<String>? vipKeywords,
    List<String>? ignorePatterns,
    int? checkIntervalMinutes,
    bool? cloudVoiceEnabled,
    String? elevenLabsVoiceId,
    int? scoreThreshold,
    int? lastProcessedUid,
    int? lastProcessedUidValidity,
    DateTime? lastCheckAt,
  }) {
    return AppSettings(
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      imapUser: imapUser ?? this.imapUser,
      vipAddresses: vipAddresses ?? this.vipAddresses,
      vipDomains: vipDomains ?? this.vipDomains,
      vipKeywords: vipKeywords ?? this.vipKeywords,
      ignorePatterns: ignorePatterns ?? this.ignorePatterns,
      checkIntervalMinutes:
          checkIntervalMinutes ?? this.checkIntervalMinutes,
      cloudVoiceEnabled: cloudVoiceEnabled ?? this.cloudVoiceEnabled,
      elevenLabsVoiceId: elevenLabsVoiceId ?? this.elevenLabsVoiceId,
      scoreThreshold: scoreThreshold ?? this.scoreThreshold,
      lastProcessedUid: lastProcessedUid ?? this.lastProcessedUid,
      lastProcessedUidValidity:
          lastProcessedUidValidity ?? this.lastProcessedUidValidity,
      lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    );
  }

  /// The check interval options offered in Settings (prd.md §6.4).
  static const List<int> checkIntervalOptions = [15, 30, 60, 120];

  /// Voice used when cloud voice is off or ElevenLabs fails.
  static const String offlineTtsLanguage = 'en-US';

  /// Slightly slower than the platform default, for clarity (prd.md §7).
  static const double offlineTtsSpeechRate = 0.45;

  // --- shared_preferences serialisation (architecture.md §5.2) ---

  /// Preferences are stored as one flat string map rather than individual keys,
  /// so adding a setting cannot leave an orphaned key behind.
  ///
  /// Secrets are deliberately absent: they live in the Android KeyStore via
  /// `flutter_secure_storage` (prd.md §8).
  Map<String, Object?> toMap() => {
        'imapHost': imapHost,
        'imapPort': imapPort,
        'imapUser': imapUser,
        'vipAddresses': vipAddresses,
        'vipDomains': vipDomains,
        'vipKeywords': vipKeywords,
        'ignorePatterns': ignorePatterns,
        'checkIntervalMinutes': checkIntervalMinutes,
        'cloudVoiceEnabled': cloudVoiceEnabled,
        'elevenLabsVoiceId': elevenLabsVoiceId,
        'scoreThreshold': scoreThreshold,
        'lastProcessedUid': lastProcessedUid,
        'lastProcessedUidValidity': lastProcessedUidValidity,
        'lastCheckAt': lastCheckAt?.millisecondsSinceEpoch,
      };

  factory AppSettings.fromMap(Map<String, Object?> map) {
    return AppSettings(
      imapHost: _string(map['imapHost']) ?? 'imap.gmail.com',
      imapPort: _int(map['imapPort']) ?? 993,
      imapUser: _string(map['imapUser']) ?? '',
      vipAddresses: _strings(map['vipAddresses']),
      vipDomains: _strings(map['vipDomains']),
      vipKeywords: _strings(map['vipKeywords']),
      ignorePatterns: _strings(map['ignorePatterns']),
      checkIntervalMinutes: _int(map['checkIntervalMinutes']) ?? 60,
      cloudVoiceEnabled: _bool(map['cloudVoiceEnabled']) ?? true,
      elevenLabsVoiceId:
          _string(map['elevenLabsVoiceId']) ?? 'EXAVITQu4vr4xnSDxMaL',
      scoreThreshold: _int(map['scoreThreshold']) ?? 30,
      lastProcessedUid: _int(map['lastProcessedUid']) ?? 0,
      lastProcessedUidValidity: _int(map['lastProcessedUidValidity']),
      lastCheckAt: _date(map['lastCheckAt']),
    );
  }

  static String? _string(Object? raw) {
    if (raw is String) return raw;
    return null;
  }

  static int? _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static bool? _bool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return null;
  }

  static DateTime? _date(Object? raw) {
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }
}