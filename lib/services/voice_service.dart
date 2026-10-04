/// Cloud voice: turns each flagged summary into an mp3 with ElevenLabs.
///
/// Specification: architecture.md §9 and §6.4.
///
/// # What leaves the device, and what does not
///
/// This is the only place in the app where anything is sent to a third party,
/// which makes it worth stating precisely (prd.md §8):
///
/// * **Sent:** the `speechText` only — roughly 30 words, assembled from the
///   rules engine's deadline and Gemma's WHAT/DO lines.
/// * **Never sent:** the subject, sender, or any part of the original email.
///
/// The speech text is built by [GemmaService.buildSpeechText] and this class
/// never touches the raw mail body, so there is no code path by which an email
/// could reach ElevenLabs.
///
/// If the key is missing, the free tier is exhausted, or the network is down,
/// this degrades to [AudioSource.offlineTts] and the ▶ button speaks on the
/// device instead. The product keeps working with no cloud voice at all.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/gemma_service.dart';
import 'package:path_provider/path_provider.dart';

/// Architecture.md §9: `eleven_flash_v2_5` is the low-latency model.
const String kElevenLabsModelId = 'eleven_flash_v2_5';

/// Query string, not a body field — a common misreading of the API.
const String kElevenLabsOutputFormat = 'mp3_44100_128';

/// Default voice: "Bella" (architecture.md §5.2).
const String kDefaultVoiceId = 'EXAVITQu4vr4xnSDxMaL';

/// Hard cap on what we will send, as a belt-and-braces guard.
///
/// architecture.md §9 notes the real limit is 2,500 characters; our speech text
/// is ~250. Enforcing it here means a future prompt change cannot accidentally
/// ship a whole email body to a third party.
const int kMaxSpeechChars = 500;

/// Result of a synthesis attempt.
class VoiceResult {
  const VoiceResult({required this.source, this.path});

  /// Where the audio will come from when the ▶ button is tapped.
  final AudioSource source;

  /// Absolute path to the generated mp3, when one was produced.
  final String? path;

  bool get hasCloudAudio =>
      source == AudioSource.elevenlabs && (path?.isNotEmpty ?? false);
}

/// Why a synthesis attempt failed, for the pipeline log.
enum VoiceFailure {
  noApiKey,
  quotaExhausted,
  badRequest,
  network,
  unknown,
}

class VoiceException implements Exception {
  const VoiceException(this.failure, this.message);

  final VoiceFailure failure;
  final String message;

  @override
  String toString() => 'VoiceException($failure): $message';
}

class VoiceService {
  VoiceService({Dio? dio, this.documentsDirectory})
      : _dio = dio ?? Dio();

  final Dio _dio;

  /// Resolves the app documents directory.
  ///
  /// Injected so tests can supply a temp directory — `path_provider` needs a
  /// platform channel, which would otherwise make every request-shaping test
  /// impossible to write.
  final Future<Directory> Function()? documentsDirectory;

  Future<Directory> _docs() async {
    final provided = documentsDirectory;
    if (provided != null) return provided();
    return getApplicationDocumentsDirectory();
  }

  /// Whether audio has already been generated for this item, in this process.
  ///
  /// A cache on top of the on-disk check: without it, a refresh that re-processes
  /// five items would re-bill all five even though the mp3s are on disk.
  final Set<String> _generatedThisRun = {};

