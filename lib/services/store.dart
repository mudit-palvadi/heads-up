/// Persistence: sqflite for items, KeyStore for secrets, prefs for settings.
///
/// Specification: architecture.md §5.1 and §5.2, §10.
///
/// Three stores, deliberately separated:
///
/// * **`mail_items`** (sqflite) — email content. Local only, never leaves the
///   device (prd.md §8).
/// * **Android KeyStore** (`flutter_secure_storage`) — the IMAP app password,
///   the ElevenLabs key and the HF token. Never in sqflite, never in prefs,
///   never in the repo.
/// * **`shared_preferences`** — non-secret settings.
///
/// Keeping secrets out of both plain-text stores is the point: prefs and sqflite
/// are readable from a backup or another app with elevated access, KeyStore is
/// not.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Storage keys for secrets. Named per architecture.md §10.
abstract final class SecretKeys {
  /// 16-character Gmail app password.
  static const String imapPassword = 'imap_password';

  /// ElevenLabs API key. Optional — the app works without it (cloud voice off).
  static const String elevenLabs = 'elevenlabs_key';

  /// Read-only HuggingFace token, for the one-time model download.
  static const String hfToken = 'hf_token';
}

const String _prefsKeySettings = 'app_settings';
const String _prefsKeyRulesOverride = 'user_rules_json';

