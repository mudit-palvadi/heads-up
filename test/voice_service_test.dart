/// Tests for [VoiceService].
///
/// The behaviour worth protecting is mostly about *restraint*: not spending
/// quota twice, not letting more than a summary leave the device, and degrading
/// to on-device speech whenever the cloud path is unavailable.
///
/// Network calls are avoided by injecting a `Dio` whose adapter is stubbed, so
/// these run offline and in milliseconds.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/gemma_service.dart';
import 'package:heads_up/services/voice_service.dart';

/// Records the request and returns a canned response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.statusCode = 200});

  /// Stubbed success body: three bytes, enough to prove the write path runs.
  static const List<int> body = [1, 2, 3];

  final int statusCode;

  RequestOptions? lastRequest;
  int calls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastRequest = options;

    if (statusCode >= 400) {
      return ResponseBody.fromString(
        '{"detail":"quota exceeded"}',
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromBytes(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
      },
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('heads_up_voice');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  VoiceService serviceWith(_StubAdapter adapter) => VoiceService(
        dio: Dio()..httpClientAdapter = adapter,
        // path_provider needs a platform channel, which is unavailable in unit
        // tests; a temp dir keeps the request path exercisable.
        documentsDirectory: () async => tempDir,
      );

  group('request shape (architecture.md §9)', () {
    test('uses the flash model and the output_format query param', () async {
      final adapter = _StubAdapter();
      final result = await serviceWith(adapter).generate(
        itemId: '1_INBOX',
        speechText: 'Form is due. Upload your ID.',
        voiceId: 'VOICE123',
        apiKey: 'sk_test',
      );

      expect(result.hasCloudAudio, isTrue);
      expect(File(result.path!).existsSync(), isTrue);

      final request = adapter.lastRequest!;
      expect(request.path, contains('/v1/text-to-speech/VOICE123'));
      expect(request.uri.queryParameters['output_format'],
          kElevenLabsOutputFormat);
      expect(request.headers['xi-api-key'], 'sk_test');
      expect(request.headers['Accept'], 'audio/mpeg');

      final data = request.data as Map<String, dynamic>;
      expect(data['model_id'], kElevenLabsModelId);
      expect(data['text'], 'Form is due. Upload your ID.');

      final settings = data['voice_settings'] as Map<String, dynamic>;
      expect(settings['speed'], lessThan(1.0), reason: 'slower, for clarity');
    });

    test('responseType is bytes, or the mp3 cannot be decoded', () async {
      final adapter = _StubAdapter();
      await serviceWith(adapter).generate(
        itemId: '1_INBOX',
        speechText: 'Something.',
        voiceId: 'V',
        apiKey: 'sk_test',
      );

      expect(adapter.lastRequest?.responseType, ResponseType.bytes);
    });
  });

  group('caching', () {
    test('a second call does not spend quota again', () async {
      final adapter = _StubAdapter();
      final service = serviceWith(adapter);

      final first = await service.generate(
        itemId: '1_INBOX',
        speechText: 'Hello there.',
        voiceId: 'V',
        apiKey: 'sk_test',
      );
      expect(first.hasCloudAudio, isTrue);
      expect(adapter.calls, 1);

      final second = await service.generate(
        itemId: '1_INBOX',
        speechText: 'Hello there.',
        voiceId: 'V',
        apiKey: 'sk_test',
      );

      expect(second.path, first.path);
      expect(
        adapter.calls,
        1,
        reason: 'architecture.md §9: one call per item, ever',
      );
    });

    test('a different item does make its own call', () async {
      final adapter = _StubAdapter();
      final service = serviceWith(adapter);
      await service.generate(
        itemId: '1_INBOX',
        speechText: 'One.',
        voiceId: 'V',
        apiKey: 'sk_test',
      );
      await service.generate(
        itemId: '2_INBOX',
        speechText: 'Two.',
        voiceId: 'V',
        apiKey: 'sk_test',
      );
      expect(adapter.calls, 2);
    });
  });

  group('restraint', () {
    test('no API key means no request at all', () async {
      final adapter = _StubAdapter();
      final result = await serviceWith(adapter).generate(
        itemId: '1_INBOX',
        speechText: 'Anything.',
        voiceId: 'V',
        apiKey: null,
      );

      expect(result.source, AudioSource.offlineTts);
      expect(adapter.calls, 0, reason: 'must not call without a key');
    });

    test('empty speech text means no request', () async {
      final adapter = _StubAdapter();
      final result = await serviceWith(adapter).generate(
        itemId: '1_INBOX',
        speechText: '   ',
        voiceId: 'V',
        apiKey: 'sk_test',
      );

      expect(result.source, AudioSource.offlineTts);
      expect(adapter.calls, 0);
    });

    test('text is capped so an email body can never be sent by accident', () {
      // Belt-and-braces guard described in the library docs.
      expect(kMaxSpeechChars, lessThan(2500));
      expect(kMaxSpeechChars, lessThanOrEqualTo(500));
    });
  });

  group('failure classification', () {
    Future<VoiceFailure> failureFor(int status) async {
      final adapter = _StubAdapter(statusCode: status);
      try {
        await serviceWith(adapter).generate(
          itemId: '1_INBOX',
          speechText: 'Hello there.',
          voiceId: 'V',
          apiKey: 'sk_test',
        );
        return VoiceFailure.unknown;
      } on VoiceException catch (e) {
        return e.failure;
      }
    }

    test('401 means the key is wrong', () async {
      expect(await failureFor(401), VoiceFailure.noApiKey);
    });

    test('403 means quota exhausted', () async {
      expect(await failureFor(403), VoiceFailure.quotaExhausted);
    });

    test('400 means a bad request', () async {
      expect(await failureFor(400), VoiceFailure.badRequest);
    });

    test('every failure explains itself to a non-technical user', () {
      for (final failure in VoiceFailure.values) {
        final message = VoiceService.explain(failure);
        expect(message, isNotEmpty, reason: failure.name);
        // Should read like advice, not a stack trace.
        expect(message, isNot(contains('Exception')));
        expect(message, isNot(contains('Dio')));
      }
    });
  });

  group('caching', () {
    test('the filename is derived from the item id', () {
      expect(VoiceService.audioFileName('4821_INBOX'), '4821_INBOX.mp3');
    });

    test('a hostile item id cannot escape the audio directory', () {
      // Item ids are derived from server data; a slash would otherwise write
      // outside the intended folder.
      final name = VoiceService.audioFileName('../../etc/passwd');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('..')));
    });

    test('an empty item id still yields a usable filename', () {
      final name = VoiceService.audioFileName('');
      expect(name, isNotEmpty);
      expect(name, endsWith('.mp3'));
    });
  });

  group('what actually leaves the device (prd.md §8)', () {
    test('the payload is the assembled summary, not the email', () {
      const output = GemmaOutput(
        what: 'Enrollment form is due',
        doIt: 'Upload your ID on the portal',
        by: 'Friday',
      );
      final text = speechTextFor(output);

      expect(text, contains('Enrollment form is due'));
      expect(text, contains('Upload your ID'));
      expect(text, contains('Friday'));

      // Nothing from the original mail may appear.
      expect(text.toLowerCase(), isNot(contains('admissions@')));
      expect(text.toLowerCase(), isNot(contains('student services')));
      expect(text.length, lessThan(200));
    });
  });

  group('needsVoice', () {
    MailItem item({
      bool processed = true,
      String? audioPath,
      AudioSource source = AudioSource.offlineTts,
    }) {
      final now = DateTime(2026, 10, 1);
      return MailItem(
        id: '1_INBOX',
        receivedAt: now,
        senderName: 'X',
        senderAddress: 'x@example.com',
        subject: 's',
        score: 50,
        reasons: const [],
        deadline: null,
        isVip: false,
        processedAt: now,
        what: processed ? 'A' : null,
        doIt: processed ? 'B' : null,
        speechText: processed ? 'A. B.' : null,
        audioPath: audioPath,
        audioSource: source,
      );
    }

    test('an unprocessed item needs no voice', () {
      expect(needsVoice(item(processed: false)), isFalse);
    });

    test('an item that already has an mp3 needs no voice', () {
      expect(
        needsVoice(item(audioPath: '/tmp/a.mp3', source: AudioSource.elevenlabs)),
        isFalse,
      );
    });

    test('a processed item awaiting voice does need it', () {
      expect(needsVoice(item()), isTrue);
    });
  });
}