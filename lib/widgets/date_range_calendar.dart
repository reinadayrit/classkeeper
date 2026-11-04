import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/app_colors.dart';

/// Result of the calendar sheet.
/// [range] is null when the student/teacher chose "All Dates" (clear filter).
/// The sheet itself returns null when it was dismissed without applying.
class DateRangeResult {
  final DateTimeRange? range;
  const DateRangeResult(this.range);
}

const List<String> _monthShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _monthFull = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "All Dates", "Oct 5" or "Oct 5 - Oct 9"
String formatDateRangeLabel(DateTimeRange? range) {
  if (range == null) return 'All Dates';
  final s = range.start;
  final e = range.end;
  if (_sameDay(s, e)) return '${_monthShort[s.month - 1]} ${s.day}';
  return '${_monthShort[s.month - 1]} ${s.day} - ${_monthShort[e.month - 1]} ${e.day}';
}

/// True when [date] falls inside [range] (whole days, both ends included).
bool isDateInRange(DateTime date, DateTimeRange? range) {
  if (range == null) return true;
  final d = DateTime(date.year, date.month, date.day);
  final s = DateTime(range.start.year, range.start.month, range.start.day);
  final e = DateTime(range.end.year, range.end.month, range.end.day);
  return !d.isBefore(s) && !d.isAfter(e);
}

/// The calendar filter sheet (same design as the faculty Records screen).
///
/// Returns a [DateRangeResult] when the user applies, or null if dismissed.
Future<DateRangeResult?> showDateRangeCalendar(
  BuildContext context, {
  DateTimeRange? initialRange,
  String title = 'Calendar Filter',
  String applyVerb = 'Apply',
  String emptyApplyText = 'Apply Date Range',
}) {
  return showModalBottomSheet<DateRangeResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _DateRangeSheet(
      initialRange: initialRange,
      title: title,
      applyVerb: applyVerb,
      emptyApplyText: emptyApplyText,
    ),
  );
}

class _DateRangeSheet extends StatefulWidget {
  final DateTimeRange? initialRange;
  final String title;
  final String applyVerb;
  final String emptyApplyText;

  const _DateRangeSheet({
    required this.initialRange,
    required this.title,
    required this.applyVerb,
    required this.emptyApplyText,
  });

  @override
  State<_DateRangeSheet> createState() => _DateRangeSheetState();
}

