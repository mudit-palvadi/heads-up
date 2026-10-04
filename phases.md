# Heads Up — Build Phases & Timeline

> **Challenge deadline:** Mon Oct 5, 2026, 12:29 PM IST
> **Today:** Fri Oct 2, 2026, ~5:30 PM IST
> **Target submission:** Sun Oct 4, 2026, by 11 PM IST (leaves 13 hours of buffer)
>
> This document is the moment-by-moment build plan. Treat it as a checklist.
> Mark items ✅ as you complete them. Cut items are in the Cut List — follow the cut order strictly.

---

## Pre-Build Checklist (do these before writing any code)

- [ ] Accept Gemma Terms of Use at https://huggingface.co/google/gemma-3-1b-it
- [ ] Generate a **read-only** HuggingFace token at https://huggingface.co/settings/tokens
- [ ] Ask friend to create app password at https://myaccount.google.com/apppasswords → label "Heads Up"
- [ ] Ask friend the four setup questions (see PRD §3)
- [ ] Claim ElevenLabs promo credits at https://hacktoberfest.com/my/promos
- [ ] Create a **new** public GitHub repo (name: `heads-up`) — commit must be after Oct 2, 7:30 AM IST ✅ (it is)
- [ ] Choose ElevenLabs voice (listen at elevenlabs.io → Voice Library → filter: English, calm)

---

## Day 1 — Friday Oct 2 (today, ~6 hours left)

### Phase 0: Scaffold (30 min)

- [x] `flutter create --org com.headsup --project-name heads_up .` in workspace
- [x] Set `minSdk = 30` and `abiFilters 'arm64-v8a'` in `android/app/build.gradle`
- [x] Add all dependencies to `pubspec.yaml` (see `architecture.md` §3)
- [x] Run `flutter pub get`
- [x] Create `.gitignore` (must include `*.env`, `secrets.dart`, `*.jks`, `*.keystore`)
- [x] Copy `prd.md`, `architecture.md`, `rules.md`, `phases.md` into repo root
- [x] Initial commit: `"chore: scaffold flutter project, add docs"`
- [ ] Push to GitHub *(needs a remote — repo must be created after Oct 2, 7:30 AM IST)*

> **Config deviations from `architecture.md` §4** (both forced, both verified by building):
> 1. **Generated files are Kotlin DSL** (`build.gradle.kts`), not the Groovy `build.gradle` in the doc.
> 2. **`compileSdk` is 36, not 35.** `androidx.core:core:1.17.0` arrives transitively and *requires*
>    compileSdk 36+; the build hard-fails at 35. `targetSdk` stays 35 so we don't opt into new
>    runtime behavior, `minSdk` stays 30 for LiteRT-LM.
> 3. **`minifyEnabled = false` line removed** — AGP 9 rejects the property under the new DSL, and it is
>    already the default, so behavior is unchanged.
>
> **Forward-compat warning (not blocking):** `flutter_tts`, `home_widget`, and `workmanager_android`
> still apply the legacy Kotlin Gradle Plugin. Flutter warns that future versions will *fail* on this.
> If a later Flutter upgrade breaks the build, bump those three first.

### Verified build facts (measured, not assumed)

| Check | Result |
|---|---|
| `package` / `applicationId` | `com.headsup` ✅ |
| `sdkVersion` (minSdk) | `30` ✅ required by LiteRT-LM |
| `targetSdkVersion` | `35` ✅ |
| `compileSdkVersion` | `36` (forced bump, see above) |
| APK size, debug, all ABIs | 281.1 MB |
| APK size, release, arm64 only | **124.6 MB** |
| arm64-v8a payload | 120.2 MB (23 `.so`) |
| armeabi-v7a / x86_64 residue | 0.1 MB each (2 tiny JNI stubs) |

