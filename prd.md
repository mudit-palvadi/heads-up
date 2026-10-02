# Heads Up — Product Requirements Document

> **Status:** Active build. Challenge deadline: Mon Oct 5, 2026, 12:29 PM IST.
> This document defines what the product is, who it is for, what it must do, and what it must never do.
> It is the source of truth for product decisions. When in doubt, refer here.

---

## 1. The Person

**Name in post:** `__FRIEND__` (fill in before publishing)
**Device:** Android 12+, 8 GB RAM
**Email:** Gmail personal, app passwords confirmed available
**Problem:** Dyslexic. Rarely opens email. Misses important things — forms, deadlines, replies — then feels guilty. The inbox feels like a pile of small threats, so he avoids it, misses something, feels worse, and avoids it more.
**Key behaviour:** He looks at his home screen constantly, even if he ignores notifications.

**The insight:** Don't make him open email. Bring the important ones to where he already looks — the home screen — in words he can absorb at a glance, and let him *listen* instead of read.

---

## 2. What the Product Is

A two-part Android app:

1. **Home screen widget** — up to 3 rows, each showing one important email summary with a play button (▶). When nothing needs him, it shows a calm empty state. This is what he actually sees and uses every day.

2. **Flutter app** — small, mostly a setup and control panel. He opens it rarely. It handles account setup, VIP rules, model download, and shows pipeline status. The widget is the real product.

---

## 3. Widget States

### 3.1 Normal state (1–3 items)

```
┌──────────────────────────────────────┐
│  2 things need you today             │
│                                      │
│  ▶  Internship form is due           │
│     Friday. Upload your ID.          │
│                                      │
│  ▶  Rahul wants a yes or no          │
│     about the room by tonight.       │
│                                      │
│  Everything else can wait.           │
└──────────────────────────────────────┘
```

- Header: `{n} thing(s) need you today`
- Each row: amber play button (▶) + 1–2 short lines of text (WHAT + DO condensed)
- Footer: `Everything else can wait.` (dim, always present when items shown)
- Max 3 rows. Never more.

### 3.2 Empty state (nothing flagged)

```
┌──────────────────────────────────────┐
│                                      │
│   Nothing needs you today ✓          │
│                                      │
└──────────────────────────────────────┘
```

- Large, calm, centred text.
- High contrast. This is a *feature*, not an afterthought. The relief of seeing this is part of the product.
- No footer, no sub-text.

### 3.3 Urgent state (item has deadline ≤ today)

- Same layout as normal.
- The urgent item's play button and text get an amber/red accent (`#FF6B35`).
- Header changes to: `1 thing needs you TODAY`

### 3.4 Loading / error state

- `Checking your mail…` during first run.
- `Couldn't reach your mail. Tap to retry.` on connection failure.
- Tapping the error state opens the app on the Status screen.

---

## 4. What Each Widget Item Contains

Each item is a `MailItem` with:

| Field | Description | Source |
|---|---|---|
| `what` | What the email is. One short line. | Gemma output |
| `doIt` | The one thing he must do. One short line. | Gemma output |
| `by` | Deadline, e.g. "Friday" or "Oct 10". Null if none. | Rules engine (never Gemma) |
| `audioPath` | Path to pre-generated mp3 on device. | ElevenLabs (or null) |
| `audioSource` | `elevenlabs`, `offline_tts`, or `none` | VoiceService |
| `speechText` | The text spoken. = what + ". " + doIt + (by ? " By " + by : "") | Composed locally |

**Speech text example:** `"Internship form is due. Upload your ID by Friday."`

The widget displays `what` on line 1 and `doIt` (+ `by` if present) on line 2.
The ▶ button plays the `speechText` audio.

---

## 5. Tap Behaviour

| Tap target | Action |
|---|---|
| ▶ button | Play pre-generated audio. If no audio file, use flutter_tts to speak speechText. |
| Item text | Open app on detail/status view for that item. Allow "Mark done" or "Not important". |
| Empty state | Open app on Status screen. |
| Error state | Open app on Status screen. |

**Play button behaviour detail:**
1. If `audioPath` exists and file is on disk → `just_audio` plays it instantly (no network).
2. If `audioSource == offline_tts` → `flutter_tts` speaks the `speechText` at tap time.
3. Playing a new item stops any currently playing audio.
4. No loading spinner. It must feel instant.

---

## 6. The Flutter App Screens

### 6.1 Setup Screen (first-run flow)
- Step 1: IMAP host (pre-filled: `imap.gmail.com`), port (`993`), username (email address)
- Step 2: App password field (masked, 16-char Google app password)
- Step 3: ElevenLabs API key (masked, optional — can skip for offline-only)
- Step 4: Download Gemma model (progress bar, ~529 MB)
- "Test connection" button — shows ✓ or error inline
- Privacy note (non-negotiable, always visible): *"This app reads your emails on this phone. Only short summaries are sent to ElevenLabs for voice. Your full emails never leave the phone."*

### 6.2 Status Screen (home)
- Last check time: `Last checked 4 min ago`
- Current items: shows the same 3 items as the widget
- `Refresh now` button — runs the full pipeline immediately
- Model status: `Gemma ready` / `Downloading… 47%` / `Not downloaded`
- Pipeline log: last 5 events (collapsible)
- Error display: clear message + suggested fix

### 6.3 VIP Rules Screen
- VIP senders list: add/remove email addresses (e.g., `dad@gmail.com`)
- VIP domains: add/remove domains (e.g., `university.edu`)
- Important keywords: add/remove words (e.g., `deadline`, `urgent`)
- Ignore list: senders/domains to always skip
- "Reset to defaults" button

