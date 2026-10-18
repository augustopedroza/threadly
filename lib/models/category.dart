/// User-defined, app-managed bucket of people (e.g. "LDS").
///
/// A category classifies conversations — both individual chats and group chats
/// — and drives the home screen's tabs. It lives only in this app's local
/// store; members are conversation ids.
class Category {
  final int id;
  final String name;

  /// ARGB color used for the category's chip/tab accent.
  final int color;

  const Category({required this.id, required this.name, required this.color});
}

/// Per-conversation annotation: a nickname, an ad-hoc color, a free-text note,
/// and/or a reminder.
///
/// Independent of categories. Keyed by the conversation id ([threadKey] is the
/// historical column name).
class ConversationAnnotation {
  final String threadKey;

  /// Custom nickname shown as a subtitle under the title, or null.
  final String? name;

  /// ARGB color, or null for none.
  final int? color;
  final String? note;

  /// When to fire a local reminder notification for this conversation
  /// (epoch ms), or null for no reminder. Kept after firing so the list can
  /// show it as elapsed until the user clears or replaces it.
  final int? remindAtMs;

  /// What the reminder is for ("Big move at home"), shown on the reminders
  /// screen and as the notification text. Only set alongside [remindAtMs].
  final String? remindWhat;

  const ConversationAnnotation({
    required this.threadKey,
    this.name,
    this.color,
    this.note,
    this.remindAtMs,
    this.remindWhat,
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
