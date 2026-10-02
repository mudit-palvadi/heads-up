/// Tests for [Cleaner] — architecture.md §6.2.
///
/// These are the fiddliest rules in the pipeline: strip the history, strip the
/// signature, strip the footer, and never cut a word in half. Getting any of
/// them wrong quietly feeds Gemma a wall of quoted text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/services/cleaner.dart';

import 'support/fake_email.dart';

void main() {
  const cleaner = Cleaner();

  group('htmlToText', () {
    test('converts block elements to line breaks, not one run-on line', () {
      // Regression guard: Document.body.text concatenates with no separator,
      // which would yield "The Daily BriefHere are today's stories".
      const html = '<body><h1>The Daily Brief</h1><p>Markets close higher.</p>'
          '</body>';
      final text = cleaner.htmlToText(html);
      expect(text, contains('The Daily Brief'));
      expect(text, contains('Markets close higher.'));
      expect(text, isNot(contains('BriefMarkets')));
    });

    test('drops script and style contents entirely', () {
      const html = '<body><style>.a{color:red}</style>'
          '<script>alert(1)</script><p>Real content</p></body>';
      final text = cleaner.htmlToText(html);
      expect(text, contains('Real content'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('color:red')));
    });

    test('resolves HTML entities', () {
      expect(cleaner.htmlToText('<p>a &amp; b</p>'), contains('a & b'));
      expect(cleaner.htmlToText('<p>it&#39;s</p>'), contains("it's"));
    });

    test('handles <br> as a line break', () {
      final text = cleaner.htmlToText('<p>one<br>two</p>');
      expect(text, contains('one'));
      expect(text, contains('two'));
    });

    test('returns empty string for empty input', () {
      expect(cleaner.htmlToText(''), '');
      expect(cleaner.htmlToText('   '), '');
    });
  });

  group('stripQuotedReplies', () {
    test('removes everything after an RFC 3676 "wrote:" line', () {
      const text = 'Thanks, that works.\n\n'
          'On Wed, 30 Sep 2026, Sam wrote:\n'
          '> Here are the notes from Tuesday.\n'
          '> Section two is wrong.';
      final result = cleaner.stripQuotedReplies(text);
      expect(result, contains('Thanks, that works.'));
      expect(result, isNot(contains('Here are the notes')));
      expect(result, isNot(contains('Section two')));
    });

    test('removes an Outlook "Original Message" banner onwards', () {
      const text = 'My reply here.\n\n'
          '-----Original Message-----\n'
          'From: someone\n'
          'Sent: Tuesday\n'
          'Old content that should go.';
      final result = cleaner.stripQuotedReplies(text);
      expect(result, contains('My reply here.'));
      expect(result, isNot(contains('Old content')));
    });

    test('leaves text without quotes untouched', () {
      const text = 'Plain message with no history.\nSecond line.';
      expect(cleaner.stripQuotedReplies(text), text);
    });
  });

  group('stripSignature', () {
    test('removes everything after the RFC 3676 delimiter', () {
      const text = 'The actual message.\n\n-- \nJane Doe\nSenior Engineer';
      final result = cleaner.stripSignature(text);
      expect(result, contains('The actual message.'));
      expect(result, isNot(contains('Senior Engineer')));
    });

    test('leaves a message with no signature untouched', () {
      const text = 'No signature here.';
      expect(cleaner.stripSignature(text), text);
    });
  });

  group('stripFooters', () {
    test('removes unsubscribe boilerplate', () {
      const text = 'Real offer text.\n\nUnsubscribe at any time.';
      final result = cleaner.stripFooters(text);
      expect(result, contains('Real offer text.'));
      expect(result.toLowerCase(), isNot(contains('unsubscribe')));
    });

    test('removes "manage preferences" and "view in browser"', () {
      const text = 'Story body.\nManage preferences | View in browser';
      final result = cleaner.stripFooters(text);
      expect(result, contains('Story body.'));
      expect(result.toLowerCase(), isNot(contains('preferences')));
    });

    test('does not touch ordinary words containing "unsubscribe"', () {
      // Guards against an over-eager regex eating real instructions.
      const text = 'Please call to unsubscribe from the reminder service.';
      expect(cleaner.stripFooters(text), isNotEmpty);
    });
  });

  group('truncateForGemma', () {
    test('leaves short text untouched', () {
      const text = 'Short enough.';
      expect(cleaner.truncateForGemma(text), text);
    });

    test('clips long text to the character limit', () {
      final long = List.filled(400, 'word').join(' ');
      final result = cleaner.truncateForGemma(long);
      expect(result.length, lessThanOrEqualTo(kGemmaCharLimit));
    });

    test('clips on a word boundary, never mid-word', () {
      final long = List.filled(400, 'alpha beta gamma').join(' ');
      final result = cleaner.truncateForGemma(long);
      expect(result.endsWith('alpha') || result.endsWith('beta') ||
          result.endsWith('gamma'), isTrue);
      expect(result, isNot(contains('alphabetagamma')));
    });
  });

  group('normalizeWhitespace', () {
    test('collapses runs of blank lines to a single break', () {
      expect(cleaner.normalizeWhitespace('a\n\n\n\n\nb'), 'a\n\nb');
    });

    test('normalizes CRLF line endings', () {
      expect(cleaner.normalizeWhitespace('a\r\nb'), 'a\nb');
    });

    test('collapses runs of spaces and tabs', () {
      expect(cleaner.normalizeWhitespace('a    \t  b'), 'a b');
    });
  });

  group('clean (full pipeline)', () {
    test('prefers text/plain over HTML', () {
      final result = cleaner.clean('Plain version', '<p>HTML version</p>');
      expect(result, contains('Plain version'));
      expect(result, isNot(contains('HTML version')));
    });

    test('falls back to HTML when there is no plain part', () {
      final result = cleaner.clean(null, '<p>HTML only body</p>');
      expect(result, contains('HTML only body'));
    });

    test('treats a blank plain part as absent', () {
      final result = cleaner.clean('   ', '<p>Fallback body</p>');
      expect(result, contains('Fallback body'));
    });

    test('returns empty string for an empty message', () {
      expect(cleaner.clean(null, null), '');
    });
  });

  group('against the real fixtures', () {
    test('every fixture loads and has a sender, subject and body', () {
      final emails = loadAllFakeEmails();
      expect(emails, hasLength(20));
      for (final email in emails) {
        expect(email.senderAddress, contains('@'), reason: email.name);
        expect(email.subject, isNotEmpty, reason: email.name);
        expect(email.body, isNotEmpty, reason: email.name);
      }
    });

    test('fixture 07 strips its quoted history', () {
      final email = loadFakeEmail('07_long_thread');
      expect(email.body, contains('On Tue, 29 Sep 2026, Sam wrote:'));
      final cleaned = cleaner.clean(email.body, null);
      expect(cleaned, contains('I will take the second half'));
      expect(cleaned, isNot(contains('Section two still has')));
    });

    test('fixture 08 (HTML-only newsletter) yields readable plain text', () {
      final email = loadFakeEmail('08_html_heavy');
      final cleaned = cleaner.clean(null, email.body);
      expect(cleaned, contains('Markets close higher'));
      expect(cleaned, isNot(contains('<p>')), reason: 'tags must be stripped');
      expect(cleaned.toLowerCase(), isNot(contains('manage preferences')));
    });

    test('fixture 04 loses its unsubscribe footer', () {
      final email = loadFakeEmail('04_newsletter_promo');
      final cleaned = cleaner.clean(email.body, null);
      expect(cleaned.toLowerCase(), isNot(contains('unsubscribe')));
    });

    test('fixture dates parse correctly', () {
      final email = loadFakeEmail('01_college_form_deadline');
      final date = parseFixtureDate(email.header('date')!);
      expect(date, DateTime.utc(2026, 10, 1, 10, 0, 0));
    });
  });
}