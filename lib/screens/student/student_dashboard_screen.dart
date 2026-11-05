import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/schedule_utils.dart';
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
  bool _hasRecords = false; // false = nothing recorded yet
  int _enrolledClassesCount = 0;
  int _presentCount = 0;
  int _lateCount = 0;
  int _excusedCount = 0;
  int _absentCount = 0;
  int _streak = 0; // sessions in a row without an absence

  // Attendance rate per class, and absences that still need a reason
  List<Map<String, dynamic>> _classRates = [];
  List<Map<String, dynamic>> _needsReason = [];
  String _nextClassHint = '';

  // Lists for dynamic rendering
  List<Map<String, dynamic>> _todayClasses = [];
  List<Map<String, dynamic>> _announcements = [];
  List<Map<String, dynamic>> _attendanceHistory = [];

  // Pagination Controllers
  final PageController _classPageController = PageController();
  int _currentClassPage = 0;

  final PageController _attendancePageController = PageController();
  int _currentAttendancePage = 0;

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

      // 3. Attendance history & metrics
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
                class_id,
                date,
                classes (
                  course_code,
                  course_name
                )
              )
            ''')
            .eq('student_id', user.id);

        final List<Map<String, dynamic>> records = attendanceRes
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        DateTime? recordDate(Map<String, dynamic> r) {
          final session = r['attendance_sessions'] as Map<String, dynamic>?;
          return DateTime.tryParse(session?['date']?.toString() ?? '') ??
              DateTime.tryParse(r['scanned_at']?.toString() ?? '')?.toLocal();
        }

        // Newest first (absent records have no scan time, so sort by the
        // session date instead of scanned_at)
        records.sort((a, b) {
          final da = recordDate(a);
          final db = recordDate(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });

        int present = 0, late = 0, excused = 0, absent = 0;
        int streak = 0;
        bool streakBroken = false;
        final Map<String, List<int>> perClass = {}; // code -> [attended, total]
        final Map<String, String> classNames = {};
        final List<Map<String, dynamic>> needsReason = [];

        for (final r in records) {
          final st = r['status']?.toString().toLowerCase() ?? '';

          if (st == 'present') present++;
          if (st == 'late') late++;
          if (st == 'excused') excused++;
          if (st == 'absent') absent++;

          final bool attended = st != 'absent';

          if (!streakBroken) {
            if (attended) {
              streak++;
            } else {
              streakBroken = true;
            }
          }

          final session = r['attendance_sessions'] as Map<String, dynamic>?;
          final cls = session?['classes'] as Map<String, dynamic>?;
          final String code = cls?['course_code']?.toString() ?? 'Class';
          classNames[code] = cls?['course_name']?.toString() ?? '';

          final counts = perClass.putIfAbsent(code, () => [0, 0]);
          counts[1]++;
          if (attended) counts[0]++;

          if (st == 'absent' &&
              (r['reason_category']?.toString() ?? '').isEmpty) {
            needsReason.add(r);
          }
        }

        final int total = records.length;

        _hasRecords = total > 0;
        _attendanceRate =
            total == 0 ? 0.0 : (present + late + excused) / total * 100;
        _presentCount = present;
        _lateCount = late;
        _excusedCount = excused;
        _absentCount = absent;
        _streak = streak;
        _needsReason = needsReason;

        _classRates = perClass.entries.map((e) {
          return {
            'code': e.key,
            'name': classNames[e.key] ?? '',
            'attended': e.value[0],
            'total': e.value[1],
            'rate': e.value[1] == 0 ? 0.0 : e.value[0] / e.value[1],
          };
        }).toList()
          ..sort((a, b) {
            final c = (a['rate'] as double).compareTo(b['rate'] as double);
            return c != 0
                ? c
                : a['code'].toString().compareTo(b['code'].toString());
          });

        _attendanceHistory = records;
      } catch (e) {
        debugPrint('Attendance query error: $e');
        _hasRecords = false;
        _attendanceRate = 0.0;
        _presentCount = 0;
        _lateCount = 0;
        _excusedCount = 0;
        _absentCount = 0;
        _streak = 0;
        _classRates = [];
        _needsReason = [];
        _attendanceHistory = [];
      }

      // 4. Today's classes, worked out from each class schedule
      final int todayWeekday = DateTime.now().weekday;

      int startMinutes(Map<String, dynamic> cls) {
        final t = ScheduleUtils.parseStartTime((cls['schedule'] ?? '').toString());
        return t == null ? 0 : t.hour * 60 + t.minute;
      }

      final todaysList = enrolledClasses
          .where((cls) => ScheduleUtils.parseWeekdays(
                  (cls['schedule'] ?? '').toString())
              .contains(todayWeekday))
          .toList()
        ..sort((a, b) => startMinutes(a).compareTo(startMinutes(b)));

      _todayClasses = todaysList.map((cls) {
        return {
          'code': cls['course_code']?.toString() ?? 'N/A',
          'title': cls['course_name']?.toString() ?? 'Untitled Course',
          'time': '${cls['schedule'] ?? "TBA"} • Sec ${cls['section'] ?? "A"}',
          'status': 'Today',
          'statusColor': AppColors.primaryBlue,
          'statusBg': const Color(0xFFEFF6FF),
        };
      }).toList();

      // Hint shown when there is no class today
      final nextClass = ScheduleUtils.nextOccurrence(
        enrolledClasses.map((c) => (c['schedule'] ?? '').toString()).toList(),
      );
      _nextClassHint = nextClass == null
          ? ''
          : 'Next class: ${enrolledClasses[nextClass.index]['course_code']} - ${ScheduleUtils.whenLabel(nextClass)}';

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

  // --- STUDENT REASON SUBMISSION ---
  // Saves the reason on the attendance record AND creates the excuse letter
  // (pending) so the teacher sees it, the same as the Classes screen.
  void _showStudentAddReasonModal(Map<String, dynamic> record) {
    final reasonCtrl = TextEditingController(
      text: (record['remarks'] ?? '').toString().startsWith('Auto-marked')
          ? ''
          : (record['remarks'] ?? '').toString(),
    );
    String? selectedCategory = 'Medical / Illness';
    bool isSubmitting = false;

    final session = record['attendance_sessions'] as Map<String, dynamic>?;
    final String? classId = session?['class_id']?.toString();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
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
                  'Official University Memo',
                  'Other'
                ]
                    .map((cat) => DropdownMenuItem(
                        value: cat,
                        child: Text(cat,
                            style: GoogleFonts.poppins(fontSize: 12))))
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
                onPressed: isSubmitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryBlue),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final String remarks = reasonCtrl.text.trim();
                      if (remarks.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Please explain your reason.'),
                          ),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);

                      try {
                        final user = _supabase.auth.currentUser;

                        await _supabase.from('attendance_records').update({
                          'reason_category': selectedCategory,
                          'remarks': remarks,
                        }).eq('id', record['id']);

                        // Excuse letter for the teacher to review
                        if (user != null && classId != null) {
                          final existing = await _supabase
                              .from('absence_reasons')
                              .select('id')
                              .eq('attendance_record_id', record['id'])
                              .maybeSingle();

                          final letter = {
                            'reason': '$selectedCategory: $remarks',
                            'status': 'pending',
                          };

                          if (existing != null) {
                            await _supabase
                                .from('absence_reasons')
                                .update(letter)
                                .eq('id', existing['id']);
                          } else {
                            await _supabase.from('absence_reasons').insert({
                              'attendance_record_id': record['id'],
                              'student_id': user.id,
                              'class_id': classId,
                              ...letter,
                            });
                          }
                        }

                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Reason submitted to your teacher.'),
                            ),
                          );
                          _fetchDashboardData();
                        }
                      } catch (e) {
                        debugPrint('Reason submit error: $e');
                        if (ctx.mounted) {
                          setDialogState(() => isSubmitting = false);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Could not save your reason. Please try again.'),
                            ),
                          );
                        }
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text('Submit',
                      style: GoogleFonts.poppins(
                          color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    ).then((_) {
      // Wait for the closing animation before disposing the controller
      Future.delayed(const Duration(milliseconds: 600), reasonCtrl.dispose);
    });
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
                    _buildSectionTitle('ATTENDANCE OVERVIEW'),
                    const SizedBox(height: 12),
                    _buildUsageProgressCards(),
                    const SizedBox(height: 24),
                    if (_needsReason.isNotEmpty) ...[
                      _buildSectionTitle('ABSENCES NEEDING A REASON'),
                      const SizedBox(height: 12),
                      _buildNeedsReasonCard(),
                      const SizedBox(height: 24),
                    ],
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
                    _buildSectionTitle('ATTENDANCE BY CLASS'),
                    const SizedBox(height: 12),
                    _buildAttendanceGraph(),
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
    final double ratio = (_attendanceRate / 100).clamp(0.0, 1.0);

    final String label;
    final Color color;
    if (!_hasRecords) {
      label = 'No records yet';
      color = Colors.grey;
    } else if (_attendanceRate >= 90) {
      label = 'Excellent';
      color = const Color(0xFF10B981);
    } else if (_attendanceRate >= 75) {
      label = 'Good';
      color = const Color(0xFF3B82F6);
    } else if (_attendanceRate >= 60) {
      label = 'Needs improvement';
      color = const Color(0xFFF59E0B);
    } else {
      label = 'At risk';
      color = const Color(0xFFEF4444);
    }

    Widget countTile(String name, int value, Color c) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                '$value',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: c,
                ),
              ),
              Text(
                name,
                style: GoogleFonts.poppins(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _hasRecords ? '${_attendanceRate.toStringAsFixed(1)}%' : '—',
                style: GoogleFonts.poppins(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0F172A),
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    label,
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Present, late or excused, across $_enrolledClassesCount '
            'class${_enrolledClassesCount == 1 ? '' : 'es'}',
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _hasRecords ? ratio : 0,
              minHeight: 8,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              countTile('Present', _presentCount, const Color(0xFF10B981)),
              const SizedBox(width: 8),
              countTile('Late', _lateCount, const Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              countTile('Excused', _excusedCount, const Color(0xFF8B5CF6)),
              const SizedBox(width: 8),
              countTile('Absent', _absentCount, const Color(0xFFEF4444)),
            ],
          ),
          if (_hasRecords) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  size: 16,
                  color: _streak > 0
                      ? const Color(0xFFF97316)
                      : Colors.grey.shade400,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _streak == 0
                        ? 'Your last session was an absence. Start a new streak next class.'
                        : 'Streak: $_streak session${_streak == 1 ? '' : 's'} in a row without an absence',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: Colors.grey.shade700,
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

  /// Latest absences that still have no reason, with an Add Reason button.
  Widget _buildNeedsReasonCard() {
    final shown = _needsReason.take(3).toList();

    String dateOf(Map<String, dynamic> r) {
      final session = r['attendance_sessions'] as Map<String, dynamic>?;
      final d = DateTime.tryParse(session?['date']?.toString() ?? '');
      if (d == null) return '';
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month - 1]} ${d.day}, ${d.year}';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_needsReason.length} absence${_needsReason.length == 1 ? '' : 's'} without a reason. '
            'Tell your teacher why so it can be reviewed.',
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: const Color(0xFF92400E),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          for (final r in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (((r['attendance_sessions']
                                          as Map<String, dynamic>?)?['classes']
                                      as Map<String, dynamic>?)?['course_code'] ??
                                  'Class')
                              .toString(),
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                          ),
                        ),
                        Text(
                          dateOf(r),
                          style: GoogleFonts.poppins(
                            fontSize: 10,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => _showStudentAddReasonModal(r),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryBlue,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      'Add Reason',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_needsReason.length > shown.length)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => widget.onTabSelected?.call(1),
                child: Text(
                  'See all ${_needsReason.length} in Classes',
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Attendance rate for each class (real data, lowest first).
  Widget _buildAttendanceGraph() {
    if (_classRates.isEmpty) {
      return _buildEmptyTile('No attendance recorded yet.');
    }

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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _classRates.length; i++) ...[
            InkWell(
              onTap: () => widget.onTabSelected?.call(1),
              borderRadius: BorderRadius.circular(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _classRates[i]['code'].toString(),
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      Text(
                        '${((_classRates[i]['rate'] as double) * 100).round()}%  '
                        '(${_classRates[i]['attended']}/${_classRates[i]['total']})',
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
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

  Widget _buildPaginatedTodayClasses() {
    if (_todayClasses.isEmpty) {
      return _buildEmptyTile(_nextClassHint.isEmpty
          ? 'No classes scheduled for today.'
          : 'No classes today. $_nextClassHint');
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

    // Same rule as the Classes screen: a reason can be added any time
    final bool canAddReason = true;

    final statusStr = record['status']?.toString().toUpperCase() ?? 'PRESENT';
    final statusLower = statusStr.toLowerCase();

    final isPresent = statusLower == 'present';
    final isLate = statusLower == 'late';
    final isExcused = statusLower == 'excused';
    final isAbsent = statusLower == 'absent';

    final String reasonCat = (record['reason_category'] ?? '').toString();
    final String remarks = (record['remarks'] ?? '').toString();
    final bool hasReason = reasonCat.isNotEmpty;
    // "Auto-marked absent..." is written by the system, not a student reason
    final bool systemRemark = remarks.startsWith('Auto-marked');

    Color badgeBg = isPresent
        ? const Color(0xFFE8F5E9)
        : isLate
            ? const Color(0xFFFFF3E0)
            : isExcused
                ? const Color(0xFFF3E5F5)
                : const Color(0xFFFFEBEE);

    Color badgeColor = isPresent
        ? Colors.green.shade700
        : isLate
            ? Colors.orange.shade800
            : isExcused
                ? Colors.purple.shade700
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
          if (hasReason || (remarks.isNotEmpty && !systemRemark)) ...[
            const SizedBox(height: 4),
            Text(
              'Reason: ${hasReason ? reasonCat : ''}${remarks.isNotEmpty && !systemRemark ? (hasReason ? ' ($remarks)' : remarks) : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: isExcused ? Colors.purple.shade700 : Colors.blueGrey,
              ),
            ),
          ] else if ((isAbsent || isLate) && !isExcused) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'No reason submitted yet',
                  style: GoogleFonts.poppins(
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                    color: Colors.orange.shade800,
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