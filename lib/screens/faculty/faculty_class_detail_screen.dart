import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';

class FacultyClassDetailScreen extends StatefulWidget {
  final Map<String, dynamic> classData;

  const FacultyClassDetailScreen({super.key, required this.classData});

  @override
  State<FacultyClassDetailScreen> createState() =>
      _FacultyClassDetailScreenState();
}

class _FacultyClassDetailScreenState extends State<FacultyClassDetailScreen> {
  final _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _roster = [];
  bool _isLoadingRoster = true;
  bool _isAddingStudent = false;

  Map<String, dynamic>? _selectedSearchResult;

  @override
  void initState() {
    super.initState();
    _fetchRoster();
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

  Future<void> _fetchRoster() async {
    setState(() => _isLoadingRoster = true);
    try {
      final response = await _supabase
          .from('class_enrollments')
          .select(
              'id, student_id, joined_at, profiles(id, full_name, school_id, email)')
          .eq('class_id', widget.classData['id'])
          .order('joined_at', ascending: true);

      if (mounted) {
        setState(() {
          _roster = List<Map<String, dynamic>>.from(response);
        });
      }
    } catch (e) {
      _showNotification('Failed to load roster: $e');
    } finally {
      if (mounted) setState(() => _isLoadingRoster = false);
    }
  }

  Future<void> _addStudentByProfile(Map<String, dynamic> profile) async {
    // Only students can be enrolled (never faculty accounts)
    if ((profile['role'] ?? '').toString().toLowerCase() != 'student') {
      _showNotification('Only students can be added to a class.');
      return;
    }

    final studentUserId = profile['id'];

    final isAlreadyEnrolled = _roster.any(
      (e) => e['profiles'] != null && e['profiles']['id'] == studentUserId,
    );

    if (isAlreadyEnrolled) {
      _showNotification('Student is already in this class.');
      return;
    }

    setState(() => _isAddingStudent = true);

    try {
      await _supabase.from('class_enrollments').insert({
        'class_id': widget.classData['id'],
        'student_id': studentUserId,
      });

      _selectedSearchResult = null;
      await _fetchRoster();
      _showNotification('Added ${profile['full_name']} to class!',
          isError: false);
    } catch (e) {
      _showNotification('Error adding student: $e');
    } finally {
      if (mounted) setState(() => _isAddingStudent = false);
    }
  }

  // --- SAFE JSON & UUID PARSING FOR SCANNED QR BADGES ---
  Future<void> _processScannedStudentBadge(String rawScannedCode) async {
    final scannedCode = rawScannedCode.trim();
    if (scannedCode.isEmpty) return;

    setState(() => _isAddingStudent = true);

    try {
      String? searchId;
      String? searchSchoolId;
      String? searchEmail;

      // 1. Try parsing JSON if the payload is structured JSON
      if (scannedCode.startsWith('{') && scannedCode.endsWith('}')) {
        try {
          final Map<String, dynamic> parsedJson = jsonDecode(scannedCode);
          searchId = parsedJson['id']?.toString() ??
              parsedJson['student_id']?.toString() ??
              parsedJson['userId']?.toString();
          searchSchoolId = parsedJson['studentId']?.toString() ??
              parsedJson['school_id']?.toString() ??
              parsedJson['schoolId']?.toString();
          searchEmail = parsedJson['email']?.toString();
        } catch (_) {
          // Not valid JSON, treat as plain text
        }
      }

      Map<String, dynamic>? studentProfile;

      // 2. Query using extracted JSON fields
      if (searchSchoolId != null || searchEmail != null || searchId != null) {
        final List<String> conditions = [];
        if (searchId != null && searchId.isNotEmpty) {
          conditions.add('id.eq.$searchId');
        }
        if (searchSchoolId != null && searchSchoolId.isNotEmpty) {
          conditions.add('school_id.eq.$searchSchoolId');
        }
        if (searchEmail != null && searchEmail.isNotEmpty) {
          conditions.add('email.eq.$searchEmail');
        }

        if (conditions.isNotEmpty) {
          studentProfile = await _supabase
              .from('profiles')
              .select('id, full_name, school_id, email, role')
              .eq('role', 'student')
              .or(conditions.join(','))
              .limit(1)
              .maybeSingle();
        }
      }

      // 3. Fallback query for plain text (School ID / Email / UUID)
      if (studentProfile == null) {
        final bool isUuid = RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(scannedCode);

        final List<String> fallbackConditions = [
          'school_id.eq.$scannedCode',
          'email.eq.$scannedCode',
        ];
        if (isUuid) {
          fallbackConditions.add('id.eq.$scannedCode');
        }

        studentProfile = await _supabase
            .from('profiles')
            .select('id, full_name, school_id, email, role')
            .eq('role', 'student')
            .or(fallbackConditions.join(','))
            .limit(1)
            .maybeSingle();
      }

      if (studentProfile == null) {
        _showNotification(
            'No student found matching this QR code badge.\nOnly student accounts can be added.');
        return;
      }

      await _addStudentByProfile(studentProfile);
    } catch (e) {
      _showNotification('Error processing QR badge: $e');
    } finally {
      if (mounted) setState(() => _isAddingStudent = false);
    }
  }

  // --- LIVE STUDENT BADGE QR CAMERA SCANNER DIALOG ---
  void _openStudentBadgeScanner() {
    bool hasScanned = false;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: Colors.white,
        child: Container(
          padding: const EdgeInsets.all(20),
          constraints: const BoxConstraints(maxWidth: 340, maxHeight: 420),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Scan Student Badge QR',
                        style: GoogleFonts.poppins(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      Text(
                        'Point camera at student\'s badge QR',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded,
                        size: 20, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: MobileScanner(
                    onDetect: (capture) {
                      if (hasScanned) return;
                      final List<Barcode> barcodes = capture.barcodes;
                      for (final barcode in barcodes) {
                        final String? codeValue = barcode.rawValue;
                        if (codeValue != null && codeValue.trim().isNotEmpty) {
                          hasScanned = true;
                          Navigator.pop(ctx);
                          _processScannedStudentBadge(codeValue);
                          break;
                        }
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Position the QR code inside the frame to automatically add student.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeStudent(String enrollmentId, String studentName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Remove Student',
            style:
                GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text('Remove $studentName from this class?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _supabase.from('class_enrollments').delete().eq('id', enrollmentId);
      await _fetchRoster();
      _showNotification('Removed $studentName.', isError: false);
    } catch (e) {
      _showNotification('Failed to remove student: $e');
    }
  }

  // --- CLASS JOIN QR DIALOG WITH STANDARD BLACK QR ---
  void _showJoinQrDialog(String rawJoinCode) {
    final joinCode =
        (rawJoinCode.isEmpty || rawJoinCode == 'N/A') ? 'NO-CODE' : rawJoinCode;
    final courseCode = widget.classData['course_code'] ?? '';
    final section = widget.classData['section'] ?? '';

    final subtitleText = courseCode.isNotEmpty
        ? '$courseCode${section.isNotEmpty ? " - Section $section" : ""}'
        : 'Scan to join class';

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        elevation: 8,
        backgroundColor: Colors.white,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Dialog Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Class QR Code',
                          style: GoogleFonts.poppins(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF0F2552),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleText,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.of(ctx).pop(),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Standard Black & White QR Code Container
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(24),
                  border:
                      Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                ),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: joinCode,
                    version: QrVersions.auto,
                    size: 180.0,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Student Join Code Label
              Text(
                'STUDENT JOIN CODE',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 8),

              // Join Code Badge
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFBFDBFE), width: 1),
                ),
                child: Center(
                  child: Text(
                    joinCode,
                    style: GoogleFonts.poppins(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4.0,
                      color: const Color(0xFF0F2552),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Helper Text
              Text(
                'Students can scan this QR using the ClassKeeper app or manually type the code.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 20),

              // Done Button
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F2552),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Done',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
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

  @override
  Widget build(BuildContext context) {
    final courseCode = widget.classData['course_code'] ?? '';
    final courseName = widget.classData['course_name'] ?? '';
    final section = widget.classData['section'] ?? '';
    final schedule = widget.classData['schedule'] ?? '';
    final joinCode = (widget.classData['join_code'] != null &&
            widget.classData['join_code'].toString().isNotEmpty)
        ? widget.classData['join_code'].toString()
        : 'N/A';

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
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 16, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // BACK ARROW & CLASS TITLE
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
                        courseCode,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      Text(
                        '$courseName - Section $section',
                        style: GoogleFonts.poppins(
                            fontSize: 11, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // SUMMARY CARD
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Container(
                width: double.infinity,
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
                      children: [
                        const Icon(Icons.access_time,
                            size: 14, color: Colors.grey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            schedule,
                            style: GoogleFonts.poppins(
                                fontSize: 11, color: Colors.grey.shade600),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('JOIN CODE',
                                style: GoogleFonts.poppins(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey)),
                            Text(joinCode,
                                style: GoogleFonts.poppins(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlue,
                                    letterSpacing: 2)),
                          ],
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _showJoinQrDialog(joinCode),
                          icon: const Icon(Icons.qr_code,
                              size: 16, color: Colors.white),
                          label: Text('Show QR',
                              style: GoogleFonts.poppins(
                                  fontSize: 11, color: Colors.white)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryBlue,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // SEARCH AND ADD STUDENT
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text(
                'SEARCH AND ADD STUDENT',
                style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                    letterSpacing: 0.8),
              ),
            ),
            const SizedBox(height: 8),

            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: Autocomplete<Map<String, dynamic>>(
                      displayStringForOption: (option) =>
                          '${option['full_name']} (${option['email'] ?? option['school_id'] ?? ''})',
                      optionsBuilder:
                          (TextEditingValue textEditingValue) async {
                        final query = textEditingValue.text.trim();
                        if (query.length < 2)
                          return const Iterable<Map<String, dynamic>>.empty();

                        try {
                          final results = await _supabase
                              .from('profiles')
                              .select('id, full_name, school_id, email, role')
                              .eq('role',
                                  'student') // students only, no faculty
                              .or('full_name.ilike.%$query%,school_id.ilike.%$query%,email.ilike.%$query%')
                              .limit(5);

                          return List<Map<String, dynamic>>.from(
                              results as List);
                        } catch (_) {
                          return const Iterable<Map<String, dynamic>>.empty();
                        }
                      },
                      onSelected: (selection) {
                        setState(() => _selectedSearchResult = selection);
                      },
                      fieldViewBuilder:
                          (context, controller, focusNode, onEditingComplete) {
                        return Container(
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
                            controller: controller,
                            focusNode: focusNode,
                            style: GoogleFonts.poppins(
                                fontSize: 12, fontWeight: FontWeight.w500),
                            decoration: InputDecoration(
                              hintText: 'Search name, ID, or email...',
                              hintStyle: GoogleFonts.poppins(
                                  fontSize: 12, color: Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.search_rounded,
                                  size: 20, color: AppColors.primaryBlue),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    BorderSide(color: Colors.grey.shade200),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                    color: AppColors.primaryBlue, width: 1.5),
                              ),
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
                              width: MediaQuery.of(context).size.width - 120,
                              constraints: const BoxConstraints(maxHeight: 240),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: ListView.separated(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
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
                                          horizontal: 12, vertical: 10),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 15,
                                            backgroundColor:
                                                const Color(0xFFEFF6FF),
                                            child: Text(
                                              name.isNotEmpty
                                                  ? name[0].toUpperCase()
                                                  : 'S',
                                              style: GoogleFonts.poppins(
                                                fontSize: 11,
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
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.grey.shade800,
                                                  ),
                                                ),
                                                Text(
                                                  'ID: $schoolId ${email.isNotEmpty ? "• $email" : ""}',
                                                  style: GoogleFonts.poppins(
                                                    fontSize: 10,
                                                    color: Colors.grey.shade500,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                  ),
                  const SizedBox(width: 8),

                  // SCAN BADGE BUTTON
                  IconButton(
                    onPressed: _openStudentBadgeScanner,
                    icon: const Icon(Icons.qr_code_scanner_rounded,
                        color: AppColors.primaryBlue),
                    tooltip: 'Scan Student Badge QR',
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFEFF6FF),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // ADD BUTTON
                  ElevatedButton(
                    onPressed: (_selectedSearchResult == null ||
                            _isAddingStudent)
                        ? null
                        : () => _addStudentByProfile(_selectedSearchResult!),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                    ),
                    child: _isAddingStudent
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : Text('Add',
                            style: GoogleFonts.poppins(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ENROLLED STUDENTS LIST
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text(
                'ENROLLED STUDENTS (${_roster.length})',
                style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                    letterSpacing: 0.8),
              ),
            ),
            const SizedBox(height: 10),

            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: _isLoadingRoster
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator()))
                  : _roster.isEmpty
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.group_off_outlined,
                                  size: 40, color: Colors.grey),
                              const SizedBox(height: 8),
                              Text(
                                'No students yet',
                                style: GoogleFonts.poppins(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Add students using one of the options below:',
                                style: GoogleFonts.poppins(
                                    fontSize: 11, color: Colors.grey.shade500),
                              ),
                              const SizedBox(height: 16),
                              ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: Colors.grey.shade200),
                                ),
                                leading: const Icon(Icons.qr_code_scanner,
                                    color: AppColors.primaryBlue),
                                title: Text('Scan Student Badge QR',
                                    style: GoogleFonts.poppins(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                    'Scan student\'s personal badge QR code to enroll instantly.',
                                    style: GoogleFonts.poppins(fontSize: 10)),
                                onTap: _openStudentBadgeScanner,
                              ),
                              const SizedBox(height: 8),
                              ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: Colors.grey.shade200),
                                ),
                                leading: const Icon(Icons.qr_code_rounded,
                                    color: AppColors.primaryBlue),
                                title: Text('Join QR or code',
                                    style: GoogleFonts.poppins(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                    'Students scan or type code "$joinCode" to self-enroll.',
                                    style: GoogleFonts.poppins(fontSize: 10)),
                                onTap: () => _showJoinQrDialog(joinCode),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _roster.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = _roster[index];
                            final profile =
                                item['profiles'] as Map<String, dynamic>?;
                            final name = profile?['full_name'] ?? 'Student';
                            final schoolId = profile?['school_id'] ?? 'N/A';
                            final email = profile?['email'] ?? '';

                            return Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: const Color(0xFFEFF6FF),
                                  child: Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : 'S',
                                    style: GoogleFonts.poppins(
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue),
                                  ),
                                ),
                                title: Text(name,
                                    style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                    'ID: $schoolId ${email.isNotEmpty ? "• $email" : ""}',
                                    style: GoogleFonts.poppins(
                                        fontSize: 10, color: Colors.grey)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.person_remove_outlined,
                                      color: Colors.redAccent, size: 20),
                                  onPressed: () => _removeStudent(
                                      item['id'].toString(), name),
                                ),
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
}
