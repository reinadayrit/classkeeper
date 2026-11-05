import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/faculty_notice_refresh.dart';
import '../../services/schedule_utils.dart';

/// Data model matching Supabase 'classes' schema
class FacultyClassItem {
  final String id;
  final String code;
  final String title;
  final String schedule;
  final String enrolledCount;
  final int enrolledInt;

  const FacultyClassItem({
    required this.id,
    required this.code,
    required this.title,
    required this.schedule,
    required this.enrolledCount,
    required this.enrolledInt,
  });
}

class FacultyDashboardScreen extends StatefulWidget {
  final Function(int) onTabSelected;

  const FacultyDashboardScreen({
    super.key,
    required this.onTabSelected,
  });

  @override
  State<FacultyDashboardScreen> createState() => _FacultyDashboardScreenState();
}

class _FacultyDashboardScreenState extends State<FacultyDashboardScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = true;
  String _facultyName = 'Faculty Member';
  String? _profileImageUrl;
  List<FacultyClassItem> _classList = [];
  int _totalStudents = 0;

  // Dynamic Metrics (Active Classes Only)
  double? _avgAttendance; // null = no attendance recorded yet
  int _atRiskStudentsCount = 0; // students with 2+ absences
  int _pendingExcuseCount = 0; // excuse letters waiting for review
  int _openSessionCount = 0; // attendance sessions not ended yet

  // Attendance rate per class: {code, title, rate, attended, total}
  List<Map<String, dynamic>> _classRates = [];

  // Attendance rate per weekday (null = no sessions on that day)
  Map<String, double?> _weeklyPercentages = {
    'Mon': null,
    'Tue': null,
    'Wed': null,
    'Thu': null,
    'Fri': null,
  };

  // Up Next scheduled class variables
  String _nextClassCode = 'N/A';
  String _nextClassTitle = 'No upcoming class scheduled';
  String _nextClassSchedule = 'N/A';
  String _nextClassWhen = ''; // e.g. "Today, 8:00 AM"
  bool _nextIsReal = false; // false = schedule could not be read

  // Classes Pagination State
  final PageController _classPageController = PageController();
  int _currentClassPage = 0;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
    // Refresh the counts when an excuse letter is approved or rejected
    FacultyNoticeRefresh.tick.addListener(_fetchDashboardData);
  }

  @override
  void dispose() {
    FacultyNoticeRefresh.tick.removeListener(_fetchDashboardData);
    _classPageController.dispose();
    super.dispose();
  }

  /// Queries Supabase for profile, active classes, enrollments, and active attendance metrics dynamically
  Future<void> _fetchDashboardData() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // 1. Query Profile Data (full_name, avatar_url)
      final profileData = await _supabase
          .from('profiles')
          .select('full_name, avatar_url')
          .eq('id', user.id)
          .maybeSingle();

      if (profileData != null) {
        _facultyName = profileData['full_name'] ?? 'Faculty Member';
        _profileImageUrl = profileData['avatar_url'];
      }

      // 2. Query ACTIVE Classes only (filtering out archived classes)
      final classesResponse = await _supabase
          .from('classes')
          .select(
              'id, course_code, course_name, schedule, is_archived, class_enrollments(count)')
          .eq('faculty_id', user.id)
          .filter('is_archived', 'neq', true);

      final List<FacultyClassItem> loadedClasses = [];
      final List<String> activeClassIds = [];
      int aggregateStudents = 0;

      for (var row in (classesResponse as List)) {
        final cId = row['id']?.toString() ?? '';
        if (cId.isNotEmpty) activeClassIds.add(cId);

        final enrollments = row['class_enrollments'] as List?;
        final count = (enrollments != null && enrollments.isNotEmpty)
            ? enrollments.first['count'] as int
            : 0;

        aggregateStudents += count;

        loadedClasses.add(
          FacultyClassItem(
            id: cId,
            code: row['course_code'] ?? 'COURSE',
            title: row['course_name'] ?? 'Untitled Course',
            schedule: row['schedule'] ?? 'Schedule not set',
            enrolledCount: '$count Enrolled',
            enrolledInt: count,
          ),
        );
      }

      // 3. "Up Next": the class that meets next, based on the schedule text
      if (classesResponse.isNotEmpty) {
        final schedules = (classesResponse as List)
            .map((c) => (c['schedule'] ?? '').toString())
            .toList();
        final next = ScheduleUtils.nextOccurrence(schedules);

        // If no schedule can be read, fall back to the first class
        final nextClass =
            next != null ? classesResponse[next.index] : classesResponse.first;

        _nextIsReal = next != null;
        _nextClassWhen = next != null ? ScheduleUtils.whenLabel(next) : '';
        _nextClassCode = nextClass['course_code'] ?? 'COURSE';
        _nextClassTitle = nextClass['course_name'] ?? 'Scheduled Class';
        _nextClassSchedule = nextClass['schedule'] ?? 'Schedule not set';
      } else {
        _nextIsReal = false;
        _nextClassWhen = '';
        _nextClassCode = 'N/A';
        _nextClassTitle = 'No active class scheduled';
        _nextClassSchedule = 'N/A';
      }

      // 4. Compute Dynamic Attendance Analytics & At-Risk Students for ACTIVE classes only
      int totalLogs = 0;
      int presentOrLateCount = 0;
      final Map<String, int> studentAbsentCounts = {};
      int openSessions = 0;
      int pendingExcuses = 0;
      final Map<String, List<int>> perClassCounts =
          {}; // id -> [attended, total]
      final Map<int, List<int>> weekdayCounters = {
        1: [0, 0], // Mon: [present/late count, total count]
        2: [0, 0], // Tue
        3: [0, 0], // Wed
        4: [0, 0], // Thu
        5: [0, 0], // Fri
      };

      if (activeClassIds.isNotEmpty) {
        final sessionsRes = await _supabase
            .from('attendance_sessions')
            .select('id, class_id, created_at, date, is_ended')
            .inFilter('class_id', activeClassIds);

        final Map<String, DateTime> sessionDateMap = {};
        final Map<String, String> sessionClassMap = {};
        final List<String> sessionIds = [];

        for (var s in sessionsRes) {
          final sId = s['id'].toString();
          sessionIds.add(sId);
          sessionClassMap[sId] = s['class_id']?.toString() ?? '';
          if (s['is_ended'] == false) openSessions++;

          // Use the session date (same as the Records screen)
          final DateTime? parsed =
              DateTime.tryParse(s['date']?.toString() ?? '') ??
                  DateTime.tryParse(s['created_at']?.toString() ?? '')
                      ?.toLocal();
          if (parsed != null) sessionDateMap[sId] = parsed;
        }

        // Excuse letters waiting for the teacher
        try {
          final pendingRes = await _supabase
              .from('absence_reasons')
              .select('id')
              .inFilter('class_id', activeClassIds)
              .ilike('status', 'pending');
          pendingExcuses = (pendingRes as List).length;
        } catch (e) {
          debugPrint('Could not count excuse letters: $e');
        }

        if (sessionIds.isNotEmpty) {
          final recordsRes = await _supabase
              .from('attendance_records')
              .select('student_id, session_id, status')
              .inFilter('session_id', sessionIds);

          for (var rec in recordsRes) {
            totalLogs++;
            final statusStr = rec['status']?.toString().toLowerCase() ?? '';
            final studentId = rec['student_id']?.toString() ?? '';
            final sessionId = rec['session_id']?.toString() ?? '';
            final sessionDate = sessionDateMap[sessionId];

            // Per-class totals
            final classKey = sessionClassMap[sessionId] ?? '';
            if (classKey.isNotEmpty) {
              final c = perClassCounts.putIfAbsent(classKey, () => [0, 0]);
              c[1]++;
              if (statusStr != 'absent') c[0]++;
            }

            if (statusStr == 'present' ||
                statusStr == 'late' ||
                statusStr == 'excused') {
              presentOrLateCount++;
            } else if (statusStr == 'absent') {
              studentAbsentCounts[studentId] =
                  (studentAbsentCounts[studentId] ?? 0) + 1;
            }

            // Group by weekday
            if (sessionDate != null) {
              final wd = sessionDate.weekday;
              if (weekdayCounters.containsKey(wd)) {
                weekdayCounters[wd]![1]++; // total
                if (statusStr == 'present' ||
                    statusStr == 'late' ||
                    statusStr == 'excused') {
                  weekdayCounters[wd]![0]++; // present/late
                }
              }
            }
          }
        }
      }

      // Average attendance (present + late + excused), same as Records.
      // null when nothing has been recorded yet.
      final double? calculatedAvg =
          totalLogs > 0 ? (presentOrLateCount / totalLogs) * 100 : null;

      // Students with 2 or more absences (same rule as the Records screen)
      final int atRisk =
          studentAbsentCounts.values.where((cnt) => cnt >= 2).length;

      // Attendance rate per weekday, only for days that have sessions
      double? dayRate(int weekday) {
        final counts = weekdayCounters[weekday]!;
        return counts[1] > 0 ? counts[0] / counts[1] : null;
      }

      final Map<String, double?> computedWeekly = {
        'Mon': dayRate(1),
        'Tue': dayRate(2),
        'Wed': dayRate(3),
        'Thu': dayRate(4),
        'Fri': dayRate(5),
      };

      // Attendance rate per class (lowest first)
      final List<Map<String, dynamic>> classRates = [];
      for (final c in loadedClasses) {
        final counts = perClassCounts[c.id];
        if (counts == null || counts[1] == 0) continue;
        classRates.add({
          'code': c.code,
          'title': c.title,
          'attended': counts[0],
          'total': counts[1],
          'rate': counts[0] / counts[1],
        });
      }
      classRates
          .sort((a, b) => (a['rate'] as double).compareTo(b['rate'] as double));

      if (mounted) {
        setState(() {
          _classRates = classRates;
          _classList = loadedClasses;
          _totalStudents = aggregateStudents;
          _avgAttendance = calculatedAvg;
          _atRiskStudentsCount = atRisk;
          _pendingExcuseCount = pendingExcuses;
          _openSessionCount = openSessions;
          _weeklyPercentages = computedWeekly;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primaryBlue),
      );
    }

    final firstName = _facultyName.trim().split(' ').first;

    return RefreshIndicator(
      onRefresh: _fetchDashboardData,
      color: AppColors.primaryBlue,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- 1. TOP BLUE BANNER & FLOATING UP-NEXT CARD ---
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 50, 20, 55),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primaryBlue,
                        Color(0xFF1E3A8A),
                        Color(0xFF2563EB),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(28),
                      bottomRight: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.school_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'FACULTY PORTAL',
                                  style: GoogleFonts.poppins(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => widget.onTabSelected(5),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: CircleAvatar(
                                radius: 18,
                                backgroundColor: AppColors.primaryBlue
                                    .withValues(alpha: 0.12),
                                backgroundImage: _profileImageUrl != null
                                    ? NetworkImage(_profileImageUrl!)
                                    : null,
                                child: _profileImageUrl == null
                                    ? const Icon(
                                        Icons.person_rounded,
                                        color: AppColors.primaryBlue,
                                        size: 20,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Hi $firstName,',
                        style: GoogleFonts.poppins(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        "Let's keep your classes in check!",
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: -36,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.qr_code_rounded,
                            color: AppColors.primaryBlue,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _nextIsReal
                                    ? 'UP NEXT • $_nextClassCode'
                                    : 'YOUR CLASS • $_nextClassCode',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              Text(
                                _nextClassTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF0F172A),
                                ),
                              ),
                              Text(
                                _nextClassWhen.isNotEmpty
                                    ? '$_nextClassWhen  •  $_nextClassSchedule'
                                    : _nextClassSchedule,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () => widget.onTabSelected(2),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryBlue,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                          icon: const Icon(Icons.add,
                              size: 16, color: Colors.white),
                          label: Text(
                            'Start QR',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 52),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle('QUICK ACTIONS'),
                  const SizedBox(height: 12),
                  _buildQuickActions(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('OVERVIEW'),
                  const SizedBox(height: 12),
                  _buildUsageProgressCards(),
                  const SizedBox(height: 24),
                  _buildSectionTitle("TODAY'S SCHEDULE"),
                  const SizedBox(height: 12),
                  _buildTodaySchedule(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('NEEDS ATTENTION'),
                  const SizedBox(height: 12),
                  _buildAttentionCard(context),
                  const SizedBox(height: 24),
                  _buildSectionTitle('ATTENDANCE BY DAY'),
                  const SizedBox(height: 12),
                  _buildAnalyticsCard(context),
                  const SizedBox(height: 24),
                  if (_classRates.isNotEmpty) ...[
                    _buildSectionTitle('ATTENDANCE BY CLASS'),
                    const SizedBox(height: 12),
                    _buildClassRatesCard(),
                    const SizedBox(height: 24),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionTitle('YOUR CLASSES'),
                      GestureDetector(
                        onTap: () => widget.onTabSelected(1),
                        child: Text(
                          'View All',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: AppColors.primaryBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildPaginatedClasses(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.poppins(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: AppColors.primaryBlue,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildQuickActionItem(
          icon: Icons.class_rounded,
          label: 'Classes',
          color: AppColors.primaryBlue,
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected(1),
        ),
        _buildQuickActionItem(
          icon: Icons.qr_code_scanner_rounded,
          label: 'Generate QR',
          color: const Color(0xFF2563EB),
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected(2),
        ),
        _buildQuickActionItem(
          icon: Icons.assignment_rounded,
          label: 'Records',
          color: AppColors.primaryBlue,
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected(3),
        ),
        _buildQuickActionItem(
          icon: Icons.campaign_rounded,
          label: 'Announce',
          color: const Color(0xFF2563EB),
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected(4),
        ),
      ],
    );
  }

  Widget _buildUsageProgressCards() {
    final String avgText =
        _avgAttendance == null ? '—' : '${_avgAttendance!.toStringAsFixed(1)}%';

    return Row(
      children: [
        Expanded(
          child: _buildStatTile(
            icon: Icons.groups_rounded,
            label: 'Students',
            value: '$_totalStudents',
            caption: 'enrolled',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatTile(
            icon: Icons.class_rounded,
            label: 'Classes',
            value: '${_classList.length}',
            caption: 'active',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatTile(
            icon: Icons.pie_chart_rounded,
            label: 'Attendance',
            value: avgText,
            caption: _avgAttendance == null ? 'no records yet' : 'average',
          ),
        ),
      ],
    );
  }

  Widget _buildStatTile({
    required IconData icon,
    required String label,
    required String value,
    required String caption,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.primaryBlue, size: 18),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0F172A),
              ),
            ),
          ),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF334155),
            ),
          ),
          Text(
            caption,
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  /// Things the teacher can act on, with real counts.
  Widget _buildAttentionCard(BuildContext context) {
    Widget row({
      required IconData icon,
      required Color color,
      required String text,
      required int tab,
    }) {
      return InkWell(
        onTap: () => widget.onTabSelected(tab),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF1E293B),
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: Colors.grey.shade400, size: 20),
            ],
          ),
        ),
      );
    }

    final rows = <Widget>[
      if (_pendingExcuseCount > 0)
        row(
          icon: Icons.mark_email_unread_outlined,
          color: const Color(0xFFF59E0B),
          text:
              '$_pendingExcuseCount excuse letter${_pendingExcuseCount == 1 ? '' : 's'} waiting for review',
          tab: 3,
        ),
      if (_atRiskStudentsCount > 0)
        row(
          icon: Icons.person_off_outlined,
          color: const Color(0xFFEF4444),
          text:
              '$_atRiskStudentsCount student${_atRiskStudentsCount == 1 ? '' : 's'} with 2 or more absences',
          tab: 3,
        ),
      if (_openSessionCount > 0)
        row(
          icon: Icons.qr_code_2_rounded,
          color: AppColors.primaryBlue,
          text:
              '$_openSessionCount attendance session${_openSessionCount == 1 ? '' : 's'} still open',
          tab: 2,
        ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: rows.isEmpty ? 14 : 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: rows.isEmpty
          ? Row(
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    color: Colors.green.shade500, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "You're all caught up. No excuse letters to review, no at-risk students and no open sessions.",
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      color: Colors.grey.shade700,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (int i = 0; i < rows.length; i++) ...[
                  rows[i],
                  if (i != rows.length - 1)
                    Divider(height: 1, color: Colors.grey.shade200),
                ],
              ],
            ),
    );
  }

  /// Classes that meet today, worked out from each class schedule.
  Widget _buildTodaySchedule() {
    int startMinutes(FacultyClassItem c) {
      final t = ScheduleUtils.parseStartTime(c.schedule);
      return t == null ? 0 : t.hour * 60 + t.minute;
    }

    final int today = DateTime.now().weekday;
    final todays = _classList
        .where((c) => ScheduleUtils.parseWeekdays(c.schedule).contains(today))
        .toList()
      ..sort((a, b) => startMinutes(a).compareTo(startMinutes(b)));

    if (todays.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.event_available_rounded,
                color: Colors.grey.shade400, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _nextIsReal
                    ? 'No classes today. Next: $_nextClassCode ($_nextClassWhen)'
                    : 'No classes scheduled for today.',
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          for (int i = 0; i < todays.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.primaryBlue,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${todays[i].code}  •  ${todays[i].title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1E293B),
                          ),
                        ),
                        Text(
                          '${todays[i].schedule}  •  ${todays[i].enrolledCount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 10.5,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => widget.onTabSelected(2),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.primaryBlue),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Start QR',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i != todays.length - 1)
              Divider(height: 1, color: Colors.grey.shade200),
          ],
        ],
      ),
    );
  }

  /// Attendance rate for each class (lowest first). Tap to open Records.
  Widget _buildClassRatesCard() {
    Color colorFor(double r) {
      if (r >= 0.85) return const Color(0xFF10B981);
      if (r >= 0.70) return const Color(0xFFF59E0B);
      return const Color(0xFFEF4444);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _classRates.length; i++) ...[
            InkWell(
              onTap: () => widget.onTabSelected(3),
              borderRadius: BorderRadius.circular(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_classRates[i]['code']}',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      Text(
                        '${((_classRates[i]['rate'] as double) * 100).round()}%',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: colorFor(_classRates[i]['rate'] as double),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _classRates[i]['rate'] as double,
                      minHeight: 8,
                      backgroundColor: Colors.grey.shade100,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorFor(_classRates[i]['rate'] as double),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i != _classRates.length - 1) const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _buildAnalyticsCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Attendance by Day',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
                  Text(
                    'Present, late or excused, across all sessions',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
              const Icon(
                Icons.bar_chart_rounded,
                color: AppColors.primaryBlue,
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _BarChartColumn(
                  day: 'Mon', percentage: _weeklyPercentages['Mon']),
              _BarChartColumn(
                  day: 'Tue', percentage: _weeklyPercentages['Tue']),
              _BarChartColumn(
                  day: 'Wed', percentage: _weeklyPercentages['Wed']),
              _BarChartColumn(
                  day: 'Thu', percentage: _weeklyPercentages['Thu']),
              _BarChartColumn(
                  day: 'Fri', percentage: _weeklyPercentages['Fri']),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaginatedClasses() {
    if (_classList.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Center(
          child: Text(
            'No active classes assigned yet.',
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 110,
          child: PageView.builder(
            controller: _classPageController,
            itemCount: _classList.length,
            onPageChanged: (index) {
              setState(() => _currentClassPage = index);
            },
            itemBuilder: (context, index) {
              final item = _classList[index];
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryBlue,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  item.code,
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.schedule,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF0F172A),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        item.enrolledCount,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.primaryBlue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (_classList.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              _classList.length > 5 ? 5 : _classList.length,
              (index) {
                final isSelected = index == _currentClassPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: isSelected ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primaryBlue
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQuickActionItem({
    required IconData icon,
    required String label,
    required Color color,
    required Color backgroundColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: backgroundColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: const Color(0xFF334155),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BarChartColumn extends StatelessWidget {
  final String day;
  final double? percentage; // null = no sessions on that day

  const _BarChartColumn({
    required this.day,
    required this.percentage,
  });

  @override
  Widget build(BuildContext context) {
    final double? p = percentage;
    final String label = p == null ? '—' : '${(p * 100).round()}%';

    return Column(
      children: [
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 9,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 50,
          width: 12,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.bottomCenter,
          child: p == null
              ? null
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 50 * p.clamp(0.05, 1.0),
                  width: 12,
                  decoration: BoxDecoration(
                    color: AppColors.primaryBlue,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          day,
          style: GoogleFonts.poppins(
            fontSize: 11,
            color: const Color(0xFF64748B),
          ),
        ),
      ],
    );
  }
}
