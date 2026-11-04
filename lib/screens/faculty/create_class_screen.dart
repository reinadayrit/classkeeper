import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/location_service.dart';
import 'faculty_class_detail_screen.dart';

class ClassDaySchedule {
  final String day;
  int startHour;
  int startMinute;
  String startPeriod; // 'AM' or 'PM'
  int endHour;
  int endMinute;
  String endPeriod; // 'AM' or 'PM'

  ClassDaySchedule({
    required this.day,
    this.startHour = 8,
    this.startMinute = 0,
    this.startPeriod = 'AM',
    this.endHour = 9,
    this.endMinute = 30,
    this.endPeriod = 'AM',
  });

  String get formattedSchedule {
    final startM = startMinute.toString().padLeft(2, '0');
    final endM = endMinute.toString().padLeft(2, '0');
    return '$day $startHour:$startM $startPeriod - $endHour:$endM $endPeriod';
  }
}

class CreateClassScreen extends StatefulWidget {
  const CreateClassScreen({super.key});

  @override
  State<CreateClassScreen> createState() => _CreateClassScreenState();
}

class _CreateClassScreenState extends State<CreateClassScreen> {
  final _supabase = Supabase.instance.client;

  // Single textbox per line
  final _codeController = TextEditingController();
  final _courseController = TextEditingController();
  final _nameController = TextEditingController();
  final _sectionController = TextEditingController();

  // Geolocation & Map Controller (Defaults to STI College Davao)
  final MapController _mapController = MapController();
  double _classLatitude = 7.0739;
  double _classLongitude = 125.6128;
  double _allowedRadiusMeters = 50.0;
  bool _isGettingLocation = false;
  bool _isCustomGpsCaptured = false;

  // Schedules
  final List<String> _weekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  final List<ClassDaySchedule> _selectedSchedules = [];

  bool _isSaving = false;

