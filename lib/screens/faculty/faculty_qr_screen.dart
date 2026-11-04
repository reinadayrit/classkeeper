import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../widgets/date_range_calendar.dart';
import '../../services/location_service.dart';

class FacultyQrScreen extends StatefulWidget {
  const FacultyQrScreen({super.key});

  @override
  State<FacultyQrScreen> createState() => _FacultyQrScreenState();
}

class _FacultyQrScreenState extends State<FacultyQrScreen> {
  final _supabase = Supabase.instance.client;
  RealtimeChannel? _realtimeChannel;

  List<Map<String, dynamic>> _myClasses = [];
  String? _selectedClassId;
  String? _activeSessionId;
  String? _qrToken;
  bool _isLoadingClasses = true;
  bool _isStartingSession = false;
  bool _isEndingSession = false;
  String? _reopeningSessionId; // only the clicked session shows a spinner

  // History & Filters State
  List<Map<String, dynamic>> _historySessions = [];
  bool _isLoadingHistory = false;
  String _filterClassId = 'all';
  String _filterStatus = 'all'; // 'all', 'active', 'ended'
  DateTimeRange? _filterDateRange; // same calendar as the Records screen

  // Session history pagination
  int _historyPage = 1;
  static const int _historyPerPage = 5;

  // Map Controls (Defaults to STI College Davao)
  final MapController _mapController = MapController();
  double _classLatitude = 7.0739;
  double _classLongitude = 125.6128;
  bool _hasCustomClassCoords = false;

  // Geofence override: OFF = session inherits the class location,
  // ON = this session only uses the teacher's current location.
  bool _overrideLocation = false;
  bool _isLocatingOverride = false;

  // Session Configurations
  double _selectedRadiusMeters = 50.0;
  int _selectedLateLimitMinutes = 15;

  final List<double> _defaultRadiusOptions = [
    30.0,
    50.0,
    75.0,
    100.0,
    150.0,
    200.0,
    500.0,
  ];
  final List<int> _defaultLateLimitOptions = [5, 10, 15, 20, 25, 30, 45, 60];

  @override
  void initState() {
    super.initState();
    _fetchFacultyClasses();
    _setupRealtimeListener();
  }