### 6.4 Settings Screen
- Check interval: 15 min / 30 min / 1 hr / 2 hr (default: 1 hr)
- Cloud voice toggle: `Nicer voice (sends short summary text to ElevenLabs)` — on by default
- Voice picker: shows ElevenLabs voice list (fetched from API), play preview
- Score threshold: slider (default: 30) — advanced, collapsed by default
- Disconnect account / Reset app

### 6.5 Missed List Screen (demo / hand-over feature)
- "Load last 30 days" button
- Requires explicit confirmation: *"This will process your last 30 days of email on your phone. Nothing is sent anywhere. Continue?"*
- Shows results in two groups: **Still actionable** / **Already past**
- Each item shows the same WHAT/DO/BY format
- "This is what you may have missed" — emotional core of the hand-over demo

---

## 7. Dyslexia Design Rules

These apply to **every piece of text** in the widget and the app:

| Rule | Reason |
|---|---|
| Font: system `sans-serif` (Roboto on Android). No serif, no italic. | Italic and serif fonts are harder for dyslexic readers. |
| Line spacing: 1.3× minimum | Prevents lines from merging visually. |
| Left-aligned text. Never justified. | Justified text creates uneven word spacing. |
| Max 2 lines per widget item, ~7 words per line | Reduces working memory load. |
| High contrast: white text on `#1A1A2E` (dark navy) | Adequate contrast ratio (≥ 4.5:1). |
| One action per item | Multiple actions in one place are confusing. |
| Clear deadline: "by Friday", not "by EOD 10/08/2026" | Plain language, no jargon. |
| Audio is always available — reading is optional | He should never be forced to read. |
| Empty state is large and calm, not small and greyed-out | Relief is part of the UX. |
| No badges, dots, or animated counts on the widget | Visual noise. |

---

## 8. Privacy & Safety Constraints

These are hard constraints, not preferences. Do not soften or remove them.

| Constraint | Detail |
|---|---|
| Read-only mailbox access | The app uses IMAP EXAMINE (not SELECT). It never sends, deletes, moves, or marks any email. |
| Full emails stay on the phone | Email bodies, subjects, and sender details are stored only in the local sqflite database. |
| What leaves the phone | (a) IMAP traffic to Gmail's servers. (b) The short `speechText` (~30 words) sent to ElevenLabs when cloud voice is on. |
| Accurate privacy claim | *"Your full emails never leave this phone. Only a short, plain summary is sent to ElevenLabs for voice."* Never say "nothing leaves the phone." |
| Consent before reading | Friend explicitly accepts the setup before the app reads any email. He controls the VIP list and can edit it at any time. |
| Revocation | He can revoke the app password from Google Account → Security → App Passwords at any time. Document this in the README and in the app. |
| No secrets in code or repo | IMAP app password and ElevenLabs key stored in `flutter_secure_storage` (Android KeyStore). Never committed. |
| No real email in public artifacts | All screenshots, GIFs, demo videos, shared agent sessions use fake or blurred content. |

---

## 9. The Hand-Over Moment

Before the formal hand-over:
1. Run the 30-day missed list on his phone (with consent). Show him what he already missed.
2. Let him see 1–2 items that are still actionable and can be fixed now.

At hand-over:
1. Install the APK, walk him through setup (5 minutes).
2. Let him add people he cares about to the VIP list himself.
3. Stand back and watch him use it.
4. Record what he says (voice note or written, with permission).

In the write-up:
- Use his real words, not paraphrases.
- If he was surprised, delighted, confused, or indifferent — report it honestly.
- A short, awkward real reaction beats a polished invented one.
- His reaction (or the lack of a strong one) is still part of the story.

---

## 10. The Challenge Context

- **Challenge:** Hacktoberfest Weekend Challenge — "Build for a Friend" (DEV Community, Oct 2026)
- **Deadline:** Mon Oct 5, 2026, 12:29 PM IST (submit by Sun night Oct 4)
- **Judging:** Writing Quality (weighted most heavily), Relevance, Creativity, Technical Execution, Partner Tech Use
- **Prize targets:**
  - Best Use of Gemma — $200 (Gemma is the on-device open-weight core)
  - Best Use of ElevenLabs — $100 (ElevenLabs voices the summaries + narrates the demo video)
- **Rules that matter:**
  - Project must be new (started after Oct 2, 7:30 AM IST — it is ✓)
  - Submissions in English only
  - No pull requests to existing projects
  - AI tools allowed for building
  - List all real teammates' DEV handles

---

## 11. Definition of Done

### Must have (never cut)
- [ ] App reads mail read-only via IMAP EXAMINE on the phone
- [ ] Rules engine flags emails by score (VIP, keywords, deadlines, ignore patterns)
- [ ] Gemma 3 1B-IT rewrites each flagged email as WHAT / DO / BY on-device
- [ ] Deadlines come only from rules engine — never invented by Gemma
- [ ] ElevenLabs audio generated, saved as mp3, playable from widget ▶ button
- [ ] flutter_tts offline fallback works when no audio file
- [ ] Widget shows ≤ 3 items and the `Nothing needs you today ✓` empty state
- [ ] Installed on friend's real Android phone, handed over
- [ ] His real reaction recorded (even if brief)
- [ ] Demo video made with fake/blurred content
- [ ] DEV post published with tags: `devchallenge`, `weekendchallenge`, `hf26challenge`

### Nice to have (cut in this order if behind)
- [ ] 30-day missed list screen
- [ ] Pre-generated ElevenLabs audio for "Nothing needs you today ✓"
- [ ] Urgent amber/red item styling
- [ ] Mark done / not important actions from widget
- [ ] Background WorkManager refresh (fallback: refresh on app open only)
- [ ] Measured latency / RAM numbers in post
