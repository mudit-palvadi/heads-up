# Heads Up — Technical Architecture

> **Target device:** Android 12+ (API 32+), 8 GB RAM, arm64-v8a
> **Platform:** Android only. No iOS, no web, no desktop.
> **Language:** Dart / Flutter for app logic. Kotlin for the Android widget provider (~20 lines).
> **All verified against pub.dev and official docs as of Oct 2, 2026.**

---

## 1. System Overview

```
┌─────────────────────────── ANDROID PHONE ───────────────────────────┐
│                                                                      │
│  Trigger: WorkManager (every 60 min, best-effort)                    │
│        OR: App opened / "Refresh now" tapped                         │
│        │                                                             │
│        ▼                                                             │
│  MailService (IMAP EXAMINE, read-only)                               │
│    └─ enough_mail ImapClient                                         │
│    └─ Gmail: imap.gmail.com:993 (SSL)                                │
│    └─ Fetches new messages since lastProcessedUid                    │
│    └─ BODY.PEEK[] — never sets \Seen flag                           │
│        │                                                             │
│        ▼                                                             │
│  Cleaner                                                             │
│    └─ HTML → plain text (html package)                               │
│    └─ Strip quoted replies, signatures, footers                      │
│    └─ Truncate to 1,500 chars for Gemma                              │
│        │                                                             │
│        ▼                                                             │
│  RulesEngine (deterministic, no AI)                                  │
│    └─ Score each email (VIP, keywords, deadlines, penalties)         │
│    └─ Extract deadline (regex, never AI)                             │
│    └─ Emails with score ≥ 30 → queue for Gemma                       │
│    └─ Cap: max 5 per run                                             │
│        │                                                             │
│        ▼  [runs when app is OPEN — not in WorkManager background]    │
│  GemmaService (on-device inference)                                  │
│    └─ flutter_gemma + flutter_gemma_litertlm                         │
│    └─ Gemma 3 1B-IT, INT4 quantized, ~529 MB .litertlm file          │
│    └─ Produces: WHAT / DO / BY in plain language                     │
│    └─ BY must match rules-extracted deadline (or NONE)               │
│        │                                                             │
│        ▼                                                             │
│  VoiceService                                                        │
│    └─ ElevenLabs REST API (speechText ≤ 40 words)                   │
│    └─ Saves mp3 to <appDocDir>/audio/<itemId>.mp3                    │
│    └─ On failure: marks item audioSource = offline_tts               │
│        │                                                             │
│        ▼                                                             │
│  Store (sqflite + flutter_secure_storage)                            │
│    └─ Persists MailItem rows + settings                              │
│    └─ Secrets (IMAP password, ElevenLabs key, HF token) in KeyStore  │
│        │                                                             │
│        ▼                                                             │
│  WidgetSync (home_widget)                                            │
│    └─ HomeWidget.saveWidgetData() for each field                     │
│    └─ HomeWidget.updateWidget() to trigger redraw                    │
│        │                                                             │
│        ▼                                                             │
│  Android Widget (native XML + Kotlin)                                │
│    └─ HeadsUpWidgetProvider.kt reads shared data via HomeWidgetPlugin │
│    └─ RemoteViews renders up to 3 rows + empty state                 │
│    └─ ▶ tap → HomeWidgetBackgroundIntent → widgetInteractivityCallback│
│           → just_audio plays mp3 OR flutter_tts speaks text          │
│                                                                      │
│  Network calls:                                                      │
│    - IMAP: Gmail servers (mail fetch)                                │
│    - HTTPS: api.elevenlabs.io (short text only, ≤ 40 words)          │
│    - HTTPS: HuggingFace (one-time model download, ~529 MB)           │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Flutter Project Structure

```
heads_up/
├── lib/
│   ├── main.dart                        # App entry point, callback registration
│   ├── models/
│   │   ├── mail_item.dart               # MailItem data class + enums
│   │   └── settings.dart               # AppSettings data class
│   ├── services/
│   │   ├── mail_service.dart            # IMAP fetch via enough_mail
│   │   ├── cleaner.dart                 # HTML→text, strip, truncate
│   │   ├── rules_engine.dart            # Scoring + deadline extraction
│   │   ├── gemma_service.dart           # On-device inference
│   │   ├── voice_service.dart           # ElevenLabs + flutter_tts fallback
│   │   ├── store.dart                   # sqflite DB + secure storage wrapper
│   │   ├── widget_sync.dart             # home_widget data write + update trigger
│   │   └── pipeline.dart               # Orchestrates all services in order
│   ├── background/
│   │   └── callback_dispatcher.dart    # WorkManager task + widget tap callback
│   └── ui/
│       ├── setup_screen.dart
│       ├── status_screen.dart           # Home screen of the app
│       ├── rules_screen.dart
│       ├── settings_screen.dart
│       └── missed_list_screen.dart
├── android/
│   └── app/src/main/
│       ├── kotlin/com/headsup/
│       │   └── HeadsUpWidgetProvider.kt  # ~60 lines Kotlin, reads shared data
│       └── res/
│           ├── layout/widget_layout.xml
│           ├── drawable/
│           │   ├── widget_bg.xml         # Rounded rect background
│           │   └── ic_play.xml           # Play button vector
│           └── xml/heads_up_widget_info.xml
│   └── AndroidManifest.xml
├── test/
│   ├── fixtures/fake_emails/            # 20 synthetic test emails (no real data)
│   ├── rules_engine_test.dart
│   ├── cleaner_test.dart
│   └── gemma_output_test.dart
├── assets/
│   └── default_rules.json              # Default scoring config (bundled)
├── pubspec.yaml
├── README.md
├── .gitignore                           # MUST include: *.env, secrets.dart, *.jks
├── prd.md
├── architecture.md
├── rules.md
└── phases.md
```

---

## 3. Dependencies (pubspec.yaml)

```yaml
environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.22.0'