> **`abiFilters` does NOT filter the Flutter engine.** Engine `.so` files are injected from the
> extracted engine artifact and bypass the Gradle filter, so a build without
> `--target-platform android-arm64` ships 67 MB of unusable engine code. `./tool/build_apk.ps1`
> applies the flag and prints a breakdown so this never silently regresses.
>
> **Do not run on an x86_64 emulator.** The manifest still declares all three ABIs while only
> arm64-v8a carries real libraries, so an emulator install would succeed and then fail to find
> `libflutter.so`. Physical arm64 device only — which is what Day 2 already assumes.
>
> **R8/minification is deliberately OFF.** `flutter_secure_storage` 11.2.0 depends on Tink and
> ships no consumer ProGuard rules; minifying risks silently breaking storage of the IMAP app
> password. It would only shrink the ~27 MB of dex, never the ~120 MB of native libs. Do not
> "optimize" this during the hackathon without a device test.
>
> **`flutter_gemma` installs a native-assets build hook** that downloads LiteRT-LM binaries from
> GitHub releases — including **host** binaries (~76 MB, `litertlm-windows_x86_64.tar.gz`) whenever
> `flutter test` runs on Windows. Cold `flutter test` is therefore slow and needs GitHub reachable.
> If it appears to hang with no output, this download is the cause: check
> `%LOCALAPPDATA%\flutter_gemma\native\` for a truncated `.tar.gz` and resume it. Worth revisiting
> after the deadline: the pure-logic tests (`MailItem`, rules engine, cleaner) could move to a
> `core` package with no `flutter_gemma` dependency, making them fast and hermetic.

### Phase 0b: models (done ahead of Phase 1)

- [x] `assets/default_rules.json` — default action words + thresholds (see `rules.md` §6)
- [x] Add `assets/` to `flutter.assets` in pubspec.yaml
- [x] `lib/models/mail_item.dart` — MailItem, AudioSource, ItemStatus (see `architecture.md` §5.1)
- [x] `lib/models/settings.dart` — AppSettings (see `architecture.md` §5.2)

### Phase 1: Fake email fixtures (45 min)

Create all 20 files in `test/fixtures/fake_emails/`. **No real email content anywhere.**

Each file is plain text with headers + body. Use the fixture table in `rules.md` §8 to write them:

```
# test/fixtures/fake_emails/01_college_form_deadline.txt
From: admissions@university.edu
To: friend@gmail.com
Subject: URGENT: Enrollment Form Due Oct 10
Date: Thu, 01 Oct 2026 10:00:00 +0530

Dear Student,

Your enrollment form for the upcoming semester must be submitted by October 10, 2026.
Please upload your ID proof and signed declaration on the student portal.

Failure to submit by the deadline will result in cancellation of your enrollment.

