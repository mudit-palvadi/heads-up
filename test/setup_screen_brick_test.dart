/// Guards the invariant that the Setup screen can never brick itself.
///
/// Found the hard way on device: during the first live run of Spike B, both
/// buttons stayed greyed out with no message and no way forward. The cause was
/// structural — `_saveAll()` and the secret read sat *outside* the try block,
/// so any throw from them left `_busy` stuck true, and there was no timeout on
/// the IMAP socket to fall back on.
///
/// A widget test would need dependency injection for `Store` and `MailService`,
/// which this screen does not have. So this asserts the shape of the source
/// instead, the same way `read_only_guard_test.dart` defends the fetch
/// constant: the failure mode is a code structure, so the test checks the
/// structure.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/ui/setup_screen.dart').readAsStringSync();

  /// Returns the body of the method declaration at [signature].
  String bodyOf(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: 'method not found: $signature');

    var depth = 0;
    var seenBrace = false;
    for (var i = start; i < source.length; i++) {
      final c = source[i];
      if (c == '{') {
        depth++;
        seenBrace = true;
      } else if (c == '}') {
        depth--;
        if (seenBrace && depth == 0) return source.substring(start, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('the Setup screen cannot get stuck disabled', () {
    test('every _busy = true is undone in a finally block', () {
      // A busy flag cleared only on the success path is the bug. Checking that
      // each guard method both sets and resets it *and* has a `finally` keeps
      // the reset unreachable-by-throw, without trying to match across nested
      // braces with a regex.
      for (final signature in [
        'Future<void> _testConnection()',
        'Future<void> _downloadModel()',
      ]) {
        final body = bodyOf(signature);
        expect(
          RegExp(r'_busy\s*=\s*true').hasMatch(body),
          isTrue,
          reason: '$signature should disable the buttons while it works',
        );
        expect(
          RegExp(r'_busy\s*=\s*false').hasMatch(body),
          isTrue,
          reason: '$signature must re-enable the buttons',
        );
        expect(
          body.contains('finally'),
          isTrue,
          reason: '$signature must reset _busy from a finally, or a throw '
              'leaves the screen permanently disabled',
        );
        // Exactly one reset: a second one on a success path is how the
        // original bug was able to hide behind a correct-looking reset.
        expect(
          RegExp(r'_busy\s*=\s*false').allMatches(body).length,
          1,
          reason: '$signature should clear the flag in exactly one place',
        );
      }
    });

    test('_testConnection wraps its whole body, not just the socket calls', () {
      final body = bodyOf('Future<void> _testConnection()');
      final tryAt = body.indexOf('try {');

      // Match the *statement*, not the bare name: the explanatory comment above
      // the try mentions `_saveAll()`, and matching that made this test pass
      // for the wrong reason — the same trap as the vacuous BODY.PEEK[] check
      // in read_only_guard_test.dart.
      expect(
        body.indexOf('await _saveAll();'),
        greaterThan(tryAt),
        reason: '_saveAll() must be inside the try, or a throw there bricks '
            'the screen',
      );
      expect(
        body.indexOf('await _store.readSecret('),
        greaterThan(tryAt),
        reason: 'the secret read must be inside the try',
      );
    });

    test('_testConnection catches non-MailException errors too', () {
      final body = bodyOf('Future<void> _testConnection()');

      // A bare `on MailException` let socket/TLS errors escape as unhandled
      // async errors, which is what left the UI disabled with no message.
      expect(
        body.contains('on MailException'),
        isTrue,
        reason: 'MailException still needs its own branch for copy quality',
      );
      expect(
        RegExp(r'\}\s*catch\s*\(').hasMatch(body),
        isTrue,
        reason: 'a catch-all is required so nothing escapes unhandled',
      );
    });

    test('_testConnection cannot leave the socket hanging forever', () {
      final body = bodyOf('Future<void> _testConnection()');

      // MailService.connect is now bounded internally; this asserts the screen
      // relies on that rather than waiting unbounded on a silent server.
      expect(
        body.contains('service.connect('),
        isTrue,
        reason: 'connect should still be the single entry point',
      );
      expect(
        body.contains('.timeout('),
        isFalse,
        reason: 'the bound lives in MailService.kConnectTimeout, not here — a '
            'second timeout here would silently change the error copy',
      );
    });

    test('disconnect cannot mask the result or re-stick the button', () {
      final body = bodyOf('Future<void> _testConnection()');

      expect(
        body.contains('service?.disconnect()'),
        isTrue,
        reason: 'disconnect must tolerate service being null if connect threw',
      );
      expect(
        RegExp(r'await service\?\.disconnect\(\);\s*\}\s*catch').hasMatch(body),
        isTrue,
        reason: 'disconnect needs its own try, or a failing socket call hides '
            'the real proof result',
      );
    });
  });

  group('the IMAP handshake is bounded', () {
    test('connect() applies kConnectTimeout to login, not just the socket', () {
      final mail = File('lib/services/mail_service.dart').readAsStringSync();
      final connect = bodyOf2(mail, 'Future<void> connect({');

      // enough_mail bounds connectToServer (20s) but login waits on a server
      // response with no timeout of its own — this is the hang that happened.
      expect(
        RegExp(r'login\(user, password\)\.timeout\(').hasMatch(connect),
        isTrue,
        reason: 'login() must be bounded or a silent server hangs the UI',
      );
      expect(
        RegExp(r'connectToServer\([^;]*\.timeout\(').hasMatch(connect),
        isTrue,
        reason: 'the socket open should be bounded explicitly too',
      );
    });

    test('a timeout is reported as a connection failure, not swallowed', () {
      final mail = File('lib/services/mail_service.dart').readAsStringSync();
      expect(
        RegExp(r'on TimeoutException').hasMatch(mail),
        isTrue,
        reason: 'a timeout must surface as MailException so the panel can '
            'show it',
      );
      expect(
        RegExp(r"MailFailure\.connection,\s*\n?\s*'Timed out").hasMatch(mail),
        isTrue,
        reason: 'and it must be distinguishable from other connection errors',
      );
    });

    test('kConnectTimeout is long enough for mobile data', () {
      final mail = File('lib/services/mail_service.dart').readAsStringSync();
      // Too aggressive a bound fails connections that were about to succeed on
      // a phone; too long and the friend still can't tap anything.
      final match =
          RegExp(r'kConnectTimeout\s*=\s*Duration\(seconds:\s*(\d+)\)')
              .firstMatch(mail);
      expect(match, isNotNull, reason: 'kConnectTimeout must be a constant');
      final seconds = int.parse(match!.group(1)!);
      expect(seconds, greaterThanOrEqualTo(20));
      expect(seconds, lessThanOrEqualTo(60));
    });
  });
}

/// Like [bodyOf] but for a standalone file's source.
///
/// Takes the *body* start rather than the signature, so a signature that
/// contains its own brace — `connect({` — cannot desynchronise the depth
/// counter by one and swallow the following methods.
String bodyOf2(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'method not found: $signature');

  final bodyStart = source.indexOf('async {', start);
  expect(bodyStart, isNot(-1), reason: 'no async body after: $signature');

  var depth = 0;
  for (var i = bodyStart + 'async '.length; i < source.length; i++) {
    final c = source[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(bodyStart, i + 1);
    }
  }
  fail('unbalanced braces after $signature');
}