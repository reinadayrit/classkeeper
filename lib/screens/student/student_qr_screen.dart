import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../constants/app_colors.dart';
import '../../services/location_service.dart';
import '../../widgets/date_range_calendar.dart';

class StudentQrScreen extends StatefulWidget {
  const StudentQrScreen({super.key});

  @override
  State<StudentQrScreen> createState() => _StudentQrScreenState();
}

class _StudentQrScreenState extends State<StudentQrScreen> {
  int _selectedTab = 0;

  bool _isFlashOn = false;
  bool _isProcessingScan = false;

  String? _lastScannedCode;

  late final MobileScannerController _scannerController;

  late Future<List<Map<String, dynamic>>> _historyFuture;

  // History filters + pagination
  String? _filterClassId;
  String _filterStatus = 'all';
  DateTimeRange? _filterDateRange; // same calendar as the faculty screen
  int _historyPage = 0;
  static const int _historyPageSize = 5;

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void initState() {
    super.initState();

    _scannerController = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.noDuplicates,
    );

    _historyFuture = _fetchAttendanceHistory();
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------
  // CUSTOM SNACKBAR
  // ---------------------------------------------------------

  void _showCustomSnackBar({
    required String message,
    required Color backgroundColor,
    required IconData icon,
  }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        backgroundColor: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        margin: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 22),
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

  // ---------------------------------------------------------
  // FETCH STUDENT PROFILE
  // ---------------------------------------------------------