  @override
  void dispose() {
    _codeController.dispose();
    _courseController.dispose();
    _nameController.dispose();
    _sectionController.dispose();
    _mapController.dispose();
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
        backgroundColor: isError
            ? Colors.redAccent
            : const Color(0xFF41A564), // GREEN for success
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String _generateJoinCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  double _getZoomForRadius(double radius) {
    if (radius <= 50) return 18.0;
    if (radius <= 75) return 17.5;
    if (radius <= 100) return 17.0;
    return 16.5;
  }

  Future<void> _captureClassroomLocation() async {
    setState(() => _isGettingLocation = true);
    try {
      final Position position = await LocationService.getCurrentPosition();
      if (mounted) {
        setState(() {
          _classLatitude = position.latitude;
          _classLongitude = position.longitude;
          _isCustomGpsCaptured = true;
        });

        // Center map on newly captured position
        _mapController.move(
          LatLng(position.latitude, position.longitude),
          _getZoomForRadius(_allowedRadiusMeters),
        );

        _showNotification('Classroom GPS captured successfully!',
            isError: false);
      }
    } catch (e) {
      _showNotification(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isGettingLocation = false);
    }
  }

  String _formattedScheduleString() {
    if (_selectedSchedules.isEmpty) return 'No schedule set';
    return _selectedSchedules.map((s) => s.formattedSchedule).join(', ');
  }

  Future<void> _saveClass() async {
    final code = _codeController.text.trim();
    final course = _courseController.text.trim();
    final name = _nameController.text.trim();
    final section = _sectionController.text.trim();

    if (code.isEmpty || course.isEmpty || name.isEmpty || section.isEmpty) {
      _showNotification('Please fill in all course fields.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception("User session expired.");

      final joinCode = _generateJoinCode();

      final Map<String, dynamic> classData = {
        'faculty_id': userId,
        'course_code': code,
        'course_name': '$course - $name',
        'schedule': _formattedScheduleString(),
        'section': section,
        'latitude': _classLatitude,
        'longitude': _classLongitude,
        'radius_meters': _allowedRadiusMeters,
        'join_code': joinCode,
      };

      final newClass =
          await _supabase.from('classes').insert(classData).select().single();

      if (mounted) {
        _showNotification('Class created! Join Code: $joinCode',
            isError: false);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => FacultyClassDetailScreen(classData: newClass),
          ),
        );
      }
    } catch (e) {
      _showNotification('Error creating class: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        backgroundColor: AppColors.primaryBlue,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        automaticallyImplyLeading: false,
        title: Image.asset(
          'assets/images/logo_home.png',
          height: 90,
          fit: BoxFit.contain,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none, size: 20),
            onPressed: () {
              _showNotification('No new notifications', isError: false);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          // MAIN FORM CONTENT
          SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(10, 16, 18, 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // PAGE TITLE & BACK ARROW
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        color: AppColors.primaryBlue,
                        size: 22,
                      ),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Create Class',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                            ),
                          ),
                          Text(
                            'Configure course info, schedule, and scan geofence.',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // SECTION 1: COURSE DETAILS
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: _buildSectionHeader('COURSE DETAILS'),
                ),
                const SizedBox(height: 12),

                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Column(
                    children: [
                      _buildTextField(
                        controller: _codeController,
                        label: 'Subject Code',
                        hint: 'e.g. CS101',
                        icon: Icons.code_rounded,
                      ),
                      const SizedBox(height: 14),
                      _buildTextField(
                        controller: _courseController,
                        label: 'Course Program',
                        hint: 'e.g. BSIT',
                        icon: Icons.school_outlined,
                      ),
                      const SizedBox(height: 14),
                      _buildTextField(
                        controller: _nameController,
                        label: 'Course Title / Name',
                        hint: 'e.g. Mobile Programming',
                        icon: Icons.book_outlined,
                      ),
                      const SizedBox(height: 14),
                      _buildTextField(
                        controller: _sectionController,
                        label: 'Section',
                        hint: 'e.g. 101',
                        icon: Icons.class_outlined,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // SECTION 2: CLASS SCHEDULE
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: _buildSectionHeader('CLASS SCHEDULE'),
                ),
                const SizedBox(height: 12),

                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _weekDays.map((day) {
                      final isSelected =
                          _selectedSchedules.any((s) => s.day == day);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedSchedules
                                  .removeWhere((s) => s.day == day);
                            } else {
                              _selectedSchedules
                                  .add(ClassDaySchedule(day: day));
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primaryBlue
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primaryBlue
                                  : Colors.grey.shade300,
                              width: 1.5,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppColors.primaryBlue
                                          .withValues(alpha: 0.25),
                                      blurRadius: 6,
                                      offset: const Offset(0, 3),
                                    )
                                  ]
                                : [],
                          ),
                          child: Text(
                            day,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade700,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),

                // INLINE TIME SELECTORS
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: Column(
                      children: [
                        if (_selectedSchedules.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          ..._selectedSchedules.map((schedule) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
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
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEFF6FF),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'Schedule for ${schedule.day}',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildInlineTimePicker(
                                          title: 'Start Time',
                                          hour: schedule.startHour,
                                          minute: schedule.startMinute,
                                          period: schedule.startPeriod,
                                          onHourChanged: (h) => setState(
                                              () => schedule.startHour = h),
                                          onMinuteChanged: (m) => setState(
                                              () => schedule.startMinute = m),
                                          onPeriodChanged: (p) => setState(
                                              () => schedule.startPeriod = p),
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 6.0),
                                        child: Icon(Icons.arrow_forward_rounded,
                                            size: 16, color: Colors.grey),
                                      ),
                                      Expanded(
                                        child: _buildInlineTimePicker(
                                          title: 'End Time',
                                          hour: schedule.endHour,
                                          minute: schedule.endMinute,
                                          period: schedule.endPeriod,
                                          onHourChanged: (h) => setState(
                                              () => schedule.endHour = h),
                                          onMinuteChanged: (m) => setState(
                                              () => schedule.endMinute = m),
                                          onPeriodChanged: (p) => setState(
                                              () => schedule.endPeriod = p),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // SECTION 3: GEOFENCING & LOCATION WITH DEFAULT STI COLLEGE DAVAO MAP
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: _buildSectionHeader('GEOFENCING & LOCATION'),
                ),
                const SizedBox(height: 12),

                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Container(
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
                              'Allowed Scan Radius',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<double>(
                                  value: _allowedRadiusMeters,
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlue,
                                  ),
                                  items: [50.0, 75.0, 100.0, 150.0].map((r) {
                                    return DropdownMenuItem<double>(
                                      value: r,
                                      child: Text('${r.round()} Meters'),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setState(() {
                                        _allowedRadiusMeters = val;
                                        _mapController.move(
                                          LatLng(
                                              _classLatitude, _classLongitude),
                                          _getZoomForRadius(val),
                                        );
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // GPS CAPTURE BUTTON
                        InkWell(
                          onTap: _isGettingLocation
                              ? null
                              : _captureClassroomLocation,
                          borderRadius: BorderRadius.circular(12),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: _isCustomGpsCaptured
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _isCustomGpsCaptured
                                    ? AppColors.primaryBlue
                                    : Colors.grey.shade300,
                                width: _isCustomGpsCaptured ? 1.5 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _isCustomGpsCaptured
                                      ? Icons.my_location_rounded
                                      : Icons.location_searching_rounded,
                                  color: AppColors.primaryBlue,
                                  size: 24,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _isCustomGpsCaptured
                                        ? 'GPS Set: ${_classLatitude.toStringAsFixed(4)}, ${_classLongitude.toStringAsFixed(4)}'
                                        : 'Tap to update GPS with live classroom location',
                                    style: GoogleFonts.poppins(
                                      fontSize: 11,
                                      fontWeight: _isCustomGpsCaptured
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                                ),
                                if (_isGettingLocation)
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // MAP VIEW DEFAULTING TO STI COLLEGE DAVAO
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            height: 220,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Stack(
                              children: [
                                FlutterMap(
                                  mapController: _mapController,
                                  options: MapOptions(
                                    initialCenter:
                                        LatLng(_classLatitude, _classLongitude),
                                    initialZoom:
                                        _getZoomForRadius(_allowedRadiusMeters),
                                    minZoom: 14.0,
                                    maxZoom: 19.0,
                                  ),
                                  children: [
                                    TileLayer(
                                      urlTemplate:
                                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                      userAgentPackageName:
                                          'com.classkeeper.app',
                                    ),
                                    // GEOFENCE RADIUS CIRCLE
                                    CircleLayer(
                                      circles: [
                                        CircleMarker(
                                          point: LatLng(
                                              _classLatitude, _classLongitude),
                                          radius: _allowedRadiusMeters,
                                          useRadiusInMeter: true,
                                          color: AppColors.primaryBlue
                                              .withValues(alpha: 0.2),
                                          borderColor: AppColors.primaryBlue,
                                          borderStrokeWidth: 2.5,
                                        ),
                                      ],
                                    ),
                                    // CLASSROOM CENTER MARKER
                                    MarkerLayer(
                                      markers: [
                                        Marker(
                                          point: LatLng(
                                              _classLatitude, _classLongitude),
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

                                // LOCATION BADGE
                                Positioned(
                                  top: 10,
                                  left: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.12),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.school_rounded,
                                            size: 13,
                                            color: AppColors.primaryBlue),
                                        const SizedBox(width: 5),
                                        Text(
                                          _isCustomGpsCaptured
                                              ? 'Custom Location'
                                              : 'STI College Davao',
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.primaryBlue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                                // TOP-RIGHT RADIUS OVERLAY BADGE
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.12),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: AppColors.primaryBlue,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Radius Zone: ${_allowedRadiusMeters.round()}m',
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.primaryBlue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                                // BOTTOM-RIGHT RECENTER BUTTON
                                Positioned(
                                  bottom: 10,
                                  right: 10,
                                  child: FloatingActionButton.small(
                                    heroTag: 'recenter_map',
                                    backgroundColor: Colors.white,
                                    foregroundColor: AppColors.primaryBlue,
                                    elevation: 3,
                                    onPressed: () {
                                      _mapController.move(
                                        LatLng(_classLatitude, _classLongitude),
                                        _getZoomForRadius(_allowedRadiusMeters),
                                      );
                                    },
                                    child: const Icon(
                                        Icons.center_focus_strong_rounded,
                                        size: 18),
                                  ),
                                ),
                              ],
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

          // FLOATING SAVE BUTTON
          Positioned(
            left: 18,
            right: 18,
            bottom: 18,
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryBlue.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveClass,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryBlue,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        'Save Class & Generate Join Code',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
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

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            style:
                GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.poppins(
                  fontSize: 12, color: Colors.grey.shade400),
              prefixIcon: Icon(icon, size: 26, color: AppColors.primaryBlue),
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.primaryBlue, width: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInlineTimePicker({
    required String title,
    required int hour,
    required int minute,
    required String period,
    required ValueChanged<int> onHourChanged,
    required ValueChanged<int> onMinuteChanged,
    required ValueChanged<String> onPeriodChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: hour,
                  isDense: true,
                  style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue),
                  items: List.generate(12, (i) => i + 1).map((h) {
                    return DropdownMenuItem<int>(
                        value: h, child: Text(h.toString().padLeft(2, '0')));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) onHourChanged(val);
                  },
                ),
              ),
              Text(':',
                  style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey)),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: minute,
                  isDense: true,
                  style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue),
                  items: [0, 15, 30, 45].map((m) {
                    return DropdownMenuItem<int>(
                        value: m, child: Text(m.toString().padLeft(2, '0')));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) onMinuteChanged(val);
                  },
                ),
              ),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: period,
                  isDense: true,
                  style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlue),
                  items: ['AM', 'PM'].map((p) {
                    return DropdownMenuItem<String>(value: p, child: Text(p));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) onPeriodChanged(val);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
