/// Loads the synthetic email fixtures from `test/fixtures/fake_emails/`.
///
/// The fixture format is the plain-text shape documented in rules.md §8:
///
/// ```text
/// From: sender@example.com
/// To: friend@gmail.com
/// Subject: URGENT: Enrollment Form Due Oct 10
/// Date: Thu, 01 Oct 2026 10:00:00 +0530
///
/// [body]
/// ```
///
/// These contain no real email content (prd.md §8), which is what makes them
/// safe to commit and to feed to Gemma during Spike A.
library;

import 'dart:io';

/// One parsed fixture: a case-insensitive header map plus the raw body.
class FakeEmail {
  FakeEmail({required this.name, required this.headers, required this.body});

  /// File name without the `.txt` extension, e.g. `01_college_form_deadline`.
  final String name;

  final Map<String, String> headers;
  final String body;

  String get senderAddress => _header('from');
  String get subject => _header('subject');
  String get senderName => senderAddress;

  bool hasHeader(String key) => headers.containsKey(_key(key));

  String? header(String key) => headers[_key(key)];

  List<String> get toAddresses => _addresses(_header('to'));

  List<String> get ccAddresses => _addresses(_header('cc'));

  String _header(String key) => headers[_key(key)]?.trim() ?? '';

  static String _key(String raw) => raw.toLowerCase().trim();
}

String _key(String raw) => raw.toLowerCase().trim();

List<String> _addresses(String raw) => raw
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// Parses a single fixture body.
FakeEmail parseFakeEmail(String name, String source) {
  final lines = source.split('\n');
  final headers = <String, String>{};
  var index = 0;

  // Headers run until the first blank line.
  for (; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim().isEmpty) {
      index++;
      break;
    }
    final separator = line.indexOf(':');
    if (separator == -1) continue;
    final key = _key(line.substring(0, separator));
    final value = line.substring(separator + 1).trim();
    // Repeated headers (To:, Cc:) accumulate rather than overwrite.
    headers[key] = headers.containsKey(key) ? '${headers[key]}, $value' : value;
  }

  return FakeEmail(
    name: name,
    headers: headers,
    body: lines.skip(index).join('\n').trim(),
  );
}

/// Reads every fixture in the directory, sorted by file name.
List<FakeEmail> loadAllFakeEmails() {
  final dir = Directory('test${Platform.pathSeparator}fixtures'
      '${Platform.pathSeparator}fake_emails');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    throw StateError('No fixtures found in ${dir.path}');
  }

  return files
      .map((f) => parseFakeEmail(
            f.uri.pathSegments.last.replaceAll('.txt', ''),
            f.readAsStringSync(),
          ))
      .toList();
}

/// Looks up one fixture by its name without the extension.
FakeEmail loadFakeEmail(String name) {
  final all = loadAllFakeEmails();
  return all.firstWhere(
    (e) => e.name == name,
    orElse: () => throw StateError('No fixture named "$name"'),
  );
}

/// Parses the `Date:` header of a fixture.
///
/// Fixtures use RFC 5322 dates such as `Thu, 01 Oct 2026 10:00:00 +0530`.
/// `DateTime.parse` does not accept that shape, so the fields are pulled out
/// directly — no locale data and no timezone database needed for tests.
///
/// Returns a **local** [DateTime], because the rules engine builds deadlines in
/// local time ("by Friday" means the reader's Friday). Keeping both sides local
/// also makes the tests independent of the machine's timezone.
DateTime? parseFixtureDate(String raw) {
  final match = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(raw.trim());
  if (match == null) return null;

  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  final month = months[match.group(2)!.toLowerCase()];
  if (month == null) return null;

  return DateTime(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6) ?? '0'),
  );
}