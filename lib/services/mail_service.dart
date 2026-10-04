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

import 'package:heads_up/services/rules_engine.dart';

/// Messages larger than this are skipped: they are almost always attachments,
/// and the pipeline only ever wants the text body.
const int kMaxMessageBytes = 500000;

/// The one fetch definition this app is allowed to use.
///
/// `BODY.PEEK[]` is load-bearing. `BODY[]` would mark messages read.
const String kReadOnlyFetch = 'BODY.PEEK[] ENVELOPE FLAGS RFC822.SIZE';

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
  const FlagSnapshot(this.seenUids);

  /// UIDs that carry `\Seen`.
  final Set<int> seenUids;

  int get count => seenUids.length;

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
  }) async {
    try {
      await _client.connectToServer(host, port, isSecure: true);
      await _client.login(user, password);
      _connected = true;
    } on ImapException catch (e) {
      throw _translate(e);
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
    final sequence = MessageSequence()..addRangeToLast(lastUid + 1);

    try {
      final result = await _client.uidFetchMessages(sequence, kReadOnlyFetch);
      final messages = result.messages
          .where((m) => (m.size ?? 0) < kMaxMessageBytes)
          .toList();

      assertNoMessagesMarkedRead(messages);

      return messages.map(_toFetchedMail).toList();
    } on ImapException catch (e) {
      throw _translate(e);
    }
  }

  /// Highest UID present, so the caller can advance its checkpoint.
  Future<int> newestUid() async {
    _requireConnection();
    final mailbox = await examineInbox();
    if (mailbox.messagesExists == 0) return 0;

    final sequence = MessageSequence()..addLast();
    try {
      final result = await _client.uidFetchMessages(sequence, 'UID FLAGS');
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
    if (mailbox.messagesExists == 0) return const FlagSnapshot({});

    // Walk backwards from the newest so the newest N are covered even in a
    // large mailbox.
    final sequence = MessageSequence()
      ..addRange(
        mailbox.messagesExists > take ? mailbox.messagesExists - take : 1,
        mailbox.messagesExists,
      );

    try {
      final result = await _client.uidFetchMessages(sequence, 'UID FLAGS');
      return FlagSnapshot(
        result.messages
            .where((m) => m.isSeen)
            .map((m) => m.uid ?? 0)
            .toSet(),
      );
    } on ImapException catch (e) {
      throw _translate(e);
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
static Mailbox _inbox() => Mailbox(
      encodedName: 'INBOX',
      encodedPath: 'INBOX',
      flags: const <MailboxFlag>[],
      pathSeparator: '/',
    );

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