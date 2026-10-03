/// Generates a short spoken-summary test tone without any external tools.
///
/// The widget's ▶ button has to be proven to work *before* the ElevenLabs key
/// exists, and `just_audio` will happily play a WAV. So a synthesised tone stands
/// in for a real mp3: if the tap → background isolate → playback chain is broken,
/// it shows up here without needing a single credential.
///
/// The output is a valid RIFF/WAVE file: a 44-byte header followed by 16-bit
/// PCM samples. `just_audio` decodes it natively.
library;

import 'dart:io';
import 'dart:math' show pi;
import 'dart:typed_data';

/// Sample rate. 16 kHz mono keeps the file tiny while staying clearly audible.
const int _sampleRate = 16000;

/// How long the tone lasts. Long enough to notice, short enough to re-tap fast.
const Duration _toneLength = Duration(milliseconds: 400);

/// Writes [test_tone.wav] into [directory] and returns the file path.
///
/// Overwrites any existing file, so re-running is idempotent.
Future<File> writeTestTone(Directory directory, {String name = 'test_tone.wav'}) async {
  if (!directory.existsSync()) {
    await directory.create(recursive: true);
  }
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(buildTestToneWav());
  return file;
}

/// Builds the bytes of a 16-bit mono PCM WAV containing two short tones.
///
/// Deliberately two tones rather than one: it makes it obvious by ear whether
/// the whole clip played or whether playback started and got cut off.
Uint8List buildTestToneWav() {
  const int channels = 1;
  const int bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  final frameCount = _sampleRate * _toneLength.inMilliseconds ~/ 1000;
  final dataBytes = frameCount * channels * bytesPerSample;

  final bytes = ByteData(44 + dataBytes);

  // --- RIFF header ---
  void writeAscii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  writeAscii(8, 'WAVE');

  // --- fmt chunk ---
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // PCM chunk size
  bytes.setUint16(20, 1, Endian.little); // format = PCM
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, _sampleRate, Endian.little);
  bytes.setUint32(
    28,
    _sampleRate * channels * bytesPerSample,
    Endian.little,
  ); // byte rate
  bytes.setUint16(32, channels * bytesPerSample, Endian.little); // block align
  bytes.setUint16(34, bitsPerSample, Endian.little);

  // --- data chunk ---
  writeAscii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);

  const firstTone = 440.0; // A4
  const secondTone = 660.0; // E5
  final halfFrames = frameCount ~/ 2;

  for (var frame = 0; frame < frameCount; frame++) {
    // A short fade in/out per tone avoids a click at each boundary.
    final inFirstHalf = frame < halfFrames;
    final localFrame = inFirstHalf ? frame : frame - halfFrames;
    final localLength = inFirstHalf ? halfFrames : frameCount - halfFrames;

    final envelope = (1.0 - (localFrame / localLength)) * 0.4 + 0.2;
    final frequency = inFirstHalf ? firstTone : secondTone;

    final t = frame / _sampleRate;
    final sample = (envelope * _sine(2 * pi * frequency * t)) * 32767;
    bytes.setInt16(
      44 + frame * bytesPerSample,
      sample.round().clamp(-32768, 32767),
      Endian.little,
    );
  }

  return bytes.buffer.asUint8List();
}

double _sine(double radians) {
  // Taylor-free approximation is unnecessary here; Dart has no sin, so use a
  // short minimax-style polynomial over the 0..2*pi range.
  // Normalised: x in [-pi, pi].
  var x = radians % (2 * pi);
  if (x > pi) x -= 2 * pi;
  if (x < -pi) x += 2 * pi;
  // Bhaskara I approximation — plenty accurate for a test tone.
  final absX = x.abs();
  final numerator = 16 * absX * (pi - absX);
  final denominator = 5 * pi * pi - 4 * absX * (pi - absX);
  final value = numerator / denominator;
  return x < 0 ? -value : value;
}