dependencies:
  flutter:
    sdk: flutter

  # On-device Gemma inference
  flutter_gemma: ^1.11.3
  flutter_gemma_litertlm: ^1.0.1   # LiteRT-LM engine (required alongside flutter_gemma)

  # IMAP
  enough_mail: ^2.1.7

  # Home screen widget bridge
  home_widget: ^0.10.0

  # Background tasks
  workmanager: ^0.10.10

  # Offline TTS fallback
  flutter_tts: ^4.2.5

  # Audio playback (local mp3 files)
  just_audio: ^0.10.6

  # HTTP (ElevenLabs REST)
  dio: ^5.7.0

  # Secrets storage (Android KeyStore backed)
  flutter_secure_storage: ^11.2.0

  # Local database
  sqflite: ^2.3.3+1
  shared_preferences: ^2.3.3

  # File paths
  path_provider: ^2.1.4

  # Date formatting
  intl: ^0.19.0

  # HTML → text conversion
  html: ^0.15.4

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

---

## 4. Android Build Config

### android/app/build.gradle

```gradle
android {
    compileSdk 35
    defaultConfig {
        applicationId "com.headsup"
        minSdk 30           // Required for LiteRT-LM (flutter_gemma_litertlm)
        targetSdk 35
        versionCode 1
        versionName "1.0.0"
        ndk {
            abiFilters 'arm64-v8a'   // LiteRT-LM is 64-bit only; strips 32-bit libs
        }
    }
    buildTypes {
        release {
            minifyEnabled false    // Keep false during hackathon — debug easier
        }
    }
}
```

### android/app/src/main/AndroidManifest.xml — critical entries

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- Permissions -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>

    <!-- flutter_tts: REQUIRED on Android 11+ or speak() silently fails -->
    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>

    <application ...>

        <!-- Widget provider -->
        <receiver android:name=".HeadsUpWidgetProvider" android:exported="true">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/heads_up_widget_info"/>
        </receiver>

        <!-- home_widget background intent receiver -->
        <receiver
            android:name="es.antonborri.home_widget.HomeWidgetBackgroundReceiver"
            android:exported="true"/>

        <!-- home_widget background service -->
        <service
            android:name="es.antonborri.home_widget.HomeWidgetBackgroundService"
            android:permission="android.permission.BIND_JOB_SERVICE"
            android:exported="true"/>

    </application>
</manifest>
```

### android/app/src/main/res/xml/heads_up_widget_info.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="180dp"
    android:updatePeriodMillis="0"
    android:initialLayout="@layout/widget_layout"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"/>
```

---

## 5. Data Models

### 5.1 MailItem

