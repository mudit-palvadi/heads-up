/// Tests for [MailItem] — the type the whole widget renders from.
///
/// If these are wrong, the friend either sees nothing or sees the wrong thing,
/// so the round-trip and the urgency rule are both pinned down here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';

MailItem _item({
  DateTime? deadline,
  String? what,
  String? doIt,
  String? speechText,
  AudioSource audioSource = AudioSource.none,
  ItemStatus status = ItemStatus.fresh,
}) {
  final received = DateTime(2026, 10, 1, 9);
  return MailItem(
    id: '4821_INBOX',
    receivedAt: received,
    senderName: 'Admissions',
    senderAddress: 'admissions@university.edu',
    subject: 'Enrollment form due Oct 10',
    score: 110,
    reasons: const ['VIP domain', 'action word in subject', 'deadline within window'],
    deadline: deadline,
    isVip: true,
    processedAt: received,
    what: what,
    doIt: doIt,
    speechText: speechText,
    audioSource: audioSource,
    status: status,
  );
}

void main() {
  group('db round-trip', () {
    test('preserves every field through toMap/fromMap', () {
      final original = _item(
        deadline: DateTime(2026, 10, 10),
        what: 'Internship form is due',
        doIt: 'Upload your ID',
        speechText: 'Internship form is due. Upload your ID. By Oct 10',
        audioSource: AudioSource.elevenlabs,
        status: ItemStatus.done,
      );

      final restored = MailItem.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.receivedAt, original.receivedAt);
      expect(restored.senderName, original.senderName);
      expect(restored.senderAddress, original.senderAddress);
      expect(restored.subject, original.subject);
      expect(restored.score, original.score);
      expect(restored.reasons, original.reasons);
      expect(restored.deadline, original.deadline);
      expect(restored.isVip, isTrue);
      expect(restored.what, original.what);
      expect(restored.doIt, original.doIt);
      expect(restored.by, original.by);
      expect(restored.speechText, original.speechText);
      expect(restored.audioSource, AudioSource.elevenlabs);
      expect(restored.status, ItemStatus.done);
      expect(restored.processedAt, original.processedAt);
    });

    test('null deadline survives as null, not epoch zero', () {
      final restored = MailItem.fromMap(_item().toMap());
      expect(restored.deadline, isNull);
    });

    test('reasons are stored as a JSON array', () {
      final map = _item().toMap();
      expect(map['reasons'], contains('VIP domain'));
      expect(map['reasons'], startsWith('['));
    });

    test('a corrupt reasons column degrades instead of throwing', () {
      final map = _item().toMap()..['reasons'] = 'not json at all';
      expect(MailItem.fromMap(map).reasons, isEmpty);
    });

    test('an unknown audio_source reads back as none', () {
      final map = _item().toMap()..['audio_source'] = 'from_the_future';
      expect(MailItem.fromMap(map).audioSource, AudioSource.none);
    });
  });

  group('isProcessed', () {
    test('is false until Gemma has produced a full WHAT/DO/speech triple', () {
      expect(_item().isProcessed, isFalse);
      expect(_item(what: 'a', doIt: 'b').isProcessed, isFalse);
    });

    test('is true once all three are present', () {
      // architecture.md §8: the widget only ever shows fully processed items.
      final item = _item(what: 'a', doIt: 'b', speechText: 'a. b');
      expect(item.isProcessed, isTrue);
    });
  });

  group('isUrgent', () {
    test('is false when there is no deadline', () {
      expect(_item().isUrgent, isFalse);
    });

    test('is false for a deadline in the future (prd.md §3.3)', () {
      final later = DateTime.now().add(const Duration(days: 3));
      expect(_item(deadline: later).isUrgent, isFalse);
    });

    test('is true for a deadline today', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 18);
      expect(_item(deadline: today).isUrgent, isTrue);
    });

    test('is true for a deadline already passed', () {
      final past = DateTime.now().subtract(const Duration(days: 1));
      expect(_item(deadline: past).isUrgent, isTrue);
    });

    test('ignores the time of day, comparing dates only', () {
      // A deadline at 23:59 tonight must not read as "overdue" at 09:00.
      final now = DateTime.now();
      final tonight = DateTime(now.year, now.month, now.day, 23, 59);
      expect(_item(deadline: tonight).isUrgent, isTrue);
    });
  });

  group('copyWith', () {
    test('changes only the named fields', () {
      final original = _item(deadline: DateTime(2026, 10, 10), what: 'old');
      final updated = original.copyWith(what: 'new');

      expect(updated.what, 'new');
      expect(updated.score, original.score);
      expect(updated.deadline, original.deadline);
      expect(updated.isVip, original.isVip);
      expect(updated.id, original.id);
    });
  });
}