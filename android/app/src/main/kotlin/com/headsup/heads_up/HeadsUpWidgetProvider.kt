package com.headsup.heads_up

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Renders the Heads Up home screen widget.
 *
 * Specification: prd.md §3, architecture.md §7.1.
 *
 * Three deviations from the architecture doc, all forced or deliberate:
 *
 * 1. **`onUpdate` takes a fourth argument.** architecture.md §7.1 shows the
 *    three-argument `AppWidgetProvider.onUpdate`; in home_widget 0.10.0
 *    `HomeWidgetProvider` declares an *abstract* four-argument overload taking
 *    `SharedPreferences`, which is what `HomeWidgetPlugin.getData()` returns.
 *    The three-argument form is implemented by the base class and delegates here.
 * 2. **View IDs are constants**, not `resources.getIdentifier(...)` lookups as
 *    in §7.1. The IDs are static and known at compile time, so reflective lookup
 *    would only cost compile-time safety.
 * 3. **The play button is always wired.** §7.1 only attached the broadcast when
 *    an audio path existed; here the intent always carries both the path and the
 *    speech text, and Dart decides which to use at tap time. That keeps the
 *    widget honest when ElevenLabs has not run yet — the row still speaks, via
 *    flutter_tts. (`getBroadcast` returns a `PendingIntent`, not an `Intent`.)
 *
 * Reads data written by `lib/services/widget_sync.dart`; the shared key names
 * are asserted by `test/kotlin_contract_test.dart`.
 */
class HeadsUpWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { id ->
            appWidgetManager.updateAppWidget(id, buildViews(context, widgetData))
        }
    }

    private fun buildViews(
        context: Context,
        data: SharedPreferences,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_layout)
        val count = data.getInt(KEY_ITEM_COUNT, 0)
                .coerceIn(0, MAX_ITEMS)

        if (count == 0) {
            // prd.md §3.2: calm and centred, no header and no footer.
            views.setViewVisibility(R.id.empty_state, View.VISIBLE)
            views.setViewVisibility(R.id.header_text, View.GONE)
            views.setViewVisibility(R.id.items_container, View.GONE)
            views.setViewVisibility(R.id.footer_text, View.GONE)
            return views
        }

        views.setViewVisibility(R.id.empty_state, View.GONE)
        views.setViewVisibility(R.id.items_container, View.VISIBLE)
        views.setViewVisibility(R.id.footer_text, View.VISIBLE)
        views.setViewVisibility(R.id.header_text, View.VISIBLE)
        views.setTextViewText(
            R.id.header_text,
            context.resources.getQuantityString(
                R.plurals.widget_header, count, count
            )
        )

        for (index in 0 until MAX_ITEMS) {
            val rowId = ROW_IDS[index]
            val textId = TEXT_IDS[index]
            val playId = PLAY_IDS[index]

            if (index >= count) {
                views.setViewVisibility(rowId, View.GONE)
                continue
            }

            // Shared prefix, asserted against Dart by
            // test/kotlin_contract_test.dart. Getting this wrong (e.g. using
            // `index.toString()` alone) yields keys like "0_what" while Dart
            // writes "item0_what" — the widget then renders the header and rows
            // correctly but every text field silently blank, because
            // item_count is a full key and still resolves.
            val rowKey = ROW_KEY_PREFIX + index
            val what = data.getString(rowKey + SUFFIX_WHAT, "").orEmpty()
            val doIt = data.getString(rowKey + SUFFIX_DO, "").orEmpty()
            val by = data.getString(rowKey + SUFFIX_BY, "").orEmpty()
            val audio = data.getString(rowKey + SUFFIX_AUDIO, "").orEmpty()
            val speech = data.getString(rowKey + SUFFIX_SPEECH, "").orEmpty()
            val urgent = data.getBoolean(rowKey + SUFFIX_URGENT, false)

            views.setViewVisibility(rowId, View.VISIBLE)

            // Line 1 is WHAT, line 2 is DO plus the plain-language deadline.
            // Left-aligned, never justified (prd.md §7).
            views.setTextViewText(
                textId,
                if (by.isBlank()) "$what\n$doIt" else "$what\n$doIt  •  by $by"
            )

            // prd.md §3.3: today's deadlines get the urgent accent.
            if (urgent) {
                views.setInt(textId, "setTextColor", URGENT_COLOR)
                views.setInt(playId, "setColorFilter", URGENT_COLOR)
            } else {
                views.setInt(textId, "setTextColor", TEXT_PRIMARY_COLOR)
                views.setInt(playId, "setColorFilter", ACCENT_COLOR)
            }

            views.setOnClickPendingIntent(playId, playIntent(context, index, audio, speech))
        }

        return views
    }

    /**
     * Builds the tap intent. Always carries both fields so Dart can prefer a
     * pre-generated mp3 and fall back to on-device TTS.
     */
    private fun playIntent(
        context: Context,
        index: Int,
        audioPath: String,
        speechText: String,
    ): PendingIntent = HomeWidgetBackgroundIntent.getBroadcast(
        context,
        Uri.parse("headsup://play?idx=$index" +
            "&path=${Uri.encode(audioPath)}" +
            "&text=${Uri.encode(speechText)}")
    )

    companion object {
        /** prd.md §3.1: the widget never shows more than three items. */
        private const val MAX_ITEMS = 3

        const val KEY_ITEM_COUNT = "item_count"

        // Must equal WidgetSync.rowKeyPrefix in Dart. See test/kotlin_contract_test.dart.
        private const val ROW_KEY_PREFIX = "item"

        // Suffixes appended to the row index: "item0_what", "item0_do", ...
        // These must stay in step with WidgetSync in
        // lib/services/widget_sync.dart.
        private const val SUFFIX_WHAT = "_what"
        private const val SUFFIX_DO = "_do"
        private const val SUFFIX_BY = "_by"
        private const val SUFFIX_SPEECH = "_speech"
        private const val SUFFIX_AUDIO = "_audio"
        private const val SUFFIX_URGENT = "_urgent"

        private val ROW_IDS = intArrayOf(R.id.item0_row, R.id.item1_row, R.id.item2_row)
        private val TEXT_IDS = intArrayOf(R.id.item0_text, R.id.item1_text, R.id.item2_text)
        private val PLAY_IDS = intArrayOf(R.id.item0_play, R.id.item1_play, R.id.item2_play)

        private const val TEXT_PRIMARY_COLOR = 0xFFFFFFFF.toInt()
        private const val ACCENT_COLOR = 0xFFFFAB40.toInt()
        private const val URGENT_COLOR = 0xFFFF6B35.toInt()
    }
}