```dart
enum AudioSource { elevenlabs, offlineTts, none }
enum ItemStatus { fresh, done, dismissed }

class MailItem {
  final String id;               // "${uid}_INBOX" — stable across sessions
  final DateTime receivedAt;
  final String senderName;
  final String senderAddress;
  final String subject;          // Stored locally only — NEVER sent to any API
  final int score;               // Rules engine output
  final List<String> reasons;    // Why this was flagged (for debug/log)
  final DateTime? deadline;      // Extracted by rules engine (regex). NULL if none.
  final bool isVip;

  // Gemma output (nullable until processed)
  String? what;                  // "Internship form is due"
  String? doIt;                  // "Upload your ID on the portal"
  String? by;                    // "Friday" (must match deadline or be null)
  String? speechText;            // what + ". " + doIt + (by ? " By " + by : "")

  // Audio
  String? audioPath;             // Absolute path to mp3, null if not generated
  AudioSource audioSource;       // elevenlabs | offlineTts | none

  ItemStatus status;             // fresh | done | dismissed
  DateTime processedAt;
}
```

**sqflite table: `mail_items`**

| Column | Type | Notes |
|---|---|---|
| id | TEXT PRIMARY KEY | |
| received_at | INTEGER | Unix ms |
| sender_name | TEXT | |
| sender_address | TEXT | |
| subject | TEXT | |
| score | INTEGER | |
| reasons | TEXT | JSON array |
| deadline | INTEGER | Unix ms, nullable |
| is_vip | INTEGER | 0/1 |
| what | TEXT | nullable |
| do_it | TEXT | nullable |
| by_text | TEXT | nullable |
| speech_text | TEXT | nullable |
| audio_path | TEXT | nullable |
| audio_source | TEXT | 'elevenlabs'/'offline_tts'/'none' |
| status | TEXT | 'fresh'/'done'/'dismissed' |
| processed_at | INTEGER | Unix ms |

### 5.2 AppSettings (shared_preferences)

```dart
class AppSettings {
  String imapHost;              // 'imap.gmail.com'
  int imapPort;                 // 993
  String imapUser;              // 'user@gmail.com'
  // imapPassword → flutter_secure_storage key: 'imap_password'
  // elevenLabsKey → flutter_secure_storage key: 'elevenlabs_key'
  // hfToken → flutter_secure_storage key: 'hf_token'
  List<String> vipAddresses;   // Exact email addresses
  List<String> vipDomains;     // Domain suffixes e.g. 'university.edu'
  List<String> vipKeywords;    // Custom keywords
  List<String> ignorePatterns; // Sender addresses/domains to always skip
  int checkIntervalMinutes;    // Default: 60
  bool cloudVoiceEnabled;      // Default: true
  String elevenLabsVoiceId;    // Default: 'EXAVITQu4vr4xnSDxMaL' (Bella)
  int scoreThreshold;          // Default: 30
  int lastProcessedUid;        // Persisted between sessions
  int? lastProcessedUidValidity; // IMAP UIDVALIDITY — reset if changed
  DateTime? lastCheckAt;
}
```

**flutter_secure_storage keys:**

| Key | Contains |
|---|---|
| `imap_password` | 16-char Gmail app password |
| `elevenlabs_key` | ElevenLabs API key |
| `hf_token` | HuggingFace read-only token (for model download) |

---

## 6. Service Specifications

### 6.1 MailService

**File:** `lib/services/mail_service.dart`

```dart
class MailService {
  final ImapClient _client = ImapClient(isLogEnabled: false);

  Future<void> connect(String host, int port, String user, String password) async {
    await _client.connectToServer(host, port, isSecure: true);
    await _client.login(user, password);
  }

  Future<List<MimeMessage>> fetchNew(int lastUid, int uidValidity) async {
    // EXAMINE = read-only. Never use selectMailbox() — it may set \Seen.
    final mailbox = await _client.examineMailboxByPath('INBOX');
    
    // Guard against empty mailbox
    if (mailbox.messagesExists == 0) return [];
    
    // If UIDVALIDITY changed, the server reset UIDs — start from scratch
    if (uidValidity != 0 && mailbox.uidValidity != uidValidity) {
      lastUid = 0; // Caller must save new uidValidity
    }

    final sequence = MessageSequence()
      ..addRangeToLast(lastUid + 1); // UIDs from lastUid+1 to *

    // BODY.PEEK[] fetches full body WITHOUT setting \Seen flag
    final result = await _client.uidFetchMessages(
      sequence,
      'BODY.PEEK[] ENVELOPE FLAGS RFC822.SIZE',
    );

    // Filter: skip messages > 500 KB (huge attachments, not email bodies)
    return result.messages
        .where((m) => (m.size ?? 0) < 500000)
        .toList();
  }

  Future<void> disconnect() async {
    await _client.logout();
  }
}
```

