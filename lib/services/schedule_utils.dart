import 'package:flutter/material.dart';

/// The next time a class meets, worked out from its schedule text.
class NextClass {
  final int index; // position in the list that was searched
  final DateTime start;
  final int dayOffset; // 0 = today, 1 = tomorrow, ...
  final bool hasTime;

  const NextClass({
    required this.index,
    required this.start,
    required this.dayOffset,
    required this.hasTime,
  });
}

/// Helpers that read the free-text class schedule, for example:
///   "Mon & Wed - 8:00 AM to 10:00 AM", "Tuesday/Thursday 1:00 PM", "MWF 9:00 AM"
class ScheduleUtils {
  ScheduleUtils._();

  static const List<String> _dayShort = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// Weekdays found in the schedule (1 = Monday ... 7 = Sunday).
  /// Empty when the text has no recognizable days (for example "TBA").
  static Set<int> parseWeekdays(String schedule) {
    final text = schedule.toLowerCase();
    final Set<int> days = {};

    // Day names: mon, monday, tue, tues, thu, thurs ...
    final names = RegExp(r'\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b');
    for (final m in names.allMatches(text)) {
      switch (m.group(1)) {
        case 'mon':
          days.add(1);
          break;
        case 'tue':
          days.add(2);
          break;
        case 'wed':
          days.add(3);
          break;
        case 'thu':
          days.add(4);
          break;
        case 'fri':
          days.add(5);
          break;
        case 'sat':
          days.add(6);
          break;
        case 'sun':
          days.add(7);
          break;
      }
    }
    if (days.isNotEmpty) return days;

    // Compact codes at the start, like MWF, TTh or MW
    final compact = RegExp(r'^\s*((?:th|sa|su|m|t|w|f|s)+)\b').firstMatch(text);
    if (compact != null) {
      final code = compact.group(1)!;
      int i = 0;
      while (i < code.length) {
        if (code.startsWith('th', i)) {
          days.add(4);
          i += 2;
        } else if (code.startsWith('sa', i)) {
          days.add(6);
          i += 2;
        } else if (code.startsWith('su', i)) {
          days.add(7);
          i += 2;
        } else {
          switch (code[i]) {
            case 'm':
              days.add(1);
              break;
            case 't':
              days.add(2);
              break;
            case 'w':
              days.add(3);
              break;
            case 'f':
              days.add(5);
              break;
            case 's':
              days.add(6);
              break;
          }
          i += 1;
        }
      }
    }
    return days;
  }

  /// First clock time in the schedule, e.g. "8:00 AM" -> 08:00.
  static TimeOfDay? parseStartTime(String schedule) {
    final m = RegExp(r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)', caseSensitive: false)
        .firstMatch(schedule);
    if (m == null) return null;

    int hour = int.parse(m.group(1)!) % 12;
    final int minute = int.tryParse(m.group(2) ?? '0') ?? 0;
    if (m.group(3)!.toLowerCase() == 'pm') hour += 12;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static bool isToday(String schedule, {DateTime? now}) {
    final n = now ?? DateTime.now();
    return parseWeekdays(schedule).contains(n.weekday);
  }

  /// The class that meets next (a class that started up to 3 hours ago still
  /// counts as "now"). Returns null if no schedule could be read.
  static NextClass? nextOccurrence(List<String> schedules, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    NextClass? best;

    for (int i = 0; i < schedules.length; i++) {
      final days = parseWeekdays(schedules[i]);
      if (days.isEmpty) continue;
      final time = parseStartTime(schedules[i]);

      for (int offset = 0; offset <= 7; offset++) {
        final date = today.add(Duration(days: offset));
        if (!days.contains(date.weekday)) continue;

        final start = DateTime(
          date.year,
          date.month,
          date.day,
          time?.hour ?? 0,
          time?.minute ?? 0,
        );

        // Today's class that ended hours ago: look at the following days
        if (offset == 0 &&
            time != null &&
            start.isBefore(n.subtract(const Duration(hours: 3)))) {
          continue;
        }

        if (best == null || start.isBefore(best.start)) {
          best = NextClass(
            index: i,
            start: start,
            dayOffset: offset,
            hasTime: time != null,
          );
        }
        break;
      }
    }
    return best;
  }

  static String _formatTime(DateTime dt) {
    final int h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final String m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// "Today, 8:00 AM", "Tomorrow, 1:00 PM" or "Mon, 8:00 AM"
  static String whenLabel(NextClass next) {
    final String day = next.dayOffset == 0
        ? 'Today'
        : next.dayOffset == 1
            ? 'Tomorrow'
            : _dayShort[next.start.weekday - 1];
    return next.hasTime ? '$day, ${_formatTime(next.start)}' : day;
  }
}
