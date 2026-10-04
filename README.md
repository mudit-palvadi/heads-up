# Heads Up

MIT licensed — see [`LICENSE`](LICENSE). That covers this source code only; the
Gemma weights are downloaded at runtime under Google's Gemma Terms of Use.

**The three things that need you today, on your home screen.**

Built for a friend who is dyslexic, rarely opens his email, and misses the
things that matter. Heads Up puts at most three flagged emails on his Android
home screen as short plain lines, each with a ▶ button so he can listen instead
of read.

The widget is the product. The app is only setup and a control panel.

---

## Status — what is actually verified

This is the honest picture, because "it works" is not a useful claim.

| Area | State | Evidence |
|---|---|---|
| Rules engine + cleaner | **Verified** | 20 hand-written fixtures; every pass/fail row in `rules.md` §8 asserted. Pure logic, no device needed. |
| On-device inference | **Verified on hardware** | Gemma 3 1B-IT via LiteRT-LM on a realme RMX3853 (Android 16). Output passed the `WHAT/DO/BY` validator. Measurements below. |
| Widget ▶ button → audio | **Verified on hardware** | Two paths proven: ElevenLabs mp3 → `AudioTrack`, and the `flutter_tts` fallback. Audio focus stayed on the launcher. |
| Widget row/key contract | **Verified** | A test greps the Kotlin provider and the Dart writer and asserts the keys and the 3-row cap agree. |
| Read-only IMAP | **Unit-tested, not yet run against a live inbox** | Three-layer guard + a self-grepping test. The staged live proof is built into the Setup screen but has not been executed. |
| ElevenLabs voice | **Unit-tested, not yet run live** | Request shape and payload size are asserted; no real key has been called from the device. |
| Full pipeline end-to-end | **Unit-tested with fakes only** | `Pipeline.runFull` has never completed against real mail. |

The widget has been shown working with fabricated data. It has **not** yet been
shown pulling a real deadline out of a real inbox and saying it out loud.

---

## What it does

- Reads new mail **read-only** over IMAP — `EXAMINE` plus `BODY.PEEK[]`, so it
  never sets `\Seen` and nothing in Gmail ever shows up as read. It cannot send,
  delete, or move mail either.
- Decides what matters with a **deterministic rules engine**: VIP senders and
  domains, action words, regex-extracted deadlines, and penalties for
  newsletters and bulk mail. No AI is involved in judging importance.
- Rewrites each flagged email into `WHAT / DO / BY` with **Gemma 3 1B-IT running
  on the phone** via LiteRT-LM.
- Speaks that summary with **ElevenLabs**, caching an mp3 on the device so ▶ is
  instant and works offline; falls back to the phone's own `flutter_tts` when
  there is no file.
- Shows at most **three** items on the widget, or a calm
  `Nothing needs you today ✓` when there is nothing.

Deadlines are the one thing the model is never allowed to decide. The rules
engine extracts them by regex and hands the value to the prompt; if the model's
`BY:` does not match, the output is **rejected** and a template fallback is used
instead of a guessed date.

---

## Privacy

> Your full emails never leave this phone. Only a short, plain summary is sent
> to ElevenLabs for voice.

Exactly two things ever leave the device:

1. **IMAP traffic** to Gmail's own servers, using an app password you created.
2. **The ~30-word summary text**, and only when cloud voice is on.

Email bodies, subjects, and sender details are stored only in the local SQLite
database. Turn cloud voice off in Settings and nothing is sent anywhere — the
phone's built-in text-to-speech is used instead.

**Where secrets live.** The IMAP app password, the ElevenLabs key and the
Hugging Face token go into `flutter_secure_storage`, which is backed by the
Android KeyStore. The app password field and the clipboard are cleared as soon
as a value is saved. Nothing secret is in this repository; `.gitignore` excludes
the local config and the repository was scanned for token-shaped strings before
its first push.

**How to revoke access, at any time.** Google Account → Security → App
Passwords → delete "Heads Up". That breaks the app's ability to read mail
immediately, without uninstalling anything. Uninstalling also works, but the app
password stays valid in Google's records until you delete it there.

---

