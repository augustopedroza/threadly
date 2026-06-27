import 'dart:typed_data';

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

  /// normalized phone -> contact photo thumbnail bytes (when the contact has one).
  final Map<String, Uint8List> _phoneToPhoto;

  /// lowercased contact display name -> photo thumbnail. Used to resolve an
  /// avatar for bridge conversations, where participants are name-only ghosts
  /// with no phone number to key on.
  final Map<String, Uint8List> _nameToPhoto;

  /// lowercased contact display name -> a dialable phone number. Used to recover
  /// a sendable number for bridge conversations (their participants are name-only
  /// ghosts with no number), so the native handoff opens the right thread.
  final Map<String, String> _nameToPhone;

  const ContactsSnapshot({
    required this.available,
    required Map<String, String> phoneToName,
    Map<String, Uint8List> phoneToPhoto = const {},
    Map<String, Uint8List> nameToPhoto = const {},
    Map<String, String> nameToPhone = const {},
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

  /// The avatar photo to show for a conversation: the contact's photo for a 1:1
  /// thread, or null for group threads (no single photo) or unknown contacts.
  ///
  /// Tries the participant's phone number first (the SMS source supplies real
  /// numbers), then falls back to matching the resolved display name (the
  /// bridge supplies contact names, not numbers).
  Uint8List? photoForThread(MessageThread thread) {
    if (thread.isGroup) return null;
    if (thread.participants.isNotEmpty) {
      final byPhone = photoForPhone(thread.participants.first);
      if (byPhone != null) return byPhone;
    }
    return _nameToPhoto[titleFor(thread).toLowerCase().trim()];
  }

  /// A dialable phone number for a saved contact [name], or null.
  String? phoneForName(String name) => _nameToPhone[name.toLowerCase().trim()];

  /// Photo for a conversation title, which may be a contact name or a raw
  /// number (the notification source supplies titles, not numbers).
  Uint8List? photoForTitle(String title) {
    final byName = _nameToPhoto[title.toLowerCase().trim()];
    if (byName != null) return byName;
    return photoForPhone(title);
  }

  /// Resolve a thread's participants to phone numbers usable for the native
  /// `sms:` handoff. Bridge participants are name-only ghosts (`gm:…`) with no
  /// number; for a 1:1 we recover it from the contact name. Returns null if any
  /// participant can't be resolved — the caller should warn rather than open
  /// Messages on the wrong (or a bogus `gm:`) thread.
  List<String>? sendRecipients(MessageThread thread) {
    final out = <String>[];
    for (final p in thread.participants) {
      if (!p.startsWith('gm:')) {
        out.add(p);
      } else if (thread.participants.length == 1) {
        final number = phoneForName(titleFor(thread));
        if (number == null) return null;
        out.add(number);
      } else {
        return null; // a group ghost with no resolvable number
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Number of contact photos loaded (diagnostics).
  int get photoCount => _phoneToPhoto.length + _nameToPhoto.length;

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

    return ContactsSnapshot(
      available: true,
      phoneToName: phoneToName,
      phoneToPhoto: phoneToPhoto,
      nameToPhoto: nameToPhoto,
      nameToPhone: nameToPhone,
    );
  }
}
