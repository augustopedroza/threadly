/// Domain model for the "organizing" layer.
///
/// Deliberately platform-agnostic: the Android data source builds these from
/// the SMS/MMS content provider, and a future iOS data source can build the
/// same shapes from manual imports. The UI only ever talks to these types.
library;

/// Digits-only, last 10 (tolerant of formatting and country-code prefixes).
/// The canonical key for matching a phone number across SMS, categories, and
/// contacts.
String normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}

/// A single message inside a thread.
class Message {
  final String body;
  final String address; // sender/recipient phone number ("" if unknown)
  final DateTime date;
  final bool isIncoming;

  const Message({
    required this.body,
    required this.address,
    required this.date,
    required this.isIncoming,
  });
}

/// A conversation, identified by its set of participants.
///
/// A thread with more than one *other* participant is treated as a group text.
class MessageThread {
  /// Distinct participant addresses (phone numbers), excluding the device owner.
  final List<String> participants;
  final List<Message> messages;

  MessageThread({required this.participants, required this.messages});

  bool get isGroup => participants.length > 1;

  Message? get latest => messages.isEmpty ? null : messages.first;

  /// Human-readable title: the participant list, or the lone number.
  String get title =>
      participants.isEmpty ? 'Unknown' : participants.join(', ');

  /// A stable key for grouping/deduping threads by participant set.
  String get participantKey {
    final sorted = [...participants]..sort();
    return sorted.join('|');
  }
}
