/// Read-only IMAP access to Gmail.
///
/// Specification: architecture.md §6.1, prd.md §8.
///
/// # Why this file is paranoid about read-only access
///
/// `prd.md` §8 is a hard constraint, not a preference: the app "uses IMAP
/// EXAMINE (not SELECT)" and never marks anything read. If this code were to
/// get that wrong the consequence is not a crash — it is real emails silently
/// showing up as read in a real person's inbox, which only they can undo.
///
/// So correctness here is defended in three independent layers:
///
/// 1. **Only EXAMINE is reachable.** `selectMailbox` is never called; a unit
///    test greps `lib/` and fails if it ever appears
///    (`test/read_only_guard_test.dart`).
/// 2. **BODY.PEEK, never BODY.** The `PEEK` keyword is what stops the server
///    setting `\Seen`. Plain `BODY[]` would silently mark messages read.
/// 3. **Verify after the fact.** [assertNoMessagesMarkedRead] re-reads the
///    flags of everything just fetched and throws if any of them came back
///    `\Seen`. A bug in layers 1–2 therefore still cannot reach the database.
///
/// [probeFlags] exists so the read-only claim can be *measured* rather than
/// merely asserted: it fetches FLAGS only — which under RFC 3501 cannot set
/// `\Seen` — so a before/after diff proves the EXAMINE path is inert.
library;

import 'dart:async';

// `ImapException` comes through the barrel's imap.dart export.
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:heads_up/services/rules_engine.dart';

/// Messages larger than this are skipped: they are almost always attachments,
/// and the pipeline only ever wants the text body.
const int kMaxMessageBytes = 500000;

/// The one fetch definition this app is allowed to use.
///
/// **`BODY.PEEK[]` is load-bearing.** `BODY[]` would mark messages read.
///
/// **The parentheses are load-bearing too.** `enough_mail` documents its
/// criteria in this parenthesised form (`'(ENVELOPE BODY.PEEK[])'`, see
/// `ImapClient.fetchRecentMessages`) and its own high-level API always emits
/// them. Without them Gmail rejects a multi-item fetch with
/// `BAD Could not parse command` — found on the fourth live Spike B run. A
/// single unparenthesised item happens to parse, which is why the flags-only
/// probe worked while this one did not.
const String kReadOnlyFetch = '(BODY.PEEK[] ENVELOPE FLAGS RFC822.SIZE)';

/// Fetch data items for a flags-only probe.
///
/// **`UID` is deliberately NOT requested.** RFC 3501 §6.4.8 does not list it as
/// a FETCH data item — the server includes the UID automatically in every
/// `UID FETCH` response, so asking for it as well makes Gmail answer
/// `BAD Could not parse command`. Found on the third live Spike B run.
///
/// `enough_mail` parses the UID out of the response regardless of what was
/// requested (`FetchParser._parseFetch` handles `case 'UID'` on the response
/// side), so nothing is lost by leaving it out.
const String kFlagsOnlyFetch = '(FLAGS)';

/// Upper bound on the TCP/TLS connect and on the login exchange.
///
/// Deliberately generous: this runs on a phone over mobile data, and a
/// premature timeout would fail a connection that was about to succeed. It
/// exists only so that a server which accepts a socket and then never speaks
/// cannot leave the UI spinning with no way out — a failure that actually
/// happened on the first live run of Spike B.
const Duration kConnectTimeout = Duration(seconds: 30);

/// Renders the IMAP command [MailService] would send, for error messages.
///
/// Three of the four live Spike B failures were only diagnosable once the panel
/// printed the server's reply, and knowing *which* command drew it turned two
/// rounds of guessing into one screenshot. Cheap enough to always include.
String describeFetch(String sequence, String definition) =>
    'UID FETCH $sequence $definition';

/// Why a fetch could not be completed, in terms the status screen can show.
enum MailFailure {
  /// Could not reach the server, or TLS negotiation failed.
  connection,

  /// IMAP rejected the username or app password. Never retry silently.
  authentication,

  /// The server returned an alert (e.g. account locked, too many attempts).
  accountNeedsAttention,

  /// Anything else.
  unknown,
}

class MailException implements Exception {
  const MailException(this.failure, this.message);

  final MailFailure failure;
  final String message;

  /// Copy shown on the status screen (prd.md §6.2 "clear message + suggested fix").
  String get userFacing => switch (failure) {
        MailFailure.connection =>
          "Couldn't reach your mail. Check the phone has internet.",
        MailFailure.authentication =>
          'That app password was rejected. Generate a new one and re-enter it.',
        MailFailure.accountNeedsAttention =>
          'Your mail account needs attention. Open Gmail on the web to check.',
        MailFailure.unknown => 'Something went wrong reading your mail.',
      };

