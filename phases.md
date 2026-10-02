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

- [ ] `flutter create --org com.headsup --project-name heads_up .` in workspace
- [ ] Set `minSdk = 30` and `abiFilters 'arm64-v8a'` in `android/app/build.gradle`
- [ ] Add all dependencies to `pubspec.yaml` (see `architecture.md` §3)
- [ ] Run `flutter pub get`
- [ ] Create `.gitignore` (must include `*.env`, `secrets.dart`, `*.jks`, `*.keystore`)
- [ ] Copy `prd.md`, `architecture.md`, `rules.md`, `phases.md` into repo root
- [ ] Initial commit: `"chore: scaffold flutter project, add docs"`
- [ ] Push to GitHub

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

- [ ] `01_college_form_deadline.txt`
- [ ] `02_friend_yes_no.txt`
- [ ] `03_bank_payment_due.txt`
- [ ] `04_newsletter_promo.txt`
- [ ] `05_otp.txt`
- [ ] `06_calendar_invite.txt`
- [ ] `07_long_thread.txt`
- [ ] `08_html_heavy.txt`
- [ ] `09_no_deadline.txt`
- [ ] `10_tricky_date.txt`
- [ ] `11_manager_reply.txt`
- [ ] `12_interview_offer.txt`
- [ ] `13_noreply_important.txt`
- [ ] `14_non_english_line.txt`
- [ ] `15_past_deadline.txt`
- [ ] `16_fee_payment.txt`
- [ ] `17_bulk_important.txt`
- [ ] `18_short_reply.txt`
- [ ] `19_unsubscribe_only.txt`
- [ ] `20_form_submission.txt`

### Phase 2: Data models (20 min)

- [ ] `lib/models/mail_item.dart` — MailItem, AudioSource, ItemStatus (see `architecture.md` §5.1)
- [ ] `lib/models/settings.dart` — AppSettings (see `architecture.md` §5.2)
- [ ] `assets/default_rules.json` — default action words, thresholds (see `rules.md` §6)
- [ ] Add `assets/` to `flutter.assets` in pubspec.yaml

### Phase 3: Cleaner + RulesEngine (1.5 hrs)

- [ ] `lib/services/cleaner.dart` — HTML→text, strip quoted replies/signatures/footers, truncate
- [ ] `lib/services/rules_engine.dart` — full scoring + deadline extraction (see `rules.md`)
- [ ] `test/cleaner_test.dart` — HTML stripping, quote removal, signature removal, truncation
- [ ] `test/rules_engine_test.dart` — all test cases from `rules.md` §9
- [ ] `flutter test test/cleaner_test.dart test/rules_engine_test.dart` ← must pass

### Phase 4: Spike A — Gemma on device (1 hr) ← GATE

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

### Phase 5: Spike B — IMAP (30 min) ← GATE

- [ ] `lib/services/mail_service.dart` — connect, examineMailboxByPath, uidFetchMessages with BODY.PEEK[]
- [ ] Connect to a **test Gmail account** (not friend's real one — use a throwaway account first)
- [ ] Fetch 5 recent headers + one body — confirm EXAMINE (read-only) works
- [ ] Confirm no \Seen flags are set after fetch (check Gmail Sent/Inbox in browser)

**Gate decision:**
- If IMAP connects and reads → ✅ proceed
- If authentication fails → check app password is correct, check 2-Step is enabled
- If Workspace account blocks app passwords → This won't happen (friend confirmed app passwords available)

**End of Day 1 gate:** Both spikes pass → commit everything → sleep.

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