  Future<Map<String, dynamic>> _fetchLoggedInStudentProfile() async {
    final user = _supabase.auth.currentUser;

    if (user == null) {
      throw Exception('No user currently logged in.');
    }

    final response = await _supabase
        .from('profiles')
        .select('full_name, school_id, email')
        .eq('id', user.id)
        .single()
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Connection timed out while loading profile.',
          ),
        );

    return {
      'name': response['full_name'] ?? 'Unknown Student',
      'studentId': response['school_id'] ?? 'N/A',
      'email': response['email'] ?? user.email ?? 'N/A',
    };
  }

  // ---------------------------------------------------------
  // ATTENDANCE HISTORY (DATA)
  // ---------------------------------------------------------

  Future<List<Map<String, dynamic>>> _fetchAttendanceHistory() async {
    final user = _supabase.auth.currentUser;

    if (user == null) {
      throw Exception('No user currently logged in.');
    }

    final response = await _supabase
        .from('attendance_records')
        .select(
          'id, status, scanned_at, remarks, reason_category, distance_meters, '
          'attendance_sessions(date, class_id, '
          'classes(id, course_code, course_name, section))',
        )
        .eq('student_id', user.id)
        .order('scanned_at', ascending: false)
        .limit(500)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Connection timed out while loading history.',
          ),
        );

    return List<Map<String, dynamic>>.from(response);
  }

  void _refreshHistory() {
    if (!mounted) return;

    setState(() {
      _historyFuture = _fetchAttendanceHistory();
    });
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);

    if (value is List && value.isNotEmpty && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }

    return null;
  }

  Map<String, dynamic>? _classOf(Map<String, dynamic> record) {
    final session = _asMap(record['attendance_sessions']);
    return _asMap(session?['classes']);
  }

  String? _classIdOf(Map<String, dynamic> record) {
    final session = _asMap(record['attendance_sessions']);
    final classData = _classOf(record);

    return (classData?['id'] ?? session?['class_id'])?.toString();
  }

  String _formatHistoryDateTime(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();

    if (dt == null) return '--';

    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';

    return '${_formatDateOnly(dt)} • $hour12:$minute $period';
  }

  String _formatDateOnly(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');

    return '${dt.year}-$m-$d';
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'present':
        return const Color(0xFF41A564);
      case 'late':
        return Colors.orange.shade800;
      case 'excused':
        return Colors.blue.shade600;
      case 'absent':
        return const Color(0xFFE53935);
      default:
        return Colors.grey.shade600;
    }
  }

  String _capitalize(String v) =>
      v.isEmpty ? v : v[0].toUpperCase() + v.substring(1).toLowerCase();

  List<Map<String, dynamic>> _applyHistoryFilters(
    List<Map<String, dynamic>> records,
  ) {
    return records.where((r) {
      if (_filterClassId != null && _classIdOf(r) != _filterClassId) {
        return false;
      }

      if (_filterStatus != 'all' &&
          (r['status']?.toString().toLowerCase() ?? '') != _filterStatus) {
        return false;
      }

      if (_filterDateRange != null) {
        final dt =
            DateTime.tryParse(r['scanned_at']?.toString() ?? '')?.toLocal();

        if (dt == null) return false;

        final day = DateTime(dt.year, dt.month, dt.day);
        final from = DateTime(
          _filterDateRange!.start.year,
          _filterDateRange!.start.month,
          _filterDateRange!.start.day,
        );
        final to = DateTime(
          _filterDateRange!.end.year,
          _filterDateRange!.end.month,
          _filterDateRange!.end.day,
        );

        if (day.isBefore(from) || day.isAfter(to)) return false;
      }

      return true;
    }).toList();
  }

  Future<void> _pickFilterDate() async {
    final DateRangeResult? result = await showDateRangeCalendar(
      context,
      initialRange: _filterDateRange,
    );

    // null = the sheet was closed without applying
    if (result == null || !mounted) return;

    setState(() {
      _filterDateRange = result.range; // null = all dates
      _historyPage = 0;
    });
  }

  // ---------------------------------------------------------
  // EXTRACT QR TOKEN
  // ---------------------------------------------------------

  String _extractToken(String rawCode) {
    String token = rawCode.trim();

    if (token.isEmpty) {
      throw Exception('QR code is empty.');
    }

    try {
      final parsed = jsonDecode(token);

      if (parsed is Map) {
        if (parsed['qr_token'] != null) {
          token = parsed['qr_token'].toString();
        } else if (parsed['session_id'] != null) {
          token = parsed['session_id'].toString();
        } else if (parsed['join_code'] != null) {
          token = parsed['join_code'].toString();
        }
      }
    } catch (_) {
      // QR content is plain text.
    }

    token = token.trim();

    if (token.startsWith('SESSION_CODE_')) {
      token = token.replaceFirst('SESSION_CODE_', '');
    }

    if (token.isEmpty) {
      throw Exception('Invalid QR code.');
    }

    return token;
  }

  // ---------------------------------------------------------
  // MAIN QR SCAN HANDLER
  // ---------------------------------------------------------

  Future<void> _onQrDetected(String rawCode) async {
    if (_isProcessingScan) return;

    final cleanCode = rawCode.trim();

    if (cleanCode.isEmpty) return;

    if (!mounted) return;

    setState(() {
      _isProcessingScan = true;
      _lastScannedCode = cleanCode;
    });

    try {
      final user = _supabase.auth.currentUser;

      if (user == null) {
        throw Exception('No user currently logged in.');
      }

      final token = _extractToken(cleanCode);

      // 1. CHECK IF THIS IS A CLASS JOIN CODE.

      final classMatch = await _supabase
          .from('classes')
          .select('id, course_code, course_name, section, join_code')
          .ilike('join_code', token)
          .maybeSingle()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Connection timeout while validating join code.',
            ),
          );

      if (classMatch != null) {
        await _handleClassEnrollment(
          classMatch: classMatch,
          studentId: user.id,
        );
        return;
      }

      // 2. VALIDATE ATTENDANCE SESSION.

      final isUuid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(token);

      final query = _supabase.from('attendance_sessions').select(
            'id, is_ended, expires_at, created_at, '
            'late_limit_minutes, class_id, '
            'latitude, longitude, radius_meters, '
            'classes(course_code, course_name, latitude, longitude, radius_meters)',
          );

      final session = isUuid
          ? await query.eq('id', token).maybeSingle().timeout(
                const Duration(seconds: 10),
                onTimeout: () => throw TimeoutException(
                  'Connection timeout while validating session.',
                ),
              )
          : await query.eq('qr_token', token).maybeSingle().timeout(
                const Duration(seconds: 10),
                onTimeout: () => throw TimeoutException(
                  'Connection timeout while validating session.',
                ),
              );

      if (session == null) {
        throw Exception(
          'Invalid or unrecognized class code or QR token.',
        );
      }

      // 3. CHECK IF SESSION HAS ENDED.

      if (session['is_ended'] == true) {
        throw Exception(
          'This attendance session has already ended.',
        );
      }

      final String sessionId = session['id'].toString();
      final String classId = session['class_id'].toString();

      // 4. CHECK SESSION EXPIRATION.

      final expiresAtStr = session['expires_at']?.toString();

      if (expiresAtStr != null) {
        final expiresAt = DateTime.parse(expiresAtStr).toLocal();

        if (DateTime.now().isAfter(expiresAt)) {
          throw Exception(
            'This attendance session has already expired.',
          );
        }
      }

      // 5. PARSE NESTED CLASS DATA.

      Map<String, dynamic>? classData;

      if (session['classes'] is Map) {
        classData = Map<String, dynamic>.from(
          session['classes'],
        );
      } else if (session['classes'] is List &&
          (session['classes'] as List).isNotEmpty) {
        classData = Map<String, dynamic>.from(
          session['classes'][0],
        );
      }

      if (classData == null) {
        throw Exception(
          'Unable to retrieve class information.',
        );
      }

      // 6. VERIFY CLASS ENROLLMENT BEFORE LOCATION CHECK.

      final enrollment = await _supabase
          .from('class_enrollments')
          .select('id')
          .eq('class_id', classId)
          .eq('student_id', user.id)
          .maybeSingle()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Connection timeout while checking enrollment.',
            ),
          );

      if (enrollment == null) {
        final courseName = classData['course_name']?.toString() ?? 'this class';

        throw Exception(
          'Access Denied: You are not enrolled in $courseName.',
        );
      }

      // 7. GEOLOCATION VERIFICATION.

      // The session geofence (if the teacher overrode it) wins; otherwise the
      // class geofence is used.
      final dynamic latSource = session['latitude'] ?? classData['latitude'];
      final dynamic lngSource = session['longitude'] ?? classData['longitude'];
      final dynamic radiusSource =
          session['radius_meters'] ?? classData['radius_meters'];

      final double? classLat =
          latSource != null ? (latSource as num).toDouble() : null;

      final double? classLng =
          lngSource != null ? (lngSource as num).toDouble() : null;

      final double allowedRadius =
          radiusSource != null ? (radiusSource as num).toDouble() : 0.0;

      if (classLat == null || classLng == null) {
        throw Exception(
          'Location Verification Failed: Classroom coordinates are not configured.',
        );
      }

      if (allowedRadius <= 0) {
        throw Exception(
          'Location Verification Failed: Classroom radius is not configured.',
        );
      }

      final Position studentPos = await LocationService.getCurrentPosition();

      final double distance = LocationService.calculateDistanceMeters(
        startLatitude: studentPos.latitude,
        startLongitude: studentPos.longitude,
        endLatitude: classLat,
        endLongitude: classLng,
      );

      if (distance > allowedRadius) {
        throw Exception(
          'Invalid Location: You are ${distance.round()}m away from the classroom. '
          'Allowed distance: ${allowedRadius.round()}m.',
        );
      }

      // 8. CHECK EXISTING ATTENDANCE RECORD.

      final existingRecord = await _supabase
          .from('attendance_records')
          .select('id')
          .eq('session_id', sessionId)
          .eq('student_id', user.id)
          .maybeSingle()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Connection timeout while checking attendance status.',
            ),
          );

      if (existingRecord != null) {
        _showCustomSnackBar(
          message: 'You have already recorded attendance for this session.',
          backgroundColor: Colors.orange.shade800,
          icon: Icons.info_outline_rounded,
        );
        return;
      }

      // 9. DETERMINE ATTENDANCE STATUS.

      final DateTime now = DateTime.now();

      final String? createdAtStr = session['created_at']?.toString();

      final int lateLimitMinutes = session['late_limit_minutes'] != null
          ? int.tryParse(
                session['late_limit_minutes'].toString(),
              ) ??
              15
          : 15;

      String calculatedStatus = 'present';

      if (createdAtStr != null) {
        final DateTime sessionStartTime =
            DateTime.parse(createdAtStr).toLocal();

        final DateTime lateThreshold = sessionStartTime.add(
          Duration(minutes: lateLimitMinutes),
        );

        if (now.isAfter(lateThreshold)) {
          calculatedStatus = 'late';
        }
      }

      // 10. INSERT ATTENDANCE RECORD.

      await _supabase.from('attendance_records').insert({
        'session_id': sessionId,
        'student_id': user.id,
        'status': calculatedStatus,
        'scanned_at': now.toIso8601String(),
      }).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'Connection timeout while recording check-in.',
        ),
      );

      _refreshHistory();

      final bool isLate = calculatedStatus == 'late';

      _showCustomSnackBar(
        message: isLate
            ? 'Attendance recorded: Marked as LATE.'
            : 'Attendance recorded successfully!',
        backgroundColor:
            isLate ? Colors.orange.shade800 : const Color(0xFF41A564),
        icon: isLate
            ? Icons.access_time_rounded
            : Icons.check_circle_outline_rounded,
      );
    } on TimeoutException {
      _showRetrySnackBar(
        'Weak connection. Request timed out.',
      );
    } catch (e) {
      if (_isNetworkError(e)) {
        _showRetrySnackBar(
          'Network error occurred. Check your connection.',
        );
      } else {
        _showCustomSnackBar(
          message: e.toString().replaceAll('Exception: ', ''),
          backgroundColor: const Color(0xFFE53935),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingScan = false;
        });
      }
    }
  }

  // ---------------------------------------------------------
  // CLASS ENROLLMENT HANDLER
  // ---------------------------------------------------------

  Future<void> _handleClassEnrollment({
    required Map<String, dynamic> classMatch,
    required String studentId,
  }) async {
    final String classId = classMatch['id'].toString();

    final String courseName =
        classMatch['course_name']?.toString() ?? 'this class';

    final existingEnrollment = await _supabase
        .from('class_enrollments')
        .select('id')
        .eq('class_id', classId)
        .eq('student_id', studentId)
        .maybeSingle()
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Connection timeout while checking enrollment.',
          ),
        );

    if (existingEnrollment != null) {
      _showCustomSnackBar(
        message: 'You are already enrolled in $courseName.',
        backgroundColor: Colors.orange.shade800,
        icon: Icons.warning_amber_rounded,
      );
      return;
    }

    await _supabase.from('class_enrollments').insert({
      'class_id': classId,
      'student_id': studentId,
    }).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException(
        'Connection timeout while enrolling.',
      ),
    );

    _showCustomSnackBar(
      message: 'Enrolled in $courseName successfully!',
      backgroundColor: const Color(0xFF41A564),
      icon: Icons.check_circle_outline_rounded,
    );
  }

  // ---------------------------------------------------------
  // NETWORK ERROR CHECK
  // ---------------------------------------------------------

  bool _isNetworkError(dynamic error) {
    final errStr = error.toString().toLowerCase();

    return errStr.contains('socketexception') ||
        errStr.contains('clientexception') ||
        errStr.contains('failed host lookup') ||
        errStr.contains('network') ||
        errStr.contains('connection');
  }

  // ---------------------------------------------------------
  // RETRY SNACKBAR
  // ---------------------------------------------------------

  void _showRetrySnackBar(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        margin: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.amber.shade900,
        content: Row(
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'RETRY',
          textColor: Colors.white,
          onPressed: () {
            if (_lastScannedCode != null) {
              _onQrDetected(_lastScannedCode!);
            }
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------
  // MANUAL CODE ENTRY
  // ---------------------------------------------------------

  void _showManualEntryDialog() {
    final TextEditingController codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          backgroundColor: Colors.white,
          child: Container(
            padding: const EdgeInsets.all(22),
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter Class Join Code',
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: AppColors.primaryBlue,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Enter the class join code provided by your teacher to enroll in a class. Attendance requires scanning a Faculty QR.',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: codeController,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                    letterSpacing: 2.0,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: Color(0xFFE2E8F0),
                        width: 1,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: AppColors.primaryBlue,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                      },
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.poppins(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryBlue,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        final code = codeController.text.trim();

                        if (code.isNotEmpty) {
                          Navigator.pop(dialogContext);
                          _onQrDetected(code);
                        }
                      },
                      child: Text(
                        'Submit',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      // The dialog is still animating closed at this point, so wait before
      // disposing the controller (disposing too early crashes the screen).
      Future.delayed(const Duration(milliseconds: 600), codeController.dispose);
    });
  }

  // ---------------------------------------------------------
  // BUILD UI
  // ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 16,
      ),
      child: Column(
        children: [
          // TAB SELECTOR

          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedTab = 0);
                    },
                    child: _buildTab(
                      title: 'Scan Faculty QR',
                      isSelected: _selectedTab == 0,
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedTab = 1);
                    },
                    child: _buildTab(
                      title: 'My Badge QR',
                      isSelected: _selectedTab == 1,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          if (_selectedTab == 0) ...[
            _buildScanner(),
            const SizedBox(height: 28),
            _buildHistorySection(),
          ],

          if (_selectedTab == 1) ...[
            _buildStudentBadge(),
          ],

          const SizedBox(height: 100),
        ],
      ),
    );
  }

  // ---------------------------------------------------------
  // TAB WIDGET
  // ---------------------------------------------------------

  Widget _buildTab({
    required String title,
    required bool isSelected,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: isSelected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : [],
      ),
      child: Center(
        child: Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? AppColors.primaryBlue : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------
  // SCANNER WIDGET
  // ---------------------------------------------------------

  Widget _buildScanner() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          height: 320,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 15,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: (capture) {
                    if (_isProcessingScan) return;

                    for (final barcode in capture.barcodes) {
                      final value = barcode.rawValue;

                      if (value != null && value.trim().isNotEmpty) {
                        _onQrDetected(value);
                        break;
                      }
                    }
                  },
                ),
                Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.primaryBlue,
                      width: 2.5,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                if (_isProcessingScan)
                  Container(
                    color: Colors.black.withValues(alpha: 0.7),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Verifying code & processing...\nPlease wait',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: Row(
                    children: [
                      IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.4),
                        ),
                        onPressed: () async {
                          await _scannerController.toggleTorch();

                          if (mounted) {
                            setState(() {
                              _isFlashOn = !_isFlashOn;
                            });
                          }
                        },
                        icon: Icon(
                          _isFlashOn ? Icons.flash_on : Icons.flash_off,
                          color: _isFlashOn ? Colors.amber : Colors.white70,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.4),
                        ),
                        onPressed: () async {
                          await _scannerController.switchCamera();
                        },
                        icon: const Icon(
                          Icons.cameraswitch,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Align QR Code within the frame',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: BorderSide(
              color: AppColors.primaryBlue.withValues(alpha: 0.4),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _isProcessingScan ? null : _showManualEntryDialog,
          icon: const Icon(
            Icons.keyboard_outlined,
            color: AppColors.primaryBlue,
            size: 18,
          ),
          label: Text(
            'Enter Class Code Manually',
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryBlue,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------
  // STUDENT BADGE WIDGET
  // ---------------------------------------------------------

  Widget _buildStudentBadge() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _fetchLoggedInStudentProfile(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: CircularProgressIndicator(
              color: AppColors.primaryBlue,
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Error loading profile data',
                  style: GoogleFonts.poppins(
                    color: Colors.red,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () {
                    setState(() {});
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        final studentProfile = snapshot.data!;

        final name = studentProfile['name']?.toString() ?? 'Unknown Student';

        final studentId = studentProfile['studentId']?.toString() ?? 'N/A';

        final email = studentProfile['email']?.toString() ?? 'N/A';

        final qrPayload = jsonEncode({
          'studentId': studentId,
          'name': name,
          'email': email,
        });

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.grey.shade200,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 15,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              Text(
                name,
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'ID: $studentId',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                email,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.grey.shade200,
                  ),
                ),
                child: Column(
                  children: [
                    QrImageView(
                      data: qrPayload,
                      version: QrVersions.auto,
                      size: 180,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: AppColors.primaryBlue,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Show this QR to your instructor',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------
  // ATTENDANCE HISTORY (UI)
  // ---------------------------------------------------------

  Widget _buildHistorySection() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final all = snapshot.data ?? <Map<String, dynamic>>[];
        final filtered = _applyHistoryFilters(all);

        final totalPages =
            (filtered.length / _historyPageSize).ceil().clamp(1, 9999).toInt();
        final int page = _historyPage.clamp(0, totalPages - 1).toInt();
        final start = page * _historyPageSize;
        final int end =
            (start + _historyPageSize).clamp(0, filtered.length).toInt();
        final pageItems = filtered.sublist(start, end);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // HEADER
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'ATTENDANCE HISTORY',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
                  Text(
                    '${filtered.length} ${filtered.length == 1 ? 'Record' : 'Records'}',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: _refreshHistory,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // FILTERS
            _buildHistoryFilters(all),
            const SizedBox(height: 12),

            // BODY
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primaryBlue,
                  ),
                ),
              )
            else if (snapshot.hasError)
              _buildHistoryMessage(
                icon: Icons.wifi_off_rounded,
                message: 'Could not load attendance history.',
                actionLabel: 'Retry',
                onAction: _refreshHistory,
              )
            else if (filtered.isEmpty)
              _buildHistoryMessage(
                icon: Icons.history_rounded,
                message: all.isEmpty
                    ? 'No attendance records yet.'
                    : 'No records match your filters.',
              )
            else ...[
              ...pageItems.map(_buildHistoryCard),
              if (totalPages > 1)
                _buildPagination(
                  page: page,
                  totalPages: totalPages,
                  total: filtered.length,
                  from: start + 1,
                  to: end,
                ),
            ],
          ],
        );
      },
    );
  }

  // ---------------- FILTERS ----------------

  Widget _buildHistoryFilters(List<Map<String, dynamic>> all) {
    // Unique classes from the student's own records.
    final Map<String, String> classOptions = {};

    for (final r in all) {
      final id = _classIdOf(r);
      final c = _classOf(r);

      if (id != null && c != null) {
        final code = c['course_code']?.toString() ?? '';
        final section = c['section']?.toString() ?? '';
        classOptions[id] = section.isNotEmpty ? '$code ($section)' : code;
      }
    }

    // Reset a stale class filter (e.g. after refresh).
    final String? classValue =
        classOptions.containsKey(_filterClassId) ? _filterClassId : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildDropdownShell(
                  child: DropdownButton<String?>(
                    value: classValue,
                    isExpanded: true,
                    style: _filterTextStyle(),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: AppColors.primaryBlue,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All Classes'),
                      ),
                      ...classOptions.entries.map(
                        (e) => DropdownMenuItem<String?>(
                          value: e.key,
                          child: Text(
                            e.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _filterClassId = v;
                        _historyPage = 0;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildDropdownShell(
                child: DropdownButton<String>(
                  value: _filterStatus,
                  style: _filterTextStyle(),
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: AppColors.primaryBlue,
                  ),
                  items: const [
                    'all',
                    'present',
                    'late',
                    'absent',
                    'excused',
                  ]
                      .map(
                        (v) => DropdownMenuItem<String>(
                          value: v,
                          child: Text(
                            v == 'all' ? 'All Status' : _capitalize(v),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _filterStatus = v ?? 'all';
                      _historyPage = 0;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickFilterDate,
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
                border: _filterDateRange != null
                    ? Border.all(color: AppColors.primaryBlue)
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
                      formatDateRangeLabel(_filterDateRange),
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  ),
                  if (_filterDateRange != null)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _filterDateRange = null;
                          _historyPage = 0;
                        });
                      },
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.grey,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _filterTextStyle() => GoogleFonts.poppins(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppColors.primaryBlue,
      );

  Widget _buildDropdownShell({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: DropdownButtonHideUnderline(child: child),
    );
  }

  // ---------------- CARD ----------------

  Widget _buildHistoryCard(Map<String, dynamic> record) {
    final classData = _classOf(record);

    final courseCode = classData?['course_code']?.toString() ?? '';
    final courseName = classData?['course_name']?.toString() ?? 'Class';
    final section = classData?['section']?.toString() ?? '';
    final status = record['status']?.toString() ?? 'unknown';
    final remarks = record['remarks']?.toString().trim() ?? '';
    final reason = record['reason_category']?.toString().trim() ?? '';
    final distance = record['distance_meters'] is num
        ? (record['distance_meters'] as num).round()
        : null;
    final color = _statusColor(status);

    final hasFooter =
        distance != null || reason.isNotEmpty || remarks.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if (courseCode.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryBlue,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        courseCode,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (section.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      'Sec $section',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _capitalize(status),
                      style: GoogleFonts.poppins(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            courseName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(
                Icons.access_time_rounded,
                size: 12,
                color: Colors.grey,
              ),
              const SizedBox(width: 4),
              Text(
                _formatHistoryDateTime(record['scanned_at']?.toString()),
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
          if (hasFooter) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (distance != null)
                  _buildInfoPill(
                    '${distance}m from room',
                    const Color(0xFF475569),
                    icon: Icons.location_on_outlined,
                  ),
                if (reason.isNotEmpty)
                  _buildInfoPill(reason, Colors.blue.shade600),
                if (remarks.isNotEmpty)
                  Text(
                    remarks,
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey.shade600,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoPill(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryMessage({
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: Colors.grey.shade500,
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }

  // ---------------- PAGINATION ----------------

  Widget _buildPagination({
    required int page,
    required int totalPages,
    required int total,
    required int from,
    required int to,
  }) {
    int windowStart = (page - 2).clamp(0, totalPages).toInt();
    int windowEnd = (windowStart + 5).clamp(0, totalPages).toInt();
    windowStart = (windowEnd - 5).clamp(0, totalPages).toInt();

    Widget pageButton({
      required Widget child,
      required VoidCallback? onTap,
      bool active = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? AppColors.primaryBlue : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? AppColors.primaryBlue : Colors.grey.shade300,
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          Text(
            'Showing $from–$to of $total',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              pageButton(
                onTap: page > 0
                    ? () => setState(() => _historyPage = page - 1)
                    : null,
                child: Icon(
                  Icons.chevron_left_rounded,
                  size: 20,
                  color:
                      page > 0 ? AppColors.primaryBlue : Colors.grey.shade400,
                ),
              ),
              for (int i = windowStart; i < windowEnd; i++)
                pageButton(
                  active: i == page,
                  onTap: () => setState(() => _historyPage = i),
                  child: Text(
                    '${i + 1}',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: i == page ? Colors.white : AppColors.primaryBlue,
                    ),
                  ),
                ),
              pageButton(
                onTap: page < totalPages - 1
                    ? () => setState(() => _historyPage = page + 1)
                    : null,
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: page < totalPages - 1
                      ? AppColors.primaryBlue
                      : Colors.grey.shade400,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
