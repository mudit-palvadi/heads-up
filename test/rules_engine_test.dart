/// Tests for [RulesEngine] — rules.md §9, plus the 20-fixture table in §8.
///
/// The engine is the part of this app that decides whether the friend sees an
/// email at all, so the two failure modes are both pinned down:
///
///   * **False negative** — something important is silently dropped.
///   * **False positive** — three widget slots get wasted on noise.
///
/// rules.md §1 says to prefer false negatives, which is why the newsletter and
/// noreply penalties are asserted just as hard as the VIP boosts.
///
/// The clock is always injected. rules.md §8's expected scores only hold for a
/// `now` close to the fixture dates (a deadline counts as "within window" only
/// while it is still ahead of us), so every group fixes `now` explicitly.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/models/rules_config.dart';
import 'package:heads_up/services/cleaner.dart';
import 'package:heads_up/services/rules_engine.dart';

import 'support/fake_email.dart';

/// The clock the §8 table assumes: the morning the fixtures were "received".
final DateTime kNow = DateTime(2026, 10, 1, 9);

const RulesConfig _actionWords = RulesConfig(
  actionWords: [
    'deadline', 'due', 'due date', 'last date', 'last day',
    'submit', 'submission', 'upload', 'fill',
    'action required', 'action needed', 'response required',
    'urgent', 'urgently', 'immediate', 'immediately',
    'reminder', 'final reminder', 'last reminder',
    'confirm', 'confirmation', 'verify', 'verification',
    'reply by', 'respond by', 'get back',
    'expires', 'expiring', 'expiry',
    'rsvp',
    'interview', 'offer letter', 'offer',
    'fee', 'fees', 'payment', 'pay now', 'invoice',
    'form', 'application', 'enroll', 'enrolment',
    'incomplete', 'pending', 'awaiting',
    'please complete', 'kindly complete',
    'overdue', 'missed',
  ],
);

/// The user's rules layered on top, as the VIP screen would produce.
RulesConfig _config({
  List<String> vipAddresses = const [],
  List<String> vipDomains = const [],
  List<String> vipKeywords = const [],
  List<String> ignoreAddresses = const [],
}) =>
    _actionWords.copyWith(
      vipAddresses: vipAddresses,
      vipDomains: vipDomains,
      vipKeywords: vipKeywords,
      ignoreAddresses: ignoreAddresses,
    );

/// Builds engine input from a fixture, running the body through [Cleaner]
/// exactly as the pipeline does.
EmailFacts _facts(FakeEmail email) => EmailFacts(
      uid: 1000,
      receivedAt: parseFixtureDate(email.header('date')!) ?? kNow,
      senderName: email.senderAddress,
      senderAddress: email.senderAddress,
      subject: email.subject,
      body: const Cleaner().clean(email.body, null),
      listUnsubscribe: email.header('list-unsubscribe'),
      precedence: email.header('precedence'),
      xMailer: email.header('x-mailer'),
      inReplyTo: email.header('in-reply-to'),
      toAddresses: email.toAddresses,
      ccAddresses: email.ccAddresses,
    );

MailItem _scoreFixture(
  String name,
  RulesConfig config, {
  DateTime? now,
}) =>
    RulesEngine(config, now: now ?? kNow).score(_facts(loadFakeEmail(name))).item;