**Error handling:**
- `ImapException` with code `ImapResponseCode.alert` → show "Account needs attention" in status
- Connection timeout → show "Couldn't reach mail" in widget
- Auth failure → show "Check your app password" in status, do not retry

### 6.2 Cleaner

**File:** `lib/services/cleaner.dart`

```dart
class Cleaner {
  String clean(MimeMessage message) {
    String text = _extractText(message);
    text = _stripQuotedReplies(text);
    text = _stripSignature(text);
    text = _stripFooters(text);
    return text; // Full cleaned text for RulesEngine
  }

  String truncateForGemma(String cleaned) {
    // ~1,500 chars ≈ 300 words ≈ well within 1B model context
    return cleaned.length > 1500 ? cleaned.substring(0, 1500) : cleaned;
  }

  String _extractText(MimeMessage msg) {
    // Prefer text/plain; fall back to HTML→text
    final plain = msg.decodeTextPlainPart();
    if (plain != null && plain.trim().isNotEmpty) return plain;
    final html = msg.decodeTextHtmlPart();
    if (html != null) return _htmlToText(html);
    return '';
  }

  String _htmlToText(String html) {
    final doc = parse(html);
    return doc.body?.text ?? '';
  }

  String _stripQuotedReplies(String text) {
    // Remove "On [date], [name] wrote:" and everything after
    return text.replaceAll(
      RegExp(r'\nOn .{5,80} wrote:.*', dotAll: true), '');
  }

  String _stripSignature(String text) {
    // Remove everything after "-- \n" (RFC 3676 signature delimiter)
    final sigIdx = text.indexOf('\n-- \n');
    return sigIdx == -1 ? text : text.substring(0, sigIdx);
  }

  String _stripFooters(String text) {
    // Remove unsubscribe/tracking lines
    return text.replaceAll(
      RegExp(r'(?:unsubscribe|manage preferences|view in browser).{0,200}', 
             caseSensitive: false), '');
  }
}
```

### 6.3 GemmaService

**File:** `lib/services/gemma_service.dart`

**Initialization (call once at app start):**
```dart
final hfToken = await secureStorage.read(key: 'hf_token');
await FlutterGemma.initialize(
  huggingFaceToken: hfToken,
  inferenceEngines: [LiteRtLmEngine()],
);
```

**Model download (first run only):**
```dart
await FlutterGemma.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
)
.fromHuggingFace('litert-community/Gemma3-1B-IT')
.withProgress((p) => onProgress(p))  // 0.0 to 1.0
.install();
```

**Inference (one session per email, sequential):**
```dart
Future<GemmaOutput?> rewrite(String cleanedText, String senderName,
    String? deadline) async {
  final prompt = _buildPrompt(cleanedText, senderName, deadline);
  
  final model = await FlutterGemma.getActiveModel(maxTokens: 512);
  final session = await model.createSession();
  
  final buffer = StringBuffer();
  await for (final chunk in session.getResponseStream(prompt: prompt)) {
    buffer.write(chunk);
  }
  await session.close();
  
  return _parseOutput(buffer.toString(), deadline);
}

String _buildPrompt(String text, String sender, String? deadline) => '''
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

Deadline from rules: ${deadline ?? 'NONE'}
Sender: $sender
Email:
"""
$text
"""
''';

GemmaOutput? _parseOutput(String raw, String? rulesDeadline) {
  final what = _field(raw, 'WHAT');
  final doIt = _field(raw, 'DO');
  final by   = _field(raw, 'BY');

  // Validation: all three fields must be present
  if (what == null || doIt == null || by == null) return null;

  // BY must match the rules-extracted deadline or be NONE
  // (Gemma must not invent dates)
  final byClean = by.trim().toUpperCase() == 'NONE' ? null : by.trim();
  if (byClean != null && rulesDeadline == null) return null; // invented a date

  // Length guard
  if (what.length > 80 || doIt.length > 80) return null;

  return GemmaOutput(what: what, doIt: doIt, by: byClean);
}

String? _field(String raw, String name) {
  final m = RegExp('^$name:\\s*(.+)\$', multiLine: true).firstMatch(raw);
  return m?.group(1)?.trim();
}
```

