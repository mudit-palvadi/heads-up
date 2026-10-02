/// Tests for the design tokens in `prd.md` §7.
///
/// The word-budget clamp is the last line of defence: a 1B model will
/// occasionally overrun the line length it was asked for, and an unreadable
/// block of text on the home screen defeats the whole product.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heads_up/ui/theme.dart';

void main() {
  group('contrast', () {
    // PRD §7 requires >= 4.5:1 for body text. Computed rather than asserted by
    // hand so the check stays honest if a colour is ever tweaked.
    double contrast(Color a, Color b) {
      double channel(double c) => c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

      double luminance(Color c) =>
          0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

      final la = luminance(a);
      final lb = luminance(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    test('primary text clears 4.5:1 on the background', () {
      expect(
        contrast(HeadsUpColors.textPrimary, HeadsUpColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('secondary text clears 4.5:1 on the background', () {
      expect(
        contrast(HeadsUpColors.textSecondary, HeadsUpColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('the urgent accent clears 4.5:1 on the background', () {
      expect(
        contrast(HeadsUpColors.urgent, HeadsUpColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('the calm empty-state colour clears 4.5:1 on the background', () {
      expect(
        contrast(HeadsUpColors.calm, HeadsUpColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('typography', () {
    test('every text style uses the sans-serif family, never serif or italic', () {
      final styles = <TextStyle>[
        HeadsUpText.header,
        HeadsUpText.itemWhat,
        HeadsUpText.itemDoIt,
        HeadsUpText.footer,
        HeadsUpText.emptyState,
      ];
      for (final style in styles) {
        expect(style.fontFamily, HeadsUpText.fontFamily);
        expect(style.fontStyle, FontStyle.normal);
      }
    });

    test('line spacing is at least 1.3x (prd.md §7)', () {
      final styles = <TextStyle>[
        HeadsUpText.header,
        HeadsUpText.itemWhat,
        HeadsUpText.itemDoIt,
        HeadsUpText.footer,
        HeadsUpText.emptyState,
      ];
      for (final style in styles) {
        expect(style.height, greaterThanOrEqualTo(1.3));
      }
    });
  });

  group('clampToWordBudget', () {
    test('leaves text within budget untouched', () {
      const input = 'Upload your ID on the portal';
      expect(clampToWordBudget(input), input);
    });

    test('trims an overlong line to 7 words with an ellipsis', () {
      const input =
          'Please upload your signed declaration and the ID proof document today';
      final result = clampToWordBudget(input);
      expect(result.split(' ').length, lessThanOrEqualTo(8)); // 7 + '...'
      expect(result, endsWith('...'));
    });

    test('honours a custom budget', () {
      expect(clampToWordBudget('one two three four five', maxWords: 3),
          'one two three...');
    });

    test('collapses runs of whitespace', () {
      expect(clampToWordBudget('  hello   world  '), 'hello world');
    });

    test('returns an empty string for empty input', () {
      expect(clampToWordBudget(''), '');
      expect(clampToWordBudget('   '), '');
    });
  });

  test('the widget never renders more than three items (prd.md §3.1)', () {
    expect(HeadsUpSpacing.maxWidgetItems, 3);
  });
}