class _DateRangeSheetState extends State<_DateRangeSheet> {
  int _activeTab = 1; // 0 = presets, 1 = calendar
  late DateTime _displayedMonth;
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _start = widget.initialRange?.start;
    _end = widget.initialRange?.end;
    _displayedMonth = widget.initialRange?.start ?? DateTime.now();
  }

  Widget _tab(String label, int index) {
    final bool active = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: active ? AppColors.primaryBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: active
                    ? Colors.white
                    : AppColors.primaryBlue.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preset({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = AppColors.primaryBlue,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: const Color(0xFFF8FAFC),
        leading: Icon(icon, color: color),
        title: Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color == AppColors.primaryBlue ? null : color,
          ),
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _arrow(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.primaryBlue.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: AppColors.primaryBlue),
      ),
    );
  }

  void _pickDay(DateTime day) {
    setState(() {
      if (_start == null || (_start != null && _end != null)) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    final firstDayOfMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final daysInMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0).day;
    final startingWeekday = firstDayOfMonth.weekday % 7;
    final prevMonthDays =
        DateTime(_displayedMonth.year, _displayedMonth.month, 0).day;
    final totalGridItems = ((startingWeekday + daysInMonth) / 7).ceil() * 7;

    final String buttonText = _start == null
        ? widget.emptyApplyText
        : _end == null
            ? 'Select End Date'
            : '${widget.applyVerb} ${_monthShort[_start!.month - 1]} ${_start!.day} - ${_monthShort[_end!.month - 1]} ${_end!.day}';

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryBlue.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.title,
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.grey, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 42,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    _tab('PRESETS', 0),
                    _tab('CALENDAR', 1),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_activeTab == 0) ...[
                _preset(
                  icon: Icons.today_rounded,
                  label: 'Today',
                  onTap: () => setState(() {
                    _start = now;
                    _end = now;
                  }),
                ),
                _preset(
                  icon: Icons.date_range_rounded,
                  label: 'This Week',
                  onTap: () => setState(() {
                    _start = now.subtract(Duration(days: now.weekday - 1));
                    _end = now;
                  }),
                ),
                _preset(
                  icon: Icons.calendar_month_rounded,
                  label: 'This Month',
                  onTap: () => setState(() {
                    _start = DateTime(now.year, now.month, 1);
                    _end = now;
                  }),
                ),
                _preset(
                  icon: Icons.clear_all_rounded,
                  label: 'Clear Date Filter',
                  color: Colors.redAccent,
                  onTap: () => setState(() {
                    _start = null;
                    _end = null;
                  }),
                ),
                const SizedBox(height: 12),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_monthFull[_displayedMonth.month - 1]} ${_displayedMonth.year}',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    Row(
                      children: [
                        _arrow(Icons.chevron_left_rounded, () {
                          setState(() {
                            _displayedMonth = DateTime(_displayedMonth.year,
                                _displayedMonth.month - 1, 1);
                          });
                        }),
                        const SizedBox(width: 8),
                        _arrow(Icons.chevron_right_rounded, () {
                          setState(() {
                            _displayedMonth = DateTime(_displayedMonth.year,
                                _displayedMonth.month + 1, 1);
                          });
                        }),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                      .map((d) => SizedBox(
                            width: 32,
                            child: Center(
                              child: Text(
                                d,
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: totalGridItems,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 4,
                  ),
                  itemBuilder: (context, index) {
                    int dayNumber;
                    bool isCurrentMonth = true;
                    DateTime cellDate;

                    if (index < startingWeekday) {
                      isCurrentMonth = false;
                      dayNumber = prevMonthDays - startingWeekday + index + 1;
                      cellDate = DateTime(_displayedMonth.year,
                          _displayedMonth.month - 1, dayNumber);
                    } else if (index >= startingWeekday + daysInMonth) {
                      isCurrentMonth = false;
                      dayNumber = index - (startingWeekday + daysInMonth) + 1;
                      cellDate = DateTime(_displayedMonth.year,
                          _displayedMonth.month + 1, dayNumber);
                    } else {
                      dayNumber = index - startingWeekday + 1;
                      cellDate = DateTime(_displayedMonth.year,
                          _displayedMonth.month, dayNumber);
                    }

                    final isStart =
                        _start != null && _sameDay(_start!, cellDate);
                    final isEnd = _end != null && _sameDay(_end!, cellDate);
                    final isInRange = _start != null &&
                        _end != null &&
                        cellDate.isAfter(_start!) &&
                        cellDate.isBefore(_end!);
                    final isSelected = isStart || isEnd;

                    return InkWell(
                      onTap: () => _pickDay(cellDate),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primaryBlue
                              : isInRange
                                  ? AppColors.primaryBlue
                                      .withValues(alpha: 0.12)
                                  : Colors.transparent,
                          shape:
                              isSelected ? BoxShape.circle : BoxShape.rectangle,
                          borderRadius:
                              isInRange ? BorderRadius.circular(8) : null,
                        ),
                        child: Center(
                          child: Text(
                            '$dayNumber',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: isSelected || isInRange
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color: isSelected
                                  ? Colors.white
                                  : !isCurrentMonth
                                      ? Colors.grey.shade400
                                      : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
              ],
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    final DateTimeRange? range = _start == null
                        ? null
                        : DateTimeRange(start: _start!, end: _end ?? _start!);
                    Navigator.pop(context, DateRangeResult(range));
                  },
                  child: Text(
                    buttonText,
                    style: GoogleFonts.poppins(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
