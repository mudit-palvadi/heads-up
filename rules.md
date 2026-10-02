# Heads Up — Rules Engine Specification

> This document defines **everything** about how the app decides which emails matter.
> The rules engine is deterministic and has no AI. Gemma is used only for rewriting, never for judging importance.
> All logic here must be implementable without any network call.

---

## 1. Design Philosophy

- **Gemma decides nothing about importance.** Rules decide. Gemma only rewrites.
- Rules must be **editable by the friend** via the app's VIP Rules screen.
- Rules must be **testable offline** using the fake email fixtures in `test/fixtures/fake_emails/`.
- When in doubt, **prefer false negatives** (miss something) over false positives (spam him with irrelevant items). Three items max means each slot costs the other two.
- **Deadlines come from the rules engine only.** If the rules engine finds no deadline, `deadline = null` and Gemma is told `BY: NONE`. Gemma must not invent a date.

---

## 2. Scoring Algorithm

Each email receives a numeric `score`. Emails with `score >= threshold` (default: 30) are sent to Gemma.

### 2.1 Boost rules (positive scores)

| Condition | Score | Notes |
|---|---|---|
| Sender is in VIP address list (exact match) | +50 | e.g. `dad@gmail.com` |
| Sender domain is in VIP domain list | +30 | e.g. `@university.edu` |
| Custom VIP keyword in subject | +40 | User-defined |
| Action word in **subject** | +40 | See §3 |
| Action word in **body** | +20 | See §3 |
| Deadline date found within 14 days | +30 | See §4 |
| Direct reply to a thread the user participated in | +15 | `In-Reply-To` header set, sender not noreply |
| Sent to user alone (To: has exactly 1 address = user's address) | +10 | Not a CC or BCC |

**VIP address match:**
```dart
bool isVipAddress(String senderAddress, List<String> vipAddresses) {
  return vipAddresses.any(
    (v) => v.toLowerCase() == senderAddress.toLowerCase()
  );
}
```

**VIP domain match:**
```dart
bool isVipDomain(String senderAddress, List<String> vipDomains) {
  final domain = senderAddress.split('@').last.toLowerCase();
  return vipDomains.any(
    (v) => domain == v.toLowerCase() || domain.endsWith('.${v.toLowerCase()}')
  );
}
```

### 2.2 Penalty rules (negative scores)

| Condition | Score | Notes |
|---|---|---|
| `List-Unsubscribe` header present | -100 | Strongest signal for newsletter/bulk mail |
| `Precedence: bulk` or `Precedence: list` header | -80 | Mass mailing |
| Sender matches noreply pattern (see §5) | -60 | Unless VIP or keyword hit |
| Sender or domain is on user's ignore list | -100 | User-configured, absolute |
| `X-Mailer` contains common ESP names (Mailchimp, SendGrid, etc.) | -40 | Marketing platform |
| Subject matches promo pattern (see §5) | -30 | "50% off", "Don't miss out", etc. |

### 2.3 VIP override

If `isVip == true` (sender is in VIP list), the **noreply penalty is waived** and score is always `>= 30` regardless of other penalties. VIP is a hard override for important senders.

```dart
if (isVipAddress || isVipDomain) {
  score = max(score, 30); // Guaranteed to pass threshold
  isVip = true;
}
```

### 2.4 Score threshold and cap

- Default threshold: **30**
- Configurable in settings (advanced, collapsed by default)
- Cap per pipeline run: **5 emails maximum** passed to Gemma. If more than 5 score above threshold, take the top 5 by score.
- If the same email appears in multiple runs (UID already processed), skip it.

---

## 3. Action Words List

These words in the subject line score +40; in the body, +20.
Match is **case-insensitive** and uses whole-word matching where practical.

### English action words (default, bundled in `assets/default_rules.json`)

```json
[
  "deadline", "due", "due date", "last date", "last day",
  "submit", "submission", "upload", "fill",
  "action required", "action needed", "response required",
  "urgent", "urgently", "immediate", "immediately",
  "reminder", "final reminder", "last reminder",
  "confirm", "confirmation", "verify", "verification",
  "reply by", "respond by", "get back",
  "expires", "expiring", "expiry",
  "RSVP", "rsvp",
  "interview", "offer letter", "offer",
  "fee", "fees", "payment", "pay now", "invoice",
  "form", "application", "enroll", "enrolment",
  "incomplete", "pending", "awaiting",
  "please complete", "kindly complete",
  "overdue", "missed"
]
```

### Implementation

```dart
bool containsActionWord(String text, List<String> actionWords) {
  final lower = text.toLowerCase();
  return actionWords.any((word) => lower.contains(word.toLowerCase()));
}
```

---

## 4. Deadline Extraction

Deadlines are extracted by the **rules engine using regex**, not by Gemma.
The extracted deadline string (e.g., "Friday", "Oct 10") is:
1. Passed to Gemma as `Deadline from rules: <value>` in the prompt.
2. Gemma puts it verbatim in `BY:`. It must not change it.
3. Validated after Gemma output: if Gemma's BY doesn't match the rules deadline (or NONE), the output is rejected.

### 4.1 Regex patterns (in priority order)

All patterns are applied to the **full cleaned email text** (not truncated). Resolution is against `message.receivedAt`.

```dart
// Pattern 1: Explicit date phrases
// "by October 10", "by Oct 10", "by 10th October"
RegExp(r'by\s+((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\.?)', caseSensitive: false)

// Pattern 2: Full date (international formats)
// "10/10/2026", "10-10-2026", "2026-10-10"
RegExp(r'\b(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4}|\d{4}[\/\-]\d{2}[\/\-]\d{2})\b')

// Pattern 3: Short month + day
// "Oct 10", "October 10", "10 Oct"
RegExp(r'\b((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\.?)\b', caseSensitive: false)

// Pattern 4: Relative weekday
// "by Friday", "before Monday", "next Tuesday"
RegExp(r'\b(by|before|until|on)\s+(this\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b', caseSensitive: false)

// Pattern 5: Named relative dates
// "by tonight", "by tomorrow", "by end of day", "by EOD"
RegExp(r'\b(by|before|until)\s+(tonight|today|tomorrow|eod|end of day|end of week|this week)\b', caseSensitive: false)

// Pattern 6: Duration
// "within 3 days", "in 2 days", "within 24 hours"
RegExp(r'\bwithin\s+(\d+)\s+(hours?|days?|weeks?)\b', caseSensitive: false)
```

### 4.2 Resolution logic

```dart
DateTime? resolveDeadline(RegExpMatch match, String pattern, DateTime receivedAt) {
  switch (pattern) {
    case 'weekday':
      final weekday = _parseWeekday(match.group(0)!);
      return _nextWeekday(receivedAt, weekday);
    case 'tonight':
      return DateTime(receivedAt.year, receivedAt.month, receivedAt.day, 23, 59);
    case 'tomorrow':
      return receivedAt.add(const Duration(days: 1));
    case 'duration_days':
      final n = int.parse(match.group(1)!);
      return receivedAt.add(Duration(days: n));
    case 'duration_hours':
      final n = int.parse(match.group(1)!);
      return receivedAt.add(Duration(hours: n));
    // ... etc.
  }
  return null;
}
```

### 4.3 Deadline window filter

Only report a deadline if it falls within the next **14 days** of `now` (not `receivedAt`).
A deadline that already passed gets `+0` boost but is still reported if it was recent (within last 2 days) — it may be "still fixable" for the missed list.

### 4.4 Deadline string formatting

Return a **human-readable string** for Gemma's prompt and widget display:
- Same day → `"today"`
- +1 day → `"tomorrow"`
- Same week → `"Friday"` (weekday name)
- Beyond this week → `"Oct 10"` (month + day, no year)
- Past deadline (missed list) → `"was Oct 5"` (flag in UI as red)

---

## 5. Ignore / Penalty Patterns

### 5.1 Noreply sender patterns

```dart
const _noReplyPatterns = [
  'noreply@', 'no-reply@', 'donotreply@', 'do-not-reply@',
  'notifications@', 'mailer@', 'bounce@', 'auto@', 'automated@',
];

bool isNoReply(String address) {
  final lower = address.toLowerCase();
  return _noReplyPatterns.any((p) => lower.startsWith(p) || lower.contains(p));
}
```

### 5.2 Promotional subject patterns

```dart
const _promoSubjectPatterns = [
  r'\d+%\s*off',          // "50% off"
  r'don.t miss',
  r'limited time',
  r'special offer',
  r'buy now',
  r'shop now',
  r'sale ends',
  r'flash sale',
  r'exclusive deal',
  r'save \$?\d+',
];
```

### 5.3 Marketing ESP X-Mailer headers

```dart
const _espMarkers = [
  'mailchimp', 'sendgrid', 'hubspot', 'klaviyo', 'constant contact',
  'campaignmonitor', 'mailerlite', 'brevo', 'sendinblue',
];
```

### 5.4 User ignore list (editable in app)

A list of exact email addresses or domain patterns. An email from an ignored sender always scores ≤ -100 (below threshold), even if it contains action words.

Example user-configured ignores: `newsletter@zomato.com`, `alerts.paytm.com`

---

## 6. Rules Config Format

Bundled default: `assets/default_rules.json`
User overrides: stored in `shared_preferences` key `user_rules_json`

```json
{
  "version": 1,
  "actionWords": [
    "deadline", "due", "submit", "urgent", "reminder",
    "confirm", "expires", "RSVP", "interview", "fee", "payment",
    "form", "action required", "reply by", "last date"
  ],
  "vipAddresses": [],
  "vipDomains": [],
  "vipKeywords": [],
  "ignoreAddresses": [],
  "ignoreDomains": [],
  "scoreThreshold": 30,
  "deadlineWindowDays": 14,
  "maxItemsPerRun": 5
}
```

Rules are merged at runtime: default config provides the base, user overrides append/replace.

---

## 7. RulesEngine API

```dart
class RulesEngine {
  final RulesConfig config;

  RulesEngine(this.config);

  /// Score a single email. Returns a MailItem with score, reasons, deadline, isVip set.
  MailItem score(MimeMessage msg, String cleanedBody) {
    var score = 0;
    final reasons = <String>[];
    
    final sender = msg.fromEmail ?? '';
    final subject = msg.decodeSubject() ?? '';
    final headers = msg.headers;
    
    // VIP check (must happen first — affects penalty logic)
    final isVipAddr = isVipAddress(sender, config.vipAddresses);
    final isVipDom  = isVipDomain(sender, config.vipDomains);
    final isVip = isVipAddr || isVipDom;
    
    if (isVipAddr) { score += 50; reasons.add('VIP sender'); }
    if (isVipDom)  { score += 30; reasons.add('VIP domain'); }
    
    // Ignore list (absolute)
    if (_isIgnored(sender, config)) {
      return MailItem.ignored(msg); // score = -100, not passed to Gemma
    }
    
    // Penalties (before boosters, so VIP override can correct)
    if (headers['list-unsubscribe'] != null) {
      score -= 100; reasons.add('newsletter');
    }
    final precedence = headers['precedence']?.value?.toLowerCase() ?? '';
    if (precedence == 'bulk' || precedence == 'list') {
      score -= 80; reasons.add('bulk mail');
    }
    if (!isVip && isNoReply(sender)) {
      score -= 60; reasons.add('noreply sender');
    }
    if (_isPromoSubject(subject)) {
      score -= 30; reasons.add('promo subject');
    }
    
    // Action words
    if (containsActionWord(subject, config.actionWords)) {
      score += 40; reasons.add('action word in subject');
    } else if (containsActionWord(cleanedBody, config.actionWords)) {
      score += 20; reasons.add('action word in body');
    }
    
    // Deadline
    final deadline = extractDeadline(cleanedBody + ' ' + subject, msg.receivedDate!);
    if (deadline != null) {
      final daysAway = deadline.difference(DateTime.now()).inDays;
      if (daysAway >= -2 && daysAway <= config.deadlineWindowDays) {
        score += 30; reasons.add('deadline within window');
      }
    }
    
    // Reply detection
    if (headers['in-reply-to'] != null && !isNoReply(sender)) {
      score += 15; reasons.add('direct reply');
    }
    
    // Single recipient
    if (_isSingleRecipient(msg)) {
      score += 10; reasons.add('sent to you alone');
    }
    
    // VIP override: always pass threshold
    if (isVip) score = max(score, 30);
    
    return MailItem(
      id: '${msg.uid}_INBOX',
      receivedAt: msg.receivedDate!,
      senderName: msg.fromName ?? sender,
      senderAddress: sender,
      subject: msg.decodeSubject() ?? '',
      score: score,
      reasons: reasons,
      deadline: deadline,
      isVip: isVip,
      status: ItemStatus.fresh,
      audioSource: AudioSource.none,
      processedAt: DateTime.now(),
    );
  }
}
```

---

## 8. Test Fixtures

20 synthetic email files live in `test/fixtures/fake_emails/`. They contain **no real email content**. Each is a plain text file in the format:

```
From: sender@example.com
To: friend@gmail.com
Subject: [subject line]
Date: [date]
In-Reply-To: [optional]
List-Unsubscribe: [optional]

[body text]
```

| File | Expected score | Should pass threshold? | Expected deadline |
|---|---|---|---|
| `01_college_form_deadline.txt` | ≥ 70 | ✅ | "Oct 10" |
| `02_friend_yes_no.txt` | ≥ 30 | ✅ | "tonight" |
| `03_bank_payment_due.txt` | ≥ 60 | ✅ | "Friday" |
| `04_newsletter_promo.txt` | ≤ -60 | ❌ | null |
| `05_otp.txt` | ≤ 0 | ❌ | null |
| `06_calendar_invite.txt` | ≥ 30 | ✅ | next meeting date |
| `07_long_thread.txt` | ≥ 15 | Depends on VIP | null |
| `08_html_heavy.txt` | ≤ -60 | ❌ | null |
| `09_no_deadline.txt` | ≥ 10 | ❌ or borderline | null |
| `10_tricky_date.txt` | ≥ 50 | ✅ | "within 3 days" → resolved |
| `11_manager_reply.txt` | ≥ 65 | ✅ (VIP) | null |
| `12_interview_offer.txt` | ≥ 70 | ✅ | "next Monday" |
| `13_noreply_important.txt` | ≥ 10 | Borderline | null |
| `14_non_english_line.txt` | ≥ 30 | ✅ | optional |
| `15_past_deadline.txt` | ≥ 30 | ✅ (within -2 days) | "was Oct 5" |
| `16_fee_payment.txt` | ≥ 60 | ✅ | "tomorrow" |
| `17_bulk_important.txt` | ≥ 20 | Borderline (VIP overrides bulk penalty) | null |
| `18_short_reply.txt` | ≥ 65 | ✅ (VIP) | null |
| `19_unsubscribe_only.txt` | ≤ -100 | ❌ | null |
| `20_form_submission.txt` | ≥ 70 | ✅ | "Oct 8" |

---

## 9. Unit Test Coverage Required

```dart
// test/rules_engine_test.dart

group('Deadline extraction', () {
  test('extracts ISO date', ...);
  test('extracts "by Friday"', ...);
  test('extracts "by tonight"', ...);
  test('extracts "within 3 days"', ...);
  test('extracts "Oct 10"', ...);
  test('returns null when no deadline', ...);
  test('ignores deadline outside 14-day window', ...);
  test('accepts past deadline within 2 days (missed list)', ...);
});

group('VIP matching', () {
  test('exact address match', ...);
  test('domain match with subdomain', ...);
  test('VIP overrides noreply penalty', ...);
  test('VIP overrides bulk penalty to threshold', ...);
});

group('Ignore patterns', () {
  test('noreply@ prefix matched', ...);
  test('user ignore list absolute', ...);
  test('promo subject matched', ...);
});

group('Scoring', () {
  test('newsletter scores below threshold', ...);
  test('form deadline email scores above threshold', ...);
  test('all 20 fixtures match expected pass/fail', ...);
});
```