Student Services
University of Example
```

Write all 20 now. They are used in tests AND as Gemma test inputs.

- [x] `01_college_form_deadline.txt`
- [x] `02_friend_yes_no.txt`
- [x] `03_bank_payment_due.txt`
- [x] `04_newsletter_promo.txt`
- [x] `05_otp.txt`
- [x] `06_calendar_invite.txt`
- [x] `07_long_thread.txt`
- [x] `08_html_heavy.txt`
- [x] `09_no_deadline.txt`
- [x] `10_tricky_date.txt`
- [x] `11_manager_reply.txt`
- [x] `12_interview_offer.txt`
- [x] `13_noreply_important.txt`
- [x] `14_non_english_line.txt`
- [x] `15_past_deadline.txt`
- [x] `16_fee_payment.txt`
- [x] `17_bulk_important.txt`
- [x] `18_short_reply.txt`
- [x] `19_unsubscribe_only.txt`
- [x] `20_form_submission.txt`

> Each fixture is designed so the expected score in `rules.md` §8 actually holds under the §2 scoring
> table. Notable calibrations:
> - `13_noreply_important` needs a **VIP keyword** to land at `+20` — the `-60` noreply penalty cannot be
>   overcome by anything else, so "Borderline ≥ 10" is only reachable via `vipKeywords`.
> - `17_bulk_important` is the VIP-override case: `-100` (List-Unsubscribe) `-80` (bulk) `-60` (noreply)
>   `-30` (promo) floors it at 30 via `rules.md` §2.3, which is the "≥ 20, VIP overrides bulk" row.
> - `18_short_reply` lands at exactly `65` = VIP address `+50` + `In-Reply-To` `+15`, no body action word.
> - `15_past_deadline` has **no resolvable future date** in its body (deliberate — it is the past-deadline
>   case), so its `≥ 30` comes from subject action words. Its "was Oct 5" deadline assertion will need an
>   injected clock in the test, since the fixture is static but the window filter is relative to now.

### Phase 2: Data models (20 min) — moved to Phase 0b, done

- [x] `lib/models/mail_item.dart` — MailItem, AudioSource, ItemStatus (see `architecture.md` §5.1)
- [x] `lib/models/settings.dart` — AppSettings (see `architecture.md` §5.2)
- [x] `assets/default_rules.json` — default action words, thresholds (see `rules.md` §6)
- [x] Add `assets/` to `flutter.assets` in pubspec.yaml

### Phase 3: Cleaner + RulesEngine (1.5 hrs) — DONE

- [x] `lib/services/cleaner.dart` — HTML→text, strip quoted replies/signatures/footers, truncate
- [x] `lib/services/rules_engine.dart` — full scoring + deadline extraction (see `rules.md`)
- [x] `lib/models/rules_config.dart` — rules.md §6 config + user-override merge
- [x] `test/cleaner_test.dart` — HTML stripping, quote removal, signature removal, truncation
- [x] `test/rules_engine_test.dart` — all test cases from `rules.md` §9 + the §8 fixture table
- [x] `flutter test` ← **115 tests passing**, `flutter analyze` clean

> **Spec discrepancies found while implementing Phase 3.** Each was resolved in favour of the
> reading that keeps the product correct, and each is noted at the point of use in the code.
>
> 1. **`architecture.md` §7 does not compile against `enough_mail` 2.1.7.** It calls
>    `msg.receivedDate!`; the real accessor is `msg.date` (`DateTime?`, nullable). `headers` is
>    `List<Header>?`, also nullable. Adapted.
> 2. **`rules.md` §3 contradicts itself.** The prose says "whole-word matching where practical";
>    the code snippet below uses a bare `contains`, which scores "information" and "platform" as
>    hits for the action word "form". **Prose followed** — §1 says prefer false negatives, and false
>    positives cost widget slots.
> 3. **`rules.md` §4.1 Pattern 4 cannot match fixture 12.** The spec requires a `by|before|until|on`
>    preposition, but `12_interview_offer` says "scheduled for **next Monday**" — "for" is not in
>    that list, so the fixture's expected deadline is unreachable. Pattern 4 now also accepts a bare
>    `this/next <weekday>`. A weekday with neither qualifier nor preposition ("meet Monday
>    afternoons") is still not matched.
> 4. **`rules.md` §4.3 contradicts §7.** §4.3 says a passed deadline earns `+0` boost but is still
>    reported; §7's pseudocode adds `+30` whenever `daysAway >= -2`. **§4.3 followed** (more
>    specific, and boosting a missed deadline would surface stale items).
> 5. **"next Monday" is deliberately not pushed a further week.** On a Thursday the soonest Monday
>    is 3 days out; shifting by 7 invents a deadline a week later than reality, which is the worse
>    error for someone who might otherwise miss it.
> 6. **`rules.md` §8's expected scores and expected labels cannot both hold at one instant.** The
>    scores assume `now` ≈ the fixture dates (a deadline only boosts while it is still ahead of
>    us); the labels assume particular day offsets. Tests therefore fix `now = 2026-10-01 09:00`
>    explicitly for the §8 score table and assert labels separately with a chosen clock.
> 7. **`RulesEngine` takes `now` as a constructor argument** instead of calling `DateTime.now()`
>    inline as §4.2/§4.3 do. Without this, no deadline assertion can be deterministic.
>
> **Bug worth remembering:** `_weekdayNames` is 0-based from Monday while `DateTime.weekday` is
> 1-based. Comparing them directly made "by Friday" resolve to the day the mail arrived. Caught by
> the "by Friday" unit test, not by the fixture table.

### Phase 4: Spike A — Gemma on device (1 hr) ← GATE (original Day 1 plan, **superseded**)

> Kept for reference. The gate was actually run on Sat Oct 3 night against the real device — see the
> **PASSED** section below for measurements and outcome.

This is a go/no-go test. **Do this before building VoiceService or Widget.**

- [ ] `lib/services/gemma_service.dart` — initialize, download, inference, parse, fallback
- [ ] Write a minimal test screen: load model, feed one fake email, print WHAT/DO/BY and latency
- [ ] Run on **friend's actual phone** (Android 12, 8 GB RAM)
- [ ] Record: latency in seconds, output quality, whether model loads cleanly

**Gate decision:**
- If latency ≤ 10s/email → ✅ proceed normally
- If latency 10–20s/email → run Gemma only on app-open (not in WorkManager). Acceptable.
- If latency > 20s/email → switch to Gemma 3 270M (~150 MB, faster). See fallback ladder below.
- If model fails to load → check `arm64-v8a` ABI filter, minSdk 30, check logs

**Capture for write-up:** latency number, phone model, RAM usage screenshot

### Phase 4: Spike A — Gemma on device (1 hr) ← GATE — **PASSED**

- [x] `lib/services/gemma_runtime.dart` — initialize, download, readiness state
- [x] `lib/ui/spike_a_screen.dart` — masked token → KeyStore, download progress, latency + raw output
- [x] Ran on friend's actual phone, fed one synthetic email, captured WHAT/DO/BY + latency
- [x] **Gate decision: ≤10s/email → keep Gemma 3 1B, no fallback to 270M needed**

**Measured (feeds the DEV post — "What to Measure and Capture"):**

| Metric | Value |
|---|---|
| Device | realme RMX3853, Android 16 (SDK 36), arm64-v8a, 7.4 GB RAM |
| Model | `gemma3-1b-it-int4.litertlm`, 557 MB (584,417,280 bytes on disk) |
| Repo | `litert-community/Gemma3-1B-IT` (gated; licence accepted) |
| Engine | LiteRT-LM via `flutter_gemma` 1.11.3 |
| **Latency, cold** (incl. engine init) | **8,714 ms** |
| Latency, actual generation | 2,109 ms |
| — prefill / time-to-first-token | 1,222 ms |
| — decode | 887 ms over 22 chunks (~23.7 chunks/sec) |
| RAM during inference | TOTAL PSS 774 MB |
| Output quality | valid `WHAT/DO/BY`, **accepted by the validator** (not rejected) |
| Deadline guard | `BY: Oct 10` matched the rules-engine value — no invention |

Raw output from the gate run:
```
WHAT: Enrollment form deadline
DO: Submit your ID proof & declaration
BY: Oct 10
```

> **The 8.7 s figure includes one-time LiteRT-LM session/engine setup.** The engine's own
> instrumentation reports 2,109 ms of generation. Warm runs should sit near 2 s, so the real
> per-email cost is comfortably inside the gate — worth re-measuring warm before quoting the
> number in the post, and worth saying so plainly rather than quoting the flattering 2 s alone.
>
> **Repo note:** the code downloads from `litert-community/Gemma3-1B-IT`, **not**
> `google/gemma-3-1b-it` (which the pre-build checklist names). Accept the licence on the former.
> The `.litertlm` filename must be passed explicitly — left to itself the manifest resolver
> guesses a conventional name and fails 404. The repo also contains chipset-specific NPU builds
> (`sm8650`, `mt6991`, …); the generic INT4 build is used deliberately, since matching an NPU
> variant requires knowing the exact SoC.

### Phase 5: Spike B — IMAP (30 min) ← GATE — **NOT STARTED**

> **Session note — Sun Oct 4, ~21:15.** Service code and the staged read-only
> proof are built; the proof itself has still not been run against a live
> account. Findings from the first on-device session with the new UI:
>
> - **The app password, ElevenLabs key and HF token are all already in the
>   KeyStore.** The Setup screen showed `•••••••• saved` in all three fields —
>   that placeholder (`_savedPlaceholder`) is deliberately shown *instead of* a
>   real secret, so it is positive evidence the secret exists, not a value.
> - **What is actually missing is `AppSettings.imapUser` — the email address.**
>   That is why first-run detection correctly landed on the Setup screen:
>   without an address the app cannot connect at all. One field is all that
>   stands between here and Spike B.
> - **The release build is signed with the debug keys** (`build.gradle.kts:38`),
>   so `adb install -r app-release.apk` is an in-place update. The KeyStore
>   entries and the 557 MB model both survive. Verified: model still reported
>   `ready` after replacing a debug build with a release one.
>   **Never uninstall.** That would force a re-download through the gated
>   Hugging Face repo.
> - **`run-as com.headsup` fails on a release build** (`package not debuggable`).
>   To inspect app-private files, install `app-debug.apk` instead — it is signed
>   with the same key, so it also updates in place.
> - **The launcher component is `com.headsup.heads_up.MainActivity`**, not
>   `com.headsup.MainActivity`. The applicationId and the Kotlin package differ.
>   Launch with `adb shell monkey -p com.headsup -c android.intent.category.LAUNCHER 1`.
> - **Bug found by screenshot, not by tests:** section headings (`Your Gmail
>   account`, `Voice (optional)`, `Language model`) overlapped the floating
>   labels of the field beneath them, because `_sectionLabel` had no bottom
>   padding. Only visible on a real device at real text sizes.
>
> **Run the proof in this order, and stop if the FLAGS diff is non-zero — a
> non-zero diff means the real inbox has been marked read:**
>
> 1. Set up → enter the email address → **Test connection**.
> 2. `probeFlags()` → fetch with `BODY.PEEK[]` → `probeFlags()` again.
> 3. Both probe results must be identical.

- [ ] `lib/services/mail_service.dart` — connect, examineMailboxByPath, uidFetchMessages with BODY.PEEK[]
- [ ] Connect to a **test Gmail account** (not friend's real one — use a throwaway account first)
- [ ] Fetch 5 recent headers + one body — confirm EXAMINE (read-only) works
- [ ] Confirm no \Seen flags are set after fetch (check Gmail Sent/Inbox in browser)

**Gate decision:**
- If IMAP connects and reads → ✅ proceed
- If authentication fails → check app password is correct, check 2-Step is enabled
- If Workspace account blocks app passwords → This won't happen (friend confirmed app passwords available)

**End of Day 1 gate:** Spike A ✅ passed · Spike B ⬜ still open — app password now in hand.

---

## Day 2 — Saturday Oct 3 (full day)

### Morning: Core pipeline (3 hrs)

- [ ] `lib/services/store.dart` — sqflite schema, all CRUD methods, secure storage wrapper
- [ ] `lib/services/voice_service.dart` — ElevenLabs call, mp3 save, offline TTS fallback, playback
- [ ] `lib/services/pipeline.dart` — `runFull()` and `runLightBackground()` orchestration
- [ ] `lib/services/widget_sync.dart` — HomeWidget.saveWidgetData + updateWidget calls

**Test pipeline end-to-end with fake emails:**
```dart
// Quick integration test (not a unit test — run in a test screen)
final result = await Pipeline().runFull();
print(result); // Should show WHAT/DO/BY + audio path for top 3 items
```

### Mid-morning: Widget (2 hrs) ← HIGHEST RISK

Build and test the widget in this order. Do not skip steps.

**Step 1: Static widget (no interactivity)**
- [ ] `android/app/src/main/res/layout/widget_layout.xml` — full layout (see `architecture.md` §7.2)
- [ ] `android/app/src/main/res/drawable/widget_bg.xml` — rounded rect dark navy background
- [ ] `android/app/src/main/res/drawable/ic_play.xml` — simple play triangle vector
- [ ] `android/app/src/main/res/xml/heads_up_widget_info.xml`
- [ ] `android/app/src/main/kotlin/com/headsup/HeadsUpWidgetProvider.kt`
- [ ] `AndroidManifest.xml` — widget receiver, home_widget receivers, TTS queries entry
- [ ] Test: add widget to home screen, run `widgetSync.sync([fakeItems])` → verify text appears

**Step 2: Interactive widget (play button)**
- [ ] `lib/background/callback_dispatcher.dart` — `widgetInteractivityCallback` function
- [ ] `lib/main.dart` — `HomeWidget.registerInteractivityCallback(widgetInteractivityCallback)`
- [ ] Kotlin: add `HomeWidgetBackgroundIntent.getBroadcast(...)` to each play button
- [ ] **Test: tap ▶ on widget → audio plays.** This is the moment of truth.

**Option A / B decision point (max 2 hours on this):**
- If audio plays from the background callback → Option A confirmed ✅
- If audio fails (no sound, crash, silence) → switch to **Option B**:
  - Play button fires a normal Intent to open `AudioPlayerActivity.kt` (a transparent activity)
  - Activity plays the audio and calls `finish()` immediately after
  - One brief flash of activity, but guaranteed to work

- [ ] Commit: "feat: widget shows items and play button works"

### Afternoon: Background + UI (3 hrs)

- [ ] `lib/background/callback_dispatcher.dart` — WorkManager `callbackDispatcher`
- [ ] `lib/main.dart` — `Workmanager().initialize()` + `registerPeriodicTask(60 min)`
- [ ] `lib/ui/setup_screen.dart` — IMAP fields, ElevenLabs key, model download progress
- [ ] `lib/ui/status_screen.dart` — last check time, items, refresh button, model status
- [ ] `lib/ui/rules_screen.dart` — VIP senders/domains/keywords, ignore list
- [ ] `lib/ui/settings_screen.dart` — check interval, cloud voice toggle, voice picker
- [ ] Wire up navigation (simple `Navigator.push`, no complex routing needed)

### Late afternoon: Real phone test (1 hr)

- [ ] Build debug APK: `flutter build apk --debug`
- [ ] Install on friend's phone: `adb install build/app/outputs/flutter-apk/app-debug.apk`
- [ ] Walk through setup with his real app password and real email
- [ ] Run one full pipeline with his actual inbox
- [ ] Watch output. Tune: rules threshold, action word list, Gemma prompt if needed
- [ ] Verify: widget shows real items, play button works, empty state shows correctly

**Capture for write-up:** screenshot of widget with BLURRED or fake data (not his real emails)

### Evening: Nice-to-haves (if ahead of schedule)

- [ ] `lib/ui/missed_list_screen.dart` — 30-day backfill, consent prompt, actionable vs past
- [ ] Pre-generate ElevenLabs clip for "Nothing needs you today" phrase → bundle in app
- [ ] Urgent state styling (amber/red accent for today's deadline items)
- [ ] "Mark done" long-press action on widget items

---

## Day 3 — Sunday Oct 4 (hand-over + write-up)

### Morning: Hand-over (2 hrs)

- [ ] Sit with friend. Walk through the app together.
- [ ] He sets up his VIP list himself (don't do it for him — let him choose who matters).
- [ ] Run the missed list (30 days). Show him what he missed. Let that land.
- [ ] Record his reaction: voice note (with permission) or write down exact words.
- [ ] Let him use it for an hour. See what he does.
- [ ] Note what confused him, what he changed, what he said.

**Questions to ask during hand-over:**
1. "Does this feel right? Is the wording easy to understand?"
2. "Is the play button obvious?"
3. "Who else should be on your important list?"
4. "What would make this more useful?"

### Mid-day: Demo video + README (2 hrs)

**Demo video:**
- Use fake/blurred data or his phone with permission and blurred content
- Show: home screen → widget with 2 items → tap play → audio plays → "Nothing needs you today" state
- Narrate with ElevenLabs voice (this counts toward Best Use of ElevenLabs category)
- Keep it under 90 seconds
- Upload to YouTube (unlisted is fine) or embed as a GIF for key moments

**README.md:**
```markdown
# Heads Up

