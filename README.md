# Heads Up

Built for a friend who is dyslexic, rarely opens his email, and misses the
things that matter. **Heads Up** puts the three things that need him today on
his Android home screen, in short plain lines, each with a ▶ button so he can
listen instead of read.

The widget is the product. The app is just setup and a control panel.

---

## What it does

- Reads new mail **read-only** over IMAP (`EXAMINE` + `BODY.PEEK[]` — it never
  sets `\Seen`, never sends, never deletes) and never marks anything read in Gmail.
- Decides what matters with a **deterministic rules engine** — VIP senders and
  domains, action words, regex-extracted deadlines, and penalties for
  newsletters and bulk mail. No AI is involved in judging importance.
- Rewrites each flagged email into `WHAT / DO / BY` with **Gemma 3 1B-IT running
  on the phone** via LiteRT-LM.
- Speaks that summary with **ElevenLabs**, saving an mp3 on the device so the
  ▶ button is instant and offline; falls back to `flutter_tts` when there is no
  file.
- Shows at most **three** items on the home screen widget, or a calm
  `Nothing needs you today ✓` when there is nothing.

Deadlines are the one thing Gemma is never allowed to decide. The rules engine
extracts them by regex and hands the value to the prompt; if Gemma's `BY:` does
not match, the output is rejected and a fallback is used.

---

## Setup

1. Install the APK.
2. Create an app password at <https://myaccount.google.com/apppasswords>
   (label it `Heads Up`). This requires 2-Step Verification to be on.
3. Open the app and enter your email address and that 16-character app password.
4. Add the people and domains that matter to you on the **VIP Rules** screen.
5. Tap **Refresh now**.

The Gemma model (~529 MB) downloads once, on first run, from Hugging Face.

---

## Privacy

Your full emails never leave this phone. Only short summaries (~30 words) are
sent to ElevenLabs for voice generation when cloud voice is on. You can turn
cloud voice off at any time in Settings, in which case nothing is sent anywhere
and the phone's own text-to-speech is used instead.

IMAP app passwords, the ElevenLabs key and the Hugging Face token are stored in
`flutter_secure_storage`, backed by the Android KeyStore. Nothing secret is
committed to this repository — see `.gitignore`.

To revoke access at any time: **Google Account → Security → App Passwords →
delete "Heads Up"**. That immediately breaks the app's ability to read mail.

---

## Limitations

Stated plainly rather than buried:

- **Background sync is best-effort.** Android's Doze mode can delay the hourly
  job, and Gemma does not run in the background at all — it is too heavy and the
  process gets killed. Opening the app or tapping **Refresh now** runs the full
  pipeline. Disclose this honestly: a fresh install shows the empty state until
  the app is opened once.
- **Gemma 3 1B is a small model.** It occasionally mis-structures its output.
  Every response is validated against a strict `WHAT/DO/BY` shape and a
  deadline-match check; failures fall back to a template.
- **ElevenLabs is a cloud service**, not open source. Only the short summary
  text goes to it, never the email.
- The widget is Android-only, and the build targets `arm64-v8a` (Android 12+).

---

## App size

Measured on this build, not estimated:

| Build | Size |
|---|---|
| `flutter build apk --debug` (all ABIs) | 281.1 MB |
| `flutter build apk --release --target-platform android-arm64` | **124.6 MB** |

Two findings drove that 56% reduction:

1. **`abiFilters` does not filter the Flutter engine.** The engine's `.so`
   files are injected from the extracted engine artifact and bypass the Gradle
   filter, so a naive build ships `libflutter.so` for x86_64 and armeabi-v7a as
   well — 67 MB that can never run on the device. `--target-platform
   android-arm64` is what actually fixes it.
2. **Debug builds ship Dart as `kernel_blob.bin` (69 MB)** rather than an AOT
   snapshot.

`./tool/build_apk.ps1` applies both flags and prints a per-library breakdown, so
neither mistake gets repeated.

### What is deliberately *not* done

- **R8 / minification is off.** `flutter_secure_storage` 11.2.0 depends on Tink
  and ships no consumer ProGuard rules, so minifying risks silently breaking
  storage of the IMAP app password. R8 would only shrink the ~27 MB of dex
  anyway — not the ~120 MB of native libraries. Breaking the password store to
  save 20 MB is a bad trade.
- **The ~52 MB of Qualcomm Hexagon (`libQnnHtp*`) kernels are kept.** They are
  NPU acceleration used only on Qualcomm chipsets; `flutter_gemma_litertlm` uses
  the CPU backend by default. Excluding them would take the APK to roughly
  73 MB, but it has not been verified on hardware, and the app is handed to one
  person whose phone it must not fail on. Revisit once the target SoC is known.

### Build-time network dependency

`flutter_gemma` installs a native-assets build hook that downloads LiteRT-LM
binaries from GitHub releases — including **host** binaries
(`litertlm-windows_x86_64.tar.gz`) when running unit tests on Windows. Every
`flutter test`, `flutter build` and `flutter run` therefore needs GitHub to be
reachable. On a cold machine this is the slowest step in the whole build.

---

## Development

```bash
flutter pub get
flutter analyze          # must be clean
flutter test             # unit tests (no device needed)
./tool/build_apk.ps1     # release APK, arm64 only
```

Strict analysis is on by default in `analysis_options.yaml` (`strict-casts`,
`strict-inference`, `strict-raw-types`, plus correctness lints such as
`unawaited_futures` and `use_build_context_synchronously`). Two opinionated
lints are intentionally left off — `sort_constructors_first` (it would split
`toMap` from `fromMap`) and `public_member_api_docs` (per-field doc comments
cost more than they clarify at this size; each public type instead names the
spec section it implements).

### Docs

The specs are the source of truth, in this order:

| File | Defines |
|---|---|
| `prd.md` | Who it is for, what it must and must not do, privacy constraints |
| `architecture.md` | Pipeline, service contracts, Android widget layer |
| `rules.md` | The deterministic rules engine and deadline extraction |
| `phases.md` | Build plan, decision gates, cut list, config deviations |

---

## Built with

- **Gemma 3 1B-IT** — on-device, open-weight; rewrites every flagged email
- **ElevenLabs** — voice synthesis for the summaries and the demo narration
- Flutter, `enough_mail`, `home_widget`, `just_audio`, `flutter_tts`, Tink-backed
  `flutter_secure_storage`
- Built with OpenCode, an open-source coding agent

## Post-deadline commits

_None yet. Any commit made after Mon Oct 5, 12:29 PM IST gets listed here._