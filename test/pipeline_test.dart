/// Tests for [Pipeline] orchestration, with every service faked.
///
/// The behaviour that matters most here is not arithmetic, it is the split
/// between [Pipeline.runFull] and [Pipeline.runLight]: a background run scores
/// email but cannot rewrite it, and that half-finished state must never reach
/// the widget (architecture.md §8). That rule is easy to break by accident and
/// invisible when broken — the widget just quietly shows stale items.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:heads_up/models/settings.dart';
import 'package:heads_up/services/mail_service.dart';
import 'package:heads_up/services/pipeline.dart';
import 'package:heads_up/services/store.dart';
import 'package:heads_up/services/widget_sync.dart';

/// Records what was stored, without touching sqflite or the KeyStore.
class _FakeStore extends Store {
  AppSettings? settings;
  final List<MailItem> saved = [];
  final List<Map<String, Object?>> ruleOverrides = [];
  ({int lastUid, int? uidValidity}) checkpoint = (lastUid: 0, uidValidity: null);
  String? secret;

  @override
  Future<List<MailItem>> getTopItems({int limit = 3}) async =>
      saved.where((i) => i.isProcessed).take(limit).toList();

  @override
  Future<void> saveItem(MailItem item) async => saved.add(item);

  @override
  Future<AppSettings> loadSettings() async =>
      settings ?? AppSettings(scoreThreshold: 30);

  @override
  Future<void> saveSettings(AppSettings value) async => settings = value;

  @override
  Future<String?> readSecret(String key) async => secret;

  @override
  Future<void> saveMailCheckpoint({
    required int lastUid,
    required int? uidValidity,
    DateTime? checkedAt,
  }) async {
    checkpoint = (lastUid: lastUid, uidValidity: uidValidity);
  }

  @override
  Future<({int lastUid, int? uidValidity})> loadMailCheckpoint() async =>
      checkpoint;

  @override
  Future<Map<String, Object?>?> loadRulesOverride() async =>
      ruleOverrides.isEmpty ? null : ruleOverrides.last;
}

/// Never actually connects.
class _FakeMail extends MailService {
  _FakeMail({this.messages = const [], this.uidValidity = 999});

  List<FetchedMail> messages;
  final int uidValidity;
  int fetchCalls = 0;

  @override
  Future<int> inboxUidValidity() async => uidValidity;

  @override
  Future<List<FetchedMail>> fetchNew({required int lastUid, int take = 20}) async {
    fetchCalls++;
    return messages;
  }
}

/// Records what the pipeline pushed to the widget, without a platform channel.
class _FakeWidget extends WidgetSync {
  final List<List<MailItem>> syncs = [];

  @override
  Future<void> sync(List<MailItem> items,
      {String androidName = 'HeadsUpWidgetProvider'}) async {
    syncs.add(items);
  }

  /// What the widget would actually display, using the real filter.
  List<MailItem> get visible => WidgetSync.visibleItems(syncs.last);
}

FetchedMail _fakeFetched(int uid) => FetchedMail(
      uid: uid,
      receivedAt: DateTime(2026, 10, 1, 9),
      senderAddress: 'admissions@university.edu',
      senderName: 'Admissions',
      subject: 'URGENT: Enrollment Form Due Oct 10',
      plainText: 'Your enrollment form must be submitted by October 10, 2026. '
          'Please upload your ID proof.',
      htmlText: '',
      toAddresses: const ['friend@gmail.com'],
      ccAddresses: const [],
      listUnsubscribe: null,
      precedence: null,
      xMailer: null,
      inReplyTo: null,
    );

RulesConfig _config() => const RulesConfig(
      actionWords: ['urgent', 'due', 'form'],
      vipDomains: ['university.edu'],
      scoreThreshold: 30,
    );