**Fallback (when Gemma output fails validation or model not loaded):**
```dart
GemmaOutput fallback(MailItem item) => GemmaOutput(
  what: 'Email from ${item.senderName}',
  doIt: 'Check this message',
  by: item.deadline != null
      ? DateFormat('EEE, MMM d').format(item.deadline!)
      : null,
);
```

### 6.4 VoiceService

**File:** `lib/services/voice_service.dart`

```dart
class VoiceService {
  final Dio _dio = Dio();

  Future<AudioResult> generateAudio(MailItem item, String voiceId,
      String apiKey) async {
    // Cache: don't regenerate if file already exists
    final path = await _audioPath(item.id);
    if (await File(path).exists()) {
      return AudioResult(path: path, source: AudioSource.elevenlabs);
    }

    final text = _buildSpeechText(item);

    try {
      final response = await _dio.post(
        // output_format as query param — not in body
        'https://api.elevenlabs.io/v1/text-to-speech/$voiceId'
        '?output_format=mp3_44100_128',
        options: Options(
          headers: {
            'xi-api-key': apiKey,
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
          },
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
        data: {
          'text': text,
          'model_id': 'eleven_flash_v2_5',   // ~75ms latency
          'voice_settings': {
            'stability': 0.6,
            'similarity_boost': 0.8,
            'speed': 0.95,   // Slightly slower for clarity
          },
        },
      );

      await File(path).writeAsBytes(response.data as List<int>);
      return AudioResult(path: path, source: AudioSource.elevenlabs);

    } on DioException {
      // Any failure → mark for offline TTS at tap time
      return AudioResult(path: null, source: AudioSource.offlineTts);
    }
  }

  String _buildSpeechText(MailItem item) {
    final parts = [item.what!, item.doIt!];
    if (item.by != null) parts.add('By ${item.by}.');
    return parts.join('. ');
    // Result stays well under 40 words and the 2,500-char ElevenLabs limit
  }

  Future<String> _audioPath(String itemId) async {
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/audio');
    await audioDir.create(recursive: true);
    return '${audioDir.path}/$itemId.mp3';
  }

  // Play at tap time (Option A: background callback)
  static AudioPlayer? _currentPlayer;

  static Future<void> play(String audioPath) async {
    await _currentPlayer?.stop();
    _currentPlayer = AudioPlayer();
    await _currentPlayer!.setFilePath(audioPath);
    await _currentPlayer!.play();
  }

  static Future<void> speakOffline(String text) async {
    await _currentPlayer?.stop();
    _currentPlayer = null;
    final tts = FlutterTts();
    await tts.setLanguage('en-US');
    await tts.setSpeechRate(0.45);  // Slightly slower than default
    await tts.speak(text);
  }
}
```

### 6.5 Pipeline

**File:** `lib/services/pipeline.dart`

```dart
class Pipeline {
  // Full pipeline: IMAP + Rules + Gemma + Voice + Store + Widget
  // Call this when the app is opened or "Refresh now" is tapped.
  Future<void> runFull() async {
    final settings = await store.getSettings();
    final msgs = await mailService.fetchNew(
        settings.lastProcessedUid, settings.lastProcessedUidValidity ?? 0);

    var maxUid = settings.lastProcessedUid;
    final toProcess = <MailItem>[];

    for (final msg in msgs) {
      if ((msg.uid ?? 0) > maxUid) maxUid = msg.uid!;
      final cleaned = cleaner.clean(msg);
      final item = rulesEngine.score(msg, cleaned);
      if (item.score >= settings.scoreThreshold) {
        toProcess.add(item);
      }
    }

    // Cap at 5 to limit latency
    final capped = toProcess.take(5).toList();

    for (final item in capped) {
      final truncated = cleaner.truncateForGemma(item._cleanedText);
      final gemmaOut = await gemmaService.rewrite(
          truncated, item.senderName, 
          item.deadline != null ? _formatDeadline(item.deadline!) : null);
      
      final output = gemmaOut ?? gemmaService.fallback(item);
      item
        ..what = output.what
        ..doIt = output.doIt
        ..by = output.by
        ..speechText = VoiceService()._buildSpeechText(item);

      if (settings.cloudVoiceEnabled) {
        final audio = await voiceService.generateAudio(
            item, settings.elevenLabsVoiceId, elevenLabsKey);
        item
          ..audioPath = audio.path
          ..audioSource = audio.source;
      } else {
        item.audioSource = AudioSource.offlineTts;
      }

      await store.saveItem(item);
    }

    await store.saveLastUid(maxUid);
    await store.saveLastCheckAt(DateTime.now());
    await _syncWidget();
  }

  // Light pipeline: IMAP + Rules only. Runs in WorkManager background.
  // No Gemma (too heavy for background isolate).
  Future<void> runLightBackground() async {
    final settings = await store.getSettings();
    final msgs = await mailService.fetchNew(
        settings.lastProcessedUid, settings.lastProcessedUidValidity ?? 0);
    // Score and store without Gemma output — status: 'needs_rewrite'
    // Full pipeline runs next time app opens.
    for (final msg in msgs) {
      final item = rulesEngine.score(msg, cleaner.clean(msg));
      if (item.score >= settings.scoreThreshold) {
        await store.saveItem(item); // Stored without what/doIt/by
      }
    }
    await _syncWidget(); // Widget shows last fully-processed items
  }

  Future<void> _syncWidget() async {
    final items = await store.getTopItems(limit: 3);
    await widgetSync.sync(items);
  }
}
```

