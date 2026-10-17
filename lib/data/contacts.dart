import 'dart:typed_data';

import 'package:flutter_contacts/flutter_contacts.dart';

import '../models/phone.dart';

/// An immutable read snapshot mapping phone numbers to saved contact names, so
/// the UI can show "Olivia Bennett" instead of a raw number. Built by
/// [ContactsService.load]. Read-only: the app never writes to Contacts.
class ContactsSnapshot {
  /// True if contacts permission was granted (even if the address book is empty).
  final bool available;

  /// normalized phone -> contact display name.
  final Map<String, String> _phoneToName;

  /// normalized phone -> contact photo thumbnail bytes (when the contact has one).
  final Map<String, Uint8List> _phoneToPhoto;

  /// lowercased contact display name -> photo thumbnail. Conversation titles
  /// from Google Messages' notifications are contact names, not numbers, so
  /// avatars resolve by name.
  final Map<String, Uint8List> _nameToPhoto;

  /// lowercased contact display name -> a dialable phone number, to recover a
  /// 1:1's number from its (name) title for the `sms:` handoff fallback.
  final Map<String, String> _nameToPhone;

  /// All contacts as pickable people (normalized phone + display name), for the
  /// "new group" composer. Sorted by display name.
  final List<({String phone, String display})> people;

  const ContactsSnapshot({
    required this.available,
    required Map<String, String> phoneToName,
    Map<String, Uint8List> phoneToPhoto = const {},
    Map<String, Uint8List> nameToPhoto = const {},
    Map<String, String> nameToPhone = const {},
    this.people = const [],
  })  : _phoneToName = phoneToName,
        _phoneToPhoto = phoneToPhoto,
        _nameToPhoto = nameToPhoto,
        _nameToPhone = nameToPhone;

  static const empty = ContactsSnapshot(available: false, phoneToName: {});

  /// The saved contact name for [phone], or null if the number isn't a contact.
  String? nameForPhone(String phone) => _phoneToName[normalizePhone(phone)];

  /// The contact photo thumbnail for [phone], or null if there's no contact or
  /// the contact has no photo.
  Uint8List? photoForPhone(String phone) =>
      _phoneToPhoto[normalizePhone(phone)];

  /// A dialable phone number for a saved contact [name], or null.
  String? phoneForName(String name) => _nameToPhone[name.toLowerCase().trim()];

  /// Photo for a conversation title, which may be a contact name or a raw
  /// number (the notification source supplies titles, not numbers).
  Uint8List? photoForTitle(String title) {
    final byName = _nameToPhoto[title.toLowerCase().trim()];
    if (byName != null) return byName;
    return photoForPhone(title);
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

    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.phone, ContactProperty.photoThumbnail},
    );

    final phoneToName = <String, String>{};
    final phoneToPhoto = <String, Uint8List>{};
    final nameToPhoto = <String, Uint8List>{};
    final nameToPhone = <String, String>{};
    for (final c in contacts) {
      final displayName = (c.displayName ?? '').trim();
      final nameKey = displayName.toLowerCase();
      final thumb = c.photo?.thumbnail;
      final hasThumb = thumb != null && thumb.isNotEmpty;
      if (displayName.isNotEmpty && hasThumb) {
        nameToPhoto[nameKey] = thumb;
      }
      for (final phone in c.phones) {
        final key = normalizePhone(phone.number);
        if (key.isEmpty) continue;
        if (displayName.isNotEmpty) {
          phoneToName[key] = displayName;
          nameToPhone.putIfAbsent(nameKey, () => phone.number);
        }
        if (hasThumb) phoneToPhoto[key] = thumb;
      }
    }

    final people = [
      for (final e in phoneToName.entries) (phone: e.key, display: e.value),
    ]..sort((a, b) => a.display.toLowerCase().compareTo(b.display.toLowerCase()));

    return ContactsSnapshot(
      available: true,
      phoneToName: phoneToName,
      phoneToPhoto: phoneToPhoto,
      nameToPhoto: nameToPhoto,
      nameToPhone: nameToPhone,
      people: people,
    );
  }
}