  @override
  String toString() => 'MailException($failure): $message';
}

/// One fetched message, reduced to what the rules engine needs.
class FetchedMail {
  const FetchedMail({
    required this.uid,
    required this.receivedAt,
    required this.senderAddress,
    required this.senderName,
    required this.subject,
    required this.plainText,
    required this.htmlText,
    required this.toAddresses,
    required this.ccAddresses,
    required this.listUnsubscribe,
    required this.precedence,
    required this.xMailer,
    required this.inReplyTo,
  });

  final int uid;
  final DateTime receivedAt;
  final String senderAddress;
  final String senderName;
  final String subject;
  final String plainText;
  final String htmlText;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String? listUnsubscribe;
  final String? precedence;
  final String? xMailer;
  final String? inReplyTo;

  /// Converts to the rules engine's input shape.
  ///
  /// Everything is lower-cased here so the engine never has to wonder whether
  /// a header value was normalised upstream.
  EmailFacts toFacts(String cleanedBody) => EmailFacts(
        uid: uid,
        // Falls back to "now" when the Date header is missing or unparseable;
        // deadline resolution needs a timestamp and this must not be fatal.
        receivedAt: receivedAt,
        senderAddress: senderAddress,
        senderName: senderName,
        subject: subject,
        body: cleanedBody,
        listUnsubscribe: listUnsubscribe,
        precedence: precedence,
        xMailer: xMailer,
        inReplyTo: inReplyTo,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
      );
}

/// A snapshot of which messages are currently marked read.
///
/// Used to *prove* nothing changed (prd.md §8).
class FlagSnapshot {
  const FlagSnapshot(this.seenUids, {this.examined = 0});

  /// UIDs that carry `\Seen`.
  final Set<int> seenUids;

  /// How many messages the probe actually looked at.
  ///
  /// Needed because "no message became read" over *zero* messages is not a
  /// pass, it is an absence of evidence. Without this the proof reported
  /// `PASS — examined 0 messages` on a first successful run and would have
  /// claimed verification it never performed.
  final int examined;

  int get count => seenUids.length;

  /// True when the probe covered nothing, so a zero diff proves nothing.
  bool get isEmptyCoverage => examined == 0;

  /// UIDs that are marked read in [after] but were not in this snapshot.
  Set<int> newlySeen(FlagSnapshot after) =>
      after.seenUids.difference(seenUids);
}

class MailService {
  MailService({ImapClient? client}) : _client = client ?? ImapClient();

  final ImapClient _client;
  bool _connected = false;

  bool get isConnected => _connected;

  /// `EXAMINE` reports the mailbox as read-only; Gmail and most servers also
  /// report a `[READ-ONLY]` capability when they refuse writes.
  bool? _lastExamineWasReadOnly;

  /// Whether the last EXAMINE was confirmed read-only, for diagnostics.
  bool? get lastExamineWasReadOnly => _lastExamineWasReadOnly;

  Future<void> connect({
    required String host,
    required int port,
    required String user,
    required String password,
    Duration timeout = kConnectTimeout,
  }) async {
    try {
      // enough_mail's connectToServer bounds the socket open (20s by default)
      // but `login` has no timeout of its own — it waits on a server response
      // indefinitely. A TLS connection that is accepted and then goes quiet
      // would hang the UI forever, so the pair is bounded together here.
      await _client
          .connectToServer(host, port, isSecure: true)
          .timeout(timeout);
      await _client.login(user, password).timeout(timeout);
      _connected = true;
    } on ImapException catch (e) {
      throw _translate(e);
    } on TimeoutException {
      throw const MailException(
        MailFailure.connection,
        'Timed out waiting for the mail server to answer.',
      );
    } catch (e) {
      throw MailException(MailFailure.connection, e.toString());
    }
  }

  Future<void> disconnect() async {
    if (!_connected) return;
    try {
      await _client.logout();
    } catch (_) {
      // Nothing useful to do; the socket is going away regardless.
    }
    _connected = false;
  }

  /// Reads the INBOX with `EXAMINE`, which RFC 3501 defines as read-only.
  ///
  /// Deliberately never calls `selectMailbox`/`selectInbox`.
  Future<Mailbox> examineInbox() async {
    _requireConnection();
    try {
      final mailbox = await _client.examineMailbox(_inbox());
      _lastExamineWasReadOnly = mailbox.isReadWrite ? false : true;
      return mailbox;
    } on ImapException catch (e) {
      throw _translate(e);
    }
  }

