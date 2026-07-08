/// User-defined, app-managed bucket of people (e.g. "LDS").
///
/// A category classifies conversations — both individual chats and group chats.
/// Distinct from an SMS group chat: a category lives only in this app's local
/// store and collects people by phone number.
class Category {
  final int id;
  final String name;

  /// ARGB color used for the category's chip/tab accent.
  final int color;

  const Category({required this.id, required this.name, required this.color});
}

/// A named, saved roster of people under a [Category] — e.g. "U17 Parents
/// Carpool". Launchable as a group text in the native Messages app.
class GroupChat {
  final int id;
  final int categoryId;
  final String name;
  final List<String> members; // normalized phones

  const GroupChat({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.members,
  });
}

/// Per-conversation annotation: an ad-hoc color, a free-text note, and/or a
/// reminder.
///
/// Independent of categories. Keyed by [MessageThread.participantKey].
class ConversationAnnotation {
  final String threadKey;

  /// Custom display name shown instead of the phone number(s), or null.
  final String? name;

  /// ARGB color, or null for none.
  final int? color;
  final String? note;

  /// When to fire a local reminder notification for this conversation
  /// (epoch ms), or null for no reminder. Kept after firing so the list can
  /// show it as elapsed until the user clears or replaces it.
  final int? remindAtMs;

  const ConversationAnnotation({
    required this.threadKey,
    this.name,
    this.color,
    this.note,
    this.remindAtMs,
  });

  bool get isEmpty =>
      color == null &&
      remindAtMs == null &&
      (note == null || note!.isEmpty) &&
      (name == null || name!.isEmpty);
}

/// A person for membership editing: a normalized phone plus a display string.
typedef Person = ({String phone, String display});

/// "1 person" / "N people" — shared so roster counts read naturally everywhere.
String pluralPeople(int n) => n == 1 ? '1 person' : '$n people';

/// A small fixed palette so colors stay consistent and pickable.
const List<int> kColorPalette = [
  0xFFE53935, // red
  0xFFFB8C00, // orange
  0xFFFDD835, // yellow
  0xFF43A047, // green
  0xFF1E88E5, // blue
  0xFF8E24AA, // purple
  0xFF6D4C41, // brown
  0xFF546E7A, // blue grey
];