  // --- SUPABASE REALTIME LISTENER ENGINE ---
  void _setupRealtimeListener() {
    _realtimeChannel = _supabase
        .channel('public_faculty_qr_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_sessions',
          callback: (payload) {
            debugPrint(
              'Realtime change in attendance_sessions (${payload.eventType}). Refreshing UI...',
            );
            if (mounted) {
              _fetchFacultyClasses();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_records',
          callback: (payload) {
            debugPrint(
              'Realtime change in attendance_records (${payload.eventType}). Refreshing History...',
            );
            if (mounted) {
              _fetchSessionHistory();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'classes',
          callback: (payload) {
            debugPrint(
              'Realtime change in classes (${payload.eventType}). Refreshing class roster...',
            );
            if (mounted) {
              _fetchFacultyClasses();
            }
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _realtimeChannel?.unsubscribe();
    _mapController.dispose();
    super.dispose();
  }

  double _getZoomForRadius(double radius) {
    if (radius <= 30) return 18.5;
    if (radius <= 50) return 18.0;
    if (radius <= 75) return 17.5;
    if (radius <= 100) return 17.0;
    if (radius <= 200) return 16.0;
    return 15.0;
  }

  String _formatTimestamp(String? rawIsoString) {
    if (rawIsoString == null || rawIsoString.trim().isEmpty) return 'N/A';
    try {
      final DateTime dt = DateTime.parse(rawIsoString).toLocal();
      final String year = dt.year.toString();
      final String month = dt.month.toString().padLeft(2, '0');
      final String day = dt.day.toString().padLeft(2, '0');

      final int hourRaw = dt.hour;
      final String period = hourRaw >= 12 ? 'PM' : 'AM';
      final int hour12 = hourRaw % 12 == 0 ? 12 : hourRaw % 12;
      final String hour = hour12.toString().padLeft(2, '0');
      final String minute = dt.minute.toString().padLeft(2, '0');

      return '$year-$month-$day • $hour:$minute $period';
    } catch (_) {
      return rawIsoString;
    }
  }

  Future<void> _fetchFacultyClasses({String? preferSessionId}) async {
    if (!mounted) return;
    setState(() => _isLoadingClasses = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) setState(() => _isLoadingClasses = false);
        return;
      }

      final response = await _supabase
          .from('classes')
          .select(
            'id, course_code, course_name, section, latitude, longitude, radius_meters',
          )
          .eq('faculty_id', userId)
          .eq('is_archived', false)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('Class load timeout.'),
          );

      final List<Map<String, dynamic>> fetchedClasses =
          List<Map<String, dynamic>>.from(response);

      String? activeClassId;
      String? activeSessionId;
      String? activeQrToken;
      int activeLateLimit = 15;
      double activeRadius = 50.0;
      bool activeOverrideLocation = false;

      if (fetchedClasses.isNotEmpty) {
        final List<dynamic> classIds =
            fetchedClasses.map((c) => c['id']).toList();

        var activeQuery = _supabase
            .from('attendance_sessions')
            .select(
              'id, class_id, qr_token, late_limit_minutes, is_ended, latitude, longitude, radius_meters',
            )
            .inFilter('class_id', classIds)
            .eq('is_ended', false);

        if (preferSessionId != null) {
          activeQuery = activeQuery.eq('id', preferSessionId);
        }

        final activeSessionsRes =
            await activeQuery.order('created_at', ascending: false).limit(1);

        if ((activeSessionsRes as List).isNotEmpty) {
          final activeSession = activeSessionsRes.first;
          activeClassId = activeSession['class_id'].toString();
          activeSessionId = activeSession['id'].toString();
          activeQrToken = activeSession['qr_token'].toString();

          if (activeSession['late_limit_minutes'] != null) {
            activeLateLimit =
                int.tryParse(activeSession['late_limit_minutes'].toString()) ??
                    15;
          }

          final matchingClass = fetchedClasses.firstWhere(
            (c) => c['id'].toString() == activeClassId,
            orElse: () => {},
          );
          if (matchingClass.isNotEmpty) {
            if (matchingClass['radius_meters'] != null) {
              activeRadius = (matchingClass['radius_meters'] as num).toDouble();
            }
            if (matchingClass['latitude'] != null &&
                matchingClass['longitude'] != null) {
              _classLatitude = (matchingClass['latitude'] as num).toDouble();
              _classLongitude = (matchingClass['longitude'] as num).toDouble();
              _hasCustomClassCoords = true;
            }
          }

          // Values saved on the session override the class defaults
          if (activeSession['radius_meters'] != null) {
            activeRadius = (activeSession['radius_meters'] as num).toDouble();
          }
          if (activeSession['latitude'] != null &&
              activeSession['longitude'] != null) {
            _classLatitude = (activeSession['latitude'] as num).toDouble();
            _classLongitude = (activeSession['longitude'] as num).toDouble();
            _hasCustomClassCoords = true;
            activeOverrideLocation = true;
          }
        }
      }

      if (mounted) {
        setState(() {
          _myClasses = fetchedClasses;
          if (activeSessionId != null) {
            _selectedClassId = activeClassId;
            _activeSessionId = activeSessionId;
            _qrToken = activeQrToken;
            _selectedLateLimitMinutes = activeLateLimit;
            _selectedRadiusMeters = activeRadius;
            _overrideLocation = activeOverrideLocation;
          }
        });
      }

      _fetchSessionHistory();
    } catch (e) {
      if (mounted) {
        _showNotification('Error loading classes: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoadingClasses = false);
    }
  }

  Future<void> _fetchSessionHistory() async {
    if (!mounted) return;
    setState(() => _isLoadingHistory = true);

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) setState(() => _isLoadingHistory = false);
        return;
      }

      final List<dynamic> classIds = _myClasses.map((c) => c['id']).toList();
      if (classIds.isEmpty) {
        if (mounted) {
          setState(() {
            _historySessions = [];
            _isLoadingHistory = false;
          });
        }
        return;
      }

      var query = _supabase
          .from('attendance_sessions')
          .select(
            'id, class_id, qr_token, date, created_at, expires_at, ended_at, late_limit_minutes, is_ended, classes(course_code, course_name, section), attendance_records(id, status)',
          )
          .inFilter('class_id', classIds);

      if (_filterClassId != 'all') {
        query = query.eq('class_id', _filterClassId);
      }

      if (_filterStatus == 'active') {
        query = query.eq('is_ended', false);
      } else if (_filterStatus == 'ended') {
        query = query.eq('is_ended', true);
      }

      if (_filterDateRange != null) {
        final startStr =
            _filterDateRange!.start.toIso8601String().split('T')[0];
        final endStr = _filterDateRange!.end.toIso8601String().split('T')[0];
        query = query.gte('date', startStr).lte('date', endStr);
      }

      final response = await query.order('created_at', ascending: false);
      final List<Map<String, dynamic>> sessions =
          List<Map<String, dynamic>>.from(response);

      if (mounted) {
        setState(() {
          _historySessions = sessions;
        });
      }
    } catch (e) {
      debugPrint('Error fetching session history: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  // --- GEOFENCE HELPERS (class default vs. per-session override) ---
  Map<String, dynamic>? _selectedClassMap() {
    if (_selectedClassId == null) return null;
    for (final c in _myClasses) {
      if (c['id'].toString() == _selectedClassId) return c;
    }
    return null;
  }

  /// Puts the map location back to the class location (no override).
  void _resetLocationToClass() {
    final cls = _selectedClassMap();
    _overrideLocation = false;
    if (cls != null && cls['latitude'] != null && cls['longitude'] != null) {
      _classLatitude = (cls['latitude'] as num).toDouble();
      _classLongitude = (cls['longitude'] as num).toDouble();
      _hasCustomClassCoords = true;
    } else {
      _classLatitude = 7.0739;
      _classLongitude = 125.6128;
      _hasCustomClassCoords = false;
    }
  }

  /// Puts location AND radius back to the class defaults.
  void _resetGeofenceToClass() {
    _resetLocationToClass();
    final cls = _selectedClassMap();
    if (cls != null && cls['radius_meters'] != null) {
      _selectedRadiusMeters = (cls['radius_meters'] as num).toDouble();
    }
  }

  Future<void> _toggleLocationOverride(bool value) async {
    if (!value) {
      setState(_resetLocationToClass);
      return;
    }

    setState(() => _isLocatingOverride = true);
    try {
      final Position pos = await LocationService.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _classLatitude = pos.latitude;
        _classLongitude = pos.longitude;
        _hasCustomClassCoords = true;
        _overrideLocation = true;
      });
    } catch (e) {
      _showNotification(
        'Could not get your location: ${e.toString().replaceAll('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _isLocatingOverride = false);
    }
  }

  Future<void> _startSession() async {
    if (_selectedClassId == null) return;

    final selectedClass = _selectedClassMap();
    final bool classHasLocation = selectedClass != null &&
        selectedClass['latitude'] != null &&
        selectedClass['longitude'] != null;
    final double? classRadius = selectedClass?['radius_meters'] == null
        ? null
        : (selectedClass!['radius_meters'] as num).toDouble();

    setState(() {
      _isStartingSession = true;
      _qrToken = null;
      _activeSessionId = null;
    });

    try {
      // The session inherits the class geofence. Only the values that were
      // overridden are saved on the session (null = inherit from the class).
      double? sessionLat;
      double? sessionLng;
      double? sessionRadius;

      if (_overrideLocation || !classHasLocation) {
        try {
          final Position teacherPosition =
              await LocationService.getCurrentPosition();
          sessionLat = teacherPosition.latitude;
          sessionLng = teacherPosition.longitude;

          setState(() {
            _classLatitude = teacherPosition.latitude;
            _classLongitude = teacherPosition.longitude;
            _hasCustomClassCoords = true;
          });
        } catch (e) {
          final reason = e.toString().replaceAll('Exception: ', '');
          if (!classHasLocation) {
            // No class location to fall back on, so we cannot start safely.
            _showNotification(
              'This class has no saved location and yours could not be captured: $reason',
            );
            return;
          }
          _showNotification(
            'Location could not be captured ($reason). Using the class location instead.',
          );
          setState(_resetLocationToClass);
        }
      }

      if (classRadius == null || _selectedRadiusMeters != classRadius) {
        sessionRadius = _selectedRadiusMeters;
      }

      final now = DateTime.now();
      final generatedToken =
          'session_${now.millisecondsSinceEpoch}_$_selectedClassId';
      // No time limit: the session stays open until the teacher ends it.
      // (expires_at cannot be null in the table, so it is set far ahead.)
      final expiresAt = now.add(const Duration(days: 365));
      final todayDate = now.toIso8601String().split('T')[0];

      final Map<String, dynamic> sessionData = {
        'class_id': _selectedClassId,
        'qr_token': generatedToken,
        'date': todayDate,
        'expires_at': expiresAt.toIso8601String(),
        'late_limit_minutes': _selectedLateLimitMinutes,
        'is_ended': false,
      };
      if (sessionLat != null && sessionLng != null) {
        sessionData['latitude'] = sessionLat;
        sessionData['longitude'] = sessionLng;
      }
      if (sessionRadius != null) {
        sessionData['radius_meters'] = sessionRadius;
      }

      final sessionResponse = await _supabase
          .from('attendance_sessions')
          .insert(sessionData)
          .select('id, qr_token')
          .single();

      setState(() {
        _activeSessionId = sessionResponse['id'].toString();
        _qrToken = sessionResponse['qr_token'].toString();
      });

      _showNotification(
        'Attendance Session started successfully!',
        isError: false,
      );
      _fetchSessionHistory();
    } catch (e) {
      if (mounted) {
        _showNotification('Error starting session: $e');
      }
    } finally {
      if (mounted) setState(() => _isStartingSession = false);
    }
  }

  /// Reopens a session that was ended by mistake (same day only).
  /// Students who already scanned keep their records; only the records that
  /// were auto-marked absent on close are removed so those students can scan.
  Future<void> _reopenSession(Map<String, dynamic> session) async {
    if (_activeSessionId != null) {
      _showNotification(
        'End the current live session before reopening another.',
      );
      return;
    }

    final String sessionId = session['id'].toString();
    final String todayDate = DateTime.now().toIso8601String().split('T')[0];
    if (session['date']?.toString() != todayDate) {
      _showNotification("Only today's sessions can be reopened.");
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Reopen Session?',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: Text(
          'The same QR will go live again and stay open until you end it. Students who already '
          'scanned keep their attendance. Students who were auto-marked absent '
          'when the session closed will be able to scan again (their status is '
          'based on the original start time and late limit, so they may show '
          'as Late).',
          style: GoogleFonts.poppins(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryBlue,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Reopen',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _reopeningSessionId = sessionId);

    try {
      // 1. Find the records the system auto-marked absent when it closed.
      final autoRes = await _supabase
          .from('attendance_records')
          .select('id')
          .eq('session_id', sessionId)
          .eq('status', 'absent')
          .eq('remarks', 'Auto-marked absent on session close');

      final List<String> autoIds =
          (autoRes as List).map((r) => r['id'].toString()).toList();

      if (autoIds.isNotEmpty) {
        // Keep any record that already has an excuse letter attached.
        final reasonRes = await _supabase
            .from('absence_reasons')
            .select('attendance_record_id')
            .inFilter('attendance_record_id', autoIds);

        final Set<String> keepIds = (reasonRes as List)
            .map((r) => r['attendance_record_id'].toString())
            .toSet();

        final List<String> deleteIds =
            autoIds.where((id) => !keepIds.contains(id)).toList();

        if (deleteIds.isNotEmpty) {
          await _supabase
              .from('attendance_records')
              .delete()
              .inFilter('id', deleteIds);
        }
      }

      // 2. Put the session back to live.
      await _supabase
          .from('attendance_sessions')
          .update({
            'is_ended': false,
            'ended_at': null,
            // no time limit: stays open until the teacher ends it again
            'expires_at':
                DateTime.now().add(const Duration(days: 365)).toIso8601String(),
          })
          .eq('id', sessionId)
          .eq('is_ended', true); // this session only

      _showNotification(
        'Session reopened. Students can scan again.',
        isError: false,
      );

      // 3. Reload: this restores the live session (class, QR, geofence).
      await _fetchFacultyClasses(preferSessionId: sessionId);
    } catch (e) {
      _showNotification('Error reopening session: $e');
    } finally {
      if (mounted) setState(() => _reopeningSessionId = null);
    }
  }

  Future<void> _endSession() async {
    if (_activeSessionId == null || _selectedClassId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'End Session?',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: Text(
          'Ending this session will automatically mark all enrolled students who have not scanned in as ABSENT.',
          style: GoogleFonts.poppins(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'End Session',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isEndingSession = true);

    try {
      final enrolledRes = await _supabase
          .from('class_enrollments')
          .select('student_id')
          .eq('class_id', _selectedClassId!);

      final List<String> enrolledStudentIds =
          (enrolledRes as List).map((e) => e['student_id'].toString()).toList();

      final scannedRes = await _supabase
          .from('attendance_records')
          .select('student_id')
          .eq('session_id', _activeSessionId!);

      final Set<String> scannedStudentIds =
          (scannedRes as List).map((s) => s['student_id'].toString()).toSet();

      final List<String> absentStudentIds = enrolledStudentIds
          .where((id) => !scannedStudentIds.contains(id))
          .toList();

      if (absentStudentIds.isNotEmpty) {
        final nowIso = DateTime.now().toIso8601String();
        final List<Map<String, dynamic>> absentRecords = absentStudentIds.map((
          id,
        ) {
          return {
            'session_id': _activeSessionId,
            'student_id': id,
            'status': 'absent',
            'scanned_at': nowIso,
            'remarks': 'Auto-marked absent on session close',
          };
        }).toList();

        await _supabase.from('attendance_records').insert(absentRecords);
      }

      await _supabase.from('attendance_sessions').update({
        'is_ended': true,
        'ended_at': DateTime.now().toIso8601String(),
      }).eq('id', _activeSessionId!);

      _showNotification(
        'Session ended. ${absentStudentIds.length} unscanned student(s) marked Absent.',
        isError: false,
      );

      setState(() {
        _activeSessionId = null;
        _qrToken = null;
        _resetGeofenceToClass(); // next session starts from the class geofence
      });
      _fetchSessionHistory();
    } catch (e) {
      _showNotification('Error closing session: $e');
    } finally {
      if (mounted) setState(() => _isEndingSession = false);
    }
  }

  void _showNotification(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF41A564),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _selectFilterDate() async {
    final DateRangeResult? result = await showDateRangeCalendar(
      context,
      initialRange: _filterDateRange,
    );

    // null = the sheet was closed without applying
    if (result == null || !mounted) return;

    setState(() {
      _filterDateRange = result.range; // null = all dates
      _historyPage = 1;
    });
    _fetchSessionHistory();
  }

  void _showSessionDetailsModal(Map<String, dynamic> session) {
    final classData = session['classes'] as Map<String, dynamic>?;
    final courseCode = classData?['course_code'] ?? 'Class';
    final courseName = classData?['course_name'] ?? '';
    final section = classData?['section'] ?? '';
    final createdAt = _formatTimestamp(session['created_at']?.toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$courseCode - $courseName',
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Section $section • $createdAt',
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
                    icon: const Icon(Icons.close_rounded, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text(
                'STUDENT LOGS',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _supabase.from('attendance_records').stream(
                      primaryKey: ['id']).eq('session_id', session['id']),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final records = snapshot.data ?? [];
                    if (records.isEmpty) {
                      return Center(
                        child: Text(
                          'No records found for this session.',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      itemCount: records.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final rec = records[idx];
                        final status = (rec['status'] ?? '').toLowerCase();
                        final scannedAt = _formatTimestamp(
                          rec['scanned_at']?.toString(),
                        );

                        Color statusColor = Colors.grey;
                        if (status == 'present') statusColor = Colors.green;
                        if (status == 'late') statusColor = Colors.orange;
                        if (status == 'absent') statusColor = Colors.redAccent;

                        return FutureBuilder<Map<String, dynamic>>(
                          future: _supabase
                              .from('profiles')
                              .select('full_name, school_id')
                              .eq('id', rec['student_id'])
                              .single(),
                          builder: (context, profileSnap) {
                            final name =
                                profileSnap.data?['full_name'] ?? 'Loading...';
                            final schoolId =
                                profileSnap.data?['school_id'] ?? '';

                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: statusColor.withValues(
                                  alpha: 0.15,
                                ),
                                child: Icon(
                                  Icons.person,
                                  size: 16,
                                  color: statusColor,
                                ),
                              ),
                              title: Text(
                                name,
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'ID: $schoolId ${scannedAt.isNotEmpty ? "• $scannedAt" : ""}',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  status.toUpperCase(),
                                  style: GoogleFonts.poppins(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- SESSION HISTORY PAGINATION ---
  int get _historyTotalPages {
    final pages =
        (_historySessions.length + _historyPerPage - 1) ~/ _historyPerPage;
    return pages < 1 ? 1 : pages;
  }

  int get _safeHistoryPage {
    if (_historyPage < 1) return 1;
    if (_historyPage > _historyTotalPages) return _historyTotalPages;
    return _historyPage;
  }

  List<Map<String, dynamic>> get _pagedHistorySessions {
    final int start = (_safeHistoryPage - 1) * _historyPerPage;
    int end = start + _historyPerPage;
    if (end > _historySessions.length) end = _historySessions.length;
    return _historySessions.sublist(start, end);
  }

  Widget _buildHistoryPagination() {
    final int page = _safeHistoryPage;
    final int totalPages = _historyTotalPages;
    final int total = _historySessions.length;
    final int from = (page - 1) * _historyPerPage + 1;
    final int to =
        page * _historyPerPage > total ? total : page * _historyPerPage;

    Widget arrowButton(IconData icon, bool enabled, VoidCallback onTap) {
      return InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: enabled ? AppColors.primaryBlue : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 20,
            color: enabled ? Colors.white : Colors.grey.shade400,
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            arrowButton(
              Icons.chevron_left_rounded,
              page > 1,
              () => setState(() => _historyPage = page - 1),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Page $page of $totalPages',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
            ),
            arrowButton(
              Icons.chevron_right_rounded,
              page < totalPages,
              () => setState(() => _historyPage = page + 1),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Showing $from-$to of $total sessions',
          style: GoogleFonts.poppins(
            fontSize: 10.5,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final radiusOptions = <double>{
      ..._defaultRadiusOptions,
      _selectedRadiusMeters,
    }.toList()
      ..sort();

    final lateLimitOptions = <int>{
      ..._defaultLateLimitOptions,
      _selectedLateLimitMinutes,
    }.toList()
      ..sort();

    final bool classExists = _myClasses.any(
      (c) => c['id'].toString() == _selectedClassId,
    );
    final String? validSelectedClassId = classExists ? _selectedClassId : null;

    return RefreshIndicator(
      onRefresh: () async {
        await _fetchFacultyClasses();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20.0),
        child: Column(
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
                        'Start Attendance Session',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Configure geofence radius, late limits, and display live check-in QR.',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: AppColors.primaryBlue,
                  ),
                  onPressed: () {
                    _fetchFacultyClasses();
                  },
                  tooltip: 'Refresh Classes',
                ),
              ],
            ),
            const SizedBox(height: 20),

            // --- CLASS SELECTION DROPDOWN ---
            Text(
              'SELECT CLASS',
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  hint: Text(
                    _isLoadingClasses
                        ? 'Loading your classes...'
                        : (_myClasses.isEmpty
                            ? 'No active classes found'
                            : 'Choose a class...'),
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: Colors.grey.shade400,
                    ),
                  ),
                  value: validSelectedClassId,
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppColors.primaryBlue,
                    size: 22,
                  ),
                  items: _myClasses.map((classData) {
                    final String classId = classData['id'].toString();
                    final code = classData['course_code'] ?? '';
                    final name = classData['course_name'] ?? '';
                    final section = classData['section'] ?? '';
                    final displayText = '$code - $name ($section)';

                    return DropdownMenuItem<String>(
                      value: classId,
                      child: Text(
                        displayText,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (_isLoadingClasses ||
                          _myClasses.isEmpty ||
                          _activeSessionId != null)
                      ? null
                      : (String? newClassId) {
                          setState(() {
                            _selectedClassId = newClassId;
                            _qrToken = null;
                            _activeSessionId = null;
                            // Each class starts from its own saved geofence
                            _resetGeofenceToClass();
                          });
                        },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // --- SESSION PARAMETERS WITH INTEGRATED MATCHED MAP ---
            if (_activeSessionId == null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SESSION PARAMETERS',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlue,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        // ALLOWED RADIUS DROPDOWN
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Allowed Radius',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<double>(
                                value: radiusOptions.contains(
                                  _selectedRadiusMeters,
                                )
                                    ? _selectedRadiusMeters
                                    : radiusOptions.first,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: AppColors.primaryBlue,
                                  size: 20,
                                ),
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                      color: AppColors.primaryBlue,
                                      width: 1.5,
                                    ),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                ),
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
                                ),
                                items: radiusOptions.map((r) {
                                  return DropdownMenuItem<double>(
                                    value: r,
                                    child: Text('${r.round()} Meters'),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedRadiusMeters = val);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // LATE LIMIT DROPDOWN
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Late Limit',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<int>(
                                value: lateLimitOptions.contains(
                                  _selectedLateLimitMinutes,
                                )
                                    ? _selectedLateLimitMinutes
                                    : lateLimitOptions.first,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: AppColors.primaryBlue,
                                  size: 20,
                                ),
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                      color: AppColors.primaryBlue,
                                      width: 1.5,
                                    ),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                ),
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
                                ),
                                items: lateLimitOptions.map((m) {
                                  return DropdownMenuItem<int>(
                                    value: m,
                                    child: Text('$m Minutes'),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(
                                      () => _selectedLateLimitMinutes = val,
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // --- GEOFENCE OVERRIDE (default = inherit from class) ---
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _overrideLocation
                              ? AppColors.primaryBlue
                              : Colors.grey.shade200,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _overrideLocation
                                ? Icons.my_location_rounded
                                : Icons.school_rounded,
                            size: 18,
                            color: AppColors.primaryBlue,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Use my current location',
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade800,
                                  ),
                                ),
                                Text(
                                  _isLocatingOverride
                                      ? 'Getting your location...'
                                      : (_overrideLocation
                                          ? 'Custom location for this session only'
                                          : 'Using the class geofence'),
                                  style: GoogleFonts.poppins(
                                    fontSize: 10.5,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _overrideLocation,
                            activeColor: AppColors.primaryBlue,
                            onChanged: (_isLocatingOverride ||
                                    _selectedClassId == null)
                                ? null
                                : _toggleLocationOverride,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // --- MAP CARD EXACT MATCHING DESIGN ---
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        height: 220,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Stack(
                          children: [
                            FlutterMap(
                              key: ValueKey(
                                'map_${_selectedClassId}_${_classLatitude}_${_classLongitude}_$_selectedRadiusMeters',
                              ),
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: LatLng(
                                  _classLatitude,
                                  _classLongitude,
                                ),
                                initialZoom: _getZoomForRadius(
                                  _selectedRadiusMeters,
                                ),
                                minZoom: 13.0,
                                maxZoom: 19.0,
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate:
                                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'com.classkeeper.app',
                                ),
                                CircleLayer(
                                  circles: [
                                    CircleMarker(
                                      point: LatLng(
                                        _classLatitude,
                                        _classLongitude,
                                      ),
                                      radius: _selectedRadiusMeters,
                                      useRadiusInMeter: true,
                                      color: AppColors.primaryBlue.withValues(
                                        alpha: 0.18,
                                      ),
                                      borderColor: AppColors.primaryBlue,
                                      borderStrokeWidth: 2.5,
                                    ),
                                  ],
                                ),
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: LatLng(
                                        _classLatitude,
                                        _classLongitude,
                                      ),
                                      width: 40,
                                      height: 40,
                                      child: const Icon(
                                        Icons.location_on_rounded,
                                        color: Colors.redAccent,
                                        size: 38,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.10,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.school_rounded,
                                      size: 15,
                                      color: AppColors.primaryBlue,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _overrideLocation
                                          ? 'My Location (this session)'
                                          : (_hasCustomClassCoords
                                              ? 'Classroom Location'
                                              : 'STI College Davao'),
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 12,
                              right: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.10,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(
                                        color: AppColors.primaryBlue,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Radius Zone: ${_selectedRadiusMeters.round()}m',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: 12,
                              right: 12,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.12,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      _mapController.move(
                                        LatLng(_classLatitude, _classLongitude),
                                        _getZoomForRadius(
                                          _selectedRadiusMeters,
                                        ),
                                      );
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: Icon(
                                        Icons.center_focus_strong_rounded,
                                        size: 20,
                                        color: AppColors.primaryBlue,
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
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (_activeSessionId == null)
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    disabledBackgroundColor: Colors.grey.shade300,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _selectedClassId == null || _isStartingSession
                      ? null
                      : _startSession,
                  icon: _isStartingSession
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                  label: Text(
                    _isStartingSession
                        ? 'Starting Session...'
                        : 'Start Session',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            // --- ACTIVE SESSION CARD & LIVE COUNTER ---
            if (_qrToken != null && _activeSessionId != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6F4EA),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Live Session Active',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF10B981),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'Late Limit: $_selectedLateLimitMinutes mins',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    QrImageView(
                      data: _qrToken!,
                      version: QrVersions.auto,
                      size: 170.0,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 14),

                    // --- INTEGRATED TAP LOCATION & RADIUS BADGE ---
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.location_on_rounded,
                                size: 15,
                                color: Colors.redAccent,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Location: ${_classLatitude.toStringAsFixed(5)}, ${_classLongitude.toStringAsFixed(5)}',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          _PlaceNameText(
                            latitude: _classLatitude,
                            longitude: _classLongitude,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Students scan within ${_selectedRadiusMeters.round()}m radius',
                            style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 42,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isEndingSession ? null : _endSession,
                        icon: _isEndingSession
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.stop_circle_outlined,
                                color: Colors.white,
                                size: 18,
                              ),
                        label: Text(
                          _isEndingSession
                              ? 'Ending Session...'
                              : 'End Session & Auto-mark Absents',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // --- LIVE CHECK-IN COUNTER FEED ---
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _supabase.from('attendance_records').stream(
                    primaryKey: ['id']).eq('session_id', _activeSessionId!),
                builder: (context, snapshot) {
                  final records = snapshot.data ?? [];
                  final presentCount =
                      records.where((r) => r['status'] == 'present').length;
                  final lateCount =
                      records.where((r) => r['status'] == 'late').length;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'LIVE CHECKED-IN ROSTER',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryBlue.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${records.length} Scanned ($presentCount Present, $lateCount Late)',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (records.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Text(
                            'No students have scanned in yet.',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: records.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final record = records[index];
                              final studentId = record['student_id'];
                              final statusStr = (record['status'] ?? 'present')
                                  .toString()
                                  .toUpperCase();
                              final isPresent = statusStr == 'PRESENT';

                              return FutureBuilder<Map<String, dynamic>>(
                                future: _supabase
                                    .from('profiles')
                                    .select('full_name, school_id')
                                    .eq('id', studentId)
                                    .single(),
                                builder: (context, profileSnapshot) {
                                  final name =
                                      profileSnapshot.data?['full_name'] ??
                                          'Loading student...';
                                  final schoolId =
                                      profileSnapshot.data?['school_id'] ?? '';

                                  return ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      radius: 14,
                                      backgroundColor: isPresent
                                          ? Colors.green
                                          : Colors.orange,
                                      child: const Icon(
                                        Icons.person,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                    title: Text(
                                      name,
                                      style: GoogleFonts.poppins(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: schoolId.isNotEmpty
                                        ? Text(
                                            'ID: $schoolId',
                                            style: GoogleFonts.poppins(
                                              fontSize: 10,
                                            ),
                                          )
                                        : null,
                                    trailing: Text(
                                      statusStr,
                                      style: GoogleFonts.poppins(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: isPresent
                                            ? Colors.green.shade700
                                            : Colors.orange.shade800,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
            const SizedBox(height: 32),

            // --- SESSION HISTORY SECTION & FILTERS ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'ATTENDANCE SESSION HISTORY',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                    letterSpacing: 0.5,
                  ),
                ),
                if (_historySessions.isNotEmpty)
                  Text(
                    '${_historySessions.length} Sessions',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade500,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // FILTER CONTROLS BAR
            Container(
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
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _filterClassId,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primaryBlue,
                              ),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 18,
                                color: AppColors.primaryBlue,
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 'all',
                                  child: Text('All Classes'),
                                ),
                                ..._myClasses.map((c) {
                                  final code = c['course_code'] ?? 'Class';
                                  final sec = c['section'] ?? '';
                                  return DropdownMenuItem(
                                    value: c['id'].toString(),
                                    child: Text(
                                      '$code ${sec.isNotEmpty ? "($sec)" : ""}',
                                    ),
                                  );
                                }),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _filterClassId = val;
                                    _historyPage = 1;
                                  });
                                  _fetchSessionHistory();
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _filterStatus,
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlue,
                            ),
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: AppColors.primaryBlue,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('All Status'),
                              ),
                              DropdownMenuItem(
                                value: 'active',
                                child: Text('Live Active'),
                              ),
                              DropdownMenuItem(
                                value: 'ended',
                                child: Text('Ended'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _filterStatus = val;
                                  _historyPage = 1;
                                });
                                _fetchSessionHistory();
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: _selectFilterDate,
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
                                  _historyPage = 1;
                                });
                                _fetchSessionHistory();
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
            ),
            const SizedBox(height: 12),

            if (_isLoadingHistory)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_historySessions.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.history_toggle_off_rounded,
                      size: 40,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No attendance sessions found',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    Text(
                      'Try clearing filters or start a new attendance session above.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _pagedHistorySessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final session = _pagedHistorySessions[index];
                  final isEnded = session['is_ended'] == true;

                  final classData = session['classes'] as Map<String, dynamic>?;
                  final courseCode = classData?['course_code'] ?? 'Class';
                  final courseName = classData?['course_name'] ?? '';
                  final section = classData?['section'] ?? '';

                  final createdAtStr = _formatTimestamp(
                    session['created_at']?.toString(),
                  );
                  final records = session['attendance_records'] as List? ?? [];

                  final presentCount = records
                      .where(
                        (r) =>
                            (r['status'] ?? '').toString().toLowerCase() ==
                            'present',
                      )
                      .length;
                  final lateCount = records
                      .where(
                        (r) =>
                            (r['status'] ?? '').toString().toLowerCase() ==
                            'late',
                      )
                      .length;
                  final absentCount = records
                      .where(
                        (r) =>
                            (r['status'] ?? '').toString().toLowerCase() ==
                            'absent',
                      )
                      .length;

                  final lateLimit = session['late_limit_minutes'] ?? 15;

                  final String todayDate =
                      DateTime.now().toIso8601String().split('T')[0];
                  final bool canReopen = isEnded &&
                      session['date']?.toString() == todayDate &&
                      _activeSessionId == null;

                  return Container(
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
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _showSessionDetailsModal(session),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryBlue,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
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
                                      color: isEnded
                                          ? const Color(0xFFF1F5F9)
                                          : const Color(0xFFE6F4EA),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isEnded
                                            ? Colors.grey.shade300
                                            : const Color(0xFF10B981),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isEnded
                                              ? Icons
                                                  .check_circle_outline_rounded
                                              : Icons.sensors_rounded,
                                          size: 11,
                                          color: isEnded
                                              ? Colors.grey.shade600
                                              : const Color(0xFF10B981),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          isEnded ? 'Ended' : 'Live Active',
                                          style: GoogleFonts.poppins(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: isEnded
                                                ? Colors.grey.shade600
                                                : const Color(0xFF10B981),
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
                                style: GoogleFonts.poppins(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF0F172A),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                                    createdAtStr,
                                    style: GoogleFonts.poppins(
                                      fontSize: 10,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '• Late limit: ${lateLimit}m',
                                    style: GoogleFonts.poppins(
                                      fontSize: 10,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              const Divider(
                                height: 1,
                                color: Color(0xFFF1F5F9),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE6F4EA),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          '$presentCount Present',
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF10B981),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFF7ED),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          '$lateCount Late',
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.orange.shade800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFEF2F2),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          '$absentCount Absent',
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        'View Roster',
                                        style: GoogleFonts.poppins(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primaryBlue,
                                        ),
                                      ),
                                      const Icon(
                                        Icons.chevron_right_rounded,
                                        size: 16,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (canReopen) ...[
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  height: 36,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(
                                        color: AppColors.primaryBlue,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: _reopeningSessionId != null
                                        ? null
                                        : () => _reopenSession(session),
                                    icon: _reopeningSessionId ==
                                            session['id'].toString()
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.replay_rounded,
                                            size: 16,
                                            color: AppColors.primaryBlue,
                                          ),
                                    label: Text(
                                      'Reopen Session',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),

            if (!_isLoadingHistory &&
                _historySessions.length > _historyPerPage) ...[
              const SizedBox(height: 14),
              _buildHistoryPagination(),
            ],

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}

/// Shows the name of the place for a coordinate (street / area / city),
/// using OpenStreetMap's free reverse-geocoding service (Nominatim).
class _PlaceNameText extends StatefulWidget {
  final double latitude;
  final double longitude;

  const _PlaceNameText({
    required this.latitude,
    required this.longitude,
  });

  @override
  State<_PlaceNameText> createState() => _PlaceNameTextState();
}

class _PlaceNameTextState extends State<_PlaceNameText> {
  // Remember results so the same spot is not looked up again and again
  static final Map<String, String> _cache = {};

  String? _placeName;
  bool _loading = true;

  String get _key =>
      '${widget.latitude.toStringAsFixed(5)},${widget.longitude.toStringAsFixed(5)}';

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(covariant _PlaceNameText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey =
        '${oldWidget.latitude.toStringAsFixed(5)},${oldWidget.longitude.toStringAsFixed(5)}';
    if (oldKey != _key) _lookup();
  }

  String _buildName(Map<String, dynamic> data) {
    final Map<String, dynamic> addr = data['address'] is Map
        ? Map<String, dynamic>.from(data['address'] as Map)
        : <String, dynamic>{};

    String pick(List<String> keys) {
      for (final k in keys) {
        final v = (addr[k] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    final String place = (data['name'] ?? '').toString().trim();
    final String road = pick(['road', 'pedestrian', 'path']);
    final String area = pick(
        ['suburb', 'neighbourhood', 'village', 'quarter', 'city_district']);
    final String city = pick(['city', 'town', 'municipality', 'county']);

    final parts = <String>[];
    for (final p in [place, road, area, city]) {
      if (p.isNotEmpty && !parts.contains(p)) parts.add(p);
    }
    if (parts.isNotEmpty) return parts.take(3).join(', ');

    // Fallback: first parts of the full address
    final String full = (data['display_name'] ?? '').toString();
    return full.split(',').map((e) => e.trim()).take(3).join(', ');
  }

  Future<void> _lookup() async {
    final String key = _key;

    final cached = _cache[key];
    if (cached != null) {
      setState(() {
        _placeName = cached;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _placeName = null;
    });

    String? result;
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': widget.latitude.toString(),
        'lon': widget.longitude.toString(),
        'zoom': '18',
        'addressdetails': '1',
        'accept-language': 'en',
      });

      final response = await http.get(uri, headers: {
        'User-Agent': 'ClassKeeper/1.0 (student project)'
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data['error'] == null) {
          final name = _buildName(data);
          if (name.isNotEmpty) {
            result = name;
            _cache[key] = name;
          }
        }
      }
    } catch (e) {
      debugPrint('Could not look up place name: $e');
    }

    // Ignore the answer if the location changed while we were waiting
    if (!mounted || key != _key) return;
    setState(() {
      _placeName = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Text(
        'Finding place name...',
        style: GoogleFonts.poppins(
          fontSize: 10.5,
          fontStyle: FontStyle.italic,
          color: Colors.grey.shade500,
        ),
      );
    }

    // If the lookup failed, just show nothing (coordinates are still shown)
    if (_placeName == null) return const SizedBox.shrink();

    return Text(
      _placeName!,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.poppins(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: Colors.grey.shade800,
        height: 1.3,
      ),
    );
  }
}
