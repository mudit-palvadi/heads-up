/// "Last checked 4 min ago" — the status screen's first line.
///
/// Specification: prd.md §6.2.
///
/// Split into its own tiny, pure module because it is user-facing copy on the
/// one screen the friend is most likely to read, and because a relative-time
/// helper that silently returns "just now" forever is easy to get wrong.
library;

/// Formats how long ago [then] was, relative to [now].
///
/// Deliberately coarse: prd.md §7 asks for short, plain language, so this says
/// "4 min ago" rather than "4 minutes and 12 seconds ago". Past times read
/// naturally; a future [then] (clock skew, a slow save) degrades to "just now"
/// rather than "in -2 min", which would be nonsense to a reader.
String formatLastChecked(DateTime? then, {DateTime? now}) {
  if (then == null) return 'Not checked yet';

  final reference = now ?? DateTime.now();
  final elapsed = reference.difference(then);

  if (elapsed.isNegative || elapsed.inSeconds < 45) return 'Just now';
  if (elapsed.inMinutes < 60) {
    final minutes = elapsed.inMinutes;
    return '$minutes min ago';
  }
  if (elapsed.inHours < 24) {
    final hours = elapsed.inHours;
    return hours == 1 ? '1 hour ago' : '$hours hours ago';
  }
  final days = elapsed.inDays;
  return days == 1 ? '1 day ago' : '$days days ago';
}

/// "3 things need you today" — the header shown on both the widget and here.
String formatItemCountHeader(int count) {
  if (count <= 0) return 'Nothing needs you today';
  if (count == 1) return '1 thing needs you today';
  return '$count things need you today';
}

/// The status screen's model line (prd.md §6.2).
enum ModelLabel { ready, downloading, notDownloaded, unknown }

String formatModelLabel(ModelLabel label, {double? progress}) {
  switch (label) {
    case ModelLabel.ready:
      return 'Gemma ready';
    case ModelLabel.downloading:
      final percent = progress == null
          ? 0
          : (progress * 100).round().clamp(0, 100);
      return 'Downloading… $percent%';
    case ModelLabel.notDownloaded:
      return 'Model not downloaded';
    case ModelLabel.unknown:
      return 'Model status unknown';
  }
}