class Store {
  Store({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  Database? _db;

  // --- sqflite -------------------------------------------------------------

  /// Opens the database, creating it on first run.
  Future<Database> database() async {
    final existing = _db;
    if (existing != null) return existing;

    final dir = await getDatabasesPath();
    final opened = await openDatabase(
      '$dir/heads_up.db',
      version: 1,
      onCreate: (db, version) async {
        // Schema from architecture.md §5.1. `subject` is stored because the app
        // is read-only and never modifies the mailbox, but it must never be
        // transmitted (prd.md §8).
        await db.execute('''
          CREATE TABLE mail_items (
            id           TEXT PRIMARY KEY,
            received_at  INTEGER NOT NULL,
            sender_name  TEXT NOT NULL,
            sender_address TEXT NOT NULL,
            subject      TEXT NOT NULL,
            score        INTEGER NOT NULL,
            reasons      TEXT NOT NULL,
            deadline     INTEGER,
            is_vip       INTEGER NOT NULL,
            what         TEXT,
            do_it        TEXT,
            by_text      TEXT,
            speech_text  TEXT,
            audio_path   TEXT,
            audio_source TEXT NOT NULL,
            status       TEXT NOT NULL,
            processed_at INTEGER NOT NULL
          )
        ''');
        // The widget always asks for the top few fresh items, and the pipeline
        // asks for "anything newer than the last UID".
        await db.execute(
          'CREATE INDEX idx_mail_items_received ON mail_items(received_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_mail_items_status ON mail_items(status, score DESC)',
        );
      },
    );
    _db = opened;
    return opened;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Inserts or replaces an item, keyed on its stable `id` (architecture.md §5.1).
  ///
  /// Uses `ConflictAlgorithm.replace` because re-processing an email must not
  /// create a second row, and an item can legitimately gain `what`/`doIt`/
  /// `audioPath` between the light and full pipeline runs.
  Future<void> saveItem(MailItem item) async {
    final db = await database();
    await db.insert(
      'mail_items',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveItems(Iterable<MailItem> items) async {
    final batch = items.toList();
    if (batch.isEmpty) return;
    final db = await database();
    final batchDb = db.batch();
    for (final item in batch) {
      batchDb.insert(
        'mail_items',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batchDb.commit(noResult: true);
  }

  /// Items for the widget, best first.
  ///
  /// Filters to `fresh` and fully processed: architecture.md §8 is explicit that
  /// the widget shows only the last *fully processed* items, so anything still
  /// waiting on Gemma must stay invisible.
  Future<List<MailItem>> getTopItems({int limit = 3}) async {
    final db = await database();
    final rows = await db.query(
      'mail_items',
      where: 'status = ? AND what IS NOT NULL AND do_it IS NOT NULL '
          'AND speech_text IS NOT NULL',
      whereArgs: ['fresh'],
      orderBy: 'score DESC, received_at DESC',
      limit: limit,
    );
    return rows.map(MailItem.fromMap).toList();
  }

  Future<List<MailItem>> getAllItems({int limit = 200}) async {
    final db = await database();
    final rows = await db.query(
      'mail_items',
      orderBy: 'received_at DESC',
      limit: limit,
    );
    return rows.map(MailItem.fromMap).toList();
  }

  Future<MailItem?> getItem(String id) async {
    final db = await database();
    final rows = await db.query(
      'mail_items',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : MailItem.fromMap(rows.first);
  }

  Future<void> setStatus(String id, ItemStatus status) async {
    final db = await database();
    await db.update(
      'mail_items',
      {'status': status.dbValue},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Drops items whose mp3 has gone, so the widget stops pointing at missing
  /// files and `LocalAudio` falls back to TTS.
  Future<int> clearMissingAudio() async {
    final db = await database();
    return db.update(
      'mail_items',
      {'audio_path': null, 'audio_source': AudioSource.offlineTts.dbValue},
      where: 'audio_path IS NOT NULL',
    );
  }

  /// Removes every row. Used by "Reset app" in Settings (prd.md §6.4).
  Future<void> clearItems() async {
    final db = await database();
    await db.delete('mail_items');
  }

  // --- Secrets (Android KeyStore) -------------------------------------------

  Future<String?> readSecret(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      // A corrupt KeyStore entry must not crash startup; treat as absent so the
      // friend can simply re-enter it.
      return null;
    }
  }

  Future<void> writeSecret(String key, String value) async {
    await _secure.write(key: key, value: value);
  }

  Future<void> deleteSecret(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {
      // Nothing to do.
    }
  }

  /// "Disconnect account / Reset app" (prd.md §6.4) — removes every secret and
  /// every stored email, and leaves only non-secret preferences behind.
  Future<void> resetEverything() async {
    await clearItems();
    for (final key in [
      SecretKeys.imapPassword,
      SecretKeys.elevenLabs,
      SecretKeys.hfToken,
    ]) {
      await deleteSecret(key);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeySettings);
    await prefs.remove(_prefsKeyRulesOverride);
  }

  // --- Settings (non-secret) ------------------------------------------------

  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeySettings);
    if (raw == null) return AppSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return AppSettings();
      return AppSettings.fromMap(decoded.cast<String, Object?>());
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeySettings, jsonEncode(settings.toMap()));
  }

  /// The user's rules override, layered over `assets/default_rules.json`.
  Future<Map<String, Object?>?> loadRulesOverride() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyRulesOverride);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRulesOverride(Map<String, Object?> override) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyRulesOverride, jsonEncode(override));
  }

  // --- Pipeline checkpoints --------------------------------------------------

  /// Highest UID processed, and the UIDVALIDITY it belonged to.
  ///
  /// If the server later reports a different UIDVALIDITY it has rebuilt its
  /// mailbox and every UID is meaningless — the caller must restart from zero
  /// rather than skip the whole inbox (architecture.md §6.1).
  Future<({int lastUid, int? uidValidity})> loadMailCheckpoint() async {
    final settings = await loadSettings();
    return (
      lastUid: settings.lastProcessedUid,
      uidValidity: settings.lastProcessedUidValidity,
    );
  }

  Future<void> saveMailCheckpoint({
    required int lastUid,
    required int? uidValidity,
    DateTime? checkedAt,
  }) async {
    final settings = await loadSettings();
    await saveSettings(
      settings.copyWith(
        lastProcessedUid: lastUid,
        lastProcessedUidValidity: uidValidity,
        lastCheckAt: checkedAt ?? DateTime.now(),
      ),
    );
  }

  /// Deletes cached audio files and forgets their paths.
  ///
  /// Called after a "Reset" or when the documents directory has been cleared, so
  /// the widget never points ▶ at a file that no longer exists.
  Future<int> forgetAudioPaths() => clearMissingAudio();
}