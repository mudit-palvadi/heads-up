/// The fetch definitions this app is allowed to send, checked against the RFC.
///
/// Found on the third live Spike B run: the FLAGS probe sent
/// `UID FETCH <range> UID FLAGS`, and Gmail replied
/// `BAD Could not parse command`.
///
/// The cause is easy to get wrong and impossible to guess from the library:
/// RFC 3501 §6.4.8 does not list `UID` among the FETCH data items a client may
/// request. A `UID FETCH` response *always* carries the UID regardless, so
/// requesting it is not merely redundant — it is a syntax error, and a strict
/// server will refuse the whole command.
///
/// This matters beyond tidiness: the read-only proof's first stage *is* this
/// probe. When it fails, the guarantee goes unmeasured and the panel honestly
/// says "not checked".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/services/mail_service.dart';

/// Splits a fetch definition into its individual data items.
List<String> items(String definition) => definition
    .split(RegExp(r'\s+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  group('kReadOnlyFetch', () {
    test('asks for BODY.PEEK[], never a bare BODY[]', () {
      expect(kReadOnlyFetch, contains('BODY.PEEK[]'));
      expect(
        kReadOnlyFetch,
        isNot(contains('BODY[]')),
        reason: 'BODY[] would mark real messages read',
      );
    });

    test('does not request UID', () {
      expect(
        items(kReadOnlyFetch),
        isNot(contains('UID')),
        reason: 'UID is not a requestable FETCH item (RFC 3501 6.4.8)',
      );
    });

    test('every item is a real FETCH data item', () {
      const allowed = {
        'ENVELOPE',
        'FLAGS',
        'INTERNALDATE',
        'RFC822',
        'RFC822.HEADER',
        'RFC822.SIZE',
        'RFC822.TEXT',
        'BODY',
        'BODYSTRUCTURE',
      };

      for (final item in items(kReadOnlyFetch)) {
        // BODY[...] forms carry a section spec, e.g. BODY.PEEK[HEADER.FIELDS].
        final isSectionFetch = item.startsWith('BODY');
        expect(
          isSectionFetch || allowed.contains(item),
          isTrue,
          reason: '"$item" is not a FETCH data item in RFC 3501; '
              'the server will answer BAD',
        );
      }
    });
  });

  group('kFlagsOnlyFetch', () {
    test('is exactly FLAGS', () {
      expect(kFlagsOnlyFetch, 'FLAGS');
    });

    test('does not request UID — the bug found on device', () {
      expect(
        items(kFlagsOnlyFetch),
        isNot(contains('UID')),
        reason: 'Gmail answers "BAD Could not parse command" if UID is asked '
            'for explicitly, which silently unmeasures the read-only proof',
      );
    });
  });

  group('no fetch definition regresses to the broken form', () {
    test('the string "UID FLAGS" appears nowhere as a fetch definition', () {
      // Guards the literal, since that is exactly what was written before.
      expect(kFlagsOnlyFetch, isNot(contains('UID')));
      expect(kReadOnlyFetch, isNot(contains('UID')));
    });
  });
}