Built for my friend who's dyslexic and misses important emails.
[One-sentence description]

## What it does
[3 bullet points]

## Setup
1. Download the app
2. Go to myaccount.google.com/apppasswords → create an app password
3. Enter it in the app → add important senders → tap Refresh

## Privacy
Your full emails never leave this phone. Only short summaries (~30 words) 
are sent to ElevenLabs for voice generation when cloud voice is on.
You can turn cloud voice off at any time in Settings.
To revoke access: Google Account → Security → App Passwords → delete "Heads Up".

## Limitations
- Background sync runs every 60 min (best effort — Android may delay it).
- Open the app for instant refresh.
- Gemma 3 1B is a small model. Occasionally it misjudges tone or structure.
  The rules engine decides importance, not Gemma.
- On first install, open the app once to process new emails.

## Post-deadline commits
[Note any commits after Oct 5 12:29 PM IST here]

## Built with
- Gemma 3 1B-IT (on-device, open-weight) — for rewriting emails in plain language
- ElevenLabs — for voice synthesis
- Flutter + enough_mail + home_widget
- Built with OpenCode (open-source coding agent) using Space Bunny model
```

### Afternoon: DEV post (3 hrs)

Write the post following the arc in `prd.md` §13. Use this outline:

```
---
Title: I built an app that reads my dyslexic friend's email for him
Tags: devchallenge, weekendchallenge, hf26challenge
---

