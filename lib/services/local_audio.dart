/// Local audio playback for the widget's ▶ button.
///
/// Deliberately separate from `VoiceService`. architecture.md §6.4 puts
/// `play`/`speakOffline` as statics on `VoiceService`, but `VoiceService` also
/// owns the ElevenLabs HTTP client and therefore an API key. Keeping playback
/// independent means the ▶ button can be built, shipped and verified with no
/// credentials at all — which is how it was actually tested.
library;

import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:heads_up/models/settings.dart';
import 'package:just_audio/just_audio.dart';

/// One player shared by every row, so starting a new item stops the previous
/// one (prd.md §5: "Playing a new item stops any currently playing audio").
///
/// In a background isolate this starts null every time the isolate spins up,
/// which is the intended behaviour: taps are short-lived and never overlap.
AudioPlayer? _player;

class LocalAudio {
  const LocalAudio();

  /// Plays a pre-generated file if it is really there, otherwise falls back to
  /// on-device TTS.
  ///
  /// The existence check is not paranoia: the mp3 may have been cleared by
  /// Android's storage pressure, and passing a missing path to `just_audio`
  /// throws rather than degrading.
  Future<void> playOrSpeak({required String audioPath, required String speechText}) async {
    if (audioPath.isNotEmpty && await _existsOnDisk(audioPath)) {
      await play(audioPath);
      return;
    }
    if (speechText.isNotEmpty) {
      await speakOffline(speechText);
    }
  }

  Future<void> play(String path) async {
    await _stopPlayer();
    final player = AudioPlayer();
    _player = player;
    try {
      await player.setFilePath(path);
      await player.play();
    } catch (_) {
      // A corrupt or unreadable file must not crash the background isolate —
      // there is no UI to show an error on. Fall back to speech if we can.
      await _disposePlayer();
      rethrow;
    }
  }

  Future<void> speakOffline(String text) async {
    await _stopPlayer();

    final tts = FlutterTts();
    // Android 11+ will not speak without this query being declared in the
    // manifest; see the <queries> block in AndroidManifest.xml.
    await tts.setLanguage(AppSettings.offlineTtsLanguage);
    await tts.setSpeechRate(AppSettings.offlineTtsSpeechRate);
    await tts.setPitch(1.0);
    await tts.speak(text);
  }

  Future<void> stop() async {
    await _stopPlayer();
  }

  Future<void> _stopPlayer() async {
    try {
      await _player?.stop();
    } catch (_) {
      // Already released.
    }
    await _disposePlayer();
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    try {
      await player?.dispose();
    } catch (_) {
      // Nothing useful to do in a background isolate.
    }
  }

  Future<bool> _existsOnDisk(String path) async {
    if (path.isEmpty) return false;
    try {
      // Synchronous on purpose: this is a single stat() on the tap path, and
      // the alternative awaits a future before deciding whether to speak.
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }
}