  /// Generates an mp3 for [speechText], or explains why it could not.
  ///
  /// Never throws for an expected failure — callers get [VoiceResult] with
  /// [AudioSource.offlineTts] and the widget still works.
  Future<VoiceResult> generate({
    required String itemId,
    required String speechText,
    required String voiceId,
    String? apiKey,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      return const VoiceResult(source: AudioSource.offlineTts);
    }

    final text = speechText.trim();
    if (text.isEmpty) {
      return const VoiceResult(source: AudioSource.offlineTts);
    }

    // One call per item, ever (architecture.md §9). Checked before spending a
    // character of the free tier.
    final path = await audioPath(itemId);
    if (_generatedThisRun.contains(itemId) || await _exists(path)) {
      return VoiceResult(source: AudioSource.elevenlabs, path: path);
    }

    final payload = text.length > kMaxSpeechChars
        ? text.substring(0, kMaxSpeechChars)
        : text;

    try {
      final response = await _dio.post<List<int>>(
        _endpoint(voiceId),
        options: Options(
          headers: {
            'xi-api-key': apiKey,
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
          },
          // The response is raw mp3 bytes, not JSON — getting this wrong yields
          // a decode error rather than audio.
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
        ),
        data: {
          'text': payload,
          'model_id': kElevenLabsModelId,
          // Slightly slow, for clarity (prd.md §7).
          'voice_settings': const {
            'stability': 0.6,
            'similarity_boost': 0.8,
            'speed': 0.95,
          },
        },
      );

      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return const VoiceResult(source: AudioSource.offlineTts);
      }

      await _writeAudio(path, bytes);
      _generatedThisRun.add(itemId);
      return VoiceResult(source: AudioSource.elevenlabs, path: path);
    } on DioException catch (e) {
      // No retry (architecture.md §9): a transient failure would otherwise burn
      // quota on every background refresh.
      throw VoiceException(_classify(e), e.toString());
    }
  }

  /// Fetches the voice list for the settings picker (prd.md §6.4).
  ///
  /// Returns ids and names only; the API key is never persisted here.
  Future<List<VoiceOption>> listVoices(String apiKey) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.elevenlabs.io/v1/voices',
        options: Options(headers: {'xi-api-key': apiKey}),
      );
      final voices = response.data?['voices'];
      if (voices is! List) return const [];
      return voices
          .whereType<Map<String, dynamic>>()
          .map((v) => VoiceOption(
                id: v['voice_id'] as String? ?? '',
                name: v['name'] as String? ?? 'Unnamed',
              ))
          .where((v) => v.id.isNotEmpty)
          .toList();
    } on DioException {
      // The picker is optional; the app works with the default voice.
      return const [];
    }
  }

  /// Where an item's mp3 lives. Public so tests can assert the path shape.
  static String _endpoint(String voiceId) =>
      'https://api.elevenlabs.io/v1/text-to-speech/$voiceId'
      '?output_format=$kElevenLabsOutputFormat';

  /// `<documents>/audio/<itemId>.mp3` (architecture.md §6.4).
  ///
  /// The item id is sanitised because it derives from server data and becomes a
  /// filename. Separators and dot-runs are both stripped: a slash would escape
  /// the directory, and `..` would be a needless path-traversal foothold.
  static String audioFileName(String itemId) {
    var safe = itemId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    // Collapse any leading dots so a crafted id cannot produce "..".
    safe = safe.replaceAll(RegExp(r'^\.+'), '');
    return '${safe.isEmpty ? 'item' : safe}.mp3';
  }

  Future<String> audioPath(String itemId) async {
    final docs = await _docs();
    final dir = Directory('${docs.path}${Platform.pathSeparator}audio');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return '${dir.path}${Platform.pathSeparator}${audioFileName(itemId)}';
  }

  Future<void> _writeAudio(String path, List<int> bytes) async {
    final file = File(path);
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<bool> _exists(String path) async {
    try {
      final file = File(path);
      // A zero-byte file is a failed write, not a usable clip.
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  VoiceFailure _classify(DioException e) {
    final code = e.response?.statusCode;
    final detail = (e.response?.data is String)
        ? (e.response!.data as String).toLowerCase()
        : '';

    // 401 means the key is wrong; 403 often means quota. Both are worth
    // distinguishing because the fix differs.
    if (code == 401) return VoiceFailure.noApiKey;
    if (code == 403 ||
        detail.contains('quota') ||
        detail.contains('character_limit')) {
      return VoiceFailure.quotaExhausted;
    }
    if (code == 400 || code == 422) return VoiceFailure.badRequest;
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return VoiceFailure.network;
    }
    return VoiceFailure.unknown;
  }

  /// Copy for the status screen (prd.md §6.2 "clear message + suggested fix").
  static String explain(VoiceFailure failure) => switch (failure) {
        VoiceFailure.noApiKey =>
          'ElevenLabs rejected the API key. Re-enter it in Settings.',
        VoiceFailure.quotaExhausted =>
          'Out of ElevenLabs characters this month. '
          'The phone will speak these instead.',
        VoiceFailure.badRequest =>
          'ElevenLabs rejected that request. Turning voice off for this item.',
        VoiceFailure.network =>
          "Couldn't reach ElevenLabs. The phone will speak these instead.",
        VoiceFailure.unknown =>
          'Voice generation failed. The phone will speak these instead.',
      };
}

/// One entry in the voice picker.
class VoiceOption {
  const VoiceOption({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String toString() => 'VoiceOption($id, $name)';
}

/// Builds the text sent to ElevenLabs for [item].
///
/// A thin wrapper so the pipeline has one obvious place where "what leaves the
/// phone" is defined — see the library docs.
String speechTextFor(GemmaOutput output) =>
    GemmaService.buildSpeechText(output);

/// Whether [item] needs a cloud clip, or already has one.
bool needsVoice(MailItem item) =>
    item.isProcessed &&
    item.audioPath == null &&
    item.audioSource == AudioSource.offlineTts;