import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/faculty_notice_refresh.dart';
import '../../constants/app_colors.dart';

class FacultyRecordsScreen extends StatefulWidget {
  const FacultyRecordsScreen({super.key});

  @override
  State<FacultyRecordsScreen> createState() => _FacultyRecordsScreenState();
}

class _FacultyRecordsScreenState extends State<FacultyRecordsScreen> {
  RealtimeChannel? _realtimeChannel;

  int _selectedView = 0;
  bool _isLoading = true;

  List<Map<String, dynamic>> _rawRecords = [];
  List<Map<String, dynamic>> _filteredRecords = [];

  String _selectedClass = 'All Classes';
  List<String> _classList = ['All Classes'];

  // "With Reasons" filter placed directly before "Present"
  String _selectedStatus = 'All Status';
  final List<String> _statusList = [
    'All Status',
    'With Reasons',
    'Present',
    'Late',
    'Excused',
    'Absent'
  ];

  String _searchQuery = '';
  DateTimeRange? _selectedDateRange;

  int _currentPage = 1;
  final int _itemsPerPage = 5;

  final List<String> _reasonCategories = [
    'Medical / Illness',
    'Transportation / Traffic',
    'Family Emergency',
    'School Activity',
    'Official University Memo',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _fetchData();
    _setupRealtimeListener();
  }

