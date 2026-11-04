import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/location_service.dart';
import 'create_class_screen.dart';
import 'faculty_class_detail_screen.dart';

class FacultyClassesScreen extends StatefulWidget {
  const FacultyClassesScreen({super.key});

  @override
  State<FacultyClassesScreen> createState() => _FacultyClassesScreenState();
}

class _FacultyClassesScreenState extends State<FacultyClassesScreen> {
  final _supabase = Supabase.instance.client;
  RealtimeChannel? _realtimeChannel;

  bool _showArchived = false;
  String _searchQuery = '';
  List<Map<String, dynamic>> _classes = [];
  bool _isLoading = true;

  int _currentPage = 0;
  final int _pageSize = 10;
  int _totalClassesCount = 0;

  final List<double> _radiusOptions = [
    30.0,
    50.0,
    75.0,
    100.0,
    150.0,
    200.0,
    500.0
  ];

  @override
  void initState() {
    super.initState();
    _fetchClasses();
    _setupRealtimeListener();
  }

  // --- SUPABASE REALTIME LISTENER ENGINE ---
  void _setupRealtimeListener() {
    _realtimeChannel = _supabase
        .channel('public_faculty_classes_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'classes',
          callback: (payload) {
            debugPrint(
                'Realtime update in classes table (${payload.eventType}). Refreshing UI...');
            if (mounted) {
              _fetchClasses();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'class_enrollments',
          callback: (payload) {
            debugPrint(
                'Realtime update in class_enrollments table (${payload.eventType}). Refreshing UI...');
            if (mounted) {
              _fetchClasses();
            }
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _realtimeChannel?.unsubscribe();
    super.dispose();
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
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _fetchClasses() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final from = _currentPage * _pageSize;
      final to = from + _pageSize - 1;

      final countRes = await _supabase
          .from('classes')
          .select('id')
          .eq('faculty_id', userId)
          .eq('is_archived', _showArchived);

      _totalClassesCount = (countRes as List).length;

      final response = await _supabase
          .from('classes')
          .select('*, class_enrollments(count)')
          .eq('faculty_id', userId)
          .eq('is_archived', _showArchived)
          .order('created_at', ascending: false)
          .range(from, to);

      if (mounted) {
        setState(() {
          _classes = List<Map<String, dynamic>>.from(response);
        });
      }
    } catch (e) {
      if (mounted) {
        _showNotification('Error loading classes: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _toggleArchiveClass(String classId, bool currentStatus) async {
    try {
      await _supabase
          .from('classes')
          .update({'is_archived': !currentStatus}).eq('id', classId);

      _showNotification(
        currentStatus ? 'Class restored to Active' : 'Class archived',
        isError: false,
      );
      _fetchClasses();
    } catch (e) {
      _showNotification('Archive update failed: $e');
    }
  }

  // --- REDESIGNED EDIT CLASS DIALOG WITH GEOLOCATION ---
  void _showEditClassDialog(Map<String, dynamic> classData) {
    final codeCtrl = TextEditingController(text: classData['course_code']);
    final nameCtrl = TextEditingController(text: classData['course_name']);
    final schedCtrl = TextEditingController(text: classData['schedule']);
    final sectionCtrl = TextEditingController(text: classData['section']);

    final latCtrl =
        TextEditingController(text: classData['latitude']?.toString() ?? '');
    final lngCtrl =
        TextEditingController(text: classData['longitude']?.toString() ?? '');

    double selectedRadius =
        (classData['radius_meters'] as num?)?.toDouble() ?? 50.0;
    bool isCapturingLocation = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final availableRadiusOptions =
                <double>{..._radiusOptions, selectedRadius}.toList()..sort();

            return Dialog(
              backgroundColor: Colors.white,
              elevation: 10,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(22.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // DIALOG HEADER
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryBlue
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.edit_square,
                                  color: AppColors.primaryBlue,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Edit Class Details',
                                style: GoogleFonts.poppins(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
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

                      // COURSE INFORMATION SECTION
                      Text(
                        'COURSE INFORMATION',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 10),

                      _buildEditTextField(
                        'Course Code',
                        codeCtrl,
                        'e.g. CS555',
                        Icons.numbers_rounded,
                      ),
                      const SizedBox(height: 10),
                      _buildEditTextField(
                        'Course Name',
                        nameCtrl,
                        'e.g. Mobile Computing',
                        Icons.book_rounded,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildEditTextField(
                              'Schedule',
                              schedCtrl,
                              'e.g. Mon 8:00 AM',
                              Icons.schedule_rounded,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildEditTextField(
                              'Section',
                              sectionCtrl,
                              'e.g. 101',
                              Icons.groups_rounded,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),
                      const Divider(height: 1, color: Color(0xFFE2E8F0)),
                      const SizedBox(height: 16),

                      // GEOLOCATION & BOUNDARY SECTION
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'GEOLOCATION & BOUNDARY',
                            style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                              letterSpacing: 0.6,
                            ),
                          ),
                          if (latCtrl.text.isNotEmpty &&
                              lngCtrl.text.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE6F4EA),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle_rounded,
                                      size: 11, color: Color(0xFF10B981)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'GPS Set',
                                    style: GoogleFonts.poppins(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF10B981),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // GPS CAPTURE BUTTON
                      SizedBox(
                        width: double.infinity,
                        height: 40,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: const Color(0xFFEFF6FF),
                            side: const BorderSide(
                                color: AppColors.primaryBlue, width: 1.2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: isCapturingLocation
                              ? null
                              : () async {
                                  setDialogState(
                                      () => isCapturingLocation = true);
                                  try {
                                    final pos = await LocationService
                                        .getCurrentPosition();
                                    setDialogState(() {
                                      latCtrl.text =
                                          pos.latitude.toStringAsFixed(6);
                                      lngCtrl.text =
                                          pos.longitude.toStringAsFixed(6);
                                      isCapturingLocation = false;
                                    });
                                    _showNotification(
                                      'Current location captured successfully!',
                                      isError: false,
                                    );
                                  } catch (e) {
                                    setDialogState(
                                        () => isCapturingLocation = false);
                                    _showNotification(
                                        'Failed to capture location: $e');
                                  }
                                },
                          icon: isCapturingLocation
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primaryBlue,
                                  ),
                                )
                              : const Icon(Icons.my_location_rounded,
                                  size: 16, color: AppColors.primaryBlue),
                          label: Text(
                            isCapturingLocation
                                ? 'Acquiring Satellite Fix...'
                                : 'Capture Current GPS Location',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // LATITUDE & LONGITUDE INPUTS
                      Row(
                        children: [
                          Expanded(
                            child: _buildEditTextField(
                              'Latitude',
                              latCtrl,
                              '0.000000',
                              Icons.location_on_outlined,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildEditTextField(
                              'Longitude',
                              lngCtrl,
                              '0.000000',
                              Icons.location_on_outlined,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // GEOFENCE RADIUS DROPDOWN
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Allowed Geofence Radius',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          DropdownButtonFormField<double>(
                            value: selectedRadius,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                            ),
                            decoration: InputDecoration(
                              prefixIcon: const Icon(
                                Icons.radar_rounded,
                                size: 18,
                                color: AppColors.primaryBlue,
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    BorderSide(color: Colors.grey.shade300),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(
                                    color: AppColors.primaryBlue, width: 1.5),
                              ),
                            ),
                            items: availableRadiusOptions.map((r) {
                              return DropdownMenuItem<double>(
                                value: r,
                                child: Text('${r.round()} Meters'),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedRadius = val);
                              }
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 22),

                      // BUTTONS ROW
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
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
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () async {
                                if (codeCtrl.text.isEmpty ||
                                    nameCtrl.text.isEmpty) {
                                  _showNotification(
                                      'Course code and name are required');
                                  return;
                                }

                                final parsedLat =
                                    double.tryParse(latCtrl.text.trim());
                                final parsedLng =
                                    double.tryParse(lngCtrl.text.trim());

                                Navigator.pop(ctx);
                                try {
                                  await _supabase.from('classes').update({
                                    'course_code': codeCtrl.text.trim(),
                                    'course_name': nameCtrl.text.trim(),
                                    'schedule': schedCtrl.text.trim(),
                                    'section': sectionCtrl.text.trim(),
                                    'latitude': parsedLat,
                                    'longitude': parsedLng,
                                    'radius_meters': selectedRadius,
                                  }).eq('id', classData['id']);

                                  _fetchClasses();
                                  _showNotification(
                                    'Class details & location updated!',
                                    isError: false,
                                  );
                                } catch (e) {
                                  _showNotification('Update failed: $e');
                                }
                              },
                              child: Text(
                                'Save Changes',
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
            );
          },
        );
      },
    );
  }

  Widget _buildEditTextField(
    String label,
    TextEditingController ctrl,
    String hint,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey[700],
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade400),
            prefixIcon: Icon(icon, size: 16, color: AppColors.primaryBlue),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: AppColors.primaryBlue, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  void _navigateToCreateClass() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const CreateClassScreen(),
      ),
    ).then((_) => _fetchClasses());
  }

  void _navigateToClassDetail(Map<String, dynamic> classData) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FacultyClassDetailScreen(classData: classData),
      ),
    ).then((_) => _fetchClasses());
  }

  @override
  Widget build(BuildContext context) {
    final totalPages = (_totalClassesCount / _pageSize).ceil();
    final filteredClasses = _classes.where((c) {
      final code = (c['course_code'] ?? '').toString().toLowerCase();
      final name = (c['course_name'] ?? '').toString().toLowerCase();
      return code.contains(_searchQuery.toLowerCase()) ||
          name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // HEADER & CREATE CLASS BUTTON
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'My Classes',
                          style: GoogleFonts.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Manage course rosters, schedules, and join codes.',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _navigateToCreateClass,
                    icon: const Icon(Icons.add, size: 16),
                    label: Text('Create Class',
                        style: GoogleFonts.poppins(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // SEARCH & ARCHIVE TOGGLE
              Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val;
                          });
                        },
                        style: GoogleFonts.poppins(
                            fontSize: 12, fontWeight: FontWeight.w500),
                        decoration: InputDecoration(
                          hintText: 'Search class or subject code...',
                          hintStyle: GoogleFonts.poppins(
                              fontSize: 12, color: Colors.grey.shade400),
                          prefixIcon: const Icon(Icons.search_rounded,
                              size: 20, color: AppColors.primaryBlue),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 14),
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
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _showArchived = !_showArchived;
                        _currentPage = 0;
                      });
                      _fetchClasses();
                    },
                    style: OutlinedButton.styleFrom(
                      backgroundColor:
                          _showArchived ? AppColors.primaryBlue : Colors.white,
                      foregroundColor:
                          _showArchived ? Colors.white : AppColors.primaryBlue,
                      side: const BorderSide(
                          color: AppColors.primaryBlue, width: 1.2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _showArchived ? 'Archived' : 'Active',
                      style: GoogleFonts.poppins(
                          fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              Text(
                _showArchived ? 'ARCHIVED CLASSES' : 'ACTIVE CLASSES',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),

              // CLASS LIST VIEW
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : filteredClasses.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _showArchived
                                      ? Icons.archive_outlined
                                      : Icons.class_outlined,
                                  size: 48,
                                  color: Colors.grey.shade400,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _showArchived
                                      ? 'No archived classes.'
                                      : 'No active classes found.\nTap "Create Class" to get started!',
                                  style: GoogleFonts.poppins(
                                      color: Colors.grey[600], fontSize: 12),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: filteredClasses.length,
                            itemBuilder: (context, index) {
                              final c = filteredClasses[index];
                              return _buildClassCard(c);
                            },
                          ),
              ),

              // PAGINATION CONTROLS BAR
              if (totalPages > 1) _buildPaginationBar(totalPages),
            ],
          ),
        ),
      ),
    );
  }

  // --- REDESIGNED CLASS CARD ---
  Widget _buildClassCard(Map<String, dynamic> c) {
    final enrollmentCount =
        (c['class_enrollments'] as List?)?.first['count'] ?? 0;
    final isArchived = c['is_archived'] == true;
    final courseCode = c['course_code'] ?? 'N/A';
    final courseName = c['course_name'] ?? 'Untitled Course';
    final schedule = c['schedule'] ?? 'TBA';
    final section = c['section'] ?? '';
    final hasGps = c['latitude'] != null && c['longitude'] != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _navigateToClassDetail(c),
          child: Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // TOP ROW: COURSE CODE & SECTION + ENROLLED BADGE + MENU
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.primaryBlue,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              courseCode,
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (section.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: Text(
                                'Sec $section',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF475569),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.primaryBlue
                                    .withValues(alpha: 0.15)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.people_alt_rounded,
                                  size: 13, color: AppColors.primaryBlue),
                              const SizedBox(width: 4),
                              Text(
                                '$enrollmentCount Enrolled',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert_rounded,
                              color: Colors.grey, size: 20),
                          elevation: 6,
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          onSelected: (val) {
                            if (val == 'edit') {
                              _showEditClassDialog(c);
                            } else if (val == 'archive') {
                              _toggleArchiveClass(
                                  c['id'].toString(), isArchived);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'edit',
                              child: Row(
                                children: [
                                  const Icon(Icons.edit_outlined,
                                      size: 18, color: AppColors.primaryBlue),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Edit Details',
                                    style: GoogleFonts.poppins(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'archive',
                              child: Row(
                                children: [
                                  Icon(
                                    isArchived
                                        ? Icons.unarchive_rounded
                                        : Icons.archive_outlined,
                                    size: 18,
                                    color: isArchived
                                        ? AppColors.primaryBlue
                                        : Colors.redAccent,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    isArchived
                                        ? 'Unarchive Class'
                                        : 'Archive Class',
                                    style: GoogleFonts.poppins(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: isArchived
                                          ? AppColors.primaryBlue
                                          : Colors.redAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // COURSE NAME
                Text(
                  courseName,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0F172A),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),

                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                const SizedBox(height: 8),

                // SCHEDULE & GPS BADGE ROW
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.access_time_rounded,
                              size: 14, color: Color(0xFF64748B)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              schedule,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (hasGps)
                      Row(
                        children: [
                          const Icon(Icons.location_on_rounded,
                              size: 13, color: Color(0xFF10B981)),
                          const SizedBox(width: 3),
                          Text(
                            'Geofenced',
                            style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- STYLISH PAGINATION BAR ---
  Widget _buildPaginationBar(int totalPages) {
    final int startItem = (_currentPage * _pageSize) + 1;
    final int endItem =
        ((_currentPage + 1) * _pageSize).clamp(0, _totalClassesCount);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // PREVIOUS BUTTON
          ElevatedButton.icon(
            onPressed: _currentPage > 0
                ? () {
                    setState(() => _currentPage--);
                    _fetchClasses();
                  }
                : null,
            icon: const Icon(Icons.chevron_left_rounded, size: 18),
            label: Text('Prev',
                style: GoogleFonts.poppins(
                    fontSize: 11, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEFF6FF),
              foregroundColor: AppColors.primaryBlue,
              disabledBackgroundColor: Colors.grey.shade100,
              disabledForegroundColor: Colors.grey.shade400,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),

          // PAGE SUMMARY TEXT
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Page ${_currentPage + 1} of $totalPages',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              Text(
                'Showing $startItem–$endItem of $_totalClassesCount',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),

          // NEXT BUTTON
          ElevatedButton(
            onPressed: (_currentPage + 1) < totalPages
                ? () {
                    setState(() => _currentPage++);
                    _fetchClasses();
                  }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEFF6FF),
              foregroundColor: AppColors.primaryBlue,
              disabledBackgroundColor: Colors.grey.shade100,
              disabledForegroundColor: Colors.grey.shade400,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Row(
              children: [
                Text('Next',
                    style: GoogleFonts.poppins(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