## Setup

1. Install the APK (arm64 device, Android 12+).
2. Create an app password at <https://myaccount.google.com/apppasswords>, labelled
   `Heads Up`. This needs 2-Step Verification enabled.
3. Open the app. The **Set up** screen appears automatically on first run —
   enter your email address and the 16-character app password, and add an
   ElevenLabs key if you want the cloud voice.
4. Tap **Test connection** to run the read-only proof (see below).
5. Add the people and domains that matter to you on the **What matters to you**
   screen.
6. Tap **Refresh now**.

The Gemma model (**557 MB**) downloads once, on first run, from Hugging Face.
`architecture.md` estimates 529 MB; 557 MB is what is actually on disk, and the
code uses the measured number.

### The read-only proof

The Setup screen's **Test connection** button runs a staged check rather than
just asserting "connected":

1. Probe `FLAGS` for the mailbox — read-only, cannot mark anything read.
2. Fetch new mail with `BODY.PEEK[]`.
3. Probe `FLAGS` again.
4. **The two probes must be identical.** If they differ, the real inbox has been
   marked read, and the run stops and says so.

This exists because "we only used `EXAMINE`" is a claim, and a claim about
somebody's real inbox deserves a measurement.

---

## How it works

```
IMAP (read-only)
  └─ Cleaner ............ HTML → text, strip quotes and signatures
      └─ RulesEngine ... VIP / keywords / deadlines / bulk penalties  ← decides
          └─ GemmaService .. rewrite to WHAT / DO / BY               ← on device
              └─ VoiceService .. ElevenLabs mp3, cached locally
                  └─ WidgetSync .. 3 rows to the home screen widget
```

Two decisions worth calling out:

**The widget only ever shows fully-processed items.** An item that has not been
through Gemma and Voice does not reach the widget at all. A half-built row is
worse than no row, because a wrong date or a silent button looks like a working
one. This is enforced by `WidgetSync.visibleItems()` and pinned by tests.

**Importance is never inferred.** A 1B model asked "is this important?" produces
confident nonsense on a newsletter. So the rules engine decides, with auditable
regex, and the model only rewrites text that has already been judged worth
showing.

### Measured on the friend's phone

realme RMX3853 · Android 16 (SDK 36) · arm64-v8a · 7.4 GB RAM

| Metric | Value |
|---|---|
| Model | `gemma3-1b-it-int4.litertlm`, 557 MB |
| Engine | LiteRT-LM via `flutter_gemma` 1.11.3 |
| Latency, cold (incl. engine init) | **8,714 ms** |
| Latency, generation only | 2,109 ms |
| — prefill / time-to-first-token | 1,222 ms |
| — decode | 887 ms over 22 chunks (~23.7 chunks/sec) |
| RAM during inference | 774 MB total PSS |

The 8.7 s figure includes one-time LiteRT-LM session setup and is a cold run;
warm runs sit near the 2 s generation figure. Both are quoted because quoting
only the flattering one would be misleading.

Real output from the gate run:

```
WHAT: Enrollment form deadline
DO: Submit your ID proof & declaration
BY: Oct 10
```

`Oct 10` was the deadline the rules engine had already extracted — the guard in
§"Deadlines" above rejected anything else.

---

## Setup, tests and analysis

```bash
flutter pub get
flutter analyze          # clean, with strict-casts/strict-inference/strict-raw-types
flutter test             # 230 tests, no device required
./tool/build_apk.ps1     # release APK, arm64 only, prints a size breakdown
```

Test coverage by area:

| Suite | Tests | Covers |
|---|---|---|
| `rules_engine_test.dart` | 43 | every case in `rules.md` §9 plus the §8 fixture table |
| `gemma_service_test.dart` | 32 | `WHAT/DO/BY` parsing, deadline-match rejection, fallbacks |
| `cleaner_test.dart` | 28 | HTML stripping, quote and signature removal, truncation |
| `kotlin_contract_test.dart` | 18 | Dart↔Kotlin widget key agreement, by reading both files |
| `voice_service_test.dart` | 18 | request shape, payload size cap, quota caching |
| `relative_time_test.dart` | 15 | the status copy, pinned without needing a widget pump |
| `mail_item_test.dart` | 13 | model invariants |
| `widget_sync_test.dart` | 13 | the 3-row cap and the processed-only filter |
| `theme_test.dart` | 12 | contrast ratios against the dyslexia palette |
| `pipeline_test.dart` | 10 | `runFull` / `runLight` orchestration with fakes |
| `read_only_guard_test.dart` | 9 | the read-only guarantee, enforced against `lib/` itself |

