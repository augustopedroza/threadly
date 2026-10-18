/// Turns date/time words copied from a text message ("Saturday at 9am",
/// "Oct 20", "tomorrow at noon", "the 1st") into a concrete moment, for
/// reminder suggestions.
///
/// Deterministic on purpose: the on-device model only copies the words, and
/// this resolves them relative to [ref] — when that message was sent — so
/// "Saturday" in Wednesday's message means *that* Saturday. US conventions
/// (month/day, 12-hour clock). Returns null when the words don't parse.
library;

/// A resolved date: [when] plus whether the words gave a time of day (if
/// not, [when] is 9:00 AM that day).
class DueDate {
  const DueDate(this.when, {required this.hasTime});

  final DateTime when;
  final bool hasTime;
}

const _weekdays = {
  'monday': 1, 'mon': 1,
  'tuesday': 2, 'tue': 2, 'tues': 2,
  'wednesday': 3, 'wed': 3,
  'thursday': 4, 'thu': 4, 'thur': 4, 'thurs': 4,
  'friday': 5, 'fri': 5,
  'saturday': 6, 'sat': 6,
  'sunday': 7, 'sun': 7,
};

const _months = {
  'january': 1, 'jan': 1,
  'february': 2, 'feb': 2,
  'march': 3, 'mar': 3,
  'april': 4, 'apr': 4,
  'may': 5,
  'june': 6, 'jun': 6,
  'july': 7, 'jul': 7,
  'august': 8, 'aug': 8,
  'september': 9, 'sep': 9, 'sept': 9,
  'october': 10, 'oct': 10,
  'november': 11, 'nov': 11,
  'december': 12, 'dec': 12,
};

/// Default time when the words name a day but no time.
const _defaultHour = 9;

DueDate? parseDueDate(String words, DateTime ref) {
  var text = ' ${words.toLowerCase().replaceAll(RegExp(r"[,.!?]"), ' ')} ';
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  final refDay = DateTime(ref.year, ref.month, ref.day);

  // --- Time of day ---------------------------------------------------------
  int? hour;
  var minute = 0;
  if (text.contains(' noon ')) {
    hour = 12;
    text = text.replaceFirst(' noon ', ' ');
  } else {
    // "9am", "9:30 pm", "at 6", "@ 7:15". A bare number only counts after
    // "at"/"@" (otherwise "Oct 20" would read as 20 o'clock).
    RegExpMatch? m;
    for (final c in RegExp(
      r' (at |@ )?(\d{1,2})(?::(\d{2}))? ?(a\.?m|p\.?m)?(?= )',
    ).allMatches(text)) {
      if (c.group(1) != null || c.group(3) != null || c.group(4) != null) {
        m = c;
        break;
      }
    }
    if (m != null) {
      var h = int.parse(m.group(2)!);
      final mm = m.group(3) != null ? int.parse(m.group(3)!) : 0;
      final ampm = m.group(4);
      if (h <= 23 && mm <= 59) {
        if (ampm != null && ampm.startsWith('p') && h < 12) h += 12;
        if (ampm != null && ampm.startsWith('a') && h == 12) h = 0;
        // No am/pm: 1-7 are almost always afternoon/evening plans.
        if (ampm == null && h >= 1 && h <= 7) h += 12;
        hour = h;
        minute = mm;
        text = text.replaceRange(m.start, m.end, ' ');
      }
    }
  }
  if (hour == null && text.contains(' tonight ')) hour = 19;
  final hasTime = hour != null;

  DateTime at(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour ?? _defaultHour, minute);

  // --- Day -----------------------------------------------------------------
  DateTime? day;
  if (RegExp(r' (today|tonight) ').hasMatch(text)) {
    day = refDay;
  } else if (RegExp(r' (tomorrow|tmrw|tmr|tomorow) ').hasMatch(text)) {
    day = refDay.add(const Duration(days: 1));
  }

  // "10/20" or "10/20/26" (US month/day).
  if (day == null) {
    final m = RegExp(r' (\d{1,2})/(\d{1,2})(?:/(\d{2,4}))? ').firstMatch(text);
    if (m != null) {
      final month = int.parse(m.group(1)!);
      final d = int.parse(m.group(2)!);
      var year = m.group(3) != null ? int.parse(m.group(3)!) : ref.year;
      if (year < 100) year += 2000;
      day = _validDate(year, month, d);
      if (day != null && m.group(3) == null && day.isBefore(refDay)) {
        day = _validDate(year + 1, month, d);
      }
    }
  }

  // "Oct 20", "October 20th", "20 October".
  if (day == null) {
    for (final entry in _months.entries) {
      final m = RegExp(
        ' ${entry.key} (\\d{1,2})(?:st|nd|rd|th)? |'
        ' (\\d{1,2})(?:st|nd|rd|th)? (?:of )?${entry.key} ',
      ).firstMatch(text);
      if (m == null) continue;
      final d = int.parse(m.group(1) ?? m.group(2)!);
      day = _validDate(ref.year, entry.value, d);
      if (day != null && day.isBefore(refDay)) {
        day = _validDate(ref.year + 1, entry.value, d);
      }
      break;
    }
  }

  // "Saturday", "next Sat": the coming one. The same weekday as the message
  // means today only if a time later that day was given; else a week out.
  if (day == null) {
    for (final entry in _weekdays.entries) {
      if (!text.contains(' ${entry.key} ')) continue;
      var delta = (entry.value - ref.weekday) % 7;
      if (delta == 0 && !(hasTime && at(refDay).isAfter(ref))) delta = 7;
      day = refDay.add(Duration(days: delta));
      break;
    }
  }

  // "the 1st", "on the 20th": the next time that day of the month comes up.
  if (day == null) {
    final m = RegExp(r' the (\d{1,2})(?:st|nd|rd|th) ').firstMatch(text);
    if (m != null) {
      final d = int.parse(m.group(1)!);
      day = _validDate(ref.year, ref.month, d);
      if (day == null || day.isBefore(refDay)) {
        day = _validDate(ref.year, ref.month + 1, d);
      }
    }
  }

  // Only a time ("at 6pm"): today if still ahead of the message, else
  // tomorrow.
  if (day == null && hasTime) {
    day = at(refDay).isAfter(ref) ? refDay : refDay.add(const Duration(days: 1));
  }

  if (day == null) return null;
  return DueDate(at(day), hasTime: hasTime);
}

/// The date, or null if it doesn't exist (e.g. Feb 30). Month 13 rolls over.
DateTime? _validDate(int year, int month, int day) {
  if (day < 1 || day > 31) return null;
  final d = DateTime(year, month, day);
  final normalizedMonth = ((month - 1) % 12) + 1;
  return d.day == day && d.month == normalizedMonth ? d : null;
}