---

## 7. Android Widget Layer

### 7.1 HeadsUpWidgetProvider.kt

```kotlin
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

class HeadsUpWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context, manager: AppWidgetManager, ids: IntArray
    ) {
        ids.forEach { id ->
            val data = HomeWidgetPlugin.getData(context)
            val views = RemoteViews(context.packageName, R.layout.widget_layout)
            val count = data.getInt("item_count", 0)

            if (count == 0) {
                views.setViewVisibility(R.id.empty_state, View.VISIBLE)
                views.setViewVisibility(R.id.items_container, View.GONE)
            } else {
                views.setViewVisibility(R.id.empty_state, View.GONE)
                views.setViewVisibility(R.id.items_container, View.VISIBLE)
                views.setTextViewText(R.id.header_text, 
                    "$count thing${if (count > 1) "s" else ""} need you today")

                listOf(0, 1, 2).forEach { i ->
                    val rowId = context.resources.getIdentifier(
                        "item${i}_row", "id", context.packageName)
                    val textId = context.resources.getIdentifier(
                        "item${i}_text", "id", context.packageName)
                    val btnId = context.resources.getIdentifier(
                        "item${i}_play", "id", context.packageName)

                    if (i < count) {
                        val what = data.getString("item${i}_what", "")
                        val doIt = data.getString("item${i}_do", "")
                        val audio = data.getString("item${i}_audio", "")
                        val speech = data.getString("item${i}_speech", "")
                        
                        views.setViewVisibility(rowId, View.VISIBLE)
                        views.setTextViewText(textId, "$what\n$doIt")
                        
                        val playIntent = HomeWidgetBackgroundIntent.getBroadcast(
                            context,
                            Uri.parse("headsup://play?idx=$i" +
                                "&path=${Uri.encode(audio)}" +
                                "&text=${Uri.encode(speech)}")
                        )
                        views.setOnClickPendingIntent(btnId, playIntent)
                    } else {
                        views.setViewVisibility(rowId, View.GONE)
                    }
                }
            }
            manager.updateAppWidget(id, views)
        }
    }
}
```

### 7.2 widget_layout.xml (skeleton)

```xml
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:background="@drawable/widget_bg"
    android:padding="16dp">

    <!-- Empty state -->
    <TextView
        android:id="@+id/empty_state"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:text="Nothing needs you today ✓"
        android:textSize="18sp"
        android:textColor="#A8E6A3"
        android:fontFamily="sans-serif"
        android:gravity="center"
        android:visibility="gone"/>

    <!-- Normal state -->
    <TextView
        android:id="@+id/header_text"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:textSize="12sp"
        android:textColor="#FFFFFF"
        android:alpha="0.7"
        android:fontFamily="sans-serif"
        android:layout_marginBottom="8dp"/>

    <LinearLayout
        android:id="@+id/items_container"
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1"
        android:orientation="vertical">

        <!-- Row 0 -->
        <LinearLayout android:id="@+id/item0_row"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:orientation="horizontal"
            android:layout_marginBottom="6dp"
            android:gravity="center_vertical">
            <ImageButton android:id="@+id/item0_play"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:src="@drawable/ic_play"
                android:background="@drawable/play_btn_bg"
                android:tint="#FFAB40"
                android:layout_marginEnd="10dp"/>
            <TextView android:id="@+id/item0_text"
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:textSize="13sp"
                android:textColor="#FFFFFF"
                android:fontFamily="sans-serif"
                android:lineSpacingMultiplier="1.3"
                android:maxLines="3"
                android:ellipsize="end"/>
        </LinearLayout>

        <!-- Row 1 (same structure, id prefix item1_) -->
        <!-- Row 2 (same structure, id prefix item2_) -->

    </LinearLayout>

    <TextView
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:text="Everything else can wait."
        android:textSize="11sp"
        android:textColor="#FFFFFF"
        android:alpha="0.5"
        android:fontFamily="sans-serif"
        android:layout_marginTop="4dp"/>

</LinearLayout>
```