`read_only_guard_test.dart` is worth singling out: rather than trusting the
implementation, it **greps the source** for `selectMailbox`, `STORE`, and
`+FLAGS`, and extracts the live value of the fetch constant to assert it really
contains `BODY.PEEK[]`. That test was found to be vacuous by fault injection — an
earlier version passed even with `BODY[]` injected, because a doc comment
mentioning `BODY.PEEK[]` satisfied the assertion. It now reads the constant's
value, and both `SELECT` and `BODY[]` injections are caught.

---

## Spec discrepancies found and how they were resolved

The specs (`prd.md`, `architecture.md`, `rules.md`) contained real errors. Each
was resolved in favour of the reading that keeps the product correct, and each is
noted at the point of use in the code and in `phases.md`.

1. **`architecture.md` §7 does not compile against `enough_mail` 2.1.7.** It
   calls `msg.receivedDate!`; the real accessor is `msg.date` (`DateTime?`). Its
   `headers` is also nullable. Adapted.
2. **`rules.md` §3 contradicts itself.** The prose says "whole-word matching
   where practical"; the code snippet below it uses a bare `contains`, which
   scores "information" and "platform" as hits for the action word "form". The
   prose was followed — false positives cost widget slots, and §1 asks to prefer
   false negatives.
3. **`rules.md` §4.1 Pattern 4 cannot match fixture 12.** It requires a
   `by|before|until|on` preposition, but the fixture says "scheduled for **next
   Monday**" and "for" is not in that list. Pattern 4 now also accepts a bare
   `this|next <weekday>`.
4. **`rules.md` §4.3 contradicts §7.** §4.3 gives a passed deadline `+0` but
   still reports it; §7's pseudocode adds `+30` whenever `daysAway >= -2`. §4.3
   was followed — boosting a missed deadline would resurface stale items forever.
5. **"next Monday" is deliberately not pushed a further week.** On a Thursday the
   soonest Monday is 3 days out; shifting by 7 invents a deadline a week later
   than reality, which is the worse error for someone who might miss it.
6. **`rules.md` §8's expected scores and labels cannot both hold at one instant.**
   The scores assume `now` ≈ the fixture dates; the labels assume particular day
   offsets. Tests fix `now` explicitly for the score table and assert labels
   separately with a chosen clock.
7. **`RulesEngine` takes `now` as a constructor argument** instead of calling
   `DateTime.now()` inline as §4.2/§4.3 do. Without it, no deadline assertion
   can be deterministic.

One bug that the fixture table did **not** catch, and a single unit test did:
`DateTime.weekday` is 1-based from Monday, but the internal weekday-name list
was 0-based. Comparing them directly made "by Friday" resolve to the day the
mail arrived.

---

## App size

Measured on this build, not estimated:

| Build | Size |
|---|---|
| `flutter build apk --debug` (all ABIs) | 281.1 MB |
| `flutter build apk --release --target-platform android-arm64` | **128.7 MB** |

Two findings drove that reduction:

1. **`abiFilters` does not filter the Flutter engine.** Engine `.so` files are
   injected from the extracted engine artifact and bypass the Gradle filter, so
   a naive build ships `libflutter.so` for x86_64 and armeabi-v7a as well —
   around 67 MB that can never run on the target device.
   `--target-platform android-arm64` is what actually fixes it.
2. **Debug builds ship Dart as `kernel_blob.bin` (69 MB)** rather than an AOT
   snapshot.

`tool/build_apk.ps1` applies both flags, then measures the native payload of each
ABI in bytes and **fails the build** if a non-target ABI carries more than 1 MB.
The manifest still declares all three ABIs and every plugin contributes a couple
of tiny JNI stubs, so checking only for ABI *presence* would always look like a
failure — presence is not the problem, payload is.

