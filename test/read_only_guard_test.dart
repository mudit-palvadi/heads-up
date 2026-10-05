/// Structural guarantees that the app cannot mark email read.
///
/// `prd.md` §8 makes read-only access a hard constraint. Code review alone is
/// not a sufficient guard for that: the difference between safe and unsafe is a
/// couple of tokens (`examineMailbox` vs `selectMailbox`, `BODY.PEEK[]` vs
/// `BODY[]`), and a well-meaning change could reintroduce it without any test
/// failing.
///
/// These tests are deliberately static — they read the source — so they run in
/// CI with no IMAP server and no credentials.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/services/mail_service.dart';

String _libPath(List<String> parts) => parts.join(Platform.pathSeparator);

/// Every Dart source file under `lib/`.
List<File> _libSources() {
  final dir = Directory(_libPath(['lib']));
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

/// Reads [f] with comments stripped.
///
/// Without this the guard matches its own documentation — `mail_service.dart`
/// explains in a comment *why* it avoids `SELECT`, and that prose would trip
/// the check. Only real code can execute a mailbox write, so only real code
/// matters here.
String _codeOnly(File f) => f
    .readAsStringSync()
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('///'))
    .where((line) => !line.trimLeft().startsWith('//'))
    .where((line) => !line.trimLeft().startsWith('*'))
    .join('\n');