  /// UIDVALIDITY for the INBOX, needed to detect a server-side mailbox rebuild.
  Future<int> inboxUidValidity() async {
    final mailbox = await examineInbox();
    return mailbox.uidValidity ?? 0;
  }

  /// Fetches new messages since [lastUid], newest-last, bodies included.
  ///
  /// Read-only in three ways: `EXAMINE` to open, `BODY.PEEK[]` to read, and
  /// [assertNoMessagesMarkedRead] to verify afterwards.
  Future<List<FetchedMail>> fetchNew({
    required int lastUid,
    int take = 20,
  }) async {
    _requireConnection();
    final mailbox = await examineInbox();

    if (mailbox.messagesExists == 0) return const [];

    // If the server rebuilt the mailbox every UID we remember is meaningless,
    // so restart from scratch rather than skipping the entire inbox
    // (architecture.md §6.1).
    //
    // `take` was silently ignored until now, so the first run of a fresh
    // install asked for `1:*` — the entire mailbox. Bounded to the newest
    // [take] messages, which is also what the widget wants.
    final newest = await newestUid();
    final start =
        lastUid > 0 ? lastUid + 1 : (newest - take + 1).clamp(1, newest);
    final sequence = MessageSequence()..addRange(start, newest);

    try {
      final result = await _client.uidFetchMessages(sequence, kReadOnlyFetch);
      final messages = result.messages
          .where((m) => (m.size ?? 0) < kMaxMessageBytes)
          .toList();

      assertNoMessagesMarkedRead(messages);

      return messages.map(_toFetchedMail).toList();
    } on ImapException catch (e) {
      final translated = _translate(e);
      throw MailException(
        translated.failure,
        '${translated.message}\n'
            'Sent: ${describeFetch('$start:$newest', kReadOnlyFetch)}',
      );
    }
  }
  Future<int> newestUid() async {
    _requireConnection();
    final mailbox = await examineInbox();
    if (mailbox.messagesExists == 0) return 0;

    final sequence = MessageSequence()..addLast();
    try {
      final result = await _client.uidFetchMessages(sequence, kFlagsOnlyFetch);
      assertNoMessagesMarkedRead(result.messages);
      final uids = result.messages.map((m) => m.uid ?? 0).toList();
      return uids.isEmpty ? 0 : uids.reduce((a, b) => a > b ? a : b);
    } on ImapException catch (e) {
      throw _translate(e);
    }
  }

  /// Snapshots which messages are marked read, without touching any body.
  ///
  /// Fetching `UID FLAGS` cannot set `\Seen` under any circumstances, so this is
  /// safe to run against a real account. Comparing two snapshots is the
  /// empirical proof that the EXAMINE path is inert (prd.md §8).
  Future<FlagSnapshot> probeFlags({int take = 20}) async {
    _requireConnection();
    final mailbox = await examineInbox();
    if (mailbox.messagesExists == 0) return const FlagSnapshot({}, examined: 0);

    // The range must be expressed in UIDs, not sequence positions.
    //
    // This used to be built from `mailbox.messagesExists`, which is a *count*,
    // and then sent as `UID FETCH <count-take>:<count>`. `UID FETCH` treats
    // its range as UIDs, and on any mailbox that has been used for a while the
    // UIDs run far ahead of the message count (deleted mail, imports). So the
    // probe asked for UIDs 1..20 on an account whose UIDs were in the tens of
    // thousands, matched nothing, and the panel reported
    // `PASS — examined 0 messages` on a mailbox that had mail in it.
    //
    // Resolve the newest UID first, then step back [take] from it. Bounded, and
    // correct regardless of how the mailbox has been used.
    final newest = await newestUid();
    if (newest == 0) return const FlagSnapshot({}, examined: 0);

    final start = (newest - take + 1).clamp(1, newest);
    final sequence = MessageSequence()..addRange(start, newest);

    try {
      final result = await _client.uidFetchMessages(sequence, kFlagsOnlyFetch);
      return FlagSnapshot(
        result.messages
            .where((m) => m.isSeen)
            .map((m) => m.uid ?? 0)
            .toSet(),
        // How many the probe actually covered, as opposed to how many carried
        // \Seen. These differ on a mostly-unread mailbox, and conflating them
        // is what produced "PASS — examined 0 messages".
        examined: result.messages.length,
      );
    } on ImapException catch (e) {
      final translated = _translate(e);
      throw MailException(
        translated.failure,
        '${translated.message}\n'
            'Sent: ${describeFetch('$start:$newest', kFlagsOnlyFetch)}',
      );
    }
  }

