/// Tests for the user-facing status copy.
///
/// These strings are read more often than anything else in the app, by someone
/// for whom plain language is the whole point (prd.md §7). They are also the
/// easiest place to ship something embarrassing — "Not checked yet" rendering
/// as "checked -1 min ago" — so they are pinned here rather than left to a
/// widget test that would need a pump.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/ui/relative_time.dart';

void main() {
  final now = DateTime(2026, 10, 4, 12, 0);

  group('formatLastChecked', () {
    test('says so plainly when nothing has run yet', () {
      expect(formatLastChecked(null, now: now), 'Not checked yet');
    });

    test('reads exactly as prd.md §6.2 specifies', () {
      // The doc's own example.
      expect(
        formatLastChecked(now.subtract(const Duration(minutes: 4)), now: now),
        '4 min ago',
      );
    });

    test('treats anything under 45 seconds as "Just now"', () {
      expect(
        formatLastChecked(now.subtract(const Duration(seconds: 10)), now: now),
        'Just now',
      );
    });

    test('switches to hours after an hour', () {
      expect(
        formatLastChecked(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      expect(
        formatLastChecked(now.subtract(const Duration(hours: 5)), now: now),
        '5 hours ago',
      );
    });

    test('switches to days after a day', () {
      expect(
        formatLastChecked(now.subtract(const Duration(days: 1)), now: now),
        '1 day ago',
      );
      expect(
        formatLastChecked(now.subtract(const Duration(days: 4)), now: now),
        '4 days ago',
      );
    });

    test('never emits a negative duration if the clock skews', () {
      // A saved timestamp in the future must not render as "in -3 min ago".
      expect(
        formatLastChecked(now.add(const Duration(minutes: 5)), now: now),
        'Just now',
      );
    });

    test('never leaks a raw timestamp to the reader', () {
      final output = formatLastChecked(
        DateTime(2026, 10, 1, 8, 30),
        now: now,
      );
      expect(output, isNot(contains('2026')));
      expect(output, isNot(contains(':')));
    });
  });

  group('formatItemCountHeader', () {
    test('matches the widget header in prd.md §3.1', () {
      expect(formatItemCountHeader(3), '3 things need you today');
      expect(formatItemCountHeader(2), '2 things need you today');
    });

    test('uses the singular for one item', () {
      expect(formatItemCountHeader(1), '1 thing needs you today');
    });

    test('never says "1 things"', () {
      for (var count = 0; count <= 5; count++) {
        expect(formatItemCountHeader(count), isNot(contains('1 things')));
      }
    });

    test('zero reads calmly rather than showing an error', () {
      expect(formatItemCountHeader(0), 'Nothing needs you today');
    });
  });

  group('formatModelLabel', () {
    test('uses the wording from prd.md §6.2', () {
      expect(formatModelLabel(ModelLabel.ready), 'Gemma ready');
      expect(formatModelLabel(ModelLabel.notDownloaded),
          'Model not downloaded');
    });

    test('shows a whole-number percentage while downloading', () {
      expect(formatModelLabel(ModelLabel.downloading, progress: 0.47),
          'Downloading… 47%');
      expect(formatModelLabel(ModelLabel.downloading, progress: 0.0),
          'Downloading… 0%');
      expect(formatModelLabel(ModelLabel.downloading, progress: 1.0),
          'Downloading… 100%');
    });

    test('clamps a nonsense progress value rather than showing it', () {
      expect(formatModelLabel(ModelLabel.downloading, progress: 1.4),
          'Downloading… 100%');
      expect(formatModelLabel(ModelLabel.downloading, progress: -0.2),
          'Downloading… 0%');
    });

    test('a missing progress value does not crash', () {
      expect(formatModelLabel(ModelLabel.downloading), 'Downloading… 0%');
    });
  });
}