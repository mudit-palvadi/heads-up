/// Entry points for work that runs outside the UI.
///
/// Specification: architecture.md §8.
///
/// Both callbacks are `@pragma('vm:entry-point')` top-level functions. They run
/// in a **background isolate** — a separate Dart heap with no Flutter UI
/// available — so nothing here may touch BuildContext or Navigator.
///
/// The isolate is short-lived and is killed by Android's Low Memory Killer,
/// which is precisely why Gemma does not run here (architecture.md §8): the
/// background job only fetches and scores. Rewriting happens when the app opens.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:heads_up/services/local_audio.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/pipeline.dart';
import 'package:heads_up/services/store.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

/// WorkManager task entry point.
///
/// Not yet wired to a real pipeline — `Pipeline` lands in a later phase. Until
/// then this must stay a no-op that reports success, because a task that throws
/// is retried by WorkManager and would spin forever against a half-built
/// pipeline.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // Kept as the declared WorkManager entry point. The real task body is
  // [_backgroundTask]; WorkManager needs a top-level function it can name.
  _backgroundTask();
}

/// Handles a tap on the widget's ▶ button.
///
/// This is architecture.md §8 "Option A": the tap wakes a background isolate
/// that plays audio, so the friend never has to open the app. It also decides
/// Option A vs Option B — if this isolate cannot produce sound, we switch to a
/// transparent Activity instead (phases.md Gate 2).
@pragma('vm:entry-point')
Future<void> widgetInteractivityCallback(Uri? uri) async {
  if (uri?.host != 'play') return;

  final index = uri?.queryParameters['idx'] ?? '';
  final audioPath = uri?.queryParameters['path'] ?? '';
  final speechText = uri?.queryParameters['text'] ?? '';

  debugPrint('Heads Up widget tap: idx=$index '
      'hasAudio=${audioPath.isNotEmpty} hasText=${speechText.isNotEmpty}');

  await const LocalAudio().playOrSpeak(
    audioPath: audioPath,
    speechText: speechText,
  );
}

/// Registers the widget tap callback.
///
/// Must be awaited before `runApp` (architecture.md §8 `main.dart`). A tap that
/// arrives before this is registered has nowhere to go, which is the most likely
/// cause of "the play button does nothing on the first tap".
Future<void> registerWidgetCallbacks() async {
  await HomeWidget.registerInteractivityCallback(widgetInteractivityCallback);
}

/// Registers the hourly light sync.
///
/// Runs [Pipeline.runLight] only: IMAP plus rules. Gemma is deliberately
/// excluded because Android's Low Memory Killer will kill the process
/// mid-inference, and several seconds of heavy CPU in a background job drains
/// the battery (architecture.md §8).
///
/// The consequence — a fresh install shows the empty state until the app is
/// opened once — is disclosed in the README rather than hidden.
Future<void> registerBackgroundSync({required Store store}) async {
  // isInDebugMode is deprecated and has no effect in this version.
  await Workmanager().initialize(_backgroundTask);

  const task = 'heads_up_light_sync';
  final settings = await store.loadSettings();
  final minutes = settings.checkIntervalMinutes.clamp(15, 120);

  await Workmanager().registerPeriodicTask(
    task,
    task,
    frequency: Duration(minutes: minutes),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

/// The WorkManager entry point.
///
/// Runs in a fresh background isolate, so it rebuilds its own service graph —
/// it cannot borrow the foreground app's.
@pragma('vm:entry-point')
void _backgroundTask() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != 'heads_up_light_sync') return true;

    final store = Store();
    final mail = MailService();

    try {
      final settings = await store.loadSettings();
      final password = await store.readSecret(SecretKeys.imapPassword);
      if (password == null || password.isEmpty) {
        debugPrint('Heads Up background: no app password stored; skipping.');
        return true;
      }

      await mail.connect(
        host: settings.imapHost,
        port: settings.imapPort,
        user: settings.imapUser,
        password: password,
      );

      final result = await Pipeline(store: store, mail: mail).runLight();
      debugPrint('Heads Up background: $result');
    } catch (e) {
      // Swallow: there is no UI in a background isolate, and WorkManager will
      // run again on the next interval. Throwing here would just log noisily.
      debugPrint('Heads Up background failed: $e');
    } finally {
      await mail.disconnect();
    }
    return true;
  });
}

/// Exposed for tests: resolves a widget tap URI the same way the real callback
/// does, without needing an isolate.
({String audioPath, String speechText}) parsePlayUri(Uri uri) {
  return (
    audioPath: uri.queryParameters['path'] ?? '',
    speechText: uri.queryParameters['text'] ?? '',
  );
}

/// Whether a path refers to a file that actually exists.
///
/// Shared with tests so the "file was cleared from storage" branch is covered
/// without an emulator.
bool audioFileExists(String path) {
  if (path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}