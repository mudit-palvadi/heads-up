/// The proof panel must never report a pass it did not measure.
///
/// The first live run of Spike B rendered "Read-only: verified" in calm green
/// while, on the very same panel, reporting that the check had failed. The
/// cause was structural:
///
/// ```dart
/// bool get isReadOnly =>
///     connected && newlyReadAfterExamine == 0 && newlyReadAfterBodyFetch == 0;
/// ```
///
/// Every failure path leaves both counters at 0, so "measured nothing" and
/// "measured no change" were indistinguishable.
///
/// `ReadOnlyProof` is a plain immutable value object, so all of this is
/// testable without pumping a widget — which is fortunate, because the bug was
/// in the verdict logic rather than in the rendering.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/ui/setup_screen.dart';

void main() {
  /// A run that failed before any snapshot was taken. This is the shape that
  /// used to report a pass.
  ReadOnlyProof failedEarly({bool connected = true, String? detail}) =>
      ReadOnlyProof(
        connected: connected,
        stage: ProofStage.notRun,
        messagesProbed: 0,
        alreadyReadBefore: 0,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: false,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
        error: 'Something went wrong reading your mail.',
        errorDetail: detail,
      );

  /// A complete, clean run.
  ReadOnlyProof clean() => const ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 20,
        alreadyReadBefore: 11,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: true,
        messagesFetched: 5,
        newlyReadAfterBodyFetch: 0,
      );

  group('a run that covered nothing must not claim a pass', () {
    // The first successful connection did exactly this: every counter was 0,
    // the population it looked at was empty, and the panel rendered
    // "PASS -- examined 0 messages" in green. Zero diffs over zero messages is
    // an absence of evidence, not evidence of read-only behaviour.
    const vacuous = ReadOnlyProof(
      connected: true,
      stage: ProofStage.fullyVerified,
      messagesProbed: 0,
      alreadyReadBefore: 0,
      newlyReadAfterExamine: 0,
      bodyFetchSucceeded: true,
      messagesFetched: 0,
      newlyReadAfterBodyFetch: 0,
    );

    test('isReadOnly is false', () {
      expect(vacuous.isReadOnly, isFalse);
    });

    test('hasCoverage is false', () {
      expect(vacuous.hasCoverage, isFalse);
    });

    test('the verdict says nothing to check, not verified', () {
      expect(vacuous.verdict, 'Read-only: nothing to check');
      expect(vacuous.verdict, isNot(contains('verified')));
    });

    test('but a counted body fetch does count as coverage', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 0,
        alreadyReadBefore: 0,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: true,
        messagesFetched: 3,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.hasCoverage, isTrue, reason: 'bodies were read');
      expect(proof.isReadOnly, isTrue);
      expect(proof.verdict, 'Read-only: verified');
    });
  });

  group('the population is reported honestly', () {
    test('coverage and already-read are distinct numbers', () {
      // A mostly-unread mailbox: 20 examined, none read. Conflating these is
      // what produced "examined 0 messages" while messages were in fact covered.
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 20,
        alreadyReadBefore: 0,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: true,
        messagesFetched: 5,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.hasCoverage, isTrue);
      expect(proof.isReadOnly, isTrue);
      expect(proof.verdict, 'Read-only: verified');
      expect(proof.summary(), contains('examined 20 messages'));
      expect(proof.summary(), contains('0 already read'));
    });

    test('the summary states what the body stage did', () {
      expect(
        clean().summary(),
        contains('Bodies fetched without marking read: 5'),
      );
      expect(clean().summary(), contains('ok'));
    });

    test('a skipped body stage says so rather than reading as success', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.examineVerified,
        messagesProbed: 20,
        alreadyReadBefore: 4,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: false,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.summary(), contains('not attempted'));
    });
  });

  group('a failed run must not claim read-only', () {
    test('the exact shape that produced the false positive', () {
      final proof = failedEarly();
      expect(proof.newlyReadAfterExamine, 0);
      expect(proof.newlyReadAfterBodyFetch, 0);
      expect(
        proof.isReadOnly,
        isFalse,
        reason: 'zero counters with no measurement is not a pass',
      );
    });

    test('and is reported as unchecked rather than as a problem', () {
      final proof = failedEarly();
      expect(proof.isUnverified, isTrue);
      expect(proof.verdict, 'Read-only: not checked');
      expect(
        proof.verdict,
        isNot(contains('verified')),
        reason: 'the word "verified" must not appear for an unmeasured run',
      );
    });

    test('a failure after a successful login is still unchecked', () {
      // `connected: true` was what made the old getter return true.
      expect(failedEarly(connected: true).isReadOnly, isFalse);
      expect(failedEarly(connected: false).isReadOnly, isFalse);
    });

    test('no combination of zero counters can produce a full pass', () {
      // Exhaustive over both counters the old getter trusted, crossed with
      // every stage, both connection states, and both zero and non-zero
      // coverage. Only a completed measurement over a real population may
      // report read-only.
      for (final connected in [true, false]) {
        for (final stage in ProofStage.values) {
          for (final probed in [0, 20]) {
            final measured = stage != ProofStage.notRun;
            final proof = ReadOnlyProof(
              connected: connected,
              stage: stage,
              messagesProbed: probed,
              alreadyReadBefore: 0,
              newlyReadAfterExamine: 0,
              bodyFetchSucceeded: false,
              messagesFetched: probed == 0 ? 0 : 5,
              newlyReadAfterBodyFetch: 0,
            );
            expect(
              proof.isReadOnly,
              measured && connected && probed > 0,
              reason: 'stage $stage, connected=$connected, probed=$probed',
            );
          }
        }
      }
    });
  });

  group('a real violation is reported honestly', () {
    test('EXAMINE marking something read is not read-only', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 20,
        alreadyReadBefore: 11,
        newlyReadAfterExamine: 2,
        bodyFetchSucceeded: true,
        messagesFetched: 5,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.isReadOnly, isFalse);
      expect(
        proof.verdict,
        'Read-only: problem',
        reason: 'a measured violation must not read as verified',
      );
      expect(
        proof.summary(),
        contains('FAIL'),
        reason: 'summary must carry the verdict too',
      );
      expect(proof.summary(), contains('EXAMINE marked 2 read'));
    });

    test('BODY.PEEK marking something read is not read-only', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 20,
        alreadyReadBefore: 11,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: true,
        messagesFetched: 5,
        newlyReadAfterBodyFetch: 1,
      );
      expect(proof.isReadOnly, isFalse);
      expect(proof.summary(), contains('BODY.PEEK marked 1 read'));
    });
  });

  group('a clean complete run passes', () {
    test('and says so', () {
      final proof = clean();
      expect(proof.isReadOnly, isTrue);
      expect(proof.isUnverified, isFalse);
      expect(proof.verdict, 'Read-only: verified');
      expect(proof.summary(), contains('PASS'));
      expect(proof.summary(), contains('examined 20 messages'));
      expect(proof.error, isNull);
    });

    test('an empty mailbox is NOT a pass — this test used to say the opposite', () {
      // Previously this read "a zero-message mailbox is still a pass", on the
      // reasoning that nothing to read is a legitimate outcome. That is true of
      // the *pipeline* and false of the *proof*: a guarantee verified over
      // zero messages has verified nothing, and the panel was rendering it as
      // "PASS -- examined 0 messages" in green. The honest verdict is that
      // there was nothing to check.
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.fullyVerified,
        messagesProbed: 0,
        alreadyReadBefore: 0,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: true,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.isReadOnly, isFalse);
      expect(proof.hasCoverage, isFalse);
      expect(proof.verdict, 'Read-only: nothing to check');
    });
  });

  group('partial progress is labelled as partial', () {
    test('EXAMINE proven but body stage not finished', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.examineVerified,
        messagesProbed: 20,
        alreadyReadBefore: 11,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: false,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.isReadOnly, isTrue, reason: 'EXAMINE really was inert');
      expect(
        proof.verdict,
        'Read-only: partly verified',
        reason: 'must not claim the whole guarantee',
      );
      expect(
        proof.verdict,
        isNot('Read-only: verified'),
        reason: 'only a fully completed run may say exactly that',
      );
      expect(
        proof.summary(),
        contains('EXAMINE PASS'),
        reason: 'a partial run must not print a bare PASS',
      );
      expect(
        proof.summary(),
        isNot(startsWith('PASS —')),
        reason: 'nor may it read as an unqualified pass',
      );
    });

    test('flagsVerified is labelled distinctly', () {
      const proof = ReadOnlyProof(
        connected: true,
        stage: ProofStage.flagsVerified,
        messagesProbed: 20,
        alreadyReadBefore: 3,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: false,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.verdict, 'Read-only: partly verified');
    });
  });

  group('diagnostics are preserved', () {
    test('errorDetail survives alongside the friendly message', () {
      final proof = failedEarly(detail: 'during the FLAGS probe: BAD FETCH');
      expect(proof.error, 'Something went wrong reading your mail.');
      expect(
        proof.errorDetail,
        contains('during the FLAGS probe'),
        reason: 'the stage name is what makes the next run diagnosable',
      );
      expect(proof.errorDetail, contains('BAD FETCH'));
      expect(proof.summary(), contains('Something went wrong'));
    });

    test('a clean run carries no error detail', () {
      expect(clean().errorDetail, isNull);
    });
  });
}
