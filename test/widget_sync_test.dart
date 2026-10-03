/// Tests for the widget data contract and the test-tone generator.
///
/// The important one here is the key format. `HeadsUpWidgetProvider.kt` reads
/// these keys from a `Bundle`; if the Dart side writes `item0_whatt` and Kotlin
/// reads `item0_what`, the widget renders blank rows with **no error anywhere**
/// and no failing test. So the exact strings are pinned here, and the Kotlin
/// `SUFFIX_*` constants are cross-checked by `test/kotlin_keys_test.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/test_tone.dart';
import 'package:heads_up/services/widget_sync.dart';

MailItem _item({
  required String id,
  String? what = 'Form is due',
  String? doIt = 'Upload your ID proof',
  String? by = 'today',
  String? speech = 'Form is due. Upload your ID proof.',
  String? audio = '/tmp/tone.wav',
  bool processed = true,
  bool urgent = true,
}) {
  final now = DateTime(2026, 10, 2, 9);
  return MailItem(
    id: id,
    receivedAt: now,
    senderName: 'Example',
    senderAddress: 'example@example.com',
    subject: 'synthetic',
    score: 100,
    reasons: const [],
    deadline: DateTime(2026, 10, 2),
    isVip: false,
    processedAt: now,
    what: processed ? what : null,
    doIt: processed ? doIt : null,
    by: processed ? by : null,
    speechText: processed ? speech : null,
    audioPath: processed ? audio : null,
    audioSource: processed ? AudioSource.elevenlabs : AudioSource.none,
  );
}

void main() {
  group('widget key contract', () {
    test('keys match the format HeadsUpWidgetProvider.kt reads', () {
      // If these change, the Kotlin SUFFIX_* constants must change too.
      expect(WidgetSync.keyItemCount, 'item_count');
      expect(WidgetSync.keyWhat(0), 'item0_what');
      expect(WidgetSync.keyDo(0), 'item0_do');
      expect(WidgetSync.keyBy(2), 'item2_by');
      expect(WidgetSync.keySpeech(1), 'item1_speech');
      expect(WidgetSync.keyAudio(1), 'item1_audio');
      expect(WidgetSync.keyUrgent(2), 'item2_urgent');
    });

    test('every row uses a distinct key per field', () {
      final keys = <String>{};
      for (var i = 0; i < WidgetSync.maxItems; i++) {
        keys.addAll([
          WidgetSync.keyWhat(i),
          WidgetSync.keyDo(i),
          WidgetSync.keyBy(i),
          WidgetSync.keySpeech(i),
          WidgetSync.keyAudio(i),
          WidgetSync.keyUrgent(i),
        ]);
      }
      expect(keys, hasLength(WidgetSync.maxItems * 6));
    });

    test('the widget never carries more than three rows (prd.md §3.1)', () {
      expect(WidgetSync.maxItems, 3);
    });
  });

  group('test tone generator', () {
    final bytes = buildTestToneWav();

    test('writes a valid RIFF/WAVE header', () {
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
    });

    test('the declared sizes match the actual file length', () {
      final view = ByteData.sublistView(bytes);
      // RIFF size field counts everything after the first 8 bytes.
      expect(view.getUint32(4, Endian.little), bytes.length - 8);
      expect(view.getUint32(40, Endian.little), bytes.length - 44);
    });

    test('is a 16 kHz mono 16-bit PCM file', () {
      final view = ByteData.sublistView(bytes);
      expect(view.getUint16(20, Endian.little), 1, reason: 'format = PCM');
      expect(view.getUint16(22, Endian.little), 1, reason: 'channels');
      expect(view.getUint32(24, Endian.little), 16000, reason: 'sample rate');
      expect(view.getUint16(34, Endian.little), 16, reason: 'bits per sample');
    });

    test('actually contains audio, not silence', () {
      final view = ByteData.sublistView(bytes);
      var peak = 0;
      for (var offset = 44; offset + 1 < bytes.length; offset += 2) {
        final sample = view.getInt16(offset, Endian.little);
        if (sample.abs() > peak) peak = sample.abs();
      }
      expect(peak, greaterThan(1000), reason: 'a silent file would not prove '
          'that playback works');
    });

    test('writes the file to disk and overwrites cleanly', () async {
      final dir = Directory.systemTemp.createTempSync('heads_up_tone_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final first = await writeTestTone(dir);
      expect(first.existsSync(), isTrue);
      final size = first.lengthSync();

      // Second run must not append or truncate.
      final second = await writeTestTone(dir);
      expect(second.lengthSync(), size);
    });
  });
}