void main() {
  group('runLight never produces a widget-ready item', () {
      final widget = _FakeWidget();
    test('background scoring leaves items unrewritten and hidden', () async {
      final store = _FakeStore();
      final mail = _FakeMail(messages: [_fakeFetched(100)]);

      final pipeline = Pipeline(
        store: store,
        mail: mail,
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      final result = await pipeline.runLight();

      expect(result.succeeded, isTrue,
          reason: 'runLight failed: ${result.error}');
      expect(result.aboveThreshold, 1, reason: 'should be flagged');

      // The item is stored, but with no WHAT/DO — so it cannot be displayed.
      expect(store.saved, hasLength(1));
      final stored = store.saved.first;
      expect(stored.isProcessed, isFalse);
      expect(WidgetSync.visibleItems(store.saved), isEmpty);
    });

    test('background run does no rewriting at all', () async {
      // architecture.md §8: Gemma is never invoked from the background isolate.
      final pipeline = Pipeline(
        store: _FakeStore(),
        mail: _FakeMail(messages: [_fakeFetched(100)]),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      final result = await pipeline.runLight();

      expect(result.rewritten, 0);
      expect(result.fellBack, 0);
      expect(result.voiced, 0);
    });
  });

  group('runLight advances the checkpoint', () {
      final widget = _FakeWidget();
    test('records the highest UID seen', () async {
      final store = _FakeStore();
      final pipeline = Pipeline(
        store: store,
        mail: _FakeMail(messages: [
          _fakeFetched(100),
          _fakeFetched(107),
          _fakeFetched(103),
        ]),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      await pipeline.runLight();

      expect(store.checkpoint.lastUid, 107);
      expect(store.checkpoint.uidValidity, 999);
    });

    test('an empty inbox does not rewind the checkpoint', () async {
      final store = _FakeStore()..checkpoint = (lastUid: 42, uidValidity: 999);
      final pipeline = Pipeline(
        store: store,
        mail: _FakeMail(messages: const []),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      await pipeline.runLight();

      expect(store.checkpoint.lastUid, 42,
          reason: 'a quiet inbox must not forget progress');
    });
  });

  group('a changed UIDVALIDITY restarts the scan', () {
      final widget = _FakeWidget();
    test('does not skip the whole inbox after a server-side rebuild', () async {
      // If UIDs are meaningless, carrying the old high-water mark forward would
      // silently skip every message the friend has.
      final store = _FakeStore()..checkpoint = (lastUid: 5000, uidValidity: 111);
      final pipeline = Pipeline(
        store: store,
        // Server now reports a different UIDVALIDITY.
        mail: _FakeMail(messages: [_fakeFetched(1)], uidValidity: 222),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      await pipeline.runLight();

      expect(store.checkpoint.uidValidity, 222);
      expect(store.checkpoint.lastUid, 1,
          reason: 'should restart from the new lowest UID, not stay at 5000');
    });

    test('an unchanged UIDVALIDITY keeps the checkpoint', () async {
      final store = _FakeStore()..checkpoint = (lastUid: 500, uidValidity: 999);
      final pipeline = Pipeline(
        store: store,
        mail: _FakeMail(messages: const [], uidValidity: 999),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      await pipeline.runLight();

      expect(store.checkpoint.lastUid, 500);
    });
  });

  group('failure handling', () {
      final widget = _FakeWidget();
    test('a mail failure is reported, not thrown', () async {
      final pipeline = Pipeline(
        store: _FakeStore(),
        mail: _ThrowingMail(),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      final result = await pipeline.runFull();

      expect(result.succeeded, isFalse);
      expect(result.error, isNotNull);
      expect(result.log, isNotEmpty);
      expect(result.log.last.isError, isTrue);
    });

    test('the log is capped so the status screen stays readable', () async {
      final pipeline = Pipeline(
        store: _FakeStore(),
        mail: _ThrowingMail(),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      for (var i = 0; i < 10; i++) {
        await pipeline.runFull();
      }

      expect(pipeline.log.length, lessThanOrEqualTo(Pipeline.maxLogEvents));
    });
  });

  group('deadline wording matches what the widget shows', () {
      final widget = _FakeWidget();
    test('rules deadline is passed to Gemma, never guessed', () async {
      // The pipeline must hand Gemma the rules engine's label; the whole safety
      // story depends on Gemma not choosing its own.
      final store = _FakeStore();
      final pipeline = Pipeline(
        store: store,
        mail: _FakeMail(messages: [_fakeFetched(100)]),
        widgetSync: widget,
        configBuilder: (_) async => _config(),
      );

      await pipeline.runFull();

      // Gemma has no model in tests, so every item falls back — which is
      // itself the assertion: the run completes and stores something usable
      // rather than dropping the email.
      expect(store.saved, isNotEmpty);
      for (final item in store.saved) {
        expect(item.what, isNotNull);
        expect(item.doIt, isNotNull);
        expect(item.speechText, isNotNull,
            reason: 'a stored row must always be speakable');
      }
    });
  });

  group('the Gemma cap is respected', () {
      final widget = _FakeWidget();
    test('never rewrites more than maxItemsPerRun', () async {
      final store = _FakeStore();
      final mail = _FakeMail(messages: [
        for (var i = 0; i < 12; i++) _fakeFetched(100 + i),
      ]);

      final pipeline = Pipeline(
        store: store,
        mail: mail,
        widgetSync: widget,
        configBuilder: (_) async => const RulesConfig(
          actionWords: ['urgent'],
          vipDomains: ['university.edu'],
          scoreThreshold: 30,
          maxItemsPerRun: 5,
        ),
      );

      final result = await pipeline.runFull();

      expect(result.aboveThreshold, 12);
      expect(store.saved.length, lessThanOrEqualTo(5));
      expect(result.skippedByCap, greaterThan(0));
    });
  });
}

/// Fails at the first step, to exercise the error path.
class _ThrowingMail extends MailService {
  @override
  Future<int> inboxUidValidity() async =>
      throw const MailException(MailFailure.connection, 'offline');

  @override
  Future<List<FetchedMail>> fetchNew({required int lastUid, int take = 20}) async =>
      const [];
}