void main() {
  group('the write-capable IMAP call is never used', () {
    test('selectMailbox / selectInbox appear nowhere in lib/', () {
      // SELECT identifies the mailbox read-write and sets \Seen on fetched
      // bodies. EXAMINE is its read-only twin and is the only one allowed.
      final offenders = <String>[];
      for (final file in _libSources()) {
        final source = _codeOnly(file);
        for (final banned in [
          'selectMailbox',
          'selectInbox',
          'selectMailboxByPath',
          'selectInboxByPath',
        ]) {
          if (source.contains(banned)) {
            offenders.add('${file.path}: $banned');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Read-only violation: mail_service must use EXAMINE only.\n'
            '${offenders.join("\n")}',
      );
    });

    test('no STORE command is issued', () {
      // STORE writes flags. Heads Up never modifies the mailbox.
      for (final file in _libSources()) {
        expect(
          _codeOnly(file),
          isNot(contains('store(')),
          reason: '${file.path} appears to STORE flags',
        );
      }
    });

    test('no message is deleted or moved', () {
      for (final file in _libSources()) {
        final source = _codeOnly(file);
        for (final banned in ['deleteMailbox', 'moveMessages', 'copyMessages']) {
          expect(
            source.contains(banned),
            isFalse,
            reason: '${file.path} uses $banned',
          );
        }
      }
    });
  });

  group('the read-only fetch definition is correct', () {
    final mailServicePath = 'lib${Platform.pathSeparator}services'
        '${Platform.pathSeparator}mail_service.dart';

    late String source;

    setUpAll(() {
      source = File(mailServicePath).readAsStringSync();
    });

    test('uses BODY.PEEK, never a bare BODY[]', () {
      // `BODY[]` marks messages read; `BODY.PEEK[]` does not. This is the
      // single most dangerous token in the whole app.
      //
      // Checked by *removing* PEEK from the actual constant and re-asserting,
      // because `expect(source, contains('BODY.PEEK[]'))` alone is vacuous: the
      // file still contains that substring in a doc comment even after the
      // constant has been changed to a bare `BODY[]`.
      const peeked = 'BODY.PEEK[] ENVELOPE FLAGS RFC822.SIZE';
      expect(peeked.replaceAll('PEEK', ''), isNot(peeked));
      expect(source, contains(peeked));

      final constantMatch = RegExp(
        r"const String kReadOnlyFetch = '([^']*)';",
      ).firstMatch(source);
      expect(
        constantMatch,
        isNotNull,
        reason: 'kReadOnlyFetch constant not found',
      );

      final definition = constantMatch!.group(1)!;
      expect(
        definition,
        contains('BODY.PEEK[]'),
        reason: 'the live fetch definition must use PEEK',
      );
      // Every BODY occurrence must be the PEEK form: either `BODY.PEEK[]` or
      // `BODY.PEEK[HEADER.FIELDS (...)]`. A bare `BODY` or `BODY[...]` marks
      // messages read.
      final allBodyTokens = RegExp(
        r'BODY(?:\.PEEK)?(?:\[[^\]]*\])?',
      ).allMatches(definition);
      expect(allBodyTokens, isNotEmpty, reason: 'should have matched BODY');

      for (final match in allBodyTokens) {
        expect(
          match.group(0),
          startsWith('BODY.PEEK'),
          reason: 'fetch definition contains "${match.group(0)}" without PEEK',
        );
      }
    });

    test('the fetch definition is a single named constant', () {
      // One constant means one place to review and one place to change.
      expect(source, contains('kReadOnlyFetch'));
      expect(source, contains('const String kReadOnlyFetch'));
    });

    test('examines the inbox rather than selecting it', () {
      expect(source, contains('examineMailbox'));
    });

    test('asserts no messages were marked read after fetching', () {
      expect(source, contains('assertNoMessagesMarkedRead'));
    });
  });

  group('the probe used to prove read-only behaviour is itself safe', () {
    // This used to assert the *source text* contained the literal
    // "'UID FLAGS'", which was satisfied by any mention of the string
    // anywhere — including a doc comment — and checked nothing about what was
    // actually sent. It passed happily while the probe was sending an invalid
    // command. Now it asserts the live constant and the real call site.
    test('probeFlags fetches flags only, never content', () {
      expect(
        kFlagsOnlyFetch.replaceAll(RegExp(r'[()]'), ''),
        'FLAGS',
        reason: 'the probe must request only FLAGS (parentheses aside)',
      );
      expect(
        kFlagsOnlyFetch,
        isNot(contains('BODY')),
        reason: 'the flags probe must not fetch content',
      );
      expect(
        kFlagsOnlyFetch,
        isNot(contains('UID')),
        reason: 'UID is not a requestable FETCH item; Gmail answers BAD',
      );
    });

    test('probeFlags uses the flags-only definition, not the body one', () {
      final mailServicePath = 'lib${Platform.pathSeparator}services'
          '${Platform.pathSeparator}mail_service.dart';
      final source = File(mailServicePath).readAsStringSync();

      // Extract probeFlags' body and confirm which constant it fetches with.
      final start = source.indexOf('Future<FlagSnapshot> probeFlags(');
      expect(start, isNot(-1), reason: 'probeFlags not found');

      var depth = 0;
      var seenBrace = false;
      var end = -1;
      for (var i = source.indexOf('async {', start);
          i < source.length && end < 0;
          i++) {
        final c = source[i];
        if (c == '{') {
          depth++;
          seenBrace = true;
        } else if (c == '}') {
          depth--;
          if (seenBrace && depth == 0) end = i;
        }
      }
      expect(end, isNot(-1), reason: 'could not delimit probeFlags');
      final body = source.substring(start, end);

      expect(
        body,
        contains('kFlagsOnlyFetch'),
        reason: 'probeFlags must fetch with kFlagsOnlyFetch',
      );
      expect(
        body,
        isNot(contains('kReadOnlyFetch')),
        reason: 'probeFlags must never send the BODY.PEEK[] definition — that '
            'is the thing it exists to avoid doing before the diff is taken',
      );
    });
  });

  group('the secrets are not in the mail service', () {
    test('no hard-coded credentials', () {
      final mailServicePath = 'lib${Platform.pathSeparator}services'
          '${Platform.pathSeparator}mail_service.dart';
      final source = File(mailServicePath).readAsStringSync();

      // Passwords arrive as parameters and are read from the KeyStore.
      expect(source.contains('password:'), isFalse);
      expect(source, contains('required String password'));
    });
  });
}