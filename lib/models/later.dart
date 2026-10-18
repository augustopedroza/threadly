/// Quick "later" times for saving a conversation for later or snoozing a
/// reminder — the familiar email-app set, computed from [now] so they're
/// testable. Mornings are 9 AM, evenings 6 PM.
library;

typedef LaterOption = ({String label, DateTime when});

const _morning = 9;
const _evening = 18;

List<LaterOption> laterPresets(DateTime now) {
  DateTime at(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour);
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  // Whole minutes, so "in 1 hour" doesn't carry seconds into the display.
  final inAnHour = DateTime(now.year, now.month, now.day, now.hour, now.minute)
      .add(const Duration(hours: 1));
  // Saturday morning, offered Monday-Thursday only: on Friday it's
  // tomorrow, and on the weekend it would be *next* weekend.
  final daysToSat = DateTime.saturday - now.weekday;
  // Next Monday, strictly after today.
  final daysToMon = (DateTime.monday - now.weekday) % 7 == 0
      ? 7
      : (DateTime.monday - now.weekday) % 7;
  return [
    (label: 'In 1 hour', when: inAnHour),
    // Only while there's still a useful stretch before the evening.
    if (now.hour < _evening - 1) (label: 'This evening', when: at(today, _evening)),
    (label: 'Tomorrow morning', when: at(tomorrow, _morning)),
    if (now.weekday <= DateTime.thursday)
      (label: 'This weekend', when: at(today.add(Duration(days: daysToSat)), _morning)),
    // On Sunday next Monday is tomorrow morning: don't list it twice.
    if (daysToMon > 1)
      (label: 'Next week', when: at(today.add(Duration(days: daysToMon)), _morning)),
  ];
}

/// The "Snooze 1 hour" / "Tomorrow morning" times offered on the reminder
/// notification itself.
DateTime snoozeAnHour(DateTime now) => laterPresets(now).first.when;
DateTime snoozeTomorrow(DateTime now) => laterPresets(now)
    .firstWhere((o) => o.label == 'Tomorrow morning')
    .when;