  /// Throws if any freshly fetched message came back marked read.
  ///
  /// This is the safety net for the whole module. If the fetch definition is
  /// ever changed from `BODY.PEEK[]` to `BODY[]` by mistake, this fires instead
  /// of quietly marking a real inbox.
  static void assertNoMessagesMarkedRead(List<MimeMessage> messages) {
    final offenders =
        messages.where((m) => m.isSeen).map((m) => m.uid ?? 0).toList();
    if (offenders.isEmpty) return;
    throw MailException(
      MailFailure.unknown,
      'Read-only violation: server marked ${offenders.length} message(s) '
      'read (UIDs $offenders). Nothing was stored. This is a bug — the fetch '
      'must use BODY.PEEK[].',
    );
  }

  FetchedMail _toFetchedMail(MimeMessage msg) {
    final from = msg.from?.firstOrNull;
    return FetchedMail(
      uid: msg.uid ?? 0,
      // `MimeMessage.date` does not exist in 2.1.7 — the field belongs to
      // `Envelope`. `decodeDate()` parses the Date header.
      receivedAt: msg.decodeDate() ?? DateTime.now(),
      senderAddress: from?.email ?? '',
      senderName: from?.personalName ?? from?.email ?? '',
      subject: msg.decodeSubject() ?? '',
      plainText: msg.decodeTextPlainPart() ?? '',
      htmlText: msg.decodeTextHtmlPart() ?? '',
      toAddresses: (msg.to ?? const [])
          .map((a) => a.email)
          .where((e) => e.isNotEmpty)
          .toList(),
      ccAddresses: (msg.cc ?? const [])
          .map((a) => a.email)
          .where((e) => e.isNotEmpty)
          .toList(),
      listUnsubscribe: _header(msg, 'list-unsubscribe'),
      precedence: _header(msg, 'precedence'),
      xMailer: _header(msg, 'x-mailer'),
      inReplyTo: _header(msg, 'in-reply-to'),
    );
  }

  /// `headers` is nullable on `MimeMessage`, so this cannot assume presence.
  static String? _header(MimeMessage msg, String name) {
    final headers = msg.headers;
    if (headers == null) return null;
    for (final header in headers) {
      if (header.lowerCaseName == name) {
        final value = header.value;
        if (value == null || value.isEmpty) return null;
        return value;
      }
    }
    return null;
  }

  /// The INBOX mailbox handle.
///
/// `enough_mail` 2.1.7 has no `Mailbox.inbox` constant, so it is constructed
/// explicitly. `architecture.md` §6.1 calls `examineMailboxByPath('INBOX')`,
/// which does not exist in this version either — hence [examineInbox].
///
/// **`flags` must be a growable list.** The `Mailbox` constructor mutates it:
///
/// ```dart
/// if (!isInbox && name.toLowerCase() == 'inbox') {
///   flags.add(MailboxFlag.inbox);
/// }
/// ```
///
/// and `isInbox` is itself `hasFlag(MailboxFlag.inbox)`. So an empty list always
/// fails that guard, the branch always runs, and a `const` list throws
/// "cannot add to an unmodifiable list" — every time, not intermittently. That
/// made every IMAP read path (`probeFlags`, `fetchNew`, `newestUid`,
/// `inboxUidValidity`) fail before it could issue a single command.
///
/// Cost of finding this out: the first live run of Spike B. A `const` here is
/// exactly the kind of tidy-up that looks harmless, so the reason is recorded
/// here and pinned by a test.
static Mailbox _inbox() => Mailbox(
      encodedName: 'INBOX',
      encodedPath: 'INBOX',
      flags: <MailboxFlag>[],
      pathSeparator: '/',
    );

  /// Exposed only so a test can pin [inboxDescriptor]'s behaviour. It is the
  /// exact value handed to `examineMailbox`, and constructing it must not throw.
  @visibleForTesting
  static Mailbox get inboxForTest => _inbox();

  void _requireConnection() {
    if (!_connected) {
      throw const MailException(
        MailFailure.connection,
        'Not connected. Call connect() first.',
      );
    }
  }

  MailException _translate(ImapException e) {
    final text = e.toString().toLowerCase();

    // Auth failures must never be retried silently — the user has to fix the
    // app password (architecture.md §6.1).
    if (text.contains('authentication') ||
        text.contains('login') ||
        text.contains('invalid credentials')) {
      return MailException(MailFailure.authentication, e.toString());
    }
    if (text.contains('alert')) {
      return MailException(MailFailure.accountNeedsAttention, e.toString());
    }
    if (text.contains('socket') ||
        text.contains('host lookup') ||
        text.contains('connection')) {
      return MailException(MailFailure.connection, e.toString());
    }
    return MailException(MailFailure.unknown, e.toString());
  }
}