/// Pins the INBOX descriptor construction.
///
/// Found on the first live run of Spike B: `Mailbox` was being constructed with
/// `flags: const <MailboxFlag>[]`, and `enough_mail`'s constructor *mutates*
/// that list —
///
/// ```dart
/// if (!isInbox && name.toLowerCase() == 'inbox') {
///   flags.add(MailboxFlag.inbox);
/// }
/// ```
///
/// — so it threw "cannot add to an unmodifiable list" on every call. Since
/// `isInbox` is `hasFlag(MailboxFlag.inbox)`, an empty list always trips the
/// guard, so this was deterministic, not intermittent. Every IMAP read path
/// failed before issuing a command.
///
/// The first half of this file tests the library behaviour that caused it; the
/// second tests that *our* descriptor survives it. A grep-based test could only
/// have checked that the text `const` was absent — the bug was behavioural, so
/// the regression test has to be too.
library;

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/services/mail_service.dart';

void main() {
  group('the enough_mail behaviour that caused this bug', () {
    test('Mailbox mutates the flags list it is given', () {
      // The library's own contract, asserted so the reason for our growable
      // list is recorded somewhere executable rather than only in a comment.
      final flags = <MailboxFlag>[];
      Mailbox(
        encodedName: 'INBOX',
        encodedPath: 'INBOX',
        flags: flags,
        pathSeparator: '/',
      );
      expect(
        flags,
        contains(MailboxFlag.inbox),
        reason: 'enough_mail adds MailboxFlag.inbox itself',
      );
    });

    test('a const flags list therefore throws', () {
      // This is the exact defect. If a future enough_mail release stops
      // mutating, this test fails and the comment in mail_service.dart can be
      // revisited rather than silently going stale.
      expect(
        () => Mailbox(
          encodedName: 'INBOX',
          encodedPath: 'INBOX',
          flags: const <MailboxFlag>[],
          pathSeparator: '/',
        ),
        throwsA(anything),
        reason: 'if this no longer throws, enough_mail changed and the '
            'growable-list comment in mail_service.dart should be revisited',
      );
    });

    test('isInbox is derived from flags, and the constructor sets it', () {
      // A non-INBOX mailbox with no inbox flag is left alone — this is the
      // branch that does not run, which is what makes INBOX special.
      final other = Mailbox(
        encodedName: 'Archive',
        encodedPath: 'Archive',
        flags: <MailboxFlag>[],
        pathSeparator: '/',
      );
      expect(other.isInbox, isFalse);
      expect(other.flags, isEmpty, reason: 'nothing should have been added');

      // An INBOX mailbox is promoted *during* construction, which is precisely
      // the mutation that makes a const list fatal.
      final inbox = Mailbox(
        encodedName: 'INBOX',
        encodedPath: 'INBOX',
        flags: <MailboxFlag>[],
        pathSeparator: '/',
      );
      expect(inbox.isInbox, isTrue);
      expect(inbox.flags, contains(MailboxFlag.inbox));
    });
  });

  group('our INBOX descriptor', () {
    test('constructs without throwing', () {
      expect(() => MailService.inboxForTest, returnsNormally);
    });

    test('is recognised as the inbox', () {
      final mailbox = MailService.inboxForTest;
      expect(mailbox.isInbox, isTrue);
      expect(mailbox.encodedName, 'INBOX');
      expect(mailbox.encodedPath, 'INBOX');
      expect(mailbox.pathSeparator, '/');
    });

    test('is a read-write=false descriptor until EXAMINE says otherwise', () {
      // We construct the descriptor ourselves, so `isReadWrite` starts at its
      // default. The EXAMINE response overwrites it, and
      // `lastExamineWasReadOnly` is what the proof actually trusts. This test
      // only documents that we are not asserting read-write-ness ourselves.
      expect(MailService.inboxForTest.isReadWrite, isFalse);
    });
  });

  group('no const list is ever handed to enough_mail', () {
    test('mail_service.dart passes only growable lists into constructors', () {
      final source = File('lib/services/mail_service.dart').readAsStringSync();

      // A const collection literal inside a constructor argument list is the
      // shape of the original defect. Scan for `flags: const` and friends.
      expect(
        RegExp(r'(flags|to|cc|bcc|recipients)\s*:\s*const\s*[\[<]')
            .hasMatch(source),
        isFalse,
        reason: 'enough_mail mutates collection arguments; never pass const',
      );
    });

    test('the read-only fetch definition is still BODY.PEEK[]', () {
      // Cheap insurance that this file's edit did not disturb the one constant
      // that must never change.
      expect(kReadOnlyFetch, contains('BODY.PEEK[]'));
      expect(kReadOnlyFetch, isNot(contains('BODY[]')));
    });
  });
}