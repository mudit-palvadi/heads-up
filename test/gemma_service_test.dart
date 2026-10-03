/// Tests for [GemmaService] output handling.
///
/// These cover the safety rule the whole product rests on: **Gemma rewrites,
/// but it never decides a deadline.** rules.md §1 and architecture.md §6.3.
///
/// The model itself needs a 529 MB download and a real device, so what is tested
/// here is everything *around* it — the prompt, the parser and the validator —
/// which is precisely where an invented date would slip through.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/gemma_service.dart';

const _gemma = GemmaService();

MailItem _item({DateTime? deadline}) => MailItem(
      id: '1_INBOX',
      receivedAt: DateTime(2026, 10, 1),
      senderName: 'Admissions',
      senderAddress: 'admissions@university.edu',
      subject: 'Enrollment form',
      score: 110,
      reasons: const [],
      deadline: deadline,
      isVip: false,
      processedAt: DateTime(2026, 10, 1),
    );

void main() {
  group('prompt', () {
    test('states the rules-engine deadline verbatim', () {
      final prompt = _gemma.buildPrompt('Body text.', 'Admissions', 'Oct 10');
      expect(prompt, contains('Deadline from rules: Oct 10'));
    });

    test('says NONE explicitly when there is no deadline', () {
      // Passing null silently is how a model decides to invent one.
      final prompt = _gemma.buildPrompt('Body text.', 'Admissions', null);
      expect(prompt, contains('Deadline from rules: NONE'));
    });

    test('includes the email body and the sender', () {
      final prompt = _gemma.buildPrompt('Upload your ID.', 'Admissions', null);
      expect(prompt, contains('Upload your ID.'));
      expect(prompt, contains('Sender: Admissions'));
    });

    test('forbids guessing dates in the instructions', () {
      final prompt = _gemma.buildPrompt('Body.', 'A', null);
      expect(prompt.toLowerCase(), contains('do not guess dates'));
    });

    test('truncates an oversized body but keeps the prompt scaffolding', () {
      // The body is clipped to inputCharLimit; the surrounding instructions
      // deliberately survive, so asserting on total prompt length would be
      // wrong — what matters is that the tail of the body is gone.
      final head = 'A' * GemmaService.inputCharLimit;
      final tail = 'B' * 500;
      final prompt = _gemma.buildPrompt(head + tail, 'A', null);

      expect(prompt, contains('WHAT: <what this email is, one short line>'));
      expect(prompt, contains('Deadline from rules: NONE'));
      expect(prompt.contains(tail), isFalse, reason: 'tail must be clipped');
      expect(prompt.contains(head), isTrue);
    });
  });

  group('parsing well-formed output', () {
    test('reads all three fields, preserving the display casing of BY', () {
      final output = _gemma.parseOutput(
        'WHAT: Internship form is due\n'
        'DO: Upload your ID on the portal\n'
        'BY: Oct 10',
        'Oct 10',
      );
      expect(output, isNotNull);
      expect(output!.what, 'Internship form is due');
      expect(output.doIt, 'Upload your ID on the portal');
      // Must render as "Oct 10" on the widget, not a normalised "oct 10".
      expect(output.by, 'Oct 10');
    });

    test('strips a leading "by" and trailing full stop from BY', () {
      final output = _gemma.parseOutput(
        'WHAT: A\nDO: B\nBY: by Oct 10.',
        'Oct 10',
      );
      expect(output!.by, 'Oct 10');
    });

    test('is case-insensitive about the field names', () {
      final output = _gemma.parseOutput(
        'what: Something\ndo: Something else\nby: NONE',
        null,
      );
      expect(output, isNotNull);
      expect(output!.what, 'Something');
    });

    test('treats NONE as no deadline', () {
      final output = _gemma.parseOutput(
        'WHAT: A\nDO: B\nBY: NONE',
        null,
      );
      expect(output!.by, isNull);
    });
  });

  group('rejecting malformed output', () {
    test('rejects a missing DO', () {
      // The dangerous case: the widget would show a WHAT with no action.
      expect(
        _gemma.parseOutput('WHAT: Something\nBY: NONE', null),
        isNull,
      );
    });

    test('rejects a missing BY', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B', null),
        isNull,
      );
    });

    test('rejects empty output', () {
      expect(_gemma.parseOutput('', null), isNull);
    });

    test('rejects an over-long line', () {
      final long = 'y' * 100;
      expect(
        _gemma.parseOutput('WHAT: $long\nDO: B\nBY: NONE', null),
        isNull,
      );
    });
  });

  group('the deadline rule: Gemma may never invent a date', () {
    test('rejects a BY when the rules engine found nothing', () {
      final output = _gemma.parseOutput(
        'WHAT: A\nDO: B\nBY: Friday',
        null,
      );
      expect(output, isNull);
    });

    test('rejects a BY that disagrees with the rules deadline', () {
      // Rules said Oct 10; the model said Friday. That is an invention.
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: Friday', 'Oct 10'),
        isNull,
      );
    });

    test('rejects NONE when the rules engine found a deadline', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: NONE', 'Oct 10'),
        isNull,
      );
    });

    test('accepts the exact deadline the rules engine supplied', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: Oct 10', 'Oct 10'),
        isNotNull,
      );
    });

    test('accepts a differently-worded but identical deadline', () {
      // Same date, different phrasing — not an invention.
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: by Oct 10', 'Oct 10'),
        isNotNull,
      );
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: Oct 10.', 'Oct 10'),
        isNotNull,
      );
    });

    test('accepts the same date written day-first', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: 10 Oct', 'Oct 10'),
        isNotNull,
      );
    });

    test('accepts a weekday when the rules engine supplied a weekday', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: Friday', 'Friday'),
        isNotNull,
      );
    });

    test('rejects a weekday when the rules engine named a date', () {
      expect(
        _gemma.parseOutput('WHAT: A\nDO: B\nBY: Friday', 'Oct 10'),
        isNull,
      );
    });
  });

  group('rejection classification (for the fallback-rate metric)', () {
    test('classifies an invented date', () {
      expect(
        _gemma.classifyRejection('WHAT: A\nDO: B\nBY: Friday', null),
        GemmaRejection.inventedDate,
      );
    });

    test('classifies a malformed shape', () {
      expect(
        _gemma.classifyRejection('nothing useful here', null),
        GemmaRejection.malformedShape,
      );
    });

    test('classifies an over-long line', () {
      final long = 'z' * 100;
      expect(
        _gemma.classifyRejection('WHAT: $long\nDO: B\nBY: NONE', null),
        GemmaRejection.tooLong,
      );
    });

    test('returns null when the output is acceptable', () {
      expect(
        _gemma.classifyRejection('WHAT: A\nDO: B\nBY: NONE', null),
        isNull,
      );
    });
  });

  group('fallback', () {
    test('always produces an actionable pair of lines', () {
      final output = _gemma.fallback(_item());
      expect(output.what, 'Email from Admissions');
      expect(output.doIt, 'Check this message');
    });

    test('carries the rules deadline when there is one', () {
      final output = _gemma.fallback(_item(deadline: DateTime(2026, 10, 10)));
      expect(output.by, isNotNull);
    });

    test('has no deadline when the item has none', () {
      expect(_gemma.fallback(_item()).by, isNull);
    });
  });

  group('speech text (prd.md §4)', () {
    test('is what + do + by, each terminated', () {
      const output = GemmaOutput(
        what: 'Internship form is due',
        doIt: 'Upload your ID',
        by: 'Friday',
      );
      expect(
        GemmaService.buildSpeechText(output),
        'Internship form is due. Upload your ID. By Friday.',
      );
    });

    test('omits the deadline clause when there is none', () {
      const output = GemmaOutput(what: 'A', doIt: 'B');
      expect(GemmaService.buildSpeechText(output), 'A. B.');
    });

    test('does not double the full stop', () {
      const output = GemmaOutput(what: 'Already ended.', doIt: 'Also ended.');
      expect(GemmaService.buildSpeechText(output), 'Already ended. Also ended.');
    });

    test('stays well under the ElevenLabs character limit', () {
      // architecture.md §9: ~40 words / 2500 chars, and the speech text is the
      // only thing that ever leaves the device.
      final output = GemmaOutput(
        what: 'w' * 80,
        doIt: 'd' * 80,
        by: 'Friday',
      );
      expect(GemmaService.buildSpeechText(output).length, lessThan(250));
    });
  });
}