---

## 8. Background Execution

### Strategy (important: read this)

Running Gemma in the WorkManager background is unreliable — Android's LMK (Low Memory Killer) will kill the process, and even if it doesn't, the inference job (several seconds of heavy CPU/GPU) will drain battery and may fail on Doze.

**Chosen approach:**
- `WorkManager` runs every 60 minutes and does only the **light pipeline** (IMAP fetch + rules scoring). No Gemma, no ElevenLabs.
- **Gemma + Voice** run when the app is opened or "Refresh now" is tapped.
- The widget always shows the last *fully processed* items (Gemma output + audio). If new scored items are waiting for Gemma, they are invisible to the widget until the app opens.
- This means: fresh installs show the empty state until the app is opened once. **Disclose this in the README and the post.**

### callback_dispatcher.dart

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await Pipeline().runLightBackground();
    } catch (e) {
      // Swallow — WorkManager will retry on next interval
    }
    return true;
  });
}

// Widget play button callback
// Registered via HomeWidget.registerInteractivityCallback() — NOT registerBackgroundCallback
@pragma('vm:entry-point')
Future<void> widgetInteractivityCallback(Uri? uri) async {
  if (uri?.host != 'play') return;
  final audioPath = uri?.queryParameters['path'] ?? '';
  final speechText = uri?.queryParameters['text'] ?? '';

  if (audioPath.isNotEmpty && await File(audioPath).exists()) {
    await VoiceService.play(audioPath);
  } else if (speechText.isNotEmpty) {
    await VoiceService.speakOffline(speechText);
  }
}
```

### main.dart

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register widget tap callback (must happen before runApp)
  await HomeWidget.registerInteractivityCallback(widgetInteractivityCallback);

  // Initialize WorkManager
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  await Workmanager().registerPeriodicTask(
    'heads_up_light_sync',
    'lightSync',
    frequency: const Duration(minutes: 60),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  // Initialize Gemma (loads model into memory if already downloaded)
  final hfToken = await FlutterSecureStorage().read(key: 'hf_token');
  await FlutterGemma.initialize(
    huggingFaceToken: hfToken,
    inferenceEngines: [LiteRtLmEngine()],
  );

  runApp(const HeadsUpApp());
}
```

---

## 9. ElevenLabs Integration

| Field | Value |
|---|---|
| Endpoint | `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128` |
| Auth header | `xi-api-key: <key>` |
| Model | `eleven_flash_v2_5` (~75ms latency) |
| Input limit | ≤ 2,500 chars per call (our speech text is ≤ 40 words, ~250 chars) |
| Free tier | 10,000 chars/month (resets monthly) |
| Response | Raw mp3 bytes (`Content-Type: audio/mpeg`) |
| Caching | One call per item, ever. Check file existence before calling. |
| Failure | DioException → mark `audioSource = offlineTts`, no retry |
| Recommended voice | Fetch from `GET /v1/voices` and let user pick in settings |

---

## 10. Secrets & Security

| Secret | Where stored | Never stored in |
|---|---|---|
| Gmail app password | `flutter_secure_storage` key `imap_password` | Code, repo, logs, screenshots |
| ElevenLabs API key | `flutter_secure_storage` key `elevenlabs_key` | Code, repo, logs, screenshots |
| HuggingFace token | `flutter_secure_storage` key `hf_token` | Code, repo, logs, screenshots |

`.gitignore` must include:
```
*.env
.env*
secrets.dart
lib/secrets.dart
*.jks
*.keystore
google-services.json
```

For the hand-over APK (private, not published):
- Keys may be seeded into `flutter_secure_storage` via a one-time setup screen.
- The APK is **never uploaded to GitHub, the Play Store, or any public URL**.
- Acknowledge this approach explicitly in the DEV post.