void main() {
  group('deadline extraction (rules.md §9)', () {
    final engine = RulesEngine(_config(), now: kNow);

    ExtractedDeadline? find(String text, {DateTime? from}) => engine
        .extractDeadline(text, from ?? DateTime(2026, 10, 1, 10));

    test('extracts "by October 10"', () {
      final d = find('Your form must be submitted by October 10.');
      expect(d, isNotNull);
      expect(d!.date, DateTime(2026, 10, 10, 23, 59));
    });

    test('extracts a numeric full date', () {
      final d = find('Payment is due on 10/10/2026.');
      expect(d!.date, DateTime(2026, 10, 10));
    });

    test('extracts an ISO full date', () {
      final d = find('Payment is due on 2026-10-10.');
      expect(d!.date, DateTime(2026, 10, 10));
    });

    test('extracts "by Friday"', () {
      // 2026-10-01 is a Thursday, so "Friday" is the next day.
      final d = find('Please respond by Friday.');
      expect(d!.date, DateTime(2026, 10, 2, 23, 59));
    });

    test('extracts a bare "next Monday" with no preposition', () {
      // Fixture 12 depends on this; §4.1's preposition list misses it.
      // 2026-10-01 is a Thursday, so the next Monday is the 5th. The engine
      // deliberately does not push "next" out by a further week.
      final d = find('Your interview is scheduled for next Monday.');
      expect(d, isNotNull);
      expect(d!.date, DateTime(2026, 10, 5, 23, 59));
    });

    test('extracts "by tonight" as end of the receiving day', () {
      final d = find('I need a yes or no by tonight.');
      expect(d!.date, DateTime(2026, 10, 1, 23, 59));
    });

    test('extracts "by tomorrow"', () {
      final d = find('Pay the fee by tomorrow.');
      expect(d!.date, DateTime(2026, 10, 2, 23, 59));
    });

    test('extracts "within 3 days"', () {
      final d = find('Update your details within 3 days.');
      expect(d, isNotNull);
      expect(d!.date.day, 4);
    });

    test('extracts "within 24 hours"', () {
      final d = find('Respond within 24 hours.');
      expect(d!.date, DateTime(2026, 10, 2, 10));
    });

    test('a duration deadline keeps the receiving time of day', () {
      // Unlike a named date, "within N days" is relative, so preserving the
      // time makes the remaining interval exact.
      final d = find('Update your details within 3 days.');
      expect(d!.date, DateTime(2026, 10, 4, 10));
    });

    test('extracts a short month + day', () {
      final d = find('Submission required by Oct 8.');
      expect(d!.date, DateTime(2026, 10, 8, 23, 59));
    });

    test('returns null when there is no deadline', () {
      expect(find('Just saying hello. The weather is nice.'), isNull);
    });

    test('ignores a weekday with no preposition and no qualifier', () {
      // "meet Monday afternoons" must not invent a deadline. Note that
      // "on Monday" *does* match — §4.1 lists `on` as a valid preposition.
      expect(find('We usually meet Monday afternoons.'), isNull);
    });

    test('ignores a deadline outside the 14-day window', () {
      final d = find('Pay by March 1.');
      expect(d, isNull);
    });

    test('accepts a past deadline within 2 days (missed list)', () {
      // now = Oct 3, deadline Oct 2 -> one day past, still reported.
      final later = RulesEngine(_config(), now: DateTime(2026, 10, 3, 9));
      final d = later.extractDeadline(
        'The fee was due by Oct 2.',
        DateTime(2026, 10, 1, 10),
      );
      expect(d, isNotNull);
      expect(d!.label, 'was Oct 2');
    });

    test('rejects a past deadline older than the 2-day grace window', () {
      final later = RulesEngine(_config(), now: DateTime(2026, 10, 20, 9));
      final d = later.extractDeadline(
        'The fee was due by Oct 2.',
        DateTime(2026, 10, 1, 10),
      );
      expect(d, isNull);
    });

    test('a past deadline earns no boost (rules.md §4.3)', () {
      final later = RulesEngine(_config(), now: DateTime(2026, 10, 3, 9));
      final result = later.score(EmailFacts(
        uid: 1,
        receivedAt: DateTime(2026, 10, 1, 10),
        senderName: 'Billing',
        senderAddress: 'billing@utility.example',
        subject: 'Fee payment overdue',
        body: 'The fee was due by Oct 2.',
        toAddresses: const ['friend@gmail.com'],
      ));
      expect(result.deadline, isNotNull, reason: 'still reported');
      expect(result.item.reasons, isNot(contains('deadline within window')));
      expect(result.item.reasons, contains('deadline passed'));
    });
  });

  group('deadline wording (rules.md §4.4)', () {
    RulesEngine at(DateTime now) => RulesEngine(_config(), now: now);
    final base = DateTime(2026, 10, 1, 9);

    test('words a near deadline in plain language', () {
      expect(at(base).formatDeadlineLabel(DateTime(2026, 10, 1, 18)), 'today');
      expect(
        at(base).formatDeadlineLabel(DateTime(2026, 10, 2, 23, 59)),
        'tomorrow',
      );
      expect(
        at(base).formatDeadlineLabel(DateTime(2026, 10, 3, 23, 59)),
        'Saturday',
      );
      expect(
        at(base).formatDeadlineLabel(DateTime(2026, 11, 20)),
        'Nov 20',
      );
    });

    test('words an already-passed deadline in the past tense', () {
      // Clock must be *after* the deadline for this branch to apply.
      expect(
        at(DateTime(2026, 10, 7, 9))
            .formatDeadlineLabel(DateTime(2026, 10, 5, 23, 59)),
        'was Oct 5',
      );
    });

    test('never emits an ambiguous numeric date in the near term', () {
      final engine = RulesEngine(_config(), now: kNow);
      for (var offset = 0; offset <= 14; offset++) {
        final label = engine.formatDeadlineLabel(
          DateTime(2026, 10, 1 + offset),
        );
        expect(label, isNot(contains('2026')));
      }
    });
  });

  group('VIP matching (rules.md §2.1, §9)', () {
    final engine = RulesEngine(_config(), now: kNow);

    test('exact address match', () {
      expect(
        engine.matchesVipAddress('Dad@Gmail.com', ['dad@gmail.com']),
        isTrue,
      );
    });

    test('a non-VIP address does not match', () {
      expect(
        engine.matchesVipAddress('stranger@gmail.com', ['dad@gmail.com']),
        isFalse,
      );
    });

    test('domain match', () {
      expect(
        engine.matchesVipDomain('admissions@university.edu', ['university.edu']),
        isTrue,
      );
    });

    test('domain match includes subdomains', () {
      expect(
        engine.matchesVipDomain('admissions@mail.university.edu',
            ['university.edu']),
        isTrue,
      );
    });

    test('domain match does not fire on a lookalike suffix', () {
      expect(
        engine.matchesVipDomain('x@notuniversity.edu', ['university.edu']),
        isFalse,
      );
    });

    test('VIP overrides the noreply penalty', () {
      // The sender IS on the VIP list, which is what waives the penalty.
      final vipEngine =
          RulesEngine(_config(vipAddresses: ['noreply@dad.com']), now: kNow);
      final result = vipEngine.score(EmailFacts(
        uid: 1,
        receivedAt: kNow,
        senderName: 'Dad',
        senderAddress: 'noreply@dad.com',
        subject: 'Hello',
        body: '',
        toAddresses: const ['friend@gmail.com'],
      ));
      expect(result.item.reasons, isNot(contains('noreply sender')));
      expect(result.item.score, greaterThanOrEqualTo(30));
      expect(result.item.isVip, isTrue);
    });

    test('VIP lifts a buried score to the threshold', () {
      final vipEngine =
          RulesEngine(_config(vipAddresses: ['noreply@dad.com']), now: kNow);
      final result = vipEngine.score(EmailFacts(
        uid: 1,
        receivedAt: kNow,
        senderName: 'Dad',
        senderAddress: 'noreply@dad.com',
        subject: 'Weekly digest',
        body: '',
        listUnsubscribe: '<https://x/unsubscribe>',
        toAddresses: const ['friend@gmail.com'],
      ));
      // -100 newsletter penalty would otherwise bury this far below the bar.
      expect(result.item.score, greaterThanOrEqualTo(30));
      expect(result.item.reasons, contains('VIP override'));
    });

    test('a non-VIP noreply sender still takes the penalty', () {
      final result = engine.score(EmailFacts(
        uid: 1,
        receivedAt: kNow,
        senderName: 'Robo',
        senderAddress: 'noreply@notdad.com',
        subject: 'Hello',
        body: '',
        toAddresses: const ['friend@gmail.com'],
      ));
      expect(result.item.reasons, contains('noreply sender'));
      expect(result.item.isVip, isFalse);
    });
  });

  group('ignore and penalty patterns (rules.md §5)', () {
    final engine = RulesEngine(_config(), now: kNow);

    test('noreply prefixes are matched', () {
      for (final address in [
        'noreply@x.com',
        'no-reply@x.com',
        'donotreply@x.com',
        'do-not-reply@x.com',
        'notifications@x.com',
        'mailer@x.com',
        'bounce@x.com',
        'auto@x.com',
        'automated@x.com',
      ]) {
        expect(engine.isNoReply(address), isTrue, reason: address);
      }
    });

    test('a personal address is not treated as noreply', () {
      expect(engine.isNoReply('dad@gmail.com'), isFalse);
    });

    test('promo subjects are matched', () {
      expect(engine.matchesPromoSubject('50% off everything'), isTrue);
      expect(engine.matchesPromoSubject("Don't miss out"), isTrue);
      expect(engine.matchesPromoSubject('Flash sale ends soon'), isTrue);
      expect(engine.matchesPromoSubject('Your form is due Friday'), isFalse);
    });

    test('marketing ESPs are detected from X-Mailer', () {
      expect(engine.isEspMailer('Mailchimp'), isTrue);
      expect(engine.isEspMailer('SendGrid'), isTrue);
      expect(engine.isEspMailer('Apple Mail'), isFalse);
      expect(engine.isEspMailer(null), isFalse);
    });

    test('the user ignore list is absolute', () {
      final ignoring = RulesEngine(
        _config(ignoreAddresses: ['newsletter@zomato.com']),
        now: kNow,
      );
      final result = ignoring.score(EmailFacts(
        uid: 1,
        receivedAt: kNow,
        senderName: 'Zomato',
        senderAddress: 'newsletter@zomato.com',
        // Loaded with action words and a deadline: must still be ignored.
        subject: 'URGENT: Payment due by Friday',
        body: 'Pay now. Action required.',
        toAddresses: const ['friend@gmail.com'],
      ));
      expect(result.item.score, -100);
      expect(result.item.reasons, contains('ignored by user'));
    });
  });

  group('action words use whole-word matching (rules.md §3)', () {
    final engine = RulesEngine(_config(), now: kNow);

    test('a real action word matches', () {
      expect(engine.containsActionWord('URGENT: form due', _config().actionWords),
          isTrue);
    });

    test('multi-word action words match', () {
      expect(
        engine.containsActionWord('Action required from you', _config().actionWords),
        isTrue,
      );
    });

    test('"form" does not match inside "information" or "platform"', () {
      // This is why rules.md §3's prose ("whole-word matching where
      // practical") is followed over the bare `contains` snippet below it.
      expect(engine.containsActionWord('more information here', ['form']), isFalse);
      expect(engine.containsActionWord('use the platform', ['form']), isFalse);
      expect(engine.containsActionWord('information form', ['form']), isTrue);
    });
  });

  group('all 20 fixtures match the expected pass/fail (rules.md §8)', () {
    final config = _config(
      vipAddresses: [
        'meera.lead@examplecorp.com',
        'hr-announcements@examplecorp.com',
      ],
      vipDomains: ['university.edu'],
      vipKeywords: ['scholarship'],
    );

    /// [minimum] is the floor from the §8 table.
    const expectations = <String, ({int minimum, bool shouldPass})>{
      '01_college_form_deadline': (minimum: 70, shouldPass: true),
      '02_friend_yes_no': (minimum: 30, shouldPass: true),
      '03_bank_payment_due': (minimum: 60, shouldPass: true),
      '04_newsletter_promo': (minimum: -1000, shouldPass: false),
      '05_otp': (minimum: -1000, shouldPass: false),
      '06_calendar_invite': (minimum: 30, shouldPass: true),
      '07_long_thread': (minimum: 15, shouldPass: false),
      '08_html_heavy': (minimum: -1000, shouldPass: false),
      '09_no_deadline': (minimum: 10, shouldPass: false),
      '10_tricky_date': (minimum: 50, shouldPass: true),
      '11_manager_reply': (minimum: 65, shouldPass: true),
      '12_interview_offer': (minimum: 70, shouldPass: true),
      '13_noreply_important': (minimum: 10, shouldPass: false),
      '14_non_english_line': (minimum: 30, shouldPass: true),
      '15_past_deadline': (minimum: 30, shouldPass: true),
      '16_fee_payment': (minimum: 60, shouldPass: true),
      '17_bulk_important': (minimum: 20, shouldPass: true),
      '18_short_reply': (minimum: 65, shouldPass: true),
      '19_unsubscribe_only': (minimum: -1000, shouldPass: false),
      '20_form_submission': (minimum: 70, shouldPass: true),
    };

    test('every fixture in the table is scored', () {
      final names = loadAllFakeEmails().map((e) => e.name).toSet();
      for (final name in expectations.keys) {
        expect(names, contains(name), reason: 'fixture $name missing');
      }
      expect(expectations, hasLength(20));
    });

    for (final entry in expectations.entries) {
      final name = entry.key;
      final expected = entry.value;

      test('$name scores >= ${expected.minimum} and '
          '${expected.shouldPass ? 'passes' : 'fails'} the threshold', () {
        final item = _scoreFixture(name, config);
        expect(
          item.score,
          greaterThanOrEqualTo(expected.minimum),
          reason: '$name scored ${item.score} '
              '(reasons: ${item.reasons.join(", ")})',
        );
        expect(
          item.score >= config.scoreThreshold,
          expected.shouldPass,
          reason: '$name scored ${item.score}, '
              'reasons: ${item.reasons.join(", ")}',
        );
      });
    }
  });

  group('the Gemma-call cap (rules.md §2.4)', () {
    final engine = RulesEngine(_config(), now: kNow);

    ScoringResult result(int score, {DateTime? receivedAt}) => ScoringResult(
          item: MailItem(
            id: '${score}_INBOX',
            receivedAt: receivedAt ?? kNow,
            senderName: 'S',
            senderAddress: 's@example.com',
            subject: 'x',
            score: score,
            reasons: const [],
            deadline: null,
            isVip: false,
            processedAt: kNow,
          ),
          deadline: null,
        );

    test('keeps only the top N by score', () {
      final results = [10, 90, 30, 70, 50, 20].map(result).toList();
      final capped = engine.capToTopScoring(results, 3);
      expect(capped, hasLength(3));
      expect(capped.map((r) => r.item.score), [90, 70, 50]);
    });

    test('a cap larger than the input is a no-op', () {
      final results = [10, 20].map(result).toList();
      expect(engine.capToTopScoring(results, 5), hasLength(2));
    });

    test('ties are broken oldest-first, so the longest wait wins', () {
      final older = result(80, receivedAt: kNow.subtract(const Duration(days: 3)));
      final newer = result(80, receivedAt: kNow);
      expect(
        engine.capToTopScoring([newer, older], 1).single.item.receivedAt,
        older.item.receivedAt,
      );
    });

    test('maxScoreOf reports the best score seen', () {
      final results = [10, 90, 30].map(result).toList();
      expect(engine.maxScoreOf(results), 90);
    });
  });

  group('scored items are not yet displayable (architecture.md §8)', () {
    test('a freshly scored item cannot go on the widget', () {
      final engine = RulesEngine(_config(), now: kNow);
      final result = engine.score(EmailFacts(
        uid: 1,
        receivedAt: kNow,
        senderName: 'Admissions',
        senderAddress: 'admissions@university.edu',
        subject: 'Form due Oct 10',
        body: 'Upload your ID.',
        toAddresses: const ['friend@gmail.com'],
      ));
      expect(result.item.isProcessed, isFalse);
      expect(result.isDisplayable, isFalse);
    });
  });
}