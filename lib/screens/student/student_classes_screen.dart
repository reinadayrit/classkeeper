import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../widgets/date_range_calendar.dart';

class StudentClassesScreen extends StatefulWidget {
  final Function(int)? onTabSelected;

  const StudentClassesScreen({super.key, this.onTabSelected});

  @override
  State<StudentClassesScreen> createState() => _StudentClassesScreenState();
}

class _StudentClassesScreenState extends State<StudentClassesScreen> {
  final _supabase = Supabase.instance.client;

  bool _isLoading = true;
  bool _showArchived = false;

  List<Map<String, dynamic>> _allEnrolledClasses = [];

  RealtimeChannel? _realtimeChannel;

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
    _fetchStudentClasses();
    _subscribeToRealtimeChanges();
  }

  @override
  void dispose() {
    if (_realtimeChannel != null) {
      _supabase.removeChannel(_realtimeChannel!);
    }
    super.dispose();
  }

  /// Custom Floating Pill Alert SnackBar for uniform feedback
  void _showCustomSnackBar({
    required String message,
    required Color backgroundColor,
    required IconData icon,
    BuildContext? targetContext,
  }) {
    final ctx = targetContext ?? context;
    if (!mounted && targetContext == null) return;
    ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        backgroundColor: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        content: Row(
          children: [
            Icon(
              icon,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // REALTIME UPDATES

  void _subscribeToRealtimeChanges() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    _realtimeChannel = _supabase
        .channel('student_classes_realtime_${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'class_enrollments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'student_id',
            value: user.id,
          ),
          callback: (payload) => _fetchStudentClasses(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'student_id',
            value: user.id,
          ),
          callback: (payload) => _fetchStudentClasses(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_sessions',
          callback: (payload) => _fetchStudentClasses(),
        )
        .subscribe();
  }

  // CLASS FILTERING AND PAGINATION

  List<Map<String, dynamic>> get _filteredClasses {
    return _allEnrolledClasses.where((c) {
      final isArchived = c['is_archived'] == true ||
          c['status']?.toString().toLowerCase() == 'archived';

      return _showArchived ? isArchived : !isArchived;
    }).toList();
  }

  List<Map<String, dynamic>> get _paginatedClasses {
    final classes = _filteredClasses;

    final startIndex = (_currentPage - 1) * _itemsPerPage;

    if (startIndex >= classes.length) return [];

    final endIndex = (startIndex + _itemsPerPage < classes.length)
        ? startIndex + _itemsPerPage
        : classes.length;

    return classes.sublist(startIndex, endIndex);
  }

  int get _totalPages {
    final count = _filteredClasses.length;

    if (count == 0) return 1;

    return (count / _itemsPerPage).ceil();
  }

  // FETCH STUDENT CLASSES

  Future<void> _fetchStudentClasses() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final user = _supabase.auth.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            _allEnrolledClasses = [];
          });
        }
        return;
      }

      final todayStr = DateTime.now().toIso8601String().split('T')[0];

      final response = await _supabase.from('class_enrollments').select('''
            class_id,
            classes (
              id,
              course_code,
              course_name,
              schedule,
              section,
              is_archived,
              created_at,
              attendance_sessions (
                id,
                date,
                attendance_records (
                  id,
                  status,
                  reason_category,
                  remarks,
                  student_id
                )
              )
            )
          ''').eq('student_id', user.id);

      final List<Map<String, dynamic>> parsedClasses = [];

      final responseList = response as List<dynamic>;

      for (final row in responseList) {
        final rowMap = Map<String, dynamic>.from(row as Map);

        if (rowMap['classes'] == null) continue;

        final classData = Map<String, dynamic>.from(rowMap['classes'] as Map);

        String status = 'Upcoming';

        final rawSessions =
            classData['attendance_sessions'] as List<dynamic>? ?? [];

        // Find today's attendance session.
        Map<String, dynamic>? todaySession;

        for (final session in rawSessions) {
          final sessionMap = Map<String, dynamic>.from(session as Map);

          if (sessionMap['date'] == null) continue;

          final sessionDateStr =
              sessionMap['date'].toString().split('T')[0].split(' ')[0];

          if (sessionDateStr == todayStr) {
            todaySession = sessionMap;
            break;
          }
        }

        // Find the current student's attendance record.
        if (todaySession != null) {
          final rawRecords =
              todaySession['attendance_records'] as List<dynamic>? ?? [];

          for (final record in rawRecords) {
            final recordMap = Map<String, dynamic>.from(record as Map);

            if (recordMap['student_id'] == user.id) {
              final rawStatus = recordMap['status']?.toString();

              if (rawStatus != null && rawStatus.isNotEmpty) {
                status = rawStatus[0].toUpperCase() +
                    rawStatus.substring(1).toLowerCase();
              }

              break;
            }
          }
        }

        // Count this student's absences in the class, and how many of them
        // still have no reason submitted.
        int absentTotal = 0;
        int needsReason = 0;

        for (final session in rawSessions) {
          final sessionMap = Map<String, dynamic>.from(session as Map);
          final recs = sessionMap['attendance_records'] as List<dynamic>? ?? [];

          for (final r in recs) {
            final rm = Map<String, dynamic>.from(r as Map);
            if (rm['student_id'] != user.id) continue;

            if (rm['status']?.toString().toLowerCase() == 'absent') {
              absentTotal++;
              final cat = rm['reason_category']?.toString() ?? '';
              if (cat.isEmpty) needsReason++;
            }
          }
        }

        classData['absent_count'] = absentTotal;
        classData['needs_reason_count'] = needsReason;

        classData['computed_status'] = status;
        parsedClasses.add(classData);
      }

      if (mounted) {
        setState(() {
          _allEnrolledClasses = parsedClasses;

          if (_currentPage > _totalPages) {
            _currentPage = 1;
          }
        });
      }
    } catch (e) {
      debugPrint('Error fetching student classes: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // DATE FORMATTING

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

  // PDF EXPORT

  /// True when the attendance record's date falls inside [range].
  bool _recordInRange(Map<String, dynamic> rec, DateTimeRange? range) {
    if (range == null) return true;

    final session = rec['attendance_sessions'] as Map<String, dynamic>?;
    final String? sessionDate = session?['date']?.toString();

    DateTime? dt = sessionDate != null ? DateTime.tryParse(sessionDate) : null;
    dt ??= DateTime.tryParse(rec['scanned_at']?.toString() ?? '')?.toLocal();

    if (dt == null) return false;
    return isDateInRange(dt, range);
  }

  Future<void> _exportAttendancePdf({
    required String courseCode,
    required String courseName,
    required List<Map<String, dynamic>> records,
    String dateLabel = 'All Dates',
  }) async {
    try {
      final pdf = pw.Document();

      final user = _supabase.auth.currentUser;

      final profileRes = await _supabase
          .from('profiles')
          .select('full_name, school_id')
          .eq('id', user?.id ?? '')
          .maybeSingle();

      final studentName = profileRes?['full_name'] ?? user?.email ?? 'Student';

      final schoolId = profileRes?['school_id'] ?? 'N/A';

      int presentCount = 0;
      int lateCount = 0;
      int absentCount = 0;
      int excusedCount = 0;

      for (final record in records) {
        final status = record['status']?.toString().toUpperCase();

        if (status == 'PRESENT') {
          presentCount++;
        } else if (status == 'LATE') {
          lateCount++;
        } else if (status == 'ABSENT') {
          absentCount++;
        } else if (status == 'EXCUSED') {
          excusedCount++;
        }
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'ClassKeeper - Student Attendance Report',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue900,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        '$courseCode - $courseName',
                        style: pw.TextStyle(
                          fontSize: 13,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.grey800,
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'Period: $dateLabel',
                        style: const pw.TextStyle(
                          fontSize: 10,
                          color: PdfColors.grey700,
                        ),
                      ),
                    ],
                  ),
                  pw.Text(
                    'Generated:\n${DateTime.now().toString().split('.')[0]}',
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: PdfColors.grey600,
                    ),
                    textAlign: pw.TextAlign.right,
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 1, color: PdfColors.grey400),
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Student Name: $studentName',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'School ID: $schoolId',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 14),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  _pdfStatBadge(
                    'Total Sessions',
                    '${records.length}',
                    PdfColors.blue800,
                  ),
                  _pdfStatBadge(
                    'Present',
                    '$presentCount',
                    PdfColors.green700,
                  ),
                  _pdfStatBadge(
                    'Late',
                    '$lateCount',
                    PdfColors.orange700,
                  ),
                  _pdfStatBadge(
                    'Excused',
                    '$excusedCount',
                    PdfColors.purple700,
                  ),
                  _pdfStatBadge(
                    'Absent',
                    '$absentCount',
                    PdfColors.red700,
                  ),
                ],
              ),
              pw.SizedBox(height: 16),
              pw.TableHelper.fromTextArray(
                headers: [
                  'Date & Time',
                  'Status',
                  'Reason / Remarks',
                ],
                data: records.map((rec) {
                  final session =
                      rec['attendance_sessions'] as Map<String, dynamic>?;

                  final formattedDate = _formatDateTime(
                    rec['scanned_at'],
                    session?['date']?.toString(),
                  );

                  final status =
                      rec['status']?.toString().toUpperCase() ?? 'PRESENT';

                  final category = rec['reason_category'];
                  final remarks = rec['remarks'];

                  String reasonText = '-';

                  if (category != null &&
                      remarks != null &&
                      remarks.toString().isNotEmpty) {
                    reasonText = '$category ($remarks)';
                  } else if (category != null) {
                    reasonText = category.toString();
                  } else if (remarks != null && remarks.toString().isNotEmpty) {
                    reasonText = remarks.toString();
                  }

                  return [
                    formattedDate,
                    status,
                    reasonText,
                  ];
                }).toList(),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                  fontSize: 10,
                ),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColors.blue900),
                cellStyle: const pw.TextStyle(fontSize: 9),
                cellHeight: 24,
                cellAlignments: {
                  0: pw.Alignment.centerLeft,
                  1: pw.Alignment.center,
                  2: pw.Alignment.centerLeft,
                },
              ),
            ];
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: 'Attendance_${courseCode}_$schoolId.pdf',
      );
    } catch (e) {
      debugPrint('Error generating attendance PDF: $e');

      if (mounted) {
        _showCustomSnackBar(
          message: 'Unable to generate attendance PDF.',
          backgroundColor: const Color(0xFFE53935),
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }

  pw.Widget _pdfStatBadge(
    String label,
    String value,
    PdfColor color,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 8,
      ),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: color, width: 1),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        children: [
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            label,
            style: const pw.TextStyle(
              fontSize: 8,
              color: PdfColors.grey700,
            ),
          ),
        ],
      ),
    );
  }

  // SUBMIT EXCUSE / REASON

  void _showSubmitExcuseDialog(
    Map<String, dynamic> record,
    String classId,
    VoidCallback onSubmitted,
  ) {
    String? selectedCategory = record['reason_category'];

    final remarksCtrl = TextEditingController(
      text: record['remarks'] ?? '',
    );

    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            backgroundColor: Colors.white,
            elevation: 8,
            child: Container(
              padding: const EdgeInsets.all(22),
              constraints: const BoxConstraints(maxWidth: 380),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Submit Excuse / Reason',
                            style: GoogleFonts.poppins(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: isSubmitting
                              ? null
                              : () => Navigator.pop(dialogCtx),
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: Colors.grey,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Select a reason category and provide details for your instructor.',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'REASON CATEGORY',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: _reasonCategories.contains(selectedCategory)
                          ? selectedCategory
                          : null,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                      icon: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: AppColors.primaryBlue,
                        size: 20,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Select reason category',
                        hintStyle: GoogleFonts.poppins(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFFE2E8F0),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: AppColors.primaryBlue,
                            width: 1.5,
                          ),
                        ),
                      ),
                      items: _reasonCategories.map((cat) {
                        return DropdownMenuItem(
                          value: cat,
                          child: Text(
                            cat,
                            style: GoogleFonts.poppins(fontSize: 12),
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedCategory = val;
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'EXPLANATION / REMARKS',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: remarksCtrl,
                      style: GoogleFonts.poppins(fontSize: 12),
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Provide details or additional notes...',
                        hintStyle: GoogleFonts.poppins(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.all(14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFFE2E8F0),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: AppColors.primaryBlue,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFBFDBFE),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: AppColors.primaryBlue,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Note: Physical medical certificates or university memos must be presented in person to your instructor.',
                              style: GoogleFonts.poppins(
                                fontSize: 10.5,
                                color: AppColors.primaryBlue,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            onPressed: isSubmitting
                                ? null
                                : () => Navigator.pop(dialogCtx),
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
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: isSubmitting
                                ? null
                                : () async {
                                    if (selectedCategory == null) {
                                      _showCustomSnackBar(
                                        message:
                                            'Please select a reason category.',
                                        backgroundColor: Colors.orange.shade800,
                                        icon: Icons.warning_amber_rounded,
                                        targetContext: dialogCtx,
                                      );
                                      return;
                                    }

                                    setDialogState(() {
                                      isSubmitting = true;
                                    });

                                    try {
                                      final user = _supabase.auth.currentUser;

                                      if (user == null) {
                                        throw Exception(
                                          'No authenticated student.',
                                        );
                                      }

                                      final reasonText =
                                          '$selectedCategory: ${remarksCtrl.text.trim()}';

                                      await _supabase
                                          .from('attendance_records')
                                          .update({
                                        'reason_category': selectedCategory,
                                        'remarks': remarksCtrl.text.trim(),
                                      }).eq('id', record['id']);

                                      final existingReason = await _supabase
                                          .from('absence_reasons')
                                          .select('id')
                                          .eq(
                                            'attendance_record_id',
                                            record['id'],
                                          )
                                          .maybeSingle();

                                      if (existingReason != null) {
                                        await _supabase
                                            .from('absence_reasons')
                                            .update({
                                          'reason': reasonText,
                                          'status': 'pending',
                                        }).eq(
                                          'id',
                                          existingReason['id'],
                                        );
                                      } else {
                                        await _supabase
                                            .from('absence_reasons')
                                            .insert({
                                          'attendance_record_id': record['id'],
                                          'student_id': user.id,
                                          'class_id': classId,
                                          'reason': reasonText,
                                          'status': 'pending',
                                        });
                                      }

                                      if (dialogCtx.mounted) {
                                        Navigator.pop(dialogCtx);
                                      }

                                      if (mounted) {
                                        onSubmitted();

                                        _showCustomSnackBar(
                                          message:
                                              'Excuse submitted successfully.',
                                          backgroundColor:
                                              const Color(0xFF41A564),
                                          icon: Icons
                                              .check_circle_outline_rounded,
                                        );
                                      }
                                    } catch (e) {
                                      debugPrint(
                                        'Error submitting excuse: $e',
                                      );

                                      if (dialogCtx.mounted) {
                                        setDialogState(() {
                                          isSubmitting = false;
                                        });

                                        _showCustomSnackBar(
                                          message:
                                              'Failed to submit excuse. Please try again.',
                                          backgroundColor:
                                              const Color(0xFFE53935),
                                          icon: Icons.error_outline_rounded,
                                          targetContext: dialogCtx,
                                        );
                                      }
                                    }
                                  },
                            child: isSubmitting
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    'Submit Excuse',
                                    style: GoogleFonts.poppins(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
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
          );
        },
      ),
    ).then((_) {
      // The dialog is still animating closed at this point, so wait before
      // disposing the controller (disposing too early crashes the screen).
      Future.delayed(const Duration(milliseconds: 600), remarksCtrl.dispose);
    });
  }

  // ATTENDANCE HISTORY MODAL

  void _showAttendanceHistoryModal(
    BuildContext context,
    String classId,
    String courseCode,
    String courseName,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final user = _supabase.auth.currentUser;

        int historyPage = 1;
        int refreshKey = 0;
        DateTimeRange? dateFilter; // same calendar as the faculty Records

        const int historyPerPage = 5;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.82,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
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
                  Expanded(
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      key: ValueKey(refreshKey),
                      future: _supabase
                          .from('attendance_records')
                          .select('''
                            id,
                            status,
                            reason_category,
                            remarks,
                            scanned_at,
                            attendance_sessions!inner (
                              id,
                              date,
                              class_id
                            ),
                            absence_reasons (
                              id,
                              reason,
                              status,
                              teacher_remark
                            )
                          ''')
                          .eq('student_id', user?.id ?? '')
                          .eq(
                            'attendance_sessions.class_id',
                            classId,
                          )
                          .order(
                            'scanned_at',
                            ascending: false,
                          )
                          .then(
                            (data) => (data as List<dynamic>)
                                .map(
                                  (e) => Map<String, dynamic>.from(e as Map),
                                )
                                .toList(),
                          ),
                      builder: (context, snapshot) {
                        final allRecords = snapshot.data ?? [];

                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primaryBlue,
                            ),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Unable to load attendance history.',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.red,
                              ),
                            ),
                          );
                        }

                        if (allRecords.isEmpty) {
                          return Center(
                            child: Text(
                              'No attendance records found for this class.',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          );
                        }

                        // Apply the date filter
                        final records = allRecords
                            .where((r) => _recordInRange(r, dateFilter))
                            .toList();

                        final totalHistoryPages = records.isEmpty
                            ? 1
                            : (records.length / historyPerPage).ceil();

                        if (historyPage > totalHistoryPages) {
                          historyPage = totalHistoryPages;
                        }
                        if (historyPage < 1) historyPage = 1;

                        final startIndex = (historyPage - 1) * historyPerPage;

                        final endIndex =
                            (startIndex + historyPerPage < records.length)
                                ? startIndex + historyPerPage
                                : records.length;

                        final paginatedRecords =
                            records.sublist(startIndex, endIndex);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Attendance History',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primaryBlue,
                                        ),
                                      ),
                                      Text(
                                        '$courseCode - $courseName',
                                        style: GoogleFonts.poppins(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    // Choose which dates go into the PDF
                                    final DateRangeResult? picked =
                                        await showDateRangeCalendar(
                                      context,
                                      initialRange: dateFilter,
                                      title: 'Export PDF',
                                      applyVerb: 'Export',
                                      emptyApplyText: 'Export All Dates',
                                    );
                                    if (picked == null) return;

                                    final exportRecords = allRecords
                                        .where((r) =>
                                            _recordInRange(r, picked.range))
                                        .toList();

                                    if (exportRecords.isEmpty) {
                                      _showCustomSnackBar(
                                        message:
                                            'No attendance records in that date range.',
                                        backgroundColor:
                                            const Color(0xFFF59E0B),
                                        icon: Icons.info_outline_rounded,
                                      );
                                      return;
                                    }

                                    _exportAttendancePdf(
                                      courseCode: courseCode,
                                      courseName: courseName,
                                      records: exportRecords,
                                      dateLabel:
                                          formatDateRangeLabel(picked.range),
                                    );
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryBlue,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.picture_as_pdf_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    'PDF',
                                    style: GoogleFonts.poppins(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),

                            // Date filter (same design as faculty Records)
                            InkWell(
                              onTap: () async {
                                final DateRangeResult? picked =
                                    await showDateRangeCalendar(
                                  context,
                                  initialRange: dateFilter,
                                );
                                if (picked == null) return;
                                setModalState(() {
                                  dateFilter = picked.range;
                                  historyPage = 1;
                                });
                              },
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF4F6F9),
                                  borderRadius: BorderRadius.circular(10),
                                  border: dateFilter != null
                                      ? Border.all(
                                          color: AppColors.primaryBlue,
                                        )
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.calendar_month_rounded,
                                      size: 16,
                                      color: AppColors.primaryBlue,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        dateFilter == null
                                            ? 'Filter by date'
                                            : formatDateRangeLabel(dateFilter),
                                        style: GoogleFonts.poppins(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.primaryBlue,
                                        ),
                                      ),
                                    ),
                                    if (dateFilter != null) ...[
                                      Text(
                                        '${records.length} of ${allRecords.length}',
                                        style: GoogleFonts.poppins(
                                          fontSize: 10,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () {
                                          setModalState(() {
                                            dateFilter = null;
                                            historyPage = 1;
                                          });
                                        },
                                        child: const Icon(
                                          Icons.close,
                                          size: 16,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (records.isEmpty)
                              Expanded(
                                child: Center(
                                  child: Text(
                                    'No attendance records in this date range.',
                                    style: GoogleFonts.poppins(
                                      fontSize: 12,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Expanded(
                                child: ListView.separated(
                                  itemCount: paginatedRecords.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final rec = paginatedRecords[index];

                                    final session = rec['attendance_sessions']
                                        as Map<String, dynamic>?;

                                    final formattedDateTime = _formatDateTime(
                                      rec['scanned_at'],
                                      session?['date']?.toString(),
                                    );

                                    final status = rec['status']
                                            ?.toString()
                                            .toUpperCase() ??
                                        'PRESENT';

                                    final isPresent = status == 'PRESENT';
                                    final isLate = status == 'LATE';

                                    final category = rec['reason_category'];
                                    final remarks = rec['remarks'];

                                    final isAbsent = status == 'ABSENT';
                                    final isExcused = status == 'EXCUSED';

                                    // Colors per status: present = green,
                                    // late = orange, excused = purple,
                                    // absent = red
                                    final IconData statusIcon = isPresent
                                        ? Icons.check_circle
                                        : isLate
                                            ? Icons.access_time_filled
                                            : isExcused
                                                ? Icons.verified_rounded
                                                : Icons.cancel;
                                    final Color statusIconColor = isPresent
                                        ? Colors.green
                                        : isLate
                                            ? Colors.orange
                                            : isExcused
                                                ? Colors.purple.shade400
                                                : Colors.redAccent;
                                    final Color statusBgColor = isPresent
                                        ? const Color(0xFFE8F5E9)
                                        : isLate
                                            ? const Color(0xFFFFF3E0)
                                            : isExcused
                                                ? const Color(0xFFF3E5F5)
                                                : const Color(0xFFFFEBEE);
                                    final Color statusTextColor = isPresent
                                        ? Colors.green.shade700
                                        : isLate
                                            ? Colors.orange.shade800
                                            : isExcused
                                                ? Colors.purple.shade700
                                                : Colors.red.shade700;

                                    return Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF8FAFC),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.grey.shade200,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      statusIcon,
                                                      color: statusIconColor,
                                                      size: 18,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Flexible(
                                                      child: Text(
                                                        formattedDateTime,
                                                        style:
                                                            GoogleFonts.poppins(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          color: Colors.black87,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: statusBgColor,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Text(
                                                  status,
                                                  style: GoogleFonts.poppins(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: statusTextColor,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (category != null ||
                                              remarks != null) ...[
                                            const SizedBox(height: 6),
                                            Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: Colors.grey.shade200,
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if (category != null)
                                                    Text(
                                                      'Reason: $category',
                                                      style:
                                                          GoogleFonts.poppins(
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: AppColors
                                                            .primaryBlue,
                                                      ),
                                                    ),
                                                  if (remarks != null &&
                                                      remarks
                                                          .toString()
                                                          .isNotEmpty)
                                                    Text(
                                                      'Note: $remarks',
                                                      style:
                                                          GoogleFonts.poppins(
                                                        fontSize: 11,
                                                        color: Colors
                                                            .grey.shade700,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                          if ((!isPresent &&
                                                  !isLate &&
                                                  !isExcused) ||
                                              isAbsent) ...[
                                            const SizedBox(height: 6),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: TextButton.icon(
                                                onPressed: () =>
                                                    _showSubmitExcuseDialog(
                                                  Map<String, dynamic>.from(
                                                      rec),
                                                  classId,
                                                  () {
                                                    setModalState(() {
                                                      refreshKey++;
                                                    });
                                                  },
                                                ),
                                                icon: const Icon(
                                                  Icons.edit_note_rounded,
                                                  size: 14,
                                                ),
                                                label: Text(
                                                  category == null &&
                                                          (remarks == null ||
                                                              remarks
                                                                  .toString()
                                                                  .isEmpty)
                                                      ? 'Add Reason'
                                                      : 'Edit Excuse',
                                                  style: GoogleFonts.poppins(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            if (totalHistoryPages > 1)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.chevron_left_rounded,
                                      ),
                                      color: AppColors.primaryBlue,
                                      onPressed: historyPage > 1
                                          ? () {
                                              setModalState(() {
                                                historyPage--;
                                              });
                                            }
                                          : null,
                                    ),
                                    Text(
                                      'Page $historyPage of $totalHistoryPages',
                                      style: GoogleFonts.poppins(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.chevron_right_rounded,
                                      ),
                                      color: AppColors.primaryBlue,
                                      onPressed: historyPage < totalHistoryPages
                                          ? () {
                                              setModalState(() {
                                                historyPage++;
                                              });
                                            }
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
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

  // STATUS COLORS

  Map<String, Color> _getStatusColors(String status) {
    switch (status.toLowerCase()) {
      case 'present':
        return {
          'text': Colors.green.shade700,
          'bg': const Color(0xFFE8F5E9),
        };

      case 'late':
        return {
          'text': Colors.orange.shade800,
          'bg': const Color(0xFFFFF3E0),
        };

      case 'absent':
        return {
          'text': Colors.red.shade700,
          'bg': const Color(0xFFFFEBEE),
        };

      case 'excused':
        return {
          'text': Colors.purple.shade700,
          'bg': const Color(0xFFF3E5F5),
        };

      case 'upcoming':
      default:
        return {
          'text': Colors.blue.shade700,
          'bg': const Color(0xFFE3F2FD),
        };
    }
  }

  // MAIN BUILD

  @override
  Widget build(BuildContext context) {
    final displayedList = _paginatedClasses;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _fetchStudentClasses,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 100,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ENTER CLASS BANNER

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primaryBlue,
                        AppColors.primaryBlue.withBlue(180),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryBlue.withValues(alpha: 0.25),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ready for your session?',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                            Text(
                              'Enter a Class',
                              style: GoogleFonts.poppins(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ElevatedButton.icon(
                              onPressed: () => widget.onTabSelected?.call(2),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppColors.primaryBlue,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                              ),
                              icon: const Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 18,
                              ),
                              label: Text(
                                'Scan or Show Badge',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.meeting_room_outlined,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ENROLLED CLASSES HEADER

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'MY ENROLLED CLASSES',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    Container(
                      height: 32,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          _buildTabButton(
                            'Active',
                            !_showArchived,
                            () {
                              setState(() {
                                _showArchived = false;
                                _currentPage = 1;
                              });
                            },
                          ),
                          _buildTabButton(
                            'Archived',
                            _showArchived,
                            () {
                              setState(() {
                                _showArchived = true;
                                _currentPage = 1;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // LOADING / EMPTY / CLASS LIST

                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  )
                else if (displayedList.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        _showArchived
                            ? 'No archived classes found.'
                            : 'You are not enrolled in any active classes yet.',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  )
                else
                  Column(
                    children: [
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: displayedList.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = displayedList[index];

                          final status = item['computed_status'] ?? 'Upcoming';

                          final colors = _getStatusColors(status);

                          final classId = item['id']?.toString() ?? '';

                          final code = item['course_code']?.toString() ?? '';

                          final title = item['course_name']?.toString() ?? '';

                          return InkWell(
                            onTap: () => _showAttendanceHistoryModal(
                              context,
                              classId,
                              code,
                              title,
                            ),
                            borderRadius: BorderRadius.circular(16),
                            child: _buildCompactClassCard(
                              code: code,
                              title: title,
                              details:
                                  '${item['schedule'] ?? 'No schedule'} • Section ${item['section'] ?? 'N/A'}',
                              status: status.toString(),
                              statusColor: colors['text']!,
                              statusBg: colors['bg']!,
                              absentCount: (item['absent_count'] as int?) ?? 0,
                              needsReasonCount:
                                  (item['needs_reason_count'] as int?) ?? 0,
                            ),
                          );
                        },
                      ),

                      // CLASS PAGINATION

                      if (_filteredClasses.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                              ),
                              color: AppColors.primaryBlue,
                              onPressed: _currentPage > 1
                                  ? () {
                                      setState(() {
                                        _currentPage--;
                                      });
                                    }
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
                              icon: const Icon(
                                Icons.chevron_right_rounded,
                              ),
                              color: AppColors.primaryBlue,
                              onPressed: _currentPage < _totalPages
                                  ? () {
                                      setState(() {
                                        _currentPage++;
                                      });
                                    }
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ACTIVE / ARCHIVED TAB BUTTON

  Widget _buildTabButton(
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                  ),
                ]
              : [],
        ),
        child: Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? AppColors.primaryBlue : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // CLASS CARD

  Widget _buildCompactClassCard({
    required String code,
    required String title,
    required String details,
    required String status,
    required Color statusColor,
    required Color statusBg,
    int absentCount = 0,
    int needsReasonCount = 0,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: AppColors.primaryBlue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              code,
              style: GoogleFonts.poppins(
                fontSize: 13,
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
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),

                // Absence summary: tap the card to open the history and
                // add a reason
                if (absentCount > 0) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$absentCount Absent',
                          style: GoogleFonts.poppins(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.red.shade700,
                          ),
                        ),
                      ),
                      if (needsReasonCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8E1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFFFE082),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.edit_note_rounded,
                                size: 12,
                                color: Colors.orange.shade800,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '$needsReasonCount need a reason',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: statusBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
