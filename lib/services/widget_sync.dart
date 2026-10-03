/// Pushes the widget's display data into the native layer.
///
/// Specification: architecture.md §1 and §7, prd.md §3.
///
/// The keys written here are read by `HeadsUpWidgetProvider.kt` and must match
/// it exactly. `test/widget_sync_test.dart` pins the key format so the two sides
/// cannot drift apart silently.
///
/// Only fully processed items are ever sent. architecture.md §8 is explicit that
/// the widget shows the last *fully processed* items, so an email that has been
/// fetched and scored but not yet rewritten by Gemma must stay invisible.
library;

import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/ui/theme.dart';
import 'package:home_widget/home_widget.dart';

class WidgetSync {
  const WidgetSync();

  /// Matches `HeadsUpWidgetProvider.MAX_ITEMS`. prd.md §3.1: never more than 3.
  static const int maxItems = HeadsUpSpacing.maxWidgetItems;

  static const String keyItemCount = 'item_count';

  /// `item0_what`, `item0_do`, and so on. Mirrors the SUFFIX_* constants in
  /// HeadsUpWidgetProvider.kt.
  static String keyWhat(int i) => 'item$i$_sWhat';
  static String keyDo(int i) => 'item$i$_sDo';
  static String keyBy(int i) => 'item$i$_sBy';
  static String keySpeech(int i) => 'item$i$_sSpeech';
  static String keyAudio(int i) => 'item$i$_sAudio';
  static String keyUrgent(int i) => 'item$i$_sUrgent';

  static const String _sWhat = '_what';
  static const String _sDo = '_do';
  static const String _sBy = '_by';
  static const String _sSpeech = '_speech';
  static const String _sAudio = '_audio';
  static const String _sUrgent = '_urgent';

  /// Writes the widget data and asks Android to redraw.
  Future<void> sync(List<MailItem> items, {String androidName = 'HeadsUpWidgetProvider'}) async {
    final visible = items
        .where((item) => item.isProcessed)
        .take(maxItems)
        .toList();

    // Clear stale rows so a shrunk list does not leave the old text on screen.
    for (var i = 0; i < maxItems; i++) {
      await HomeWidget.saveWidgetData(keyWhat(i), '');
      await HomeWidget.saveWidgetData(keyDo(i), '');
      await HomeWidget.saveWidgetData(keyBy(i), '');
      await HomeWidget.saveWidgetData(keySpeech(i), '');
      await HomeWidget.saveWidgetData(keyAudio(i), '');
      await HomeWidget.saveWidgetData(keyUrgent(i), false);
    }

    for (var i = 0; i < visible.length; i++) {
      final item = visible[i];
      await HomeWidget.saveWidgetData(keyWhat(i), clampToWordBudget(item.what ?? ''));
      await HomeWidget.saveWidgetData(keyDo(i), clampToWordBudget(item.doIt ?? ''));
      await HomeWidget.saveWidgetData(keyBy(i), item.by ?? '');
      await HomeWidget.saveWidgetData(keySpeech(i), item.speechText ?? '');
      await HomeWidget.saveWidgetData(keyAudio(i), item.audioPath ?? '');
      await HomeWidget.saveWidgetData(keyUrgent(i), item.isUrgent);
    }

    // Count drives which of the two states the widget renders: >0 shows the
    // rows, 0 shows the calm empty state (prd.md §3.1 vs §3.2).
    await HomeWidget.saveWidgetData(keyItemCount, visible.length);
    await HomeWidget.updateWidget(androidName: androidName);
  }
}