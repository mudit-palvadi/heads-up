/// Turns a raw email into short, plain text that a 1B model can read.
///
/// Specification: architecture.md §6.2.
///
/// Every function here takes and returns a `String` rather than a
/// `MimeMessage`. That is deliberate: the stripping rules are the fiddly part
/// of the pipeline and they must be unit-testable without an IMAP connection
/// (rules.md §1). [Cleaner.clean] is the thin adapter that pulls the body off a
/// real message first.
///
/// Order matters and matches architecture.md §6.2:
/// extract text -> strip quoted replies -> strip signature -> strip footers.
library;

import 'package:html/parser.dart' as html_parser;

/// Roughly 300 words. Well inside Gemma 3 1B's context, and short enough that a
/// rambling newsletter cannot push the real request out of the prompt.
const int kGemmaCharLimit = 1500;

class Cleaner {
  const Cleaner();

  /// Entry point for a fetched message. Prefers `text/plain` and falls back to
  /// converting `text/html` (architecture.md §6.2 `_extractText`).
  String clean(String? plainText, String? htmlText) {
    final plain = plainText?.trim() ?? '';
    var text = plain.isNotEmpty ? plain : htmlToText(htmlText ?? '');
    text = stripQuotedReplies(text);
    text = stripSignature(text);
    text = stripFooters(text);
    return normalizeWhitespace(text);
  }

  /// Converts an HTML body to readable plain text.
  ///
  /// `Document.body.text` alone concatenates block elements with no separator,
  /// which turns `<h1>Brief</h1><p>Text</p>` into `BriefText` — one run-on line
  /// that hurts both deadline regexes and Gemma. Block boundaries are converted
  /// to newlines first so paragraphs stay separable.
  String htmlToText(String source) {
    if (source.trim().isEmpty) return '';

    final prepared = source
        // Drop non-content elements entirely, contents included.
        .replaceAll(
          RegExp(r'<(script|style|head)\b[^>]*>.*?</\1>',
              caseSensitive: false, dotAll: true),
          '',
        )
        // Block-level boundaries become line breaks.
        .replaceAll(
          RegExp(
            r'</?(?:br|p|div|li|tr|h[1-6]|table|ul|ol|blockquote|pre)\b[^>]*>',
            caseSensitive: false,
          ),
          '\n',
        )
        // Remaining tags carry no text meaning.
        .replaceAll(RegExp(r'<[^>]+>'), '');

    // The html package resolves entities (&amp; &nbsp; &#39; ...) for us.
    final body = html_parser.parse(prepared).body?.text ?? prepared;
    return body;
  }

  /// Removes the quoted history — the part that inflates a thread from two
  /// sentences to four pages.
  ///
  /// Covers the `On <date>, <name> wrote:` form (RFC 3676 §2.1, matched in
  /// architecture.md §6.2) plus the Outlook/Gmail `Original Message` banner.
  String stripQuotedReplies(String text) {
    return text
        // Outlook / AppleMail: "-----Original Message-----" onwards.
        .replaceAll(
          RegExp(r'\n\s*-{2,}\s*Original Message\s*-{2,}.*',
              caseSensitive: false, dotAll: true),
          '',
        )
        // RFC 3676: "On <date>, <person> wrote:" onwards.
        .replaceAll(
          RegExp(
            r'\n\s*(?:On|El|Am)\s.{5,120}?\s(?:wrote|writes)\s*:.*',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        // Bare attribution line, e.g. "-----Original Message-----"
        .replaceAll(
          RegExp(r'\n\s*From:\s*.+', caseSensitive: false, dotAll: true),
          '',
        );
  }

  /// Removes the signature block, anchored on the RFC 3676 `-- ` delimiter.
  String stripSignature(String text) {
    final match = RegExp(
      r'\n\s*--\s?',
      multiLine: true,
    ).firstMatch(text);
    if (match == null) return text;
    return text.substring(0, match.start);
  }

  /// Removes unsubscribe / preference boilerplate that carries no instructions
  /// for the reader.
  String stripFooters(String text) {
    return text
        .replaceAll(
          RegExp(
            r'(?:unsubscribe|manage preferences|view in browser|'
            r'you(?: are receiving|’re receiving) this|'
            r'to stop receiving|update your preferences|'
            r'no longer wish to receive).{0,200}',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        .trim();
  }

  /// Collapses runs of blank lines and trailing whitespace.
  String normalizeWhitespace(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// Clips to [kGemmaCharLimit] on a word boundary (architecture.md §6.2).
  ///
  /// Cutting mid-word reads as gibberish to the model, so the clip backs up to
  /// the last space.
  String truncateForGemma(String cleaned) {
    if (cleaned.length <= kGemmaCharLimit) return cleaned;
    final slice = cleaned.substring(0, kGemmaCharLimit);
    final lastSpace = slice.lastIndexOf(' ');
    final safeEnd = lastSpace > kGemmaCharLimit ~/ 2 ? lastSpace : kGemmaCharLimit;
    return slice.substring(0, safeEnd).trimRight();
  }
}