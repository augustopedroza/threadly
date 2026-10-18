/// Tiny, dependency-free date/time formatting for the thread list and bubbles.
///
/// Avoids pulling in `intl` for what amounts to a handful of US-style strings.
library;

const List<String> _weekdays = [
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', // weekday is 1..7 (Mon..Sun)
];
const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "3:42 PM" — 12-hour clock with an AM/PM suffix.
String formatClock(DateTime when) {
  var h = when.hour % 12;
  if (h == 0) h = 12;
  final m = when.minute.toString().padLeft(2, '0');
  final suffix = when.hour < 12 ? 'AM' : 'PM';
  return '$h:$m $suffix';
}

/// Compact recency for a list row: time today, "Yesterday", a weekday within
/// the last week, then "May 8" (or "May 8, 2024" for prior years).
String formatListTime(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(when.year, when.month, when.day);
  final days = today.difference(thatDay).inDays;
  if (days == 0) return formatClock(when);
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[when.weekday - 1];
  final md = '${_months[when.month - 1]} ${when.day}';
  return when.year == now.year ? md : '$md, ${when.year}';
}

/// Per-bubble stamp: the clock, prefixed with the date when it isn't today.
String formatMessageTime(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(when.year, when.month, when.day);
  if (today.difference(thatDay).inDays == 0) return formatClock(when);
  final md = '${_months[when.month - 1]} ${when.day}';
  return '$md, ${formatClock(when)}';
}

/// When a reminder is due, relative where that reads best: "today at 6:00 PM",
/// "tomorrow at 9:00 AM", else "Sat, Oct 17 at 9:00 AM" (with the year when
/// it isn't this year).
String formatDue(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final thatDay = DateTime(when.year, when.month, when.day);
  final days = thatDay.difference(today).inDays;
  final clock = formatClock(when);
  if (days == 0) return 'today at $clock';
  if (days == 1) return 'tomorrow at $clock';
  final md = '${_weekdays[when.weekday - 1]}, ${_months[when.month - 1]} ${when.day}';
  return when.year == now.year ? '$md at $clock' : '$md, ${when.year} at $clock';
}
