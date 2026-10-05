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
      // every stage and both connection states. Only a stage that records a
      // completed measurement may report read-only.
      for (final connected in [true, false]) {
        for (final stage in ProofStage.values) {
          final measured = stage != ProofStage.notRun;
          final proof = ReadOnlyProof(
            connected: connected,
            stage: stage,
            messagesProbed: 0,
            alreadyReadBefore: 0,
            newlyReadAfterExamine: 0,
            bodyFetchSucceeded: false,
            messagesFetched: 0,
            newlyReadAfterBodyFetch: 0,
          );
          expect(
            proof.isReadOnly,
            measured && connected,
            reason: 'stage $stage with connected=$connected',
          );
          if (!connected) {
            expect(proof.summary(), 'Could not connect.');
          } else {
            // Only a fully completed run may print an unqualified PASS; a
            // partially measured one must be visibly partial.
            final expectedPrefix = switch (stage) {
              ProofStage.fullyVerified => 'PASS —',
              ProofStage.examineVerified || ProofStage.flagsVerified =>
                'EXAMINE PASS —',
              ProofStage.notRun => 'NOT CHECKED —',
            };
            expect(
              proof.summary(),
              startsWith(expectedPrefix),
              reason: 'stage $stage must label itself honestly',
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
      expect(proof.verdict, 'Read-only: verified');
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

    test('a zero-message mailbox is still a pass', () {
      // Nothing to read is a legitimate outcome, not a failure.
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
      expect(proof.isReadOnly, isTrue);
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
        messagesProbed: 0,
        alreadyReadBefore: 0,
        newlyReadAfterExamine: 0,
        bodyFetchSucceeded: false,
        messagesFetched: 0,
        newlyReadAfterBodyFetch: 0,
      );
      expect(proof.verdict, 'Read-only: EXAMINE verified only');
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
