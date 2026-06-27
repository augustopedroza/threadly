import 'package:flutter_contacts/flutter_contacts.dart';

import '../models/thread.dart';

/// A Contacts "label" — an Android contact group, synced to Google Contacts.
class ContactLabel {
  final String id;
  final String name;
  const ContactLabel({required this.id, required this.name});
}

/// An immutable read snapshot of Contacts labels + the data needed to display
/// and assign them. Built by [ContactsLabelService.load].
class ContactsSnapshot {
  /// True if contacts permission was granted (even if the address book is empty).
  final bool available;
  final List<ContactLabel> labels;

  /// normalized phone -> label names it belongs to (for chips / filtering).
  final Map<String, Set<String>> _phoneToLabelNames;

  /// normalized phone -> contact id (for assignment).
  final Map<String, String> _phoneToContactId;

  /// normalized phone -> contact display name (for showing names over numbers).
  final Map<String, String> _phoneToName;

  const ContactsSnapshot({
    required this.available,
    required this.labels,
    required Map<String, Set<String>> phoneToLabelNames,
    required Map<String, String> phoneToContactId,
    required Map<String, String> phoneToName,
  })  : _phoneToLabelNames = phoneToLabelNames,
        _phoneToContactId = phoneToContactId,
        _phoneToName = phoneToName;

  static const empty = ContactsSnapshot(
    available: false,
    labels: [],
    phoneToLabelNames: {},
    phoneToContactId: {},
    phoneToName: {},
  );

  Set<String> labelsForPhone(String phone) =>
      _phoneToLabelNames[normalizePhone(phone)] ?? const {};

  /// Distinct label names across all participants of [thread].
  Set<String> labelsForThread(MessageThread thread) => {
        for (final p in thread.participants) ...labelsForPhone(p),
      };

  String? contactIdForPhone(String phone) =>
      _phoneToContactId[normalizePhone(phone)];

  /// The saved contact name for [phone], or null if the number isn't a contact.
  String? nameForPhone(String phone) => _phoneToName[normalizePhone(phone)];

  /// A display title for [thread]: each participant shown as their contact name
  /// where known, otherwise the raw number. Falls back to the thread's own
  /// title (e.g. "Unknown") when there are no participants.
  String titleFor(MessageThread thread) {
    if (thread.participants.isEmpty) return thread.title;
    return thread.participants.map((p) => nameForPhone(p) ?? p).join(', ');
  }
}

/// Reads and writes Contacts labels (groups) via flutter_contacts.
class ContactsLabelService {
  Future<ContactsSnapshot> load() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return ContactsSnapshot.empty;
    }

    final groups = await FlutterContacts.groups.getAll();
    final labels = [
      for (final g in groups)
        if (g.id != null) ContactLabel(id: g.id!, name: g.name),
    ];

    final contacts =
        await FlutterContacts.getAll(properties: {ContactProperty.phone});

    final phoneToLabelNames = <String, Set<String>>{};
    final phoneToContactId = <String, String>{};
    final phoneToName = <String, String>{};
    for (final c in contacts) {
      final id = c.id;
      if (id == null || c.phones.isEmpty) continue;
      final displayName = (c.displayName ?? '').trim();
      final names = (await FlutterContacts.groups.getOf(id))
          .map((g) => g.name)
          .where((n) => n.isNotEmpty)
          .toSet();
      for (final phone in c.phones) {
        final key = normalizePhone(phone.number);
        if (key.isEmpty) continue;
        phoneToContactId[key] = id;
        if (displayName.isNotEmpty) phoneToName[key] = displayName;
        if (names.isNotEmpty) {
          (phoneToLabelNames[key] ??= <String>{}).addAll(names);
        }
      }
    }

    return ContactsSnapshot(
      available: true,
      labels: labels,
      phoneToLabelNames: phoneToLabelNames,
      phoneToContactId: phoneToContactId,
      phoneToName: phoneToName,
    );
  }

  /// Create a new Contacts label (group). Returns its id, or null on failure.
  Future<String?> createLabel(String name) async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.readWrite);
    if (status != PermissionStatus.granted) return null;
    final group = await FlutterContacts.groups.create(name.trim());
    return group.id;
  }

  /// Add/remove a single contact from a label.
  Future<void> setMembership({
    required String labelId,
    required String contactId,
    required bool member,
  }) async {
    if (member) {
      await FlutterContacts.groups
          .addContacts(groupId: labelId, contactIds: [contactId]);
    } else {
      await FlutterContacts.groups
          .removeContacts(groupId: labelId, contactIds: [contactId]);
    }
  }

  /// Apply a label to every participant of a conversation. Participants without
  /// an existing contact are created (with the number as display name) so the
  /// label can be attached.
  Future<void> setLabelForThread({
    required ContactLabel label,
    required MessageThread thread,
    required ContactsSnapshot snapshot,
    required bool member,
  }) async {
    for (final phone in thread.participants) {
      final contactId = snapshot.contactIdForPhone(phone) ??
          await FlutterContacts.create(Contact(
            displayName: phone,
            phones: [Phone(number: phone)],
          ));
      await setMembership(
        labelId: label.id,
        contactId: contactId,
        member: member,
      );
    }
  }
}
