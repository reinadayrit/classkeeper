import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import 'student_profile_screen.dart';

class StudentDashboardScreen extends StatefulWidget {
  final Function(int)? onTabSelected;

  const StudentDashboardScreen({super.key, this.onTabSelected});

  @override
  State<StudentDashboardScreen> createState() => _StudentDashboardScreenState();
}

class _StudentDashboardScreenState extends State<StudentDashboardScreen> {
  final _supabase = Supabase.instance.client;

  bool _isLoading = true;

  // Student Profile Data
  String _fullName = 'Student';
  String _schoolId = 'N/A';

  // Dynamic Dashboard Stats
  double _attendanceRate = 0.0;
  int _enrolledClassesCount = 0;
  int _absentCount = 0;
  int _lateCount = 0;

  // Lists for dynamic rendering
  List<Map<String, dynamic>> _todayClasses = [];
  List<Map<String, dynamic>> _announcements = [];
  List<Map<String, dynamic>> _attendanceHistory = [];

  // Pagination Controllers
  final PageController _classPageController = PageController();
  int _currentClassPage = 0;

  final PageController _attendancePageController = PageController();
  int _currentAttendancePage = 0;

  static const List<String> _weekDays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat'
  ];

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  @override
  void dispose() {
    _classPageController.dispose();
    _attendancePageController.dispose();
    super.dispose();
  }

  Future<void> _fetchDashboardData() async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      if (mounted) setState(() => _isLoading = true);

      // 1. Profile Query
      try {
        final profileRes = await _supabase
            .from('profiles')
            .select('full_name, school_id')
            .eq('id', user.id)
            .maybeSingle();

        if (profileRes != null) {
          _fullName = profileRes['full_name'] as String? ?? 'Student';
          _schoolId = profileRes['school_id'] as String? ?? 'N/A';
        }
      } catch (e) {
        debugPrint('Profile query error: $e');
      }

      // 2. Class Enrollments Query
      final List<Map<String, dynamic>> enrolledClasses = [];
      final List<dynamic> classIds = [];

      try {
        final List<dynamic> enrollmentsRes = await _supabase
            .from('class_enrollments')
            .select(
                'class_id, classes(id, course_code, course_name, schedule, section)')
            .eq('student_id', user.id);

        for (final item in enrollmentsRes) {
          if (item is Map && item['classes'] != null) {
            final classData = item['classes'] as Map<String, dynamic>;
            enrolledClasses.add(classData);
            if (classData['id'] != null) {
              classIds.add(classData['id']);
            }
          }
        }
      } catch (e) {
        debugPrint('Enrollments query error: $e');
      }

      _enrolledClassesCount = enrolledClasses.length;

      // 3. Attendance History & Metrics Query (Calculates Rate, Absents, and Lates)
      try {
        final List<dynamic> attendanceRes = await _supabase
            .from('attendance_records')
            .select('''
              id,
              status,
              reason_category,
              remarks,
              scanned_at,
              attendance_sessions (
                date,
                classes (
                  course_code,
                  course_name
                )
              )
            ''')
            .eq('student_id', user.id)
            .order('scanned_at', ascending: false);

        if (attendanceRes.isNotEmpty) {
          final totalLogs = attendanceRes.length;
          int validAttendanceCount = 0;
          int absentCounter = 0;
          int lateCounter = 0;

          for (final log in attendanceRes) {
            if (log is Map && log['status'] != null) {
              final statusStr = log['status'].toString().toLowerCase();

              if (statusStr == 'present' ||
                  statusStr == 'late' ||
                  statusStr == 'excused') {
                validAttendanceCount++;
              }

              if (statusStr == 'absent') {
                absentCounter++;
              } else if (statusStr == 'late') {
                lateCounter++;
              }
            }
          }

          _attendanceRate = (validAttendanceCount / totalLogs) * 100;
          _absentCount = absentCounter;
          _lateCount = lateCounter;
        } else {
          _attendanceRate = 100.0;
          _absentCount = 0;
          _lateCount = 0;
        }

        _attendanceHistory = List<Map<String, dynamic>>.from(attendanceRes);
      } catch (e) {
        debugPrint('Attendance query error: $e');
        _attendanceRate = 100.0;
        _absentCount = 0;
        _lateCount = 0;
      }

      // 4. Today's Classes List
      _todayClasses = enrolledClasses.map((cls) {
        return {
          'code': cls['course_code']?.toString() ?? 'N/A',
          'title': cls['course_name']?.toString() ?? 'Untitled Course',
          'time': '${cls['schedule'] ?? "TBA"} • Sec ${cls['section'] ?? "A"}',
          'status': 'Scheduled',
          'statusColor': AppColors.primaryBlue,
          'statusBg': const Color(0xFFEFF6FF),
        };
      }).toList();

      // 5. Announcements Query
      if (classIds.isNotEmpty) {
        try {
          final List<dynamic> annRes = await _supabase
              .from('announcements')
              .select(
                  'title, content, created_at, classes(course_code, course_name)')
              .inFilter('class_id', classIds)
              .order('created_at', ascending: false)
              .limit(5);

          _announcements = annRes.map((ann) {
            Map<String, dynamic>? classInfo;
            if (ann['classes'] is Map<String, dynamic>) {
              classInfo = ann['classes'] as Map<String, dynamic>;
            }

            final courseCode =
                classInfo?['course_code']?.toString() ?? 'GENERAL';
            final courseTitle = classInfo?['course_name']?.toString() ?? '';
            final createdAt =
                DateTime.tryParse(ann['created_at']?.toString() ?? '') ??
                    DateTime.now();

            return {
              'course': courseTitle.isNotEmpty
                  ? '$courseCode - $courseTitle'
                  : courseCode,
              'timeAgo': _formatTimeAgo(createdAt),
              'title': ann['title']?.toString() ?? 'Notice',
              'desc': ann['content']?.toString() ?? '',
            };
          }).toList();
        } catch (e) {
          debugPrint('Announcements query error: $e');
        }
      } else {
        _announcements = [];
      }
    } catch (e) {
      debugPrint('Dashboard data fetch error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatTimeAgo(DateTime dateTime) {
    final difference = DateTime.now().difference(dateTime);
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  String _formatDateTime(dynamic scannedAt, String? sessionDate) {
    if (scannedAt != null) {
      final parsed = DateTime.tryParse(scannedAt.toString())?.toLocal();
      if (parsed != null) {
        final year = parsed.year;
        final month = parsed.month.toString().padLeft(2, '0');
        final day = parsed.day.toString().padLeft(2, '0');

        final hourNum = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
        final minute = parsed.minute.toString().padLeft(2, '0');
        final period = parsed.hour >= 12 ? 'PM' : 'AM';

        return '$year-$month-$day • $hourNum:$minute $period';
      }
    }
    return sessionDate ?? 'N/A';
  }

  // --- STUDENT REASON SUBMISSION MODAL (ENABLED ONLY WITHIN 3 DAYS) ---
  void _showStudentAddReasonModal(Map<String, dynamic> record) {
    final reasonCtrl = TextEditingController();
    String? selectedCategory = 'Medical / Illness';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Submit Absence/Late Reason',
            style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('REASON CATEGORY',
                style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: selectedCategory,
              items: [
                'Medical / Illness',
                'Transportation / Traffic',
                'Family Emergency',
                'School Activity',
                'Other'
              ]
                  .map((cat) => DropdownMenuItem(
                      value: cat,
                      child:
                          Text(cat, style: GoogleFonts.poppins(fontSize: 12))))
                  .toList(),
              onChanged: (val) => selectedCategory = val,
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            Text('EXPLANATION / REMARKS',
                style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue)),
            const SizedBox(height: 6),
            TextField(
              controller: reasonCtrl,
              style: GoogleFonts.poppins(fontSize: 12),
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Enter explanation for late scan or absence...',
                hintStyle: GoogleFonts.poppins(
                    fontSize: 11, color: Colors.grey.shade400),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryBlue),
            onPressed: () async {
              await _supabase.from('attendance_records').update({
                'reason_category': selectedCategory,
                'remarks': reasonCtrl.text.trim(),
              }).eq('id', record['id']);

              if (mounted) {
                Navigator.pop(ctx);
                _fetchDashboardData();
              }
            },
            child: Text('Submit',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final firstName = _fullName.trim().split(' ').first;

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primaryBlue),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: RefreshIndicator(
        onRefresh: _fetchDashboardData,
        color: AppColors.primaryBlue,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- 1. TOP BLUE BANNER & FLOATING CHECK-IN CARD ---
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
                                    Icons.badge_rounded,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'ID: $_schoolId',
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
                              onTap: () {
                                if (widget.onTabSelected != null) {
                                  widget.onTabSelected!(4);
                                } else {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          const StudentProfileScreen(),
                                    ),
                                  );
                                }
                              },
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
                                  child: const Icon(
                                    Icons.person_rounded,
                                    color: AppColors.primaryBlue,
                                    size: 20,
                                  ),
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
                          "Let's keep your attendance in check!",
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
                              Icons.qr_code_scanner_rounded,
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
                                  'QUICK CHECK-IN',
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                Text(
                                  'Scan Class QR Code',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.poppins(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF0F172A),
                                  ),
                                ),
                                Text(
                                  'Mark attendance with GPS verification',
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
                          ElevatedButton(
                            onPressed: () => widget.onTabSelected?.call(2),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryBlue,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                            ),
                            child: Text(
                              'Scan Now',
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
                    _buildSectionTitle('ATTENDANCE ANALYTICS'),
                    const SizedBox(height: 12),
                    _buildAttendanceGraph(),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildSectionTitle("TODAY'S CLASSES"),
                        GestureDetector(
                          onTap: () => widget.onTabSelected?.call(1),
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
                    _buildPaginatedTodayClasses(),
                    const SizedBox(height: 24),
                    _buildSectionTitle('RECENT ATTENDANCE RECORDS'),
                    const SizedBox(height: 12),
                    _buildPaginatedAttendanceRecords(),
                    const SizedBox(height: 24),
                    _buildSectionTitle('RECENT ANNOUNCEMENTS'),
                    const SizedBox(height: 12),
                    _buildAnnouncementsList(),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
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
          icon: Icons.qr_code_scanner_rounded,
          label: 'Scan QR',
          color: AppColors.primaryBlue,
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected?.call(2),
        ),
        _buildQuickActionItem(
          icon: Icons.class_rounded,
          label: 'Classes',
          color: const Color(0xFF2563EB),
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected?.call(1),
        ),
        _buildQuickActionItem(
          icon: Icons.campaign_rounded,
          label: 'Announce',
          color: AppColors.primaryBlue,
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected?.call(3),
        ),
        _buildQuickActionItem(
          icon: Icons.person_rounded,
          label: 'Profile',
          color: const Color(0xFF2563EB),
          backgroundColor: const Color(0xFFEFF6FF),
          onTap: () => widget.onTabSelected?.call(4),
        ),
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

  Widget _buildUsageProgressCards() {
    final double rateRatio = (_attendanceRate / 100).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Column(
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
                      Icons.add_task_rounded,
                      color: AppColors.primaryBlue,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Overall Attendance Rate',
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
                    '${_attendanceRate.toStringAsFixed(0)}% Rate',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                    ),
                  ),
                  Text(
                    _attendanceRate >= 85 ? 'Good standing' : 'Needs attention',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: _attendanceRate >= 85
                          ? Colors.green.shade600
                          : Colors.orange.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: rateRatio,
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade100,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.primaryBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMiniProgressMetric(
                  icon: Icons.school_rounded,
                  title: 'Enrolled Classes',
                  valueStr: '$_enrolledClassesCount Courses',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildMiniProgressMetric(
                  icon: Icons.cancel_outlined,
                  title: 'Total Absents',
                  valueStr: '$_absentCount Days',
                  iconColor: Colors.red.shade600,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildMiniProgressMetric(
                  icon: Icons.access_time_rounded,
                  title: 'Total Lates',
                  valueStr: '$_lateCount Days',
                  iconColor: Colors.orange.shade800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniProgressMetric({
    required IconData icon,
    required String title,
    required String valueStr,
    Color iconColor = const Color(0xFF2563EB),
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 9,
              color: Colors.grey.shade600,
            ),
          ),
          Text(
            valueStr,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceGraph() {
    return Container(
      padding: const EdgeInsets.all(16),
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
                    'Attendance Overview',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                  Text(
                    'Weekly performance trend',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_attendanceRate.toStringAsFixed(0)}%',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 90,
            width: double.infinity,
            child: CustomPaint(
              painter: _AttendanceChartPainter(
                lineColor: AppColors.primaryBlue,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _weekDays
                .map(
                  (day) => Text(
                    day,
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginatedTodayClasses() {
    if (_todayClasses.isEmpty) {
      return _buildEmptyTile('No classes scheduled for today.');
    }

    return Column(
      children: [
        SizedBox(
          height: 105,
          child: PageView.builder(
            controller: _classPageController,
            itemCount: _todayClasses.length,
            onPageChanged: (index) {
              setState(() => _currentClassPage = index);
            },
            itemBuilder: (context, index) {
              final cls = _todayClasses[index];
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryBlue,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        cls['code'],
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            cls['title'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF0F172A),
                            ),
                          ),
                          Text(
                            cls['time'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 10,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: cls['statusBg'],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        cls['status'],
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: cls['statusColor'],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (_todayClasses.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              _todayClasses.length > 5 ? 5 : _todayClasses.length,
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

  // --- PAGINATED ATTENDANCE RECORDS (3 ITEMS PER PAGE TO REMOVE GAP) ---
  Widget _buildPaginatedAttendanceRecords() {
    if (_attendanceHistory.isEmpty) {
      return _buildEmptyTile('No attendance recorded yet.');
    }

    const int itemsPerPage = 3;
    final int pageCount = (_attendanceHistory.length / itemsPerPage).ceil();

    return Column(
      children: [
        SizedBox(
          height: 240,
          child: PageView.builder(
            controller: _attendancePageController,
            itemCount: pageCount,
            onPageChanged: (index) {
              setState(() => _currentAttendancePage = index);
            },
            itemBuilder: (context, pageIndex) {
              final startIndex = pageIndex * itemsPerPage;
              final endIndex =
                  (startIndex + itemsPerPage < _attendanceHistory.length)
                      ? startIndex + itemsPerPage
                      : _attendanceHistory.length;
              final pageItems =
                  _attendanceHistory.sublist(startIndex, endIndex);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: pageItems.map((record) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: _buildAttendanceRecordCard(record),
                  );
                }).toList(),
              );
            },
          ),
        ),
        if (pageCount > 1) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(pageCount > 5 ? 5 : pageCount, (index) {
              final isSelected = index == _currentAttendancePage;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: isSelected ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color:
                      isSelected ? AppColors.primaryBlue : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  Widget _buildAttendanceRecordCard(Map<String, dynamic> record) {
    final session = record['attendance_sessions'] as Map<String, dynamic>?;
    final classData = session?['classes'] as Map<String, dynamic>?;

    final courseCode = classData?['course_code'] ?? 'Class';
    final sessionDateStr = session?['date']?.toString();
    final scannedAtStr = record['scanned_at']?.toString();
    final formattedDateTime = _formatDateTime(scannedAtStr, sessionDateStr);

    final dateToCompare =
        DateTime.tryParse(scannedAtStr ?? sessionDateStr ?? '') ??
            DateTime.now();
    final daysDifference = DateTime.now().difference(dateToCompare).inDays;
    final bool canAddReason = daysDifference <= 3;

    final statusStr = record['status']?.toString().toUpperCase() ?? 'PRESENT';
    final statusLower = statusStr.toLowerCase();

    final isPresent = statusLower == 'present';
    final isLate = statusLower == 'late';
    final isExcused = statusLower == 'excused';
    final isAbsent = statusLower == 'absent';

    final remarks = record['remarks'];
    final reasonCat = record['reason_category'];

    Color badgeBg = isPresent
        ? const Color(0xFFE8F5E9)
        : isLate
            ? const Color(0xFFFFF3E0)
            : isExcused
                ? const Color(0xFFEEF2FF)
                : const Color(0xFFFFEBEE);

    Color badgeColor = isPresent
        ? Colors.green.shade700
        : isLate
            ? Colors.orange.shade800
            : isExcused
                ? const Color(0xFF6366F1)
                : Colors.red.shade700;

    IconData statusIcon = isPresent
        ? Icons.check_circle_outline
        : isLate
            ? Icons.access_time
            : isExcused
                ? Icons.verified_user_outlined
                : Icons.cancel_outlined;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    statusIcon,
                    color: badgeColor,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        courseCode,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      Text(
                        formattedDateTime,
                        style: GoogleFonts.poppins(
                          fontSize: 9,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  statusStr,
                  style: GoogleFonts.poppins(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          if (reasonCat != null || remarks != null) ...[
            const SizedBox(height: 4),
            Text(
              'Remark: ${reasonCat ?? ''} ${remarks != null ? "($remarks)" : ""}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: isExcused ? const Color(0xFF4338CA) : Colors.blueGrey,
              ),
            ),
          ] else if ((isAbsent || isLate) && !isExcused) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  canAddReason
                      ? 'Submit reason within 3 days'
                      : 'Reason submission closed (>3 days)',
                  style: GoogleFonts.poppins(
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                    color: canAddReason
                        ? Colors.orange.shade800
                        : Colors.grey.shade400,
                  ),
                ),
                if (canAddReason)
                  GestureDetector(
                    onTap: () => _showStudentAddReasonModal(record),
                    child: Text(
                      'Add Reason',
                      style: GoogleFonts.poppins(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAnnouncementsList() {
    if (_announcements.isEmpty) {
      return _buildEmptyTile('No recent announcements.');
    }

    return Column(
      children: _announcements
          .map(
            (ann) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AnnouncementTile(
                course: ann['course'],
                timeAgo: ann['timeAgo'],
                title: ann['title'],
                desc: ann['desc'],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildEmptyTile(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Center(
        child: Text(
          message,
          style: GoogleFonts.poppins(
            fontSize: 12,
            color: Colors.grey.shade500,
          ),
        ),
      ),
    );
  }
}

// --- ANNOUNCEMENT TILE ---
class AnnouncementTile extends StatelessWidget {
  final String course;
  final String timeAgo;
  final String title;
  final String desc;

  const AnnouncementTile({
    super.key,
    required this.course,
    required this.timeAgo,
    required this.title,
    required this.desc,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  course,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ),
              Text(
                timeAgo,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: Colors.grey.shade400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

// --- ATTENDANCE CHART PAINTER ---
class _AttendanceChartPainter extends CustomPainter {
  final Color lineColor;

  _AttendanceChartPainter({required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      Offset(0, size.height * 0.65),
      Offset(size.width * 0.2, size.height * 0.45),
      Offset(size.width * 0.4, size.height * 0.70),
      Offset(size.width * 0.6, size.height * 0.25),
      Offset(size.width * 0.8, size.height * 0.35),
      Offset(size.width, size.height * 0.15),
    ];

    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final controlPoint1 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p0.dy);
      final controlPoint2 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p1.dy);
      path.cubicTo(
        controlPoint1.dx,
        controlPoint1.dy,
        controlPoint2.dx,
        controlPoint2.dy,
        p1.dx,
        p1.dy,
      );
    }

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.20),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, linePaint);

    final dotOuterPaint = Paint()..color = lineColor;
    final dotInnerPaint = Paint()..color = Colors.white;

    for (var point in points) {
      canvas.drawCircle(point, 4.5, dotOuterPaint);
      canvas.drawCircle(point, 2.0, dotInnerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
