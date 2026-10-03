/// Guards the Dart ↔ Kotlin half of the widget data contract.
///
/// The widget passes data across a language boundary through string keys. If
/// `HeadsUpWidgetProvider.kt` and `lib/services/widget_sync.dart` disagree about
/// a key, the widget renders empty rows and *nothing anywhere reports an error* —
/// no compiler complaint, no exception, no red test. The Android build will not
/// catch it either, because both sides are perfectly valid in isolation.
///
/// So this test reads the Kotlin source and asserts the constants still match
/// what Dart writes. It is deliberately a source-text check: cheap, and it fails
/// at the exact moment someone renames a constant on one side only.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/services/widget_sync.dart';

String _kotlinSource() {
  // Not const: Platform.pathSeparator is not a compile-time constant.
  final candidates = [
    'android${Platform.pathSeparator}app${Platform.pathSeparator}src'
        '${Platform.pathSeparator}main${Platform.pathSeparator}kotlin'
        '${Platform.pathSeparator}com${Platform.pathSeparator}headsup'
        '${Platform.pathSeparator}heads_up'
        '${Platform.pathSeparator}HeadsUpWidgetProvider.kt',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw StateError(
    'HeadsUpWidgetProvider.kt not found. Looked in:\n${candidates.join("\n")}',
  );
}

void main() {
  late String source;

  setUpAll(() {
    source = _kotlinSource();
  });

  /// Pulls `private const val NAME = "value"` out of the Kotlin companion object.
  ///
  /// Also accepts a bare numeric value, since `MAX_ITEMS` is an Int.
  String? constant(String name) {
    final match = RegExp('$name\\s*=\\s*(?:"([^"]*)"|(\\d+))').firstMatch(source);
    return match?.group(1) ?? match?.group(2);
  }

  group('widget key contract across the language boundary', () {
    test('the item count key matches', () {
      expect(constant('KEY_ITEM_COUNT'), WidgetSync.keyItemCount);
    });

    test('every field suffix matches', () {
      // Kotlin: SUFFIX_WHAT = "_what"  ↔  Dart: keyWhat(i) = 'item$i$_sWhat'
      expect(constant('SUFFIX_WHAT'), '_what');
      expect(constant('SUFFIX_DO'), '_do');
      expect(constant('SUFFIX_BY'), '_by');
      expect(constant('SUFFIX_SPEECH'), '_speech');
      expect(constant('SUFFIX_AUDIO'), '_audio');
      expect(constant('SUFFIX_URGENT'), '_urgent');
    });

    test('the row cap matches on both sides', () {
      expect(constant('MAX_ITEMS'), '${WidgetSync.maxItems}');
    });

    test('the Kotlin provider reads rows by suffix, not a shared prefix', () {
      // Guards against a regression where every field collapsed onto one key
      // (which would make item0_what overwrite item0_do at runtime).
      expect(source, contains('rowKey + SUFFIX_WHAT'));
      expect(source, contains('rowKey + SUFFIX_DO'));
      expect(source, isNot(contains('KEY_WHAT_PREFIX')));
    });

    test('the play button always carries an intent, audio or not', () {
      // architecture.md §7.1 only attaches the broadcast when audio exists.
      // That would leave the button dead before ElevenLabs has ever run, so the
      // intent is unconditional and Dart picks the source at tap time.
      expect(source, contains('setOnClickPendingIntent'));
      expect(source, contains('HomeWidgetBackgroundIntent.getBroadcast'));
    });
  });

  group('manifest wiring', () {
    late String manifest;

    setUpAll(() {
      final path = 'android${Platform.pathSeparator}app${Platform.pathSeparator}src'
          '${Platform.pathSeparator}main${Platform.pathSeparator}AndroidManifest.xml';
      manifest = File(path).readAsStringSync();
    });

    test('the widget provider is registered', () {
      expect(manifest, contains('.HeadsUpWidgetProvider'));
      expect(manifest, contains('android.appwidget.provider'));
    });

    test('home_widget background receiver and service are registered', () {
      // Without these, the ▶ tap reaches no Dart isolate and does nothing.
      expect(manifest, contains('HomeWidgetBackgroundReceiver'));
      expect(manifest, contains('HomeWidgetBackgroundService'));
    });

    test('TTS_SERVICE is queryable, or flutter_tts fails silently (Android 11+)', () {
      expect(manifest, contains('android.intent.action.TTS_SERVICE'));
    });

    test('INTERNET permission is declared for IMAP and ElevenLabs', () {
      expect(manifest, contains('android.permission.INTERNET'));
    });
  });

  group('widget layout', () {
    late String layout;

    setUpAll(() {
      final path = 'android${Platform.pathSeparator}app${Platform.pathSeparator}src'
          '${Platform.pathSeparator}main${Platform.pathSeparator}res'
          '${Platform.pathSeparator}layout${Platform.pathSeparator}widget_layout.xml';
      layout = File(path).readAsStringSync();
    });

    test('has exactly three rows, matching MAX_ITEMS', () {
      for (var i = 0; i < WidgetSync.maxItems; i++) {
        expect(layout, contains('item${i}_row'));
        expect(layout, contains('item${i}_text'));
        expect(layout, contains('item${i}_play'));
      }
      expect(layout, isNot(contains('item3_row')));
    });

    test('item text is capped at two lines (prd.md §7)', () {
      expect(layout, contains('android:maxLines="2"'));
    });

    test('text is left-aligned, never justified (prd.md §7)', () {
      expect(layout, isNot(contains('android:justify')));
    });

    test('carries the empty state and the footer copy hooks', () {
      expect(layout, contains('@+id/empty_state'));
      expect(layout, contains('@+id/footer_text'));
      expect(layout, contains('@+id/header_text'));
    });

    test('uses the sans-serif family and 1.3 line spacing (prd.md §7)', () {
      expect(layout, contains('android:fontFamily="sans-serif"'));
      expect(layout, contains('android:lineSpacingMultiplier="1.3"'));
    });
  });
}