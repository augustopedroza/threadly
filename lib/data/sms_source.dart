import 'package:another_telephony/telephony.dart';

import '../models/thread.dart';

/// Platform-agnostic contract for reading and sending texts.
///
/// Android implements this fully. A future iOS implementation will throw on
/// [loadThreads] (Apple exposes no read API) and route [sendSms] through the
/// system compose sheet / `sms:` deep link instead.
abstract class SmsSource {
  /// Whether this platform can list existing threads at all.
  bool get canReadThreads;

  /// Load conversations, newest message first within each thread.
  Future<List<MessageThread>> loadThreads();

  /// Send a text directly (Android: SmsManager). Throws if unsupported.
  Future<void> sendSms({required String to, required String body});
}

/// Android data source backed by the SMS content provider.
///
/// Known sharp edge (documented in the plan): this reads the **SMS** provider
/// only, so group *MMS* recipient lists are not fully reconstructed here.
/// Threads are grouped by the provider's THREAD_ID; participants are derived
/// from the addresses we can see. Reliable group-MMS participants is the
/// Phase 0 decision gate — if needed, escalate to a custom MMS content-provider
/// query or becoming the default SMS app.
class AndroidSmsSource implements SmsSource {
  final Telephony _telephony = Telephony.instance;

  @override
  bool get canReadThreads => true;

  @override
  Future<List<MessageThread>> loadThreads() async {
    final inbox = await _telephony.getInboxSms(
      columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE, SmsColumn.THREAD_ID],
      sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
    );
    final sent = await _telephony.getSentSms(
      columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE, SmsColumn.THREAD_ID],
      sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
    );

    // Bucket every message by THREAD_ID so a conversation stays together.
    final byThread = <int, List<_Raw>>{};
    void bucket(List<SmsMessage> msgs, bool incoming) {
      for (final m in msgs) {
        final tid = m.threadId ?? -1;
        (byThread[tid] ??= []).add(_Raw(
          body: m.body ?? '',
          address: m.address ?? '',
          date: DateTime.fromMillisecondsSinceEpoch(m.date ?? 0),
          isIncoming: incoming,
        ));
      }
    }

    bucket(inbox, true);
    bucket(sent, false);

    final threads = <MessageThread>[];
    for (final raws in byThread.values) {
      raws.sort((a, b) => b.date.compareTo(a.date)); // newest first
      // Participants: distinct addresses from *incoming* messages (the others).
      final participants = <String>{
        for (final r in raws)
          if (r.isIncoming && r.address.isNotEmpty) r.address,
      }.toList();
      threads.add(MessageThread(
        participants: participants,
        messages: [
          for (final r in raws)
            Message(
              body: r.body,
              address: r.address,
              date: r.date,
              isIncoming: r.isIncoming,
            ),
        ],
      ));
    }

    // Conversations ordered by most-recent activity.
    threads.sort((a, b) {
      final ad = a.latest?.date ?? DateTime(0);
      final bd = b.latest?.date ?? DateTime(0);
      return bd.compareTo(ad);
    });
    return threads;
  }

  @override
  Future<void> sendSms({required String to, required String body}) async {
    await _telephony.sendSms(to: to, message: body);
  }
}

class _Raw {
  final String body;
  final String address;
  final DateTime date;
  final bool isIncoming;
  _Raw({
    required this.body,
    required this.address,
    required this.date,
    required this.isIncoming,
  });
}