## The person

[Hook: a specific moment where he missed something. His actual words if possible.]

## The insight

[The inbox feels like a pile of small threats. Don't make him check it — bring it to him.]

## What I built

[Widget description + screenshot/GIF with fake data + demo video embed]

## How it works

[Architecture diagram from architecture.md — paste the mermaid diagram]

Plain steps:
1. App reads new emails via IMAP (read-only — it never sends or deletes anything)
2. Rules decide what matters (VIP senders, deadlines, action words)
3. Gemma 3 1B rewrites each flagged email as 3 short lines
4. ElevenLabs turns that into audio, saved to the phone
5. Widget shows up to 3 items with a play button

## Why open innovation mattered here

[His inbox has personal stuff. Full emails never left the phone. Cost: $0/email.
 I could constrain Gemma strictly — it never invents dates, only rewrites.
 ElevenLabs is a cloud service (not open-source) — I say so explicitly.
 Trade-off: small model needed rules; larger model wouldn't need them but would cost per email.]

## The hand-over

[His real reaction — verbatim, with permission]
[What he changed on the VIP list]
[What surprised me]

## Limitations I'm being honest about

- Background refresh isn't guaranteed (Android's Doze mode)
- Gemma occasionally mis-structures output (fallback templates cover this)
- ElevenLabs uses cloud voice — can be turned off

## Prize Categories

- **Best Use of Gemma** — Gemma 3 1B-IT runs on-device and rewrites every flagged email
- **Best Use of ElevenLabs** — summaries are voiced with ElevenLabs; demo video narrated with it too

## My Agent Session

[Link if shareable — ensure no real email content in session logs]
```

- [ ] Create DEV draft: `devrelay create_article` or manually at dev.to/new
- [ ] Paste content, add tags: `devchallenge`, `weekendchallenge`, `hf26challenge`
- [ ] Review: privacy language accurate? No real email content? No API keys?
- [ ] Publish

### Evening: Submit

- [ ] Final GitHub push — all code committed
- [ ] DEV post URL confirmed live
- [ ] Submit at https://dev.to/challenges/hacktoberfest-weekend-2026-10-01 (post URL + GitHub URL)
- [ ] Done by 11 PM IST ← target

---

## Cut List

Cut in this exact order if running behind. Never cut the items below the line.

| # | Cut item | When to cut |
|---|---|---|
| 1 | Missed list screen (30-day backfill) | If Saturday evening is still on widget |
| 2 | Pre-generated "Nothing needs you today" ElevenLabs clip | If Sunday morning |
| 3 | Urgent amber/red styling for today's deadlines | If Sunday morning |
| 4 | Mark done / not important widget action | If Sunday morning |
| 5 | Background WorkManager refresh | If Sunday afternoon; replace with refresh-on-open only |
| 6 | Voice picker UI in settings | Hardcode a default voice ID |
| ━ | ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ | ━━━━━━━━━━━━━━━━━ |
| — | Gemma rewriting | **Never cut** |
| — | ElevenLabs audio | **Never cut** |
| — | Play button on widget | **Never cut** |
| — | Empty state | **Never cut** |
| — | Real hand-over + reaction | **Never cut** |
| — | Honest write-up | **Never cut** |

---

## Decision Gates

### Gate 1: End of Day 1 (Friday night)
**Question:** Did both spikes pass?
- Gemma loads and produces valid WHAT/DO/BY output in ≤ 15s → ✅
- IMAP connects, fetches new messages, EXAMINE confirms read-only → ✅
- If either fails → apply fallback ladder before building anything else

### Gate 2: Saturday mid-morning (widget play button)
**Question:** Does tapping ▶ on the home screen widget play audio?
- Audio plays cleanly → Option A confirmed ✅
- Audio doesn't play → 2 hours max trying to fix, then switch to Option B

### Gate 3: Saturday late afternoon (real phone, real email)
**Question:** Does the full pipeline work on friend's real phone with real email?
- Pipeline runs, items appear on widget → ✅ continue
- Gemma too slow → Gemma runs on app-open only (not background)
- ElevenLabs failing → check API key, check free tier not exhausted

---

## Fallback Ladder

| Risk | Primary | Fallback 1 | Fallback 2 |
|---|---|---|---|
| Gemma too slow | Run on app-open only | Smaller model (Gemma 3 270M, ~150 MB) | Rules-based template strings |
| Gemma output invalid | Validate + retry once | Use fallback template immediately | Show subject + sender in widget |
| Widget play button fails (Option A) | Debug background isolate audio | Option B (transparent activity) | Tap opens app, plays there |
| ElevenLabs fails | Retry once | Mark offline_tts, flutter_tts at tap | Show item without audio |
| Background job doesn't run | Refresh on app open | Foreground service (nuclear option) | Manual refresh button only |
| App password rejected | Check 2-Step + app password | Try fresh app password | Gmail OAuth (3 hrs extra work) |

---

## What to Measure and Capture

These go directly into the write-up. Capture them **during development, not after.**

| Metric | How to capture | When |
|---|---|---|
| Gemma inference latency | `Stopwatch()` around `runFull()` per email | Day 1 Spike A |
| Gemma fallback rate | Log `fallbackUsed` per run | Day 2 during real phone test |
| Model download time | `FlutterGemma.installModel(...).withProgress(...)` | Day 2 setup |
| Model file size on disk | `ls -lh` in app documents directory | Day 2 |
| ElevenLabs chars used | ElevenLabs dashboard | Day 2 |
| RAM during inference | Android Studio Memory Profiler | Day 2 Spike A |
| Widget response to tap | Stopwatch eye-test | Day 2 widget test |
| Friend's exact reaction | Voice note or written notes | Day 3 hand-over |

---

## Commit Hygiene

```
feat: scaffold flutter project + add architecture docs
feat: add fake email fixtures (20 files)
feat: add MailItem and AppSettings models
feat: add Cleaner and RulesEngine with tests
feat: add GemmaService with prompt, parser, fallback
feat: add Store (sqflite + secure storage)
feat: add VoiceService (ElevenLabs + flutter_tts)
feat: add Pipeline orchestration
feat: add Android widget layout and HeadsUpWidgetProvider
feat: add widget interactivity callback (play button)
feat: add WorkManager background sync
feat: add all UI screens
feat: add missed list screen
fix: <whatever>
docs: update README with setup and privacy notes
```

Post any commit made after Oct 5, 12:29 PM IST in the README under `## Post-deadline commits`.