  void _setupRealtimeListener() {
    final client = Supabase.instance.client;

    _realtimeChannel = client
        .channel('public_faculty_records_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_records',
          callback: (payload) {
            if (mounted) _fetchData();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'absence_reasons',
          callback: (payload) {
            if (mounted) _fetchData();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'class_enrollments',
          callback: (payload) {
            if (mounted) _fetchData();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_sessions',
          callback: (payload) {
            if (mounted) _fetchData();
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  // --- IGNORE SYSTEM AUTO-MARKED ABSENT REMARKS ---
  bool _hasReason(Map<String, dynamic> r) {
    final cat = r['reason_category']?.toString();
    final rem = r['remarks']?.toString();
    final absenceList = r['absence_reasons'] as List?;
    final hasAbsenceData = absenceList != null && absenceList.isNotEmpty;

    final isAutoMarked =
        rem != null && rem.toLowerCase().contains('auto-marked');

    final hasValidCategory = cat != null && cat.trim().isNotEmpty;
    final hasValidRemarks =
        rem != null && rem.trim().isNotEmpty && !isAutoMarked;

    return hasAbsenceData || hasValidCategory || hasValidRemarks;
  }

  int get _pendingReasonsCount {
    return _rawRecords
        .where((r) =>
            _hasReason(r) && r['status']?.toString().toLowerCase() != 'excused')
        .length;
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            _classList = ['All Classes'];
            _rawRecords = [];
            _filteredRecords = [];
            _isLoading = false;
          });
        }
        return;
      }

      // Fetch only classes assigned to the logged-in faculty
      final classResponse = await supabase
          .from('classes')
          .select('id, course_code, course_name, section, faculty_id')
          .eq('faculty_id', user.id);
      final fetchedClasses =
          List<Map<String, dynamic>>.from(classResponse as List);

      final classNames = <String>{'All Classes'};
      for (var c in fetchedClasses) {
        final code = c['course_code']?.toString() ?? '';
        if (code.isNotEmpty) classNames.add(code);
      }

      // Fetch attendance records strictly belonging to the logged-in faculty's classes
      final recordsResponse = await supabase
          .from('attendance_records')
          .select('''
            id,
            status,
            reason_category,
            remarks,
            scanned_at,
            attendance_sessions!inner(
              id,
              date,
              classes!inner(
                id,
                course_code,
                course_name,
                section,
                faculty_id
              )
            ),
            profiles:student_id(
              id,
              full_name,
              school_id,
              email
            ),
            absence_reasons(
              id,
              reason,
              proof_url,
              status,
              teacher_remark
            )
          ''')
          .eq('attendance_sessions.classes.faculty_id', user.id)
          .order('scanned_at', ascending: false);

      final recordsData =
          List<Map<String, dynamic>>.from(recordsResponse as List);

      if (mounted) {
        setState(() {
          _classList = classNames.toList();
          _rawRecords = recordsData;
          _applyFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading faculty records: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilters() {
    List<Map<String, dynamic>> filtered = List.from(_rawRecords);

    if (_selectedClass != 'All Classes') {
      filtered = filtered.where((r) {
        final classInfo = r['attendance_sessions']?['classes'];
        return classInfo?['course_code']?.toString().toLowerCase() ==
            _selectedClass.toLowerCase();
      }).toList();
    }

    if (_selectedStatus != 'All Status') {
      if (_selectedStatus == 'With Reasons') {
        filtered = filtered.where((r) => _hasReason(r)).toList();
      } else {
        filtered = filtered.where((r) {
          final status = (r['status'] ?? '').toString().toLowerCase();
          return status == _selectedStatus.toLowerCase();
        }).toList();
      }
    }

    if (_selectedDateRange != null) {
      filtered = filtered.where((r) {
        final dateStr = r['scanned_at'] ?? r['attendance_sessions']?['date'];
        if (dateStr == null) return false;
        final dt = DateTime.tryParse(dateStr.toString());
        if (dt == null) return false;

        final startDate = DateTime(
          _selectedDateRange!.start.year,
          _selectedDateRange!.start.month,
          _selectedDateRange!.start.day,
        );
        final endDate = DateTime(
          _selectedDateRange!.end.year,
          _selectedDateRange!.end.month,
          _selectedDateRange!.end.day,
          23,
          59,
          59,
        );

        return (dt.isAfter(startDate) || dt.isAtSameMomentAs(startDate)) &&
            (dt.isBefore(endDate) || dt.isAtSameMomentAs(endDate));
      }).toList();
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((r) {
        final profile = r['profiles'];
        final name = (profile?['full_name'] ?? '').toString().toLowerCase();
        final schoolId = (profile?['school_id'] ?? '').toString().toLowerCase();
        final email = (profile?['email'] ?? '').toString().toLowerCase();
        return name.contains(q) || schoolId.contains(q) || email.contains(q);
      }).toList();
    }

    // Default sorting: Keep submitted reasons on top
    filtered.sort((a, b) {
      final aHas =
          _hasReason(a) && a['status']?.toString().toLowerCase() != 'excused';
      final bHas =
          _hasReason(b) && b['status']?.toString().toLowerCase() != 'excused';
      if (aHas && !bHas) return -1;
      if (!aHas && bHas) return 1;
      return 0;
    });

    setState(() {
      _filteredRecords = filtered;
      _currentPage = 1;
    });
  }

  void _showProofImageModal(String proofUrl, String name) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        child: Container(
          padding: const EdgeInsets.all(18),
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Submitted Proof • $name',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        size: 20, color: Colors.grey),
                    onPressed: () => Navigator.pop(ctx),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: InteractiveViewer(
                    panEnabled: true,
                    minScale: 0.8,
                    maxScale: 4.0,
                    child: Image.network(
                      proofUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(
                              color: AppColors.primaryBlue),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) => Container(
                        padding: const EdgeInsets.all(20),
                        color: Colors.grey.shade100,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.broken_image_rounded,
                                size: 40, color: Colors.grey),
                            const SizedBox(height: 8),
                            Text(
                              'Unable to load image proof.\nPlease verify file URL.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                  fontSize: 11, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
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

  // --- FORECASTING COMPUTATION ENGINE ---
  double get _projectedNextWeekRate {
    if (_filteredRecords.isEmpty) return 0.0;
    final current = _avgAttendanceRate;
    final riskPenalty = (_atRiskStudentsList.length * 1.8);
    return (current - riskPenalty).clamp(0.0, 100.0);
  }

  int get _projectedAtRiskCount {
    final Map<String, int> absencesCount = {};
    for (var r in _filteredRecords) {
      if (r['status']?.toString().toLowerCase() == 'absent') {
        final id = r['profiles']?['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          absencesCount[id] = (absencesCount[id] ?? 0) + 1;
        }
      }
    }
    final currentAtRisk = absencesCount.values.where((c) => c >= 2).length;
    final borderline = absencesCount.values.where((c) => c == 1).length;
    return currentAtRisk + (borderline * 0.5).round();
  }

  String get _forecastRiskLevel {
    final rate = _projectedNextWeekRate;
    if (rate >= 85) return 'Stable';
    if (rate >= 70) return 'Watch';
    return 'Needs attention';
  }

  Color get _forecastRiskColor {
    final rate = _projectedNextWeekRate;
    if (rate >= 85) return const Color(0xFF10B981);
    if (rate >= 70) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  // --- REAL TREND DATA (from the records, not sample numbers) ---

  /// Attendance rate (present + excused) for the most recent session dates.
  List<MapEntry<String, double>> get _recentSessionRates {
    final Map<String, List<Map<String, dynamic>>> byDate = {};
    for (final r in _filteredRecords) {
      final date =
          r['attendance_sessions']?['date']?.toString().split('T')[0] ?? '';
      if (date.isEmpty) continue;
      byDate.putIfAbsent(date, () => []).add(r);
    }

    final dates = byDate.keys.toList()..sort();
    final recent = dates.length > 10 ? dates.sublist(dates.length - 10) : dates;

    return recent.map((d) {
      final recs = byDate[d]!;
      final good = recs.where((r) {
        final st = r['status']?.toString().toLowerCase();
        return st == 'present' || st == 'excused';
      }).length;
      return MapEntry(d, recs.isEmpty ? 0.0 : good / recs.length);
    }).toList();
  }

  /// Attendance rate for Monday to Friday. Value is null if no sessions.
  List<double?> get _weekdayRates {
    final List<int> total = List.filled(5, 0);
    final List<int> good = List.filled(5, 0);

    for (final r in _filteredRecords) {
      final raw = r['attendance_sessions']?['date']?.toString();
      final dt = DateTime.tryParse(raw ?? '');
      if (dt == null || dt.weekday > 5) continue;

      final i = dt.weekday - 1;
      total[i]++;
      final st = r['status']?.toString().toLowerCase();
      if (st == 'present' || st == 'excused') good[i]++;
    }

    return List.generate(5, (i) => total[i] == 0 ? null : good[i] / total[i]);
  }

  /// Per-student counts used for the "Student Highlights" card.
  Map<String, Map<String, dynamic>> get _studentStats {
    final Map<String, Map<String, dynamic>> stats = {};
    for (final r in _filteredRecords) {
      final id = r['profiles']?['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final entry = stats.putIfAbsent(
        id,
        () => {
          'name': (r['profiles']?['full_name'] ?? 'Unknown').toString(),
          'total': 0,
          'late': 0,
          'absent': 0,
          'excused': 0,
        },
      );

      entry['total'] = (entry['total'] as int) + 1;
      final st = r['status']?.toString().toLowerCase();
      if (st == 'late') entry['late'] = (entry['late'] as int) + 1;
      if (st == 'absent') entry['absent'] = (entry['absent'] as int) + 1;
      if (st == 'excused') entry['excused'] = (entry['excused'] as int) + 1;
    }
    return stats;
  }

  void _showReasonDetailsModal(String category) {
    final records = _filteredRecords.where((r) {
      final st = r['status']?.toString().toLowerCase();
      final isNonPresent = st == 'absent' || st == 'late' || st == 'excused';
      if (!isNonPresent) return false;

      final cat = r['reason_category']?.toString();
      if (category == 'Other') {
        return cat == 'Other' ||
            cat == null ||
            !_reasonCategories.contains(cat);
      }
      return cat == category;
    }).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(22),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category,
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      Text(
                        '${records.length} Student Record(s) Flagged',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.grey, size: 22),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Text(
                        'No detailed remarks found for "$category".',
                        style: GoogleFonts.poppins(
                            fontSize: 12, color: Colors.grey.shade500),
                      ),
                    )
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final r = records[index];
                        final profile = r['profiles'];
                        final name = profile?['full_name'] ?? 'Unknown Student';
                        final schoolId = profile?['school_id'] ?? 'N/A';
                        final classInfo = r['attendance_sessions']?['classes'];
                        final courseCode = classInfo?['course_code'] ?? 'N/A';
                        final courseName = classInfo?['course_name'] ?? 'N/A';
                        final section = classInfo?['section'] ?? 'N/A';
                        final status =
                            (r['status'] ?? 'N/A').toString().toUpperCase();
                        final remarks = (r['remarks'] ?? '').toString().trim();
                        final scannedAt = r['scanned_at']?.toString();
                        final sessionDate =
                            r['attendance_sessions']?['date']?.toString();
                        final formattedTime =
                            _formatDateTime(scannedAt, sessionDate);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    name,
                                    style: GoogleFonts.poppins(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: status == 'ABSENT'
                                          ? const Color(0xFFFEE2E2)
                                          : status == 'LATE'
                                              ? const Color(0xFFFEF3C7)
                                              : const Color(0xFFEEF2FF),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      status,
                                      style: GoogleFonts.poppins(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: status == 'ABSENT'
                                            ? const Color(0xFFEF4444)
                                            : status == 'LATE'
                                                ? const Color(0xFFF59E0B)
                                                : const Color(0xFF6366F1),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                'ID: $schoolId',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  const Icon(Icons.class_outlined,
                                      size: 13, color: AppColors.primaryBlue),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '$courseCode - $courseName (Sec $section)',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade800,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.access_time_rounded,
                                      size: 13, color: AppColors.primaryBlue),
                                  const SizedBox(width: 6),
                                  Text(
                                    formattedTime,
                                    style: GoogleFonts.poppins(
                                      fontSize: 10,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: AppColors.primaryBlue
                                          .withValues(alpha: 0.2)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'REMARKS / EXPLANATION:',
                                      style: GoogleFonts.poppins(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      remarks.isNotEmpty
                                          ? remarks
                                          : 'No specific remarks entered.',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontStyle: remarks.isNotEmpty
                                            ? FontStyle.normal
                                            : FontStyle.italic,
                                        color: remarks.isNotEmpty
                                            ? Colors.grey.shade800
                                            : Colors.grey.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditRecordDialog(Map<String, dynamic> record) {
    String selectedStatus =
        (record['status'] ?? 'present').toString().toLowerCase();
    String? selectedCategory = record['reason_category'];
    final remarksCtrl = TextEditingController(text: record['remarks'] ?? '');
    final studentName = record['profiles']?['full_name'] ?? 'Student';

    final statuses = [
      {
        'key': 'present',
        'label': 'PRESENT',
        'icon': Icons.check_circle_rounded,
        'color': const Color(0xFF10B981),
        'bg': const Color(0xFFE6F4EA),
      },
      {
        'key': 'late',
        'label': 'LATE',
        'icon': Icons.access_time_filled_rounded,
        'color': const Color(0xFFF59E0B),
        'bg': const Color(0xFFFEF3C7),
      },
      {
        'key': 'excused',
        'label': 'EXCUSED',
        'icon': Icons.verified_user_rounded,
        'color': const Color(0xFF6366F1),
        'bg': const Color(0xFFEEF2FF),
      },
      {
        'key': 'absent',
        'label': 'ABSENT',
        'icon': Icons.cancel_rounded,
        'color': const Color(0xFFEF4444),
        'bg': const Color(0xFFFEE2E2),
      },
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.white,
          elevation: 12,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Container(
            padding: const EdgeInsets.all(22),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Override Status',
                            style: GoogleFonts.poppins(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                          Text(
                            studentName,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(Icons.close_rounded,
                            color: Colors.grey.shade400, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'SELECT NEW STATUS',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 2.8,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: statuses.length,
                    itemBuilder: (context, index) {
                      final item = statuses[index];
                      final isSelected = selectedStatus == item['key'];
                      final color = item['color'] as Color;
                      final bg = item['bg'] as Color;
                      final icon = item['icon'] as IconData;

                      return InkWell(
                        onTap: () {
                          setDialogState(() {
                            selectedStatus = item['key'] as String;
                          });
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? color : bg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? color : Colors.transparent,
                              width: 1.5,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: color.withValues(alpha: 0.25),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    )
                                  ]
                                : [],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icon,
                                size: 16,
                                color: isSelected ? Colors.white : color,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                item['label'] as String,
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? Colors.white : color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  if (selectedStatus != 'present') ...[
                    const SizedBox(height: 16),
                    Text(
                      'REASON CATEGORY',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedCategory,
                      style: GoogleFonts.poppins(
                          fontSize: 12, color: Colors.black87),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                      ),
                      hint: Text(
                        'Select reason category',
                        style: GoogleFonts.poppins(
                            fontSize: 11, color: Colors.grey.shade400),
                      ),
                      items: _reasonCategories.map((cat) {
                        return DropdownMenuItem(
                          value: cat,
                          child: Text(cat,
                              style: GoogleFonts.poppins(fontSize: 12)),
                        );
                      }).toList(),
                      onChanged: (val) =>
                          setDialogState(() => selectedCategory = val),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      selectedStatus == 'excused'
                          ? 'EXCUSED REMARKS (REQUIRED)'
                          : 'REMARKS / EXPLANATION',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: selectedStatus == 'excused'
                            ? const Color(0xFF6366F1)
                            : AppColors.primaryBlue,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: remarksCtrl,
                      style: GoogleFonts.poppins(fontSize: 12),
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: selectedStatus == 'excused'
                            ? 'e.g., Medical cert, official event memo...'
                            : 'Enter explanation or note...',
                        hintStyle: GoogleFonts.poppins(
                            fontSize: 11, color: Colors.grey.shade400),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(
                            'Cancel',
                            style: GoogleFonts.poppins(
                              color: Colors.grey.shade700,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryBlue,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            await Supabase.instance.client
                                .from('attendance_records')
                                .update({
                              'status': selectedStatus,
                              'reason_category': selectedStatus == 'present'
                                  ? null
                                  : selectedCategory,
                              'remarks': selectedStatus == 'present'
                                  ? null
                                  : remarksCtrl.text.trim(),
                            }).eq('id', record['id']);

                            final absenceList =
                                record['absence_reasons'] as List?;
                            if (absenceList != null && absenceList.isNotEmpty) {
                              final reasonId = absenceList.first['id'];
                              await Supabase.instance.client
                                  .from('absence_reasons')
                                  .update({
                                'status': selectedStatus == 'excused'
                                    ? 'approved'
                                    : 'rejected',
                              }).eq('id', reasonId);
                            }

                            // Update the notification bell right away
                            FacultyNoticeRefresh.bump();

                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                            }
                            if (mounted) {
                              await _fetchData();
                            }
                          },
                          child: Text(
                            'Save Override',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).then((_) {
      // Wait for the dialog's closing animation before disposing the controller
      Future.delayed(const Duration(milliseconds: 600), remarksCtrl.dispose);
    });
  }

  void _showCustomCalendarModal(BuildContext context) {
    int activeTab = 1;
    DateTime displayedMonth = _selectedDateRange?.start ?? DateTime.now();
    DateTime? tempStartDate = _selectedDateRange?.start;
    DateTime? tempEndDate = _selectedDateRange?.end;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final now = DateTime.now();

            final firstDayOfMonth =
                DateTime(displayedMonth.year, displayedMonth.month, 1);
            final daysInMonth =
                DateTime(displayedMonth.year, displayedMonth.month + 1, 0).day;
            final startingWeekday = (firstDayOfMonth.weekday % 7);
            final prevMonthDays =
                DateTime(displayedMonth.year, displayedMonth.month, 0).day;

            final totalGridItems =
                ((startingWeekday + daysInMonth) / 7).ceil() * 7;

            return Container(
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
                  )
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Calendar Filter',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
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
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setModalState(() => activeTab = 0),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              decoration: BoxDecoration(
                                color: activeTab == 0
                                    ? AppColors.primaryBlue
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Center(
                                child: Text(
                                  'PRESETS',
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: activeTab == 0
                                        ? Colors.white
                                        : AppColors.primaryBlue
                                            .withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setModalState(() => activeTab = 1),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              decoration: BoxDecoration(
                                color: activeTab == 1
                                    ? AppColors.primaryBlue
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Center(
                                child: Text(
                                  'CALENDAR',
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: activeTab == 1
                                        ? Colors.white
                                        : AppColors.primaryBlue
                                            .withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (activeTab == 0) ...[
                    ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      tileColor: const Color(0xFFF8FAFC),
                      leading: const Icon(Icons.today_rounded,
                          color: AppColors.primaryBlue),
                      title: Text('Today',
                          style: GoogleFonts.poppins(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      onTap: () {
                        setModalState(() {
                          tempStartDate = now;
                          tempEndDate = now;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      tileColor: const Color(0xFFF8FAFC),
                      leading: const Icon(Icons.date_range_rounded,
                          color: AppColors.primaryBlue),
                      title: Text('This Week',
                          style: GoogleFonts.poppins(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      onTap: () {
                        final monday =
                            now.subtract(Duration(days: now.weekday - 1));
                        setModalState(() {
                          tempStartDate = monday;
                          tempEndDate = now;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      tileColor: const Color(0xFFF8FAFC),
                      leading: const Icon(Icons.calendar_month_rounded,
                          color: AppColors.primaryBlue),
                      title: Text('This Month',
                          style: GoogleFonts.poppins(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      onTap: () {
                        final firstDay = DateTime(now.year, now.month, 1);
                        setModalState(() {
                          tempStartDate = firstDay;
                          tempEndDate = now;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      tileColor: const Color(0xFFF8FAFC),
                      leading: const Icon(Icons.clear_all_rounded,
                          color: Colors.redAccent),
                      title: Text('Clear Date Filter',
                          style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.redAccent)),
                      onTap: () {
                        setModalState(() {
                          tempStartDate = null;
                          tempEndDate = null;
                        });
                      },
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${_monthName(displayedMonth.month)} ${displayedMonth.year}',
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                          ),
                        ),
                        Row(
                          children: [
                            InkWell(
                              onTap: () {
                                setModalState(() {
                                  displayedMonth = DateTime(displayedMonth.year,
                                      displayedMonth.month - 1, 1);
                                });
                              },
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryBlue
                                      .withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.chevron_left_rounded,
                                    size: 18, color: AppColors.primaryBlue),
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                setModalState(() {
                                  displayedMonth = DateTime(displayedMonth.year,
                                      displayedMonth.month + 1, 1);
                                });
                              },
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryBlue
                                      .withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.chevron_right_rounded,
                                    size: 18, color: AppColors.primaryBlue),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                          .map((day) => SizedBox(
                                width: 32,
                                child: Center(
                                  child: Text(
                                    day,
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
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
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
                          dayNumber =
                              prevMonthDays - startingWeekday + index + 1;
                          cellDate = DateTime(displayedMonth.year,
                              displayedMonth.month - 1, dayNumber);
                        } else if (index >= startingWeekday + daysInMonth) {
                          isCurrentMonth = false;
                          dayNumber =
                              index - (startingWeekday + daysInMonth) + 1;
                          cellDate = DateTime(displayedMonth.year,
                              displayedMonth.month + 1, dayNumber);
                        } else {
                          dayNumber = index - startingWeekday + 1;
                          cellDate = DateTime(displayedMonth.year,
                              displayedMonth.month, dayNumber);
                        }

                        final isStart = tempStartDate != null &&
                            _isSameDay(tempStartDate!, cellDate);
                        final isEnd = tempEndDate != null &&
                            _isSameDay(tempEndDate!, cellDate);
                        final isInRange = tempStartDate != null &&
                            tempEndDate != null &&
                            cellDate.isAfter(tempStartDate!) &&
                            cellDate.isBefore(tempEndDate!);

                        final isSelected = isStart || isEnd;

                        return InkWell(
                          onTap: () {
                            setModalState(() {
                              if (tempStartDate == null ||
                                  (tempStartDate != null &&
                                      tempEndDate != null)) {
                                tempStartDate = cellDate;
                                tempEndDate = null;
                              } else if (tempStartDate != null &&
                                  tempEndDate == null) {
                                if (cellDate.isBefore(tempStartDate!)) {
                                  tempStartDate = cellDate;
                                } else {
                                  tempEndDate = cellDate;
                                }
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primaryBlue
                                  : isInRange
                                      ? AppColors.primaryBlue
                                          .withValues(alpha: 0.12)
                                      : Colors.transparent,
                              shape: isSelected
                                  ? BoxShape.circle
                                  : BoxShape.rectangle,
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
                        setState(() {
                          if (tempStartDate != null) {
                            _selectedDateRange = DateTimeRange(
                              start: tempStartDate!,
                              end: tempEndDate ?? tempStartDate!,
                            );
                          } else {
                            _selectedDateRange = null;
                          }
                          _applyFilters();
                        });
                        Navigator.pop(ctx);
                      },
                      child: Text(
                        tempStartDate == null
                            ? 'Apply Date Range'
                            : tempEndDate == null
                                ? 'Select End Date'
                                : 'Apply ${_monthName(tempStartDate!.month)} ${tempStartDate!.day} - ${_monthName(tempEndDate!.month)} ${tempEndDate!.day}',
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
            );
          },
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _getDateDisplayString() {
    if (_selectedDateRange == null) return 'All Dates';
    final start = _selectedDateRange!.start;
    final end = _selectedDateRange!.end;

    if (start.year == end.year &&
        start.month == end.month &&
        start.day == end.day) {
      return '${_monthName(start.month)} ${start.day}';
    }

    return '${_monthName(start.month)} ${start.day} - ${_monthName(end.month)} ${end.day}';
  }

  List<Map<String, dynamic>> get _paginatedRecords {
    final startIndex = (_currentPage - 1) * _itemsPerPage;
    if (startIndex >= _filteredRecords.length) return [];
    final endIndex = (startIndex + _itemsPerPage < _filteredRecords.length)
        ? startIndex + _itemsPerPage
        : _filteredRecords.length;
    return _filteredRecords.sublist(startIndex, endIndex);
  }

  int get _totalPages {
    if (_filteredRecords.isEmpty) return 1;
    return (_filteredRecords.length / _itemsPerPage).ceil();
  }

  int get _presentCount => _filteredRecords
      .where((r) => r['status']?.toString().toLowerCase() == 'present')
      .length;

  int get _lateCount => _filteredRecords
      .where((r) => r['status']?.toString().toLowerCase() == 'late')
      .length;

  int get _excusedCount => _filteredRecords
      .where((r) => r['status']?.toString().toLowerCase() == 'excused')
      .length;

  int get _absentCount => _filteredRecords
      .where((r) => r['status']?.toString().toLowerCase() == 'absent')
      .length;

  double get _avgAttendanceRate {
    if (_filteredRecords.isEmpty) return 0.0;
    final attended = _presentCount + _lateCount + _excusedCount;
    return (attended / _filteredRecords.length) * 100;
  }

  double get _onTimeRate {
    if (_filteredRecords.isEmpty) return 0.0;
    return (_presentCount / _filteredRecords.length) * 100;
  }

  List<Map<String, dynamic>> get _atRiskStudentsList {
    final Map<String, Map<String, dynamic>> studentMap = {};
    final Map<String, int> absencesCount = {};

    for (var r in _filteredRecords) {
      if (r['status']?.toString().toLowerCase() == 'absent') {
        final profile = r['profiles'];
        if (profile != null && profile['id'] != null) {
          final id = profile['id'].toString();
          absencesCount[id] = (absencesCount[id] ?? 0) + 1;
          studentMap[id] = {
            'profile': profile,
            'class': r['attendance_sessions']?['classes'],
          };
        }
      }
    }

    final List<Map<String, dynamic>> atRisk = [];
    absencesCount.forEach((id, count) {
      if (count >= 2) {
        atRisk.add({
          'profile': studentMap[id]?['profile'],
          'class': studentMap[id]?['class'],
          'absences': count,
        });
      }
    });

    atRisk
        .sort((a, b) => (b['absences'] as int).compareTo(a['absences'] as int));
    return atRisk;
  }

  Map<String, int> get _absenceReasonBreakdown {
    final Map<String, int> reasons = {
      'Medical / Illness': 0,
      'Transportation / Traffic': 0,
      'Family Emergency': 0,
      'School Activity': 0,
      'Official University Memo': 0,
      'Other': 0,
    };

    final nonPresents = _filteredRecords.where((r) {
      final st = r['status']?.toString().toLowerCase();
      return st == 'absent' || st == 'late' || st == 'excused';
    });

    for (var record in nonPresents) {
      final cat = record['reason_category']?.toString();
      if (cat != null && reasons.containsKey(cat)) {
        reasons[cat] = (reasons[cat] ?? 0) + 1;
      } else {
        reasons['Other'] = (reasons['Other'] ?? 0) + 1;
      }
    }
    return reasons;
  }

  // --- PDF EXPORT ENGINE INCLUDING SUBMITTED REASONS & PROOFS ---
  Future<void> _exportPDF() async {
    if (_filteredRecords.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No records available to export.',
            style: GoogleFonts.poppins(fontSize: 12),
          ),
          backgroundColor: const Color(0xFFF59E0B),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final pdf = pw.Document();

      final brandNavy = PdfColor.fromHex('#1E3A8A');
      final accentBlue = PdfColor.fromHex('#2563EB');
      final lightBlueBg = PdfColor.fromHex('#EFF6FF');
      final rowSoftBlue = PdfColor.fromHex('#F8FAFC');
      final borderGrey = PdfColor.fromHex('#CBD5E1');

      final statusTotal =
          _filteredRecords.isNotEmpty ? _filteredRecords.length : 1;
      final presentPct = ((_presentCount / statusTotal) * 100).round();
      final latePct = ((_lateCount / statusTotal) * 100).round();
      final excusedPct = ((_excusedCount / statusTotal) * 100).round();
      final absentPct = ((_absentCount / statusTotal) * 100).round();

      final reasons = _absenceReasonBreakdown;
      final totalAbsences = reasons.values.fold(0, (sum, item) => sum + item);

      final Map<String, List<Map<String, dynamic>>> recordsByClass = {};
      for (var record in _filteredRecords) {
        final classCode = record['attendance_sessions']?['classes']
                    ?['course_code']
                ?.toString() ??
            'Unassigned Class';
        recordsByClass.putIfAbsent(classCode, () => []).add(record);
      }

      final recordsWithReasons =
          _filteredRecords.where((r) => _hasReason(r)).toList();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          header: (pw.Context context) {
            return pw.Column(
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'ClassKeeper',
                          style: pw.TextStyle(
                            fontSize: 22,
                            fontWeight: pw.FontWeight.bold,
                            color: brandNavy,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          _selectedView == 1
                              ? 'CLASS ATTENDANCE REPORT'
                              : 'ATTENDANCE LOG REPORT',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.blueGrey600,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: pw.BoxDecoration(
                            color: lightBlueBg,
                            borderRadius: const pw.BorderRadius.all(
                                pw.Radius.circular(6)),
                            border:
                                pw.Border.all(color: borderGrey, width: 0.8),
                          ),
                          child: pw.Text(
                            'Class Filter: $_selectedClass',
                            style: pw.TextStyle(
                              fontSize: 9,
                              fontWeight: pw.FontWeight.bold,
                              color: brandNavy,
                            ),
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Date Range: ${_getDateDisplayString()}',
                          style: const pw.TextStyle(
                            fontSize: 9,
                            color: PdfColors.grey700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 10),
                pw.Divider(color: brandNavy, thickness: 1.5),
                pw.SizedBox(height: 12),
              ],
            );
          },
          footer: (pw.Context context) {
            final nowStr = DateTime.now().toString().split('.')[0];
            return pw.Container(
              margin: const pw.EdgeInsets.only(top: 12),
              padding: const pw.EdgeInsets.only(top: 8),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  top: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
                ),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Generated on $nowStr | ClassKeeper',
                    style: const pw.TextStyle(
                        fontSize: 8, color: PdfColors.grey600),
                  ),
                  pw.Text(
                    'Page ${context.pageNumber} of ${context.pagesCount}',
                    style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                        color: brandNavy),
                  ),
                ],
              ),
            );
          },
          build: (pw.Context context) {
            final List<pw.Widget> widgets = [];

            if (_selectedView == 1) {
              widgets.add(
                pw.Row(
                  children: [
                    _pdfMetricCard(
                      'Avg Attendance',
                      '${_avgAttendanceRate.toStringAsFixed(1)}%',
                      'Present + Excused',
                      PdfColor.fromHex('#059669'),
                      PdfColor.fromHex('#ECFDF5'),
                    ),
                    pw.SizedBox(width: 8),
                    _pdfMetricCard(
                      'On-Time Rate',
                      '${_onTimeRate.toStringAsFixed(1)}%',
                      'Punctual scans',
                      brandNavy,
                      lightBlueBg,
                    ),
                    pw.SizedBox(width: 8),
                    _pdfMetricCard(
                      'At-Risk Students',
                      '${_atRiskStudentsList.length}',
                      '≥2 Absences',
                      PdfColor.fromHex('#DC2626'),
                      PdfColor.fromHex('#FEF2F2'),
                    ),
                  ],
                ),
              );
              widgets.add(pw.SizedBox(height: 14));

              widgets.add(
                pw.Container(
                  padding: const pw.EdgeInsets.all(12),
                  decoration: pw.BoxDecoration(
                    color: lightBlueBg,
                    borderRadius:
                        const pw.BorderRadius.all(pw.Radius.circular(8)),
                    border: pw.Border.all(color: accentBlue, width: 0.8),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'NEXT WEEK OUTLOOK (ESTIMATE)',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: brandNavy,
                        ),
                      ),
                      pw.SizedBox(height: 8),
                      pw.Row(
                        children: [
                          _pdfMetricCard(
                            'Expected Rate',
                            '${_projectedNextWeekRate.toStringAsFixed(1)}%',
                            _forecastRiskLevel,
                            _projectedNextWeekRate >= 80
                                ? PdfColor.fromHex('#059669')
                                : PdfColor.fromHex('#DC2626'),
                            PdfColors.white,
                          ),
                          pw.SizedBox(width: 8),
                          _pdfMetricCard(
                            'Possible At-Risk',
                            '$_projectedAtRiskCount Students',
                            'Based on current absences',
                            PdfColor.fromHex('#D97706'),
                            PdfColors.white,
                          ),
                        ],
                      ),
                      pw.SizedBox(height: 8),
                      pw.Text(
                        'Follow-up: check in with students who already have 1 absence before the next session, and talk to students with 2 or more absences. This is a simple estimate based on the records in this report.',
                        style: const pw.TextStyle(
                          fontSize: 7.5,
                          color: PdfColors.blueGrey800,
                        ),
                      ),
                    ],
                  ),
                ),
              );
              widgets.add(pw.SizedBox(height: 14));

              widgets.add(
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      flex: 1,
                      child: pw.Container(
                        padding: const pw.EdgeInsets.all(12),
                        decoration: pw.BoxDecoration(
                          color: PdfColors.white,
                          borderRadius:
                              const pw.BorderRadius.all(pw.Radius.circular(8)),
                          border: pw.Border.all(color: borderGrey, width: 0.8),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              'Attendance Distribution',
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                                color: brandNavy,
                              ),
                            ),
                            pw.SizedBox(height: 10),
                            _pdfLegendRow('Present', '$presentPct%',
                                PdfColor.fromHex('#059669')),
                            pw.SizedBox(height: 6),
                            _pdfLegendRow('Late', '$latePct%',
                                PdfColor.fromHex('#D97706')),
                            pw.SizedBox(height: 6),
                            _pdfLegendRow('Excused', '$excusedPct%',
                                PdfColor.fromHex('#4F46E5')),
                            pw.SizedBox(height: 6),
                            _pdfLegendRow('Absent', '$absentPct%',
                                PdfColor.fromHex('#DC2626')),
                          ],
                        ),
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      flex: 1,
                      child: pw.Container(
                        padding: const pw.EdgeInsets.all(12),
                        decoration: pw.BoxDecoration(
                          color: PdfColors.white,
                          borderRadius:
                              const pw.BorderRadius.all(pw.Radius.circular(8)),
                          border: pw.Border.all(color: borderGrey, width: 0.8),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              'Absence Reason Drivers',
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                                color: brandNavy,
                              ),
                            ),
                            pw.SizedBox(height: 10),
                            ...reasons.entries.map((entry) {
                              final pct = totalAbsences > 0
                                  ? (entry.value / totalAbsences)
                                  : 0.0;
                              return pw.Padding(
                                padding: const pw.EdgeInsets.only(bottom: 6.0),
                                child: pw.Column(
                                  crossAxisAlignment:
                                      pw.CrossAxisAlignment.start,
                                  children: [
                                    pw.Row(
                                      mainAxisAlignment:
                                          pw.MainAxisAlignment.spaceBetween,
                                      children: [
                                        pw.Text(entry.key,
                                            style: const pw.TextStyle(
                                                fontSize: 7.5,
                                                color: PdfColors.grey800)),
                                        pw.Text(
                                            '${entry.value} (${(pct * 100).toStringAsFixed(0)}%)',
                                            style: pw.TextStyle(
                                                fontSize: 7.5,
                                                fontWeight: pw.FontWeight.bold,
                                                color: brandNavy)),
                                      ],
                                    ),
                                    pw.SizedBox(height: 2),
                                    pw.Container(
                                      height: 5,
                                      width: double.infinity,
                                      decoration: const pw.BoxDecoration(
                                        color: PdfColors.grey200,
                                        borderRadius: pw.BorderRadius.all(
                                            pw.Radius.circular(3)),
                                      ),
                                      child: pw.Align(
                                        alignment: pw.Alignment.centerLeft,
                                        child: pw.Container(
                                          width: pct * 180,
                                          height: 5,
                                          decoration: pw.BoxDecoration(
                                            color: accentBlue,
                                            borderRadius:
                                                const pw.BorderRadius.all(
                                                    pw.Radius.circular(3)),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
              widgets.add(pw.SizedBox(height: 18));
            } else {
              widgets.add(
                pw.Row(
                  children: [
                    _pdfStatCard('TOTAL LOGS', '${_filteredRecords.length}',
                        brandNavy, lightBlueBg),
                    pw.SizedBox(width: 8),
                    _pdfStatCard(
                        'PRESENT',
                        '$_presentCount',
                        PdfColor.fromHex('#059669'),
                        PdfColor.fromHex('#ECFDF5')),
                    pw.SizedBox(width: 8),
                    _pdfStatCard(
                        'LATE',
                        '$_lateCount',
                        PdfColor.fromHex('#D97706'),
                        PdfColor.fromHex('#FFFBEB')),
                    pw.SizedBox(width: 8),
                    _pdfStatCard(
                        'EXCUSED',
                        '$_excusedCount',
                        PdfColor.fromHex('#4F46E5'),
                        PdfColor.fromHex('#EEF2FF')),
                    pw.SizedBox(width: 8),
                    _pdfStatCard(
                        'ABSENT',
                        '$_absentCount',
                        PdfColor.fromHex('#DC2626'),
                        PdfColor.fromHex('#FEF2F2')),
                  ],
                ),
              );
              widgets.add(pw.SizedBox(height: 18));
            }

            // --- DEDICATED REASONS & PROOFS HIGHLIGHT SECTION ---
            if (recordsWithReasons.isNotEmpty) {
              widgets.add(
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#D97706'),
                    borderRadius:
                        const pw.BorderRadius.all(pw.Radius.circular(4)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'SUBMITTED EXCUSE REASONS & PROOFS (${recordsWithReasons.length})',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      pw.Text(
                        'Flagged / Pending Review',
                        style: pw.TextStyle(
                          fontSize: 8.5,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#FEF3C7'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
              widgets.add(pw.SizedBox(height: 6));

              widgets.add(
                pw.Table(
                  border: pw.TableBorder.all(color: borderGrey, width: 0.5),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(2.2),
                    1: pw.FlexColumnWidth(1.6),
                    2: pw.FlexColumnWidth(1.2),
                    3: pw.FlexColumnWidth(3.8),
                    4: pw.FlexColumnWidth(1.8),
                  },
                  children: [
                    pw.TableRow(
                      decoration:
                          pw.BoxDecoration(color: PdfColor.fromHex('#F59E0B')),
                      children: [
                        _pdfHeaderCell('Student Name'),
                        _pdfHeaderCell('Class'),
                        _pdfHeaderCell('Status'),
                        _pdfHeaderCell('Reason / Explanation'),
                        _pdfHeaderCell('Proof Attached'),
                      ],
                    ),
                    ...List.generate(recordsWithReasons.length, (idx) {
                      final rec = recordsWithReasons[idx];
                      final prof = rec['profiles'];
                      final sName = prof?['full_name']?.toString() ?? 'N/A';
                      final classCode = rec['attendance_sessions']?['classes']
                                  ?['course_code']
                              ?.toString() ??
                          'N/A';
                      final stStr =
                          (rec['status'] ?? 'N/A').toString().toUpperCase();

                      final cat = rec['reason_category']?.toString() ?? '';
                      final rem = rec['remarks']?.toString() ?? '';
                      final isAuto = rem.toLowerCase().contains('auto-marked');

                      final absList = rec['absence_reasons'] as List?;
                      String? absReason;
                      bool proof = false;
                      if (absList != null && absList.isNotEmpty) {
                        final f = absList.first;
                        absReason = f['reason']?.toString();
                        final p = f['proof_url']?.toString();
                        if (p != null && p.isNotEmpty) proof = true;
                      }

                      String rText = '';
                      if (absReason != null && absReason.trim().isNotEmpty) {
                        rText = absReason.trim();
                      } else if (cat.isNotEmpty) {
                        rText = cat;
                        if (rem.isNotEmpty && !isAuto) rText += ' ($rem)';
                      } else if (rem.isNotEmpty && !isAuto) {
                        rText = rem;
                      }

                      final isEven = idx % 2 == 0;
                      final rowBg = isEven ? PdfColors.white : rowSoftBlue;

                      return pw.TableRow(
                        decoration: pw.BoxDecoration(color: rowBg),
                        children: [
                          _pdfCell(sName, isBold: true),
                          _pdfCell(classCode),
                          _pdfCell(stStr, isBold: true),
                          _pdfCell(rText.isEmpty ? 'Reason submitted' : rText),
                          _pdfCell(proof ? 'YES (Image)' : 'NO'),
                        ],
                      );
                    }),
                  ],
                ),
              );
              widgets.add(pw.SizedBox(height: 16));
            }

            recordsByClass.forEach((classCode, records) {
              widgets.add(
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: pw.BoxDecoration(
                    color: brandNavy,
                    borderRadius:
                        const pw.BorderRadius.all(pw.Radius.circular(4)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'CLASS: $classCode',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      pw.Text(
                        '${records.length} Record(s)',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#BFDBFE'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
              widgets.add(pw.SizedBox(height: 6));

              widgets.add(
                pw.Table(
                  border: pw.TableBorder.all(
                    color: borderGrey,
                    width: 0.5,
                  ),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(2.5),
                    1: pw.FlexColumnWidth(1.8),
                    2: pw.FlexColumnWidth(1.4),
                    3: pw.FlexColumnWidth(2.8),
                    4: pw.FlexColumnWidth(3.2),
                  },
                  children: [
                    pw.TableRow(
                      decoration: pw.BoxDecoration(color: accentBlue),
                      children: [
                        _pdfHeaderCell('Student Name'),
                        _pdfHeaderCell('School ID'),
                        _pdfHeaderCell('Status'),
                        _pdfHeaderCell('Timestamp'),
                        _pdfHeaderCell('Remarks / Reason'),
                      ],
                    ),
                    ...List.generate(records.length, (index) {
                      final record = records[index];
                      final profile = record['profiles'];
                      final name = profile?['full_name']?.toString() ?? 'N/A';
                      final schoolId =
                          profile?['school_id']?.toString() ?? 'N/A';
                      final status =
                          (record['status'] ?? 'N/A').toString().toUpperCase();

                      final category =
                          record['reason_category']?.toString() ?? '';
                      final remarks = record['remarks']?.toString() ?? '';
                      final isAutoMarked =
                          remarks.toLowerCase().contains('auto-marked');

                      final absenceList = record['absence_reasons'] as List?;
                      String? absenceReasonText;
                      bool hasProof = false;
                      if (absenceList != null && absenceList.isNotEmpty) {
                        final firstAbs = absenceList.first;
                        absenceReasonText = firstAbs['reason']?.toString();
                        final pUrl = firstAbs['proof_url']?.toString();
                        if (pUrl != null && pUrl.isNotEmpty) {
                          hasProof = true;
                        }
                      }

                      String fullRemark = '';
                      if (absenceReasonText != null &&
                          absenceReasonText.trim().isNotEmpty) {
                        fullRemark = absenceReasonText.trim();
                      } else if (category.isNotEmpty) {
                        fullRemark = category;
                        if (remarks.isNotEmpty && !isAutoMarked) {
                          fullRemark += ' ($remarks)';
                        }
                      } else if (remarks.isNotEmpty && !isAutoMarked) {
                        fullRemark = remarks;
                      }

                      if (hasProof) {
                        fullRemark = fullRemark.isNotEmpty
                            ? '$fullRemark [Proof Attached]'
                            : '[Proof Attached]';
                      }

                      if (fullRemark.isEmpty) {
                        fullRemark = isAutoMarked ? '-' : '-';
                      }

                      final scannedAt = record['scanned_at']?.toString();
                      final sessionDate =
                          record['attendance_sessions']?['date']?.toString();
                      final timeStr = _formatDateTime(scannedAt, sessionDate);

                      final isEven = index % 2 == 0;
                      final rowBg = isEven ? PdfColors.white : rowSoftBlue;

                      PdfColor statusColor = PdfColor.fromHex('#059669');
                      if (status == 'LATE')
                        statusColor = PdfColor.fromHex('#D97706');
                      if (status == 'EXCUSED')
                        statusColor = PdfColor.fromHex('#4F46E5');
                      if (status == 'ABSENT')
                        statusColor = PdfColor.fromHex('#DC2626');

                      return pw.TableRow(
                        decoration: pw.BoxDecoration(color: rowBg),
                        children: [
                          _pdfCell(name, isBold: true),
                          _pdfCell(schoolId),
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text(
                              status,
                              style: pw.TextStyle(
                                fontSize: 8,
                                fontWeight: pw.FontWeight.bold,
                                color: statusColor,
                              ),
                            ),
                          ),
                          _pdfCell(timeStr),
                          _pdfCell(fullRemark),
                        ],
                      );
                    }),
                  ],
                ),
              );

              widgets.add(pw.SizedBox(height: 14));
            });

            return widgets;
          },
        ),
      );

      await Printing.sharePdf(
        bytes: await pdf.save(),
        filename:
            'attendance_analytics_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to export PDF: $e',
            style: GoogleFonts.poppins(fontSize: 11),
          ),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  pw.Widget _pdfMetricCard(
      String title, String val, String sub, PdfColor color, PdfColor bg) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: pw.BoxDecoration(
          color: bg,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          border: pw.Border.all(color: color, width: 0.8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(
                  fontSize: 7.5,
                  color: PdfColors.grey700,
                  fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              val,
              style: pw.TextStyle(
                  fontSize: 15, fontWeight: pw.FontWeight.bold, color: color),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              sub,
              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _pdfLegendRow(String label, String pct, PdfColor color) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Row(
          children: [
            pw.Container(
              width: 8,
              height: 8,
              decoration:
                  pw.BoxDecoration(color: color, shape: pw.BoxShape.circle),
            ),
            pw.SizedBox(width: 6),
            pw.Text(label,
                style:
                    const pw.TextStyle(fontSize: 8, color: PdfColors.grey800)),
          ],
        ),
        pw.Text(pct,
            style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey900)),
      ],
    );
  }

  pw.Widget _pdfHeaderCell(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8.5,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
  }

  pw.Widget _pdfCell(String text, {bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: PdfColors.grey900,
        ),
      ),
    );
  }

  pw.Widget _pdfStatCard(
      String title, String count, PdfColor textColor, PdfColor bgColor) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: pw.BoxDecoration(
          color: bgColor,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          border: pw.Border.all(color: textColor, width: 0.6),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              count,
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
                color: textColor,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 7,
                fontWeight: pw.FontWeight.bold,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(String? scannedAt, String? sessionDate) {
    if (scannedAt != null && scannedAt.isNotEmpty) {
      final dt = DateTime.tryParse(scannedAt)?.toLocal();
      if (dt != null) {
        final hour =
            dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
        final period = dt.hour >= 12 ? 'PM' : 'AM';
        final minute = dt.minute.toString().padLeft(2, '0');
        final monthStr = _monthName(dt.month);
        return '$monthStr ${dt.day}, ${dt.year} | $hour:$minute $period';
      }
    }
    if (sessionDate != null && sessionDate.isNotEmpty) {
      final dt = DateTime.tryParse(sessionDate)?.toLocal();
      if (dt != null) {
        return '${_monthName(dt.month)} ${dt.day}, ${dt.year} | Session Date';
      }
    }
    return 'N/A';
  }

  String _monthName(int month) {
    const months = [
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
      'Dec'
    ];
    return months[(month - 1) % 12];
  }

  void _showStudentDeepDiveModal(Map<String, dynamic> profile) {
    final studentId = profile['id'];
    final studentRecords =
        _rawRecords.where((r) => r['profiles']?['id'] == studentId).toList();

    final studentPresents = studentRecords
        .where((r) => r['status']?.toString().toLowerCase() == 'present')
        .length;
    final studentLates = studentRecords
        .where((r) => r['status']?.toString().toLowerCase() == 'late')
        .length;
    final studentExcused = studentRecords
        .where((r) => r['status']?.toString().toLowerCase() == 'excused')
        .length;
    final studentAbsents = studentRecords
        .where((r) => r['status']?.toString().toLowerCase() == 'absent')
        .length;

    List<String> flags = [];
    if (studentAbsents >= 2) {
      flags.add("At Risk: High Absences ($studentAbsents)");
    }
    if (studentLates >= 3) flags.add("Punctuality Warning: Frequent Lateness");
    if (studentExcused >= 1) flags.add("Exemptions Granted ($studentExcused)");

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.primaryBlue.withValues(alpha: 0.1),
                  child: Text(
                    (profile['full_name'] ?? 'S')[0].toUpperCase(),
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile['full_name'] ?? 'Student Profile',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'ID: ${profile['school_id'] ?? 'N/A'}',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (flags.isNotEmpty) ...[
              Text(
                'AUTOMATED FLAGS',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: flags
                    .map((flag) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: flag.contains('Exemptions')
                                ? const Color(0xFFEEF2FF)
                                : const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: flag.contains('Exemptions')
                                    ? const Color(0xFF6366F1)
                                        .withValues(alpha: 0.3)
                                    : const Color(0xFFEF4444)
                                        .withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                flag.contains('Exemptions')
                                    ? Icons.verified_user_outlined
                                    : Icons.warning_amber_rounded,
                                size: 12,
                                color: flag.contains('Exemptions')
                                    ? const Color(0xFF6366F1)
                                    : const Color(0xFFEF4444),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                flag,
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: flag.contains('Exemptions')
                                      ? const Color(0xFF6366F1)
                                      : const Color(0xFFEF4444),
                                ),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                _buildStatCard('Present', '$studentPresents',
                    const Color(0xFF10B981), const Color(0xFFE6F4EA)),
                const SizedBox(width: 6),
                _buildStatCard('Late', '$studentLates', const Color(0xFFF59E0B),
                    const Color(0xFFFEF3C7)),
                const SizedBox(width: 6),
                _buildStatCard('Excused', '$studentExcused',
                    const Color(0xFF6366F1), const Color(0xFFEEF2FF)),
                const SizedBox(width: 6),
                _buildStatCard('Absent', '$studentAbsents',
                    const Color(0xFFEF4444), const Color(0xFFFEE2E2)),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'RECENT SESSION LOGS',
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: studentRecords.isEmpty
                  ? Center(
                      child: Text(
                        'No attendance history found.',
                        style: GoogleFonts.poppins(
                            fontSize: 12, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: studentRecords.length,
                      itemBuilder: (context, index) {
                        final r = studentRecords[index];
                        return _buildRecordCard(r);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F6F9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedView = 0),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: _selectedView == 0
                            ? AppColors.primaryBlue
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          'Logs & Roster',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: _selectedView == 0
                                ? Colors.white
                                : Colors.grey.shade700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedView = 1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: _selectedView == 1
                            ? AppColors.primaryBlue
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          'Class Analytics',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: _selectedView == 1
                                ? Colors.white
                                : Colors.grey.shade700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _fetchData,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20.0),
                    child: _selectedView == 0
                        ? _buildRecordsView()
                        : _buildAnalyticsView(),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildRecordsView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Attendance Records',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                    ),
                  ),
                  Text(
                    'View and export attendance reports.',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              onPressed: _exportPDF,
              icon: const Icon(Icons.picture_as_pdf_rounded,
                  size: 14, color: Colors.white),
              label: Text(
                'Export PDF',
                style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryBlue,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // NOTIFICATION ALERT BANNER FOR SUBMITTED REASONS ONLY
        if (_pendingReasonsCount > 0) ...[
          GestureDetector(
            onTap: () {
              setState(() {
                _selectedStatus = 'With Reasons';
                _applyFilters();
              });
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFDBA74)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_rounded,
                      color: Color(0xFFEA580C), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$_pendingReasonsCount student excuse reason(s) pending review.',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFC2410C),
                      ),
                    ),
                  ),
                  Text(
                    'Review >',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFEA580C),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedClass,
                          isExpanded: true,
                          style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlue),
                          icon: const Icon(Icons.arrow_drop_down,
                              color: AppColors.primaryBlue),
                          items: _classList.map((value) {
                            return DropdownMenuItem(
                              value: value,
                              child:
                                  Text(value, overflow: TextOverflow.ellipsis),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _selectedClass = val);
                              _applyFilters();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _showCustomCalendarModal(context),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: _selectedDateRange != null
                            ? const Color(0xFFEFF6FF)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selectedDateRange != null
                              ? AppColors.primaryBlue
                              : Colors.grey.shade300,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.calendar_today_rounded,
                              size: 14, color: AppColors.primaryBlue),
                          const SizedBox(width: 6),
                          Text(
                            _getDateDisplayString(),
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                          if (_selectedDateRange != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedDateRange = null;
                                  _applyFilters();
                                });
                              },
                              child: const Icon(Icons.cancel_rounded,
                                  size: 14, color: Colors.grey),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Autocomplete<Map<String, dynamic>>(
                displayStringForOption: (option) => option['full_name'] ?? '',
                optionsBuilder: (TextEditingValue textEditingValue) {
                  if (textEditingValue.text.trim().isEmpty) {
                    return const Iterable<Map<String, dynamic>>.empty();
                  }
                  final query = textEditingValue.text.toLowerCase();
                  final profiles = <String, Map<String, dynamic>>{};
                  for (var r in _rawRecords) {
                    final p = r['profiles'];
                    if (p != null && p['id'] != null) {
                      profiles[p['id'].toString()] =
                          Map<String, dynamic>.from(p);
                    }
                  }
                  return profiles.values.where((p) {
                    final name =
                        (p['full_name'] ?? '').toString().toLowerCase();
                    final schoolId =
                        (p['school_id'] ?? '').toString().toLowerCase();
                    final email = (p['email'] ?? '').toString().toLowerCase();
                    return name.contains(query) ||
                        schoolId.contains(query) ||
                        email.contains(query);
                  });
                },
                onSelected: (selection) {
                  setState(() {
                    _searchQuery = selection['full_name'] ?? '';
                    _applyFilters();
                  });
                },
                fieldViewBuilder:
                    (context, controller, focusNode, onEditingComplete) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (val) {
                      _searchQuery = val;
                      _applyFilters();
                    },
                    style: GoogleFonts.poppins(
                        fontSize: 11, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      hintText: 'Search student name or ID...',
                      hintStyle: GoogleFonts.poppins(
                          fontSize: 11, color: Colors.grey.shade400),
                      prefixIcon: const Icon(Icons.search_rounded,
                          size: 18, color: AppColors.primaryBlue),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 16),
                              onPressed: () {
                                controller.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _applyFilters();
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.primaryBlue, width: 1.5),
                      ),
                    ),
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 8,
                      shadowColor: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.white,
                      child: Container(
                        width: 280,
                        constraints: const BoxConstraints(maxHeight: 220),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          itemCount: options.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            thickness: 0.5,
                            color: Colors.grey.shade100,
                          ),
                          itemBuilder: (BuildContext context, int index) {
                            final option = options.elementAt(index);
                            final name = option['full_name'] ?? 'Student';
                            final schoolId = option['school_id'] ?? 'N/A';
                            final email = option['email'] ?? '';

                            return InkWell(
                              onTap: () => onSelected(option),
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor: const Color(0xFFEFF6FF),
                                      child: Text(
                                        name.isNotEmpty
                                            ? name[0].toUpperCase()
                                            : 'S',
                                        style: GoogleFonts.poppins(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primaryBlue,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            style: GoogleFonts.poppins(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.grey.shade800,
                                            ),
                                          ),
                                          Text(
                                            'ID: $schoolId ${email.isNotEmpty ? "• $email" : ""}',
                                            style: GoogleFonts.poppins(
                                              fontSize: 9,
                                              color: Colors.grey.shade500,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // STATUS FILTER CHIPS BAR ("With Reasons" before "Present")
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _statusList.map((st) {
              final isSel = _selectedStatus == st;
              final isReasonsChip = st == 'With Reasons';

              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        st,
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight:
                              isSel ? FontWeight.bold : FontWeight.normal,
                          color: isSel ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                      if (isReasonsChip && _pendingReasonsCount > 0) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: isSel
                                ? Colors.amber.shade400
                                : Colors.orange.shade800,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$_pendingReasonsCount',
                            style: GoogleFonts.poppins(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isSel ? Colors.black87 : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  selected: isSel,
                  selectedColor: AppColors.primaryBlue,
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                        color: isSel
                            ? AppColors.primaryBlue
                            : Colors.grey.shade300),
                  ),
                  onSelected: (_) {
                    setState(() => _selectedStatus = st);
                    _applyFilters();
                  },
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 12),
        Row(
          children: [
            _buildStatCard('Present', '$_presentCount', const Color(0xFF10B981),
                const Color(0xFFE6F4EA)),
            const SizedBox(width: 6),
            _buildStatCard('Late', '$_lateCount', const Color(0xFFF59E0B),
                const Color(0xFFFEF3C7)),
            const SizedBox(width: 6),
            _buildStatCard('Excused', '$_excusedCount', const Color(0xFF6366F1),
                const Color(0xFFEEF2FF)),
            const SizedBox(width: 6),
            _buildStatCard('Absent', '$_absentCount', const Color(0xFFEF4444),
                const Color(0xFFFEE2E2)),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'RECENT ATTENDANCE LOGS',
              style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue),
            ),
            Text(
              '${_filteredRecords.length} records',
              style: GoogleFonts.poppins(
                  fontSize: 10, color: Colors.grey.shade500),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_filteredRecords.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text(
                'No attendance logs match your filters.',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: Colors.grey.shade500),
              ),
            ),
          )
        else
          ..._paginatedRecords.map((r) => _buildRecordCard(r)),
        if (_filteredRecords.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  color: AppColors.primaryBlue,
                  onPressed: _currentPage > 1
                      ? () => setState(() => _currentPage--)
                      : null,
                ),
                Text(
                  'Page $_currentPage of $_totalPages',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  color: AppColors.primaryBlue,
                  onPressed: _currentPage < _totalPages
                      ? () => setState(() => _currentPage++)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAnalyticsView() {
    final statusTotal =
        _filteredRecords.isNotEmpty ? _filteredRecords.length : 1;
    final presentPct = ((_presentCount / statusTotal) * 100).round();
    final latePct = ((_lateCount / statusTotal) * 100).round();
    final excusedPct = ((_excusedCount / statusTotal) * 100).round();
    final absentPct = ((_absentCount / statusTotal) * 100).round();

    final reasons = _absenceReasonBreakdown;
    final totalAbsences = reasons.values.fold(0, (sum, item) => sum + item);
    final atRiskList = _atRiskStudentsList;

    final Map<String, List<Map<String, dynamic>>> classGroups = {};
    for (var r in _filteredRecords) {
      final code =
          r['attendance_sessions']?['classes']?['course_code']?.toString() ??
              'Other';
      classGroups.putIfAbsent(code, () => []).add(r);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Class Analytics Overview',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue,
                    ),
                  ),
                  Text(
                    'Filter by dates, classes, and search individual profiles.',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              onPressed: _exportPDF,
              icon: const Icon(Icons.picture_as_pdf_rounded,
                  size: 14, color: Colors.white),
              label: Text(
                'Export PDF',
                style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryBlue,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedClass,
                          isExpanded: true,
                          style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlue),
                          icon: const Icon(Icons.class_outlined,
                              size: 16, color: AppColors.primaryBlue),
                          items: _classList.map((value) {
                            return DropdownMenuItem(
                              value: value,
                              child:
                                  Text(value, overflow: TextOverflow.ellipsis),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _selectedClass = val);
                              _applyFilters();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _showCustomCalendarModal(context),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_month_rounded,
                              size: 16, color: AppColors.primaryBlue),
                          const SizedBox(width: 4),
                          Text(
                            _getDateDisplayString(),
                            style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                          if (_selectedDateRange != null) ...[
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedDateRange = null;
                                  _applyFilters();
                                });
                              },
                              child: const Icon(Icons.close,
                                  size: 14, color: Colors.grey),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                onChanged: (val) {
                  setState(() => _searchQuery = val);
                  _applyFilters();
                },
                style: GoogleFonts.poppins(fontSize: 11),
                decoration: InputDecoration(
                  hintText: 'Search specific student name or ID...',
                  hintStyle: GoogleFonts.poppins(
                      fontSize: 10, color: Colors.grey.shade400),
                  prefixIcon: const Icon(Icons.person_search_rounded,
                      size: 18, color: AppColors.primaryBlue),
                  filled: true,
                  fillColor: const Color(0xFFF4F6F9),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _buildMetricCard(
                'Avg Attendance',
                '${_avgAttendanceRate.toStringAsFixed(1)}%',
                'Present + Excused',
                true,
                Icons.trending_up_rounded,
                const Color(0xFF10B981)),
            const SizedBox(width: 6),
            _buildMetricCard(
                'On-Time Rate',
                '${_onTimeRate.toStringAsFixed(1)}%',
                'Punctual scans',
                true,
                Icons.check_circle_outline_rounded,
                AppColors.primaryBlue),
            const SizedBox(width: 6),
            _buildMetricCard(
                'At-Risk Students',
                '${atRiskList.length}',
                '≥2 Absences',
                false,
                Icons.warning_amber_rounded,
                const Color(0xFFEF4444)),
          ],
        ),
        const SizedBox(height: 20),
        _buildOutlookCard(atRiskList.length),
        const SizedBox(height: 20),
        _buildTrendCard(),
        const SizedBox(height: 20),
        _buildWeekdayCard(),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attendance Breakdown',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    height: 110,
                    child: CustomPaint(
                      painter: _PieChartPainter(
                        presentRatio: _presentCount / statusTotal,
                        lateRatio: _lateCount / statusTotal,
                        excusedRatio: _excusedCount / statusTotal,
                        absentRatio: _absentCount / statusTotal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      children: [
                        _buildLegendItem(
                            'Present', '$presentPct%', const Color(0xFF10B981)),
                        const SizedBox(height: 8),
                        _buildLegendItem(
                            'Late', '$latePct%', const Color(0xFFF59E0B)),
                        const SizedBox(height: 8),
                        _buildLegendItem(
                            'Excused', '$excusedPct%', const Color(0xFF6366F1)),
                        const SizedBox(height: 8),
                        _buildLegendItem(
                            'Absent', '$absentPct%', const Color(0xFFEF4444)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
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
                      Text('Absence Reasons',
                          style: GoogleFonts.poppins(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue)),
                      Text(
                        'Tap any category below to view specific student remarks',
                        style: GoogleFonts.poppins(
                            fontSize: 10, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                  const Icon(Icons.touch_app_rounded,
                      size: 18, color: AppColors.primaryBlue),
                ],
              ),
              const SizedBox(height: 16),
              ...reasons.entries.map((entry) {
                final pct =
                    totalAbsences > 0 ? (entry.value / totalAbsences) : 0.0;
                return InkWell(
                  onTap: () => _showReasonDetailsModal(entry.key),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 6.0, horizontal: 4.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Text(
                                  entry.key,
                                  style: GoogleFonts.poppins(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade800),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.chevron_right_rounded,
                                    size: 14, color: Colors.grey.shade400),
                              ],
                            ),
                            Text(
                              '${entry.value} (${(pct * 100).toStringAsFixed(0)}%)',
                              style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade100,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              entry.key.contains('Medical')
                                  ? const Color(0xFF3B82F6)
                                  : entry.key.contains('Transportation')
                                      ? const Color(0xFFF59E0B)
                                      : entry.key.contains('Family')
                                          ? const Color(0xFF8B5CF6)
                                          : entry.key.contains('Memo')
                                              ? const Color(0xFF6366F1)
                                              : const Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (atRiskList.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFCA5A5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 18, color: Color(0xFFEF4444)),
                        const SizedBox(width: 6),
                        Text(
                          'At-Risk Students Roster',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF991B1B),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${atRiskList.length} Flagged',
                        style: GoogleFonts.poppins(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Students with 2 or more unexcused absences requiring intervention.',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 12),
                ...atRiskList.map((item) {
                  final profile = item['profile'];
                  final classInfo = item['class'];
                  final absences = item['absences'];
                  final name = profile?['full_name'] ?? 'Student';
                  final schoolId = profile?['school_id'] ?? 'N/A';
                  final classCode = classInfo?['course_code'] ?? 'Class';

                  return InkWell(
                    onTap: () {
                      if (profile != null) _showStudentDeepDiveModal(profile);
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade900,
                                  ),
                                ),
                                Text(
                                  '$schoolId • $classCode',
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$absences Absences',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFDC2626),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        if (atRiskList.isNotEmpty) const SizedBox(height: 20),
        if (classGroups.isNotEmpty)
          Container(
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
                    Text(
                      'Class-by-Class Attendance Rate',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    const Icon(Icons.bar_chart_rounded,
                        size: 18, color: AppColors.primaryBlue),
                  ],
                ),
                Text(
                  'Comparative overview across assigned course sections',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 14),
                ...classGroups.entries.map((entry) {
                  final code = entry.key;
                  final records = entry.value;
                  final total = records.length;
                  final presentOrExcused = records.where((r) {
                    final st = r['status']?.toString().toLowerCase();
                    return st == 'present' || st == 'excused';
                  }).length;

                  final rate = total > 0 ? (presentOrExcused / total) : 0.0;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              code,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade800,
                              ),
                            ),
                            Text(
                              '${(rate * 100).toStringAsFixed(1)}% ($presentOrExcused/$total)',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: rate,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade100,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              rate >= 0.85
                                  ? const Color(0xFF10B981)
                                  : rate >= 0.70
                                      ? const Color(0xFFF59E0B)
                                      : const Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        _buildHighlightsCard(),
      ],
    );
  }

  // ---------------------------------------------------------------
  // ANALYTICS CARDS
  // ---------------------------------------------------------------

  Widget _analyticsCardShell({
    required String title,
    required String subtitle,
    required Widget child,
    Color? accent,
    Widget? trailing,
  }) {
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: accent == null
            ? content
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: accent),
                    Expanded(child: content),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildOutlookCard(int atRiskNow) {
    if (_filteredRecords.isEmpty) {
      return _analyticsCardShell(
        title: 'Next Week Outlook',
        subtitle:
            'A simple estimate based on absences in the selected records.',
        child: Text(
          'No records to estimate from yet.',
          style: GoogleFonts.poppins(
            fontSize: 11,
            color: Colors.grey.shade500,
          ),
        ),
      );
    }

    final Color accent = _forecastRiskColor;
    final double nowRate = _avgAttendanceRate;
    final double expected = _projectedNextWeekRate;
    final bool growing = _projectedAtRiskCount > atRiskNow;

    Widget figure(String label, String value, String caption) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 10,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: GoogleFonts.poppins(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            Text(
              caption,
              style: GoogleFonts.poppins(
                fontSize: 10,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
      );
    }

    return _analyticsCardShell(
      title: 'Next Week Outlook',
      subtitle: 'A simple estimate based on absences in the selected records.',
      accent: accent,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            _forecastRiskLevel,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              figure(
                'Expected attendance',
                '${expected.toStringAsFixed(1)}%',
                'Now ${nowRate.toStringAsFixed(1)}%',
              ),
              Container(
                width: 1,
                height: 56,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: Colors.grey.shade200,
              ),
              figure(
                'Possible at-risk',
                '$_projectedAtRiskCount student${_projectedAtRiskCount == 1 ? '' : 's'}',
                'Now $atRiskNow at risk',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.grey.shade200),
          const SizedBox(height: 10),
          Text(
            growing
                ? 'Follow-up: check in with students who already have 1 absence before next week.'
                : 'Follow-up: nothing needed right now. Keep tracking each session.',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: Colors.grey.shade700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Counts students with 2+ absences, plus about half of those with 1.',
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendCard() {
    final rates = _recentSessionRates;

    String label(String iso) {
      final dt = DateTime.tryParse(iso);
      return dt == null ? '' : '${dt.month}/${dt.day}';
    }

    return _analyticsCardShell(
      title: 'Attendance Trend',
      subtitle: rates.length < 2
          ? 'Attendance rate per session'
          : 'Attendance rate for the last ${rates.length} sessions',
      trailing: const Icon(Icons.show_chart_rounded,
          size: 18, color: AppColors.primaryBlue),
      child: rates.length < 2
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Not enough sessions yet to show a trend.',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            )
          : Column(
              children: [
                SizedBox(
                  height: 140,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _LineGraphPainter(
                      dataPoints: rates.map((e) => e.value).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: rates
                      .map(
                        (e) => Text(
                          label(e.key),
                          style: GoogleFonts.poppins(
                            fontSize: 9,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
    );
  }

  Widget _buildWeekdayCard() {
    final rates = _weekdayRates;
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'];

    int? lowest;
    for (int i = 0; i < rates.length; i++) {
      final r = rates[i];
      if (r == null) continue;
      if (lowest == null || r < (rates[lowest] ?? 1.0)) lowest = i;
    }
    final bool hasData = rates.any((r) => r != null);

    Color colorFor(double r) {
      if (r >= 0.85) return const Color(0xFF10B981);
      if (r >= 0.70) return const Color(0xFFF59E0B);
      return const Color(0xFFEF4444);
    }

    return _analyticsCardShell(
      title: 'Attendance by Day',
      subtitle: 'Which days of the week have the best and worst attendance',
      trailing: const Icon(Icons.calendar_view_week_rounded,
          size: 18, color: AppColors.primaryBlue),
      child: !hasData
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  'No sessions recorded yet.',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...List.generate(5, (i) {
                  final r = rates[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 78,
                          child: Text(
                            days[i],
                            style: GoogleFonts.poppins(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade800,
                            ),
                          ),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: r ?? 0,
                              minHeight: 8,
                              backgroundColor: Colors.grey.shade100,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                r == null ? Colors.grey.shade300 : colorFor(r),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 62,
                          child: Text(
                            r == null
                                ? 'No class'
                                : '${(r * 100).toStringAsFixed(0)}%',
                            textAlign: TextAlign.right,
                            style: GoogleFonts.poppins(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: r == null
                                  ? Colors.grey.shade400
                                  : Colors.grey.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (lowest != null)
                  Text(
                    'Lowest attendance: ${days[lowest]} '
                    '(${((rates[lowest] ?? 0) * 100).toStringAsFixed(0)}%)',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: Colors.grey.shade600,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildHighlightsCard() {
    final stats = _studentStats.values.toList();

    final perfect = stats
        .where((e) =>
            (e['total'] as int) >= 3 &&
            e['late'] == 0 &&
            e['absent'] == 0 &&
            e['excused'] == 0)
        .toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

    final lateOften = stats.where((e) => (e['late'] as int) >= 2).toList()
      ..sort((a, b) => (b['late'] as int).compareTo(a['late'] as int));

    if (perfect.isEmpty && lateOften.isEmpty) return const SizedBox.shrink();

    Widget section({
      required String title,
      required IconData icon,
      required Color color,
      required List<Map<String, dynamic>> people,
      required String Function(Map<String, dynamic>) trailingText,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(
                '$title (${people.length})',
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (people.isEmpty)
            Text(
              'None for this period.',
              style: GoogleFonts.poppins(
                fontSize: 10.5,
                color: Colors.grey.shade500,
              ),
            )
          else
            ...people.take(5).map(
                  (p) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            p['name'].toString(),
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: Colors.grey.shade800,
                            ),
                          ),
                        ),
                        Text(
                          trailingText(p),
                          style: GoogleFonts.poppins(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          if (people.length > 5)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '+ ${people.length - 5} more',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: _analyticsCardShell(
        title: 'Student Highlights',
        subtitle: 'Based on the records shown above',
        trailing: const Icon(Icons.people_alt_outlined,
            size: 18, color: AppColors.primaryBlue),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            section(
              title: 'Perfect attendance',
              icon: Icons.emoji_events_outlined,
              color: const Color(0xFF10B981),
              people: perfect,
              trailingText: (p) => '${p['total']} sessions',
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: Colors.grey.shade200),
            const SizedBox(height: 14),
            section(
              title: 'Often late',
              icon: Icons.access_time_rounded,
              color: const Color(0xFFF59E0B),
              people: lateOften,
              trailingText: (p) => '${p['late']} times late',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(
      String label, String count, Color textColor, Color bgColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200)),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(count,
                  style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: textColor)),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                  color: bgColor, borderRadius: BorderRadius.circular(6)),
              child: Text(label,
                  style: GoogleFonts.poppins(
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                      color: textColor),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordCard(Map<String, dynamic> record) {
    final status = (record['status'] ?? 'Present').toString();
    final profile = record['profiles'];
    final name = profile?['full_name'] ?? 'Unknown Student';
    final schoolId = profile?['school_id'] ?? '2024-0000';
    final classCode =
        record['attendance_sessions']?['classes']?['course_code'] ?? 'CLASS';

    final scannedAt = record['scanned_at']?.toString();
    final sessionDate = record['attendance_sessions']?['date']?.toString();
    final formattedTime = _formatDateTime(scannedAt, sessionDate);

    final remarks = record['remarks'];
    final category = record['reason_category'];

    final absenceList = record['absence_reasons'] as List?;
    final proofUrl = (absenceList != null && absenceList.isNotEmpty)
        ? absenceList.first['proof_url']?.toString()
        : null;

    final hasReason = _hasReason(record);

    final statusLower = status.toLowerCase();
    Color statusBg = statusLower == 'present'
        ? const Color(0xFFE6F4EA)
        : statusLower == 'late'
            ? const Color(0xFFFEF3C7)
            : statusLower == 'excused'
                ? const Color(0xFFEEF2FF)
                : const Color(0xFFFEE2E2);

    Color statusColor = statusLower == 'present'
        ? const Color(0xFF10B981)
        : statusLower == 'late'
            ? const Color(0xFFF59E0B)
            : statusLower == 'excused'
                ? const Color(0xFF6366F1)
                : const Color(0xFFEF4444);

    return InkWell(
      onTap: () => _showEditRecordDialog(record),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasReason && statusLower != 'excused'
                  ? AppColors.primaryBlue.withValues(alpha: 0.4)
                  : Colors.grey.shade200,
              width: hasReason && statusLower != 'excused' ? 1.5 : 1.0,
            )),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: statusColor.withValues(alpha: 0.1),
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'S',
                          style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: statusColor),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: GoogleFonts.poppins(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasReason) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEEF2FF),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'REASON',
                                      style: GoogleFonts.poppins(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF6366F1),
                                      ),
                                    ),
                                  ),
                                ]
                              ],
                            ),
                            Text(
                              '$schoolId • $classCode • $formattedTime',
                              style: GoogleFonts.poppins(
                                  fontSize: 10, color: Colors.grey.shade600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => _showEditRecordDialog(record),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: statusBg,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          status.toUpperCase(),
                          style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: statusColor),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined,
                          size: 16, color: AppColors.primaryBlue),
                      onPressed: () => _showEditRecordDialog(record),
                    ),
                  ],
                ),
              ],
            ),
            if (category != null ||
                remarks != null ||
                (proofUrl != null && proofUrl.isNotEmpty)) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (category != null || remarks != null)
                      Text(
                        'Remark: ${category ?? ''} ${remarks != null && remarks.toString().isNotEmpty ? "($remarks)" : ""}',
                        style: GoogleFonts.poppins(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: Colors.blueGrey.shade800),
                      ),
                    if (proofUrl != null && proofUrl.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => _showProofImageModal(proofUrl, name),
                        icon: const Icon(Icons.image_outlined, size: 14),
                        label: Text(
                          'View Attached Proof Image',
                          style: GoogleFonts.poppins(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primaryBlue,
                          side: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ]
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String subtitle,
      bool isPos, IconData icon, Color iconColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 8.5,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(icon, size: 13, color: iconColor),
              ],
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: GoogleFonts.poppins(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                    fontSize: 8,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, String pct, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(label,
                style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700)),
          ],
        ),
        Text(pct,
            style:
                GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _LineGraphPainter extends CustomPainter {
  final List<double> dataPoints;

  _LineGraphPainter({required this.dataPoints});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1;

    final linePaint = Paint()
      ..color = AppColors.primaryBlue
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppColors.primaryBlue.withValues(alpha: 0.3),
          AppColors.primaryBlue.withValues(alpha: 0.01),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final dotPaint = Paint()..color = AppColors.primaryBlue;
    final innerDotPaint = Paint()..color = Colors.white;

    for (int i = 0; i <= 3; i++) {
      final y = size.height * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (dataPoints.isEmpty) return;

    final double stepX = size.width / (dataPoints.length - 1);
    final List<Offset> points = [];

    for (int i = 0; i < dataPoints.length; i++) {
      final x = i * stepX;
      final y = size.height -
          (dataPoints[i] * size.height * 0.8) -
          (size.height * 0.1);
      points.add(Offset(x, y));
    }

    final path = Path();
    final fillPath = Path();

    path.moveTo(points[0].dx, points[0].dy);
    fillPath.moveTo(points[0].dx, size.height);
    fillPath.lineTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final controlP1 = Offset(p1.dx + (p2.dx - p1.dx) / 2, p1.dy);
      final controlP2 = Offset(p1.dx + (p2.dx - p1.dx) / 2, p2.dy);

      path.cubicTo(
          controlP1.dx, controlP1.dy, controlP2.dx, controlP2.dy, p2.dx, p2.dy);
      fillPath.cubicTo(
          controlP1.dx, controlP1.dy, controlP2.dx, controlP2.dy, p2.dx, p2.dy);
    }

    fillPath.lineTo(points.last.dx, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    for (var p in points) {
      canvas.drawCircle(p, 5, dotPaint);
      canvas.drawCircle(p, 2.5, innerDotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _PieChartPainter extends CustomPainter {
  final double presentRatio, lateRatio, excusedRatio, absentRatio;

  _PieChartPainter({
    required this.presentRatio,
    required this.lateRatio,
    required this.excusedRatio,
    required this.absentRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final paint = Paint()..style = PaintingStyle.fill;
    double startAngle = -pi / 2;

    final total = presentRatio + lateRatio + excusedRatio + absentRatio;
    if (total <= 0) return;

    final presentSweep = (presentRatio / total) * 2 * pi;
    paint.color = const Color(0xFF10B981);
    canvas.drawArc(rect, startAngle, presentSweep, true, paint);
    startAngle += presentSweep;

    final lateSweep = (lateRatio / total) * 2 * pi;
    paint.color = const Color(0xFFF59E0B);
    canvas.drawArc(rect, startAngle, lateSweep, true, paint);
    startAngle += lateSweep;

    final excusedSweep = (excusedRatio / total) * 2 * pi;
    paint.color = const Color(0xFF6366F1);
    canvas.drawArc(rect, startAngle, excusedSweep, true, paint);
    startAngle += excusedSweep;

    final absentSweep = (absentRatio / total) * 2 * pi;
    paint.color = const Color(0xFFEF4444);
    canvas.drawArc(rect, startAngle, absentSweep, true, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
