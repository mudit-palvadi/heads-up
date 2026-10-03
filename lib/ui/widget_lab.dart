/// Temporary on-device harness for the home screen widget.
///
/// The widget is the actual product (prd.md §2), but it can only be verified on
/// a real device — and at this point in the build there is no mail pipeline to
/// feed it. So this screen pushes fixed, entirely fabricated items straight to
/// `WidgetSync`, which lets the layout, the two states (rows vs empty) and the
/// ▶ tap all be checked before the pipeline exists.
///
/// **No real email content may ever appear here** (prd.md §8). Every string
/// below is invented, and the ▶ audio points at a generated tone asset, not at
/// anything the friend has received.
///
/// Replaced by status_screen.dart once the pipeline lands.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:heads_up/models/mail_item.dart';
import 'package:heads_up/services/test_tone.dart';
import 'package:heads_up/services/widget_sync.dart';
import 'package:heads_up/ui/theme.dart';
import 'package:path_provider/path_provider.dart';

/// Path to the generated test tone, filled in by [resolveTonePath].
String _tonePath = '';

/// Locates the test tone so the ▶ button has a real file to play.
///
/// The tone is generated into the app's documents directory rather than bundled
/// as an asset, because `just_audio` needs a filesystem path at playback time
/// and an asset path is not one.
Future<String> resolveTonePath() async {
  if (_tonePath.isNotEmpty) return _tonePath;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = await writeTestTone(dir);
    _tonePath = file.path;
  } catch (_) {
    _tonePath = '';
  }
  return _tonePath;
}

class WidgetLab extends StatefulWidget {
  const WidgetLab({super.key});

  @override
  State<WidgetLab> createState() => _WidgetLabState();
}

class _WidgetLabState extends State<WidgetLab> {
  static const _sync = WidgetSync();

  @override
  void initState() {
    super.initState();
    unawaited(
      resolveTonePath().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Widget lab')),
      body: ListView(
        padding: const EdgeInsets.all(HeadsUpSpacing.gutter),
        children: [
          Text(
            'Temporary harness. Pushes invented data to the home screen widget '
            'so it can be checked without a mail pipeline.',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: HeadsUpSpacing.rowGap),
          FilledButton(onPressed: _pushThree, child: const Text('Push 3 items')),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _pushOneUrgent,
            child: const Text('Push 1 urgent item'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _sync.sync(const []),
            child: const Text('Push empty state'),
          ),
          const Divider(height: HeadsUpSpacing.gutter * 2),
          Text('▶ audio source', style: theme.textTheme.labelSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _pushThree,
                  child: const Text('With tone file'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  // No audio path: the widget must fall back to flutter_tts.
                  onPressed: _pushTtsOnly,
                  child: const Text('TTS fallback'),
                ),
              ),
            ],
          ),
          const SizedBox(height: HeadsUpSpacing.rowGap),
          Text(
            _tonePath.isEmpty
                ? 'Tone asset not found — audio tests will use TTS only.'
                : 'Tone: $_tonePath',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  /// Fabricated content only (prd.md §8).
  ///
  /// `deadline` is today, so every row renders in the urgent accent
  /// (prd.md §3.3) — that is intentional for a visual check.
  MailItem _labItem(
    String id,
    String what,
    String doIt, {
    String? by,
    String? audio,
  }) {
    final now = DateTime.now();
    return MailItem(
      id: id,
      receivedAt: now,
      senderName: 'Example',
      senderAddress: 'example@example.com',
      subject: 'synthetic',
      score: 100,
      reasons: const ['lab'],
      deadline: DateTime(now.year, now.month, now.day),
      isVip: false,
      processedAt: now,
      what: what,
      doIt: doIt,
      by: by,
      speechText: '$what. $doIt${by != null ? ' By $by' : ''}',
      audioPath: (audio?.isEmpty ?? true) ? null : audio,
      audioSource: (audio?.isEmpty ?? true)
          ? AudioSource.offlineTts
          : AudioSource.elevenlabs,
    );
  }

  List<MailItem> _threeItems({String? audio}) => [
        _labItem('lab1', 'Form is due', 'Upload your ID proof',
            by: 'today', audio: audio),
        _labItem('lab2', 'Room booking needs an answer', 'Say yes or no to Rahul',
            audio: audio),
        _labItem('lab3', 'Fee payment', 'Pay on the portal',
            by: 'tomorrow', audio: audio),
      ];

  /// Push the three rows, pointing ▶ at the generated tone file.
  Future<void> _pushThree() => _sync.sync(_threeItems(audio: _tonePath));

  /// Push the same rows with no audio path, so ▶ must fall back to flutter_tts.
  Future<void> _pushTtsOnly() => _sync.sync(_threeItems());

  Future<void> _pushOneUrgent() => _sync.sync([
        _labItem('lab1', 'Interview is tomorrow', 'Bring two printed copies',
            audio: _tonePath),
      ]);
}