### What is deliberately *not* done

- **R8 / minification is off.** `flutter_secure_storage` 11.2.0 depends on Tink
  and ships no consumer ProGuard rules, so minifying risks silently breaking
  storage of the IMAP app password. R8 would only shrink the ~27 MB of dex
  anyway, never the ~120 MB of native libraries. Breaking the password store to
  save 20 MB is a bad trade.
- **The ~52 MB of Qualcomm Hexagon (`libQnnHtp*`) kernels are kept.** They are
  NPU acceleration used only on Qualcomm chipsets; the LiteRT-LM CPU backend is
  what is actually used here. Excluding them would take the APK to roughly
  73 MB, but that has not been verified on hardware, and the app is handed to one
  person whose phone it must not fail on. Revisit once the target SoC is known.

### Build-time network dependency

`flutter_gemma` installs a native-assets build hook that downloads LiteRT-LM
binaries from GitHub releases — including **host** binaries
(`litertlm-windows_x86_64.tar.gz`) when running unit tests on Windows. Every
`flutter test`, `flutter build` and `flutter run` needs GitHub to be reachable.
On a cold machine this is the slowest step in the whole build. If `flutter test`
appears to hang with no output, that download is the cause.

---

## Limitations

Stated plainly rather than buried:

- **Background sync is best-effort and light-only.** Android's Doze mode can
  delay the job, and **Gemma never runs in the background** — it is too heavy and
  the process gets killed mid-inference. The scheduled job therefore runs IMAP
  and rules only, which refreshes *scores* but cannot add newly-rewritten rows.
  Opening the app or tapping **Refresh now** runs the full pipeline. A fresh
  install shows the empty state until the app is opened once.
- **Gemma 3 1B is a small model.** It occasionally mis-structures its output.
  Every response is validated against a strict `WHAT/DO/BY` shape and a
  deadline-match check; failures fall back to a template rather than showing
  something wrong.
- **Inference is not instant.** Cold start measured 8.7 s on the target phone.
  For a screen that updates on a timer this is fine; it would not be for
  anything interactive.
- **ElevenLabs is a cloud service**, not open source. Only the short summary text
  goes to it, never the email — but it is still the one place content leaves the
  device, and it can be switched off entirely.
- **Android-only, arm64-v8a, Android 12+.** Do not run it on an x86_64 emulator:
  the manifest declares that ABI but only arm64 carries real libraries, so the
  install would succeed and then fail to find `libflutter.so`.
- **Foreground-compat:** `flutter_tts`, `home_widget` and `workmanager_android`
  still use the legacy Kotlin Gradle Plugin. A future Flutter release will fail
  to build until they are updated.

---

## Docs

The specs are the source of truth, in this order:

| File | Defines |
|---|---|
| `prd.md` | Who it is for, what it must and must not do, privacy constraints |
| `architecture.md` | Pipeline, service contracts, Android widget layer |
| `rules.md` | The deterministic rules engine and deadline extraction |
| `phases.md` | Build plan, decision gates, cut list, measured results, spec discrepancies |

## Built with

- **[Gemma 3 1B-IT](https://huggingface.co/litert-community/Gemma3-1B-IT)** —
  on-device, open-weight; rewrites every flagged email. Licence must be accepted
  on that repo before download. Note the code pulls from `litert-community`, not
  `google/gemma-3-1b-it`.
- **[ElevenLabs](https://elevenlabs.io)** — voice synthesis for the summaries.
- Flutter, [`enough_mail`](https://pub.dev/packages/enough_mail),
  [`home_widget`](https://pub.dev/packages/home_widget),
  [`just_audio`](https://pub.dev/packages/just_audio),
  [`flutter_tts`](https://pub.dev/packages/flutter_tts),
  [`flutter_gemma`](https://pub.dev/packages/flutter_gemma),
  [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
- Built with [OpenCode](https://opencode.ai), an open-source coding agent.

## Post-deadline commits

_None yet. Any commit made after Mon Oct 5, 12:29 PM IST gets listed here._