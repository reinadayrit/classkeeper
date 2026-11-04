import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';

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
  double _avgAttendance = 0.0;
  int _atRiskStudentsCount = 0;
  Map<String, double> _weeklyPercentages = {
    'Mon': 0.0,
    'Tue': 0.0,
    'Wed': 0.0,
    'Thu': 0.0,
    'Fri': 0.0,
  };

  // Up Next scheduled class variables
  String _nextClassCode = 'N/A';
  String _nextClassTitle = 'No upcoming class scheduled';
  String _nextClassSchedule = 'N/A';

  // Classes Pagination State
  final PageController _classPageController = PageController();
  int _currentClassPage = 0;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  @override
  void dispose() {
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

      // 3. Set "Up Next" class values (First Active Class)
      if (classesResponse.isNotEmpty) {
        final nextClass = classesResponse.first;
        _nextClassCode = nextClass['course_code'] ?? 'COURSE';
        _nextClassTitle = nextClass['course_name'] ?? 'Scheduled Class';
        _nextClassSchedule = nextClass['schedule'] ?? 'Schedule not set';
      } else {
        _nextClassCode = 'N/A';
        _nextClassTitle = 'No active class scheduled';
        _nextClassSchedule = 'N/A';
      }

      // 4. Compute Dynamic Attendance Analytics & At-Risk Students for ACTIVE classes only
      int totalLogs = 0;
      int presentOrLateCount = 0;
      final Map<String, int> studentAbsentCounts = {};
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
            .select('id, created_at')
            .inFilter('class_id', activeClassIds);

        final Map<String, DateTime> sessionDateMap = {};
        final List<String> sessionIds = [];

        for (var s in sessionsRes) {
          final sId = s['id'].toString();
          sessionIds.add(sId);
          if (s['created_at'] != null) {
            sessionDateMap[sId] =
                DateTime.tryParse(s['created_at'].toString())?.toLocal() ??
                    DateTime.now();
          }
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

      // Average attendance calculation (Active classes only)
      final double calculatedAvg =
          totalLogs > 0 ? (presentOrLateCount / totalLogs) * 100 : 100.0;

      // Count students missing 3+ active class sessions
      final int atRisk =
          studentAbsentCounts.values.where((cnt) => cnt >= 3).length;

      // Dynamic weekly breakdown percentages
      final Map<String, double> computedWeekly = {
        'Mon': weekdayCounters[1]![1] > 0
            ? weekdayCounters[1]![0] / weekdayCounters[1]![1]
            : 0.85,
        'Tue': weekdayCounters[2]![1] > 0
            ? weekdayCounters[2]![0] / weekdayCounters[2]![1]
            : 0.90,
        'Wed': weekdayCounters[3]![1] > 0
            ? weekdayCounters[3]![0] / weekdayCounters[3]![1]
            : 0.88,
        'Thu': weekdayCounters[4]![1] > 0
            ? weekdayCounters[4]![0] / weekdayCounters[4]![1]
            : 0.92,
        'Fri': weekdayCounters[5]![1] > 0
            ? weekdayCounters[5]![0] / weekdayCounters[5]![1]
            : 0.80,
      };

      if (mounted) {
        setState(() {
          _classList = loadedClasses;
          _totalStudents = aggregateStudents;
          _avgAttendance = calculatedAvg;
          _atRiskStudentsCount = atRisk;
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
                                'UP NEXT • $_nextClassCode',
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
                                _nextClassSchedule,
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
                  _buildSectionTitle('METRICS & USAGE'),
                  const SizedBox(height: 12),
                  _buildUsageProgressCards(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('ATTENTION REQUIRED'),
                  const SizedBox(height: 12),
                  _buildAttentionCard(context),
                  const SizedBox(height: 24),
                  _buildSectionTitle('ATTENDANCE ANALYTICS'),
                  const SizedBox(height: 12),
                  _buildAnalyticsCard(context),
                  const SizedBox(height: 24),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          _buildUsageLineItem(
            icon: Icons.groups_rounded,
            title: 'Total Enrolled Students',
            currentValue: '$_totalStudents Students',
            totalValue: '320 Capacity',
            progressRatio: (_totalStudents / 320).clamp(0.0, 1.0),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMiniProgressMetric(
                  icon: Icons.class_rounded,
                  title: 'Active Classes',
                  valueStr: '${_classList.length} Courses',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMiniProgressMetric(
                  icon: Icons.pie_chart_rounded,
                  title: 'Avg Attendance',
                  valueStr: '${_avgAttendance.toStringAsFixed(1)}% Present',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUsageLineItem({
    required IconData icon,
    required String title,
    required String currentValue,
    required String totalValue,
    required double progressRatio,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.groups_rounded,
                color: AppColors.primaryBlue,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0F172A),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              currentValue,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
              ),
            ),
            Text(
              totalValue,
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progressRatio,
            minHeight: 8,
            backgroundColor: Colors.grey.shade100,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppColors.primaryBlue,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniProgressMetric({
    required IconData icon,
    required String title,
    required String valueStr,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: const Color(0xFF2563EB), size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: Colors.grey.shade600,
                  ),
                ),
                Text(
                  valueStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttentionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14.0),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFDC2626),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Absence Alerts',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF991B1B),
                  ),
                ),
                Text(
                  _atRiskStudentsCount > 0
                      ? '$_atRiskStudentsCount student(s) missing 3+ sessions will automatically trigger alerts.'
                      : 'Students missing 3+ sessions will automatically trigger alerts.',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: const Color(0xFFB91C1C),
                  ),
                ),
              ],
            ),
          ),
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
              Text(
                'Weekly Attendance Overview',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1E293B),
                ),
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
                  day: 'Mon', percentage: _weeklyPercentages['Mon']!),
              _BarChartColumn(
                  day: 'Tue', percentage: _weeklyPercentages['Tue']!),
              _BarChartColumn(
                  day: 'Wed', percentage: _weeklyPercentages['Wed']!),
              _BarChartColumn(
                  day: 'Thu', percentage: _weeklyPercentages['Thu']!),
              _BarChartColumn(
                  day: 'Fri', percentage: _weeklyPercentages['Fri']!),
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
  final double percentage;

  const _BarChartColumn({
    required this.day,
    required this.percentage,
  });

  @override
  Widget build(BuildContext context) {
    final int displayPct = (percentage * 100).toInt();

    return Column(
      children: [
        Text(
          '$displayPct%',
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: (50 * percentage.clamp(0.05, 1.0)),
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
