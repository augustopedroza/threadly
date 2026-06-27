import 'package:flutter_contacts/flutter_contacts.dart';

import '../models/thread.dart';

/// An immutable read snapshot mapping phone numbers to saved contact names, so
/// the UI can show "Olivia Bennett" instead of a raw number. Built by
/// [ContactsService.load]. Read-only: the app never writes to Contacts.
class ContactsSnapshot {
  /// True if contacts permission was granted (even if the address book is empty).
  final bool available;

  /// normalized phone -> contact display name.
  final Map<String, String> _phoneToName;

  const ContactsSnapshot({
    required this.available,
    required Map<String, String> phoneToName,
  }) : _phoneToName = phoneToName;

  static const empty = ContactsSnapshot(available: false, phoneToName: {});

  /// The saved contact name for [phone], or null if the number isn't a contact.
  String? nameForPhone(String phone) => _phoneToName[normalizePhone(phone)];

  /// A display title for [thread]: each participant shown as their contact name
  /// where known, otherwise the raw number. Falls back to the thread's own
  /// title (e.g. "Unknown") when there are no participants.
  String titleFor(MessageThread thread) {
    // A source-provided title (e.g. a bridge room name) wins over participant
    // resolution — the bridge already knows contact names we may not have.
    if (thread.sourceTitle != null && thread.sourceTitle!.isNotEmpty) {
      return thread.sourceTitle!;
    }
    if (thread.participants.isEmpty) return thread.title;
    return thread.participants.map((p) => nameForPhone(p) ?? p).join(', ');
  }
}

/// Reads saved contact names via flutter_contacts (read-only).
class ContactsService {
  Future<ContactsSnapshot> load() async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return ContactsSnapshot.empty;
    }

    final contacts =
        await FlutterContacts.getAll(properties: {ContactProperty.phone});

    final phoneToName = <String, String>{};
    for (final c in contacts) {
      final displayName = (c.displayName ?? '').trim();
      if (displayName.isEmpty) continue;
      for (final phone in c.phones) {
        final key = normalizePhone(phone.number);
        if (key.isEmpty) continue;
        phoneToName[key] = displayName;
      }
    }

    return ContactsSnapshot(available: true, phoneToName: phoneToName);
  }
}
