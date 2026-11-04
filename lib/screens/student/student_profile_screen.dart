import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../constants/app_typography.dart';
import '../login_screen.dart';

/// Student Entity Model matching Supabase schema
class StudentData {
  final String id;
  String firstName;
  String lastName;
  String email;
  String? avatarUrl;
  File? localProfileImage;
  int enrolledCourses;
  double avgAttendance;
  int sessionsAttended;

  String get fullName => '$firstName $lastName'.trim();

  StudentData({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.avatarUrl,
    this.localProfileImage,
    this.enrolledCourses = 0,
    this.avgAttendance = 0.0,
    this.sessionsAttended = 0,
  });
}

class StudentProfileScreen extends StatefulWidget {
  final StudentData? loggedInStudent;
  final String? studentId;

  const StudentProfileScreen({
    super.key,
    this.loggedInStudent,
    this.studentId,
  });

  @override
  State<StudentProfileScreen> createState() => _StudentProfileScreenState();
}

class _StudentProfileScreenState extends State<StudentProfileScreen> {
  final _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  late StudentData _student;
  bool _isLoading = true;
  Uint8List? _localImageBytes;

  @override
  void initState() {
    super.initState();
    _student = StudentData(
      id: widget.studentId ?? 'N/A',
      firstName: 'Loading...',
      lastName: '',
      email: '',
    );
    _fetchProfileFromSupabase();
  }

  /// Fetches profile metadata and active class attendance stats from Supabase
  Future<void> _fetchProfileFromSupabase() async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _student = StudentData(
            id: 'N/A',
            firstName: 'Guest',
            lastName: 'User',
            email: 'Not Logged In',
          );
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    final String userEmail = user.email ?? 'No Email';
    String fullName = user.userMetadata?['full_name'] ??
        user.userMetadata?['name'] ??
        userEmail.split('@').first;
    String schoolId = widget.studentId ?? user.id.substring(0, 8).toUpperCase();
    String? avatarUrl;

    int activeEnrolledCount = 0;
    int sessionsAttended = 0;
    double avgAttendance = 0.0;

    // 1. Fetch Profile Metadata
    try {
      final profileRes = await _supabase
          .from('profiles')
          .select('full_name, school_id, avatar_url')
          .eq('id', user.id)
          .maybeSingle();

      if (profileRes != null) {
        fullName = profileRes['full_name'] as String? ?? fullName;
        schoolId = profileRes['school_id']?.toString() ?? schoolId;
        avatarUrl = profileRes['avatar_url'] as String?;
      }
    } catch (e) {
      debugPrint('Profiles table fetch error: $e');
    }

    // 2. Fetch Active Enrolled Classes (excluding archived classes)
    List<String> activeClassIds = [];
    try {
      final List<dynamic> enrollmentsRes = await _supabase
          .from('class_enrollments')
          .select('class_id, classes!inner(id, is_archived)')
          .eq('student_id', user.id)
          .eq('classes.is_archived', false);

      activeEnrolledCount = enrollmentsRes.length;
      activeClassIds =
          enrollmentsRes.map((item) => item['class_id'].toString()).toList();
    } catch (e) {
      debugPrint('Class enrollments table fetch error: $e');
    }

    // 3. Compute Attendance Rate and Attended Sessions for Active Classes
    try {
      if (activeClassIds.isNotEmpty) {
        final List<dynamic> attendanceRes = await _supabase
            .from('attendance_records')
            .select('id, status, attendance_sessions!inner(class_id)')
            .eq('student_id', user.id)
            .inFilter('attendance_sessions.class_id', activeClassIds);

        final totalLogs = attendanceRes.length;
        for (final log in attendanceRes) {
          if (log is Map && log['status'] != null) {
            final s = log['status'].toString().toLowerCase();
            if (s == 'present' || s == 'late') {
              sessionsAttended++;
            }
          }
        }

        if (totalLogs > 0) {
          avgAttendance = (sessionsAttended / totalLogs) * 100;
        }
      }
    } catch (e) {
      debugPrint('Attendance records table fetch error: $e');
    }

    final nameParts = fullName.trim().split(' ');
    final firstName = nameParts.first;
    final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    if (mounted) {
      setState(() {
        _student = StudentData(
          id: schoolId,
          firstName: firstName,
          lastName: lastName,
          email: userEmail,
          avatarUrl: avatarUrl,
          enrolledCourses: activeEnrolledCount,
          avgAttendance: avgAttendance,
          sessionsAttended: sessionsAttended,
        );
        _isLoading = false;
      });
    }
  }

  /// Upload Avatar Photo to Supabase Storage
  Future<void> _pickAndUploadImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      final Uint8List imageBytes = await pickedFile.readAsBytes();
      setState(() => _localImageBytes = imageBytes);

      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final fileName = pickedFile.name;
      final fileExt = fileName.contains('.') ? fileName.split('.').last : 'png';
      final filePath = '${user.id}/avatar.$fileExt';

      await _supabase.storage.from('avatars').uploadBinary(
            filePath,
            imageBytes,
            fileOptions: const FileOptions(upsert: true),
          );

      final publicUrl =
          _supabase.storage.from('avatars').getPublicUrl(filePath);
      final updatedUrl =
          '$publicUrl?v=${DateTime.now().millisecondsSinceEpoch}';

      await _supabase
          .from('profiles')
          .update({'avatar_url': updatedUrl}).eq('id', user.id);

      if (mounted) {
        setState(() => _student.avatarUrl = updatedUrl);
        _showSnackBar('Profile picture updated successfully!');
      }
    } catch (e) {
      _showSnackBar('Failed to upload image: $e', isError: true);
    }
  }

  void _showSnackBar(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: GoogleFonts.poppins(fontSize: 12)),
        backgroundColor: isError ? Colors.red.shade600 : AppColors.primaryBlue,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showEditProfileBottomSheet() async {
    final nameController = TextEditingController(text: _student.fullName);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            void showImageSourceSelector() {
              showModalBottomSheet(
                context: modalContext,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (pickerContext) => Container(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Select Profile Photo',
                        style: AppTypography.titleMedium
                            .copyWith(color: AppColors.primaryBlue),
                      ),
                      const SizedBox(height: 16),
                      ListTile(
                        leading: const Icon(Icons.photo_library_outlined,
                            color: AppColors.primaryBlue),
                        title: Text('Choose from Gallery',
                            style: AppTypography.bodyMedium),
                        onTap: () {
                          Navigator.pop(pickerContext);
                          _pickAndUploadImage(ImageSource.gallery);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.camera_alt_outlined,
                            color: AppColors.primaryBlue),
                        title: Text('Take a Photo',
                            style: AppTypography.bodyMedium),
                        onTap: () {
                          Navigator.pop(pickerContext);
                          _pickAndUploadImage(ImageSource.camera);
                        },
                      ),
                    ],
                  ),
                ),
              );
            }

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 12,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Edit Profile', style: AppTypography.headerLarge),
                    Text('Update your photo and personal details',
                        style: AppTypography.bodySmall),
                    const SizedBox(height: 24),
                    Center(
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primaryBlue
                                    .withValues(alpha: 0.2),
                                width: 2,
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 46,
                              backgroundColor: const Color(0xFFE0ECFF),
                              backgroundImage: _localImageBytes != null
                                  ? MemoryImage(_localImageBytes!)
                                  : (_student.avatarUrl != null
                                      ? NetworkImage(_student.avatarUrl!)
                                      : null) as ImageProvider?,
                              child: (_localImageBytes == null &&
                                      _student.avatarUrl == null)
                                  ? const Icon(Icons.person,
                                      size: 52, color: AppColors.primaryBlue)
                                  : null,
                            ),
                          ),
                          Positioned(
                            bottom: 2,
                            right: 2,
                            child: InkWell(
                              onTap: showImageSourceSelector,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryBlue,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.white, width: 2),
                                ),
                                child: const Icon(Icons.camera_alt_rounded,
                                    color: Colors.white, size: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildInputField(
                      label: 'FULL NAME',
                      controller: nameController,
                      icon: Icons.person_outline_rounded,
                    ),
                    const SizedBox(height: 16),
                    _buildInputField(
                      label: 'EMAIL ADDRESS',
                      initialValue: _student.email,
                      icon: Icons.email_outlined,
                      isReadOnly: true,
                    ),
                    const SizedBox(height: 16),
                    _buildInputField(
                      label: 'STUDENT ID',
                      initialValue: _student.id,
                      icon: Icons.badge_outlined,
                      isReadOnly: true,
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () async {
                          final newFullName = nameController.text.trim();
                          final user = _supabase.auth.currentUser;

                          if (user != null && newFullName.isNotEmpty) {
                            try {
                              await _supabase.from('profiles').upsert({
                                'id': user.id,
                                'full_name': newFullName,
                              });
                            } catch (e) {
                              debugPrint('Error updating profile in DB: $e');
                            }
                          }

                          if (!mounted) return;

                          final nameParts = newFullName.split(' ');
                          setState(() {
                            _student.firstName = nameParts.first;
                            _student.lastName = nameParts.length > 1
                                ? nameParts.sublist(1).join(' ')
                                : '';
                          });

                          if (modalContext.mounted) {
                            Navigator.pop(modalContext);
                          }

                          _showSnackBar('Profile updated successfully!');
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryBlue,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Text(
                          'Save Changes',
                          style: AppTypography.bodyMedium.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? imageProvider;
    if (_localImageBytes != null) {
      imageProvider = MemoryImage(_localImageBytes!);
    } else if (_student.avatarUrl != null && _student.avatarUrl!.isNotEmpty) {
      imageProvider = NetworkImage(_student.avatarUrl!);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _fetchProfileFromSupabase,
          color: AppColors.primaryBlue,
          child: _isLoading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppColors.primaryBlue),
                )
              : SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.only(
                      left: 20, right: 20, top: 24, bottom: 100),
                  child: Column(
                    children: [
                      // --- AVATAR & USER DETAILS ---
                      Center(
                        child: Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFFD0D7E2), width: 2),
                              ),
                              child: CircleAvatar(
                                radius: 54,
                                backgroundColor: const Color(0xFFE8EEF7),
                                backgroundImage: imageProvider,
                                child: imageProvider == null
                                    ? const Icon(Icons.person_rounded,
                                        size: 64, color: AppColors.primaryBlue)
                                    : null,
                              ),
                            ),
                            Positioned(
                              bottom: 4,
                              right: 4,
                              child: InkWell(
                                onTap: _showEditProfileBottomSheet,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryBlue,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded,
                                      color: Colors.white, size: 14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(_student.fullName, style: AppTypography.headerLarge),
                      const SizedBox(height: 2),
                      Text(_student.email, style: AppTypography.bodySmall),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.primaryBlue.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Student ID: ${_student.id}',
                            style: AppTypography.badgeText),
                      ),

                      const SizedBox(height: 24),

                      // --- DYNAMIC STATS OVERVIEW CARD ---
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            _buildStatItem('${_student.enrolledCourses}',
                                'Enrolled Courses'),
                            _buildStatDivider(),
                            _buildStatItem(
                                '${_student.avgAttendance.toStringAsFixed(0)}%',
                                'Avg Attendance'),
                            _buildStatDivider(),
                            _buildStatItem('${_student.sessionsAttended}',
                                'Sessions Attended'),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // --- MENU CARD ---
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            _buildMenuItem(
                              icon: Icons.edit_outlined,
                              title: 'Edit Profile Details',
                              subtitle: 'Update full name and personal details',
                              onTap: _showEditProfileBottomSheet,
                            ),
                            Divider(
                                height: 1,
                                thickness: 0.8,
                                color: Colors.grey.shade100),
                            _buildMenuItem(
                              icon: Icons.lock_outline_rounded,
                              title: 'Change Password',
                              subtitle: 'Send password reset email',
                              onTap: () async {
                                if (_student.email.isNotEmpty) {
                                  await _supabase.auth
                                      .resetPasswordForEmail(_student.email);
                                  _showSnackBar(
                                      'Password reset email sent to ${_student.email}');
                                }
                              },
                            ),
                            Divider(
                                height: 1,
                                thickness: 0.8,
                                color: Colors.grey.shade100),
                            _buildMenuItem(
                              icon: Icons.logout_rounded,
                              title: 'Logout',
                              subtitle: 'Sign out of your account',
                              isDestructive: true,
                              onTap: () async {
                                final shouldLogout = await showDialog<bool>(
                                  context: context,
                                  builder: (dialogContext) => Dialog(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Container(
                                      width: 290,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 22),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'Logout',
                                            style: AppTypography.titleMedium
                                                .copyWith(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 18,
                                              color: const Color(0xFF0D253F),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            'Are you sure you want to log out?',
                                            textAlign: TextAlign.center,
                                            style: AppTypography.bodySmall
                                                .copyWith(
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          const SizedBox(height: 20),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogContext, false),
                                                  style: TextButton.styleFrom(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                                  ),
                                                  child: Text(
                                                    'Cancel',
                                                    style: AppTypography
                                                        .bodySmall
                                                        .copyWith(
                                                      color:
                                                          Colors.grey.shade600,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: ElevatedButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogContext, true),
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.red.shade600,
                                                    elevation: 0,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                                    shape:
                                                        RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    'Logout',
                                                    style: AppTypography
                                                        .bodySmall
                                                        .copyWith(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
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

                                if (shouldLogout == true && context.mounted) {
                                  await _supabase.auth.signOut();
                                  if (context.mounted) {
                                    Navigator.of(context).pushAndRemoveUntil(
                                      MaterialPageRoute(
                                          builder: (context) =>
                                              const LoginScreen()),
                                      (route) => false,
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildStatItem(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: AppTypography.statValue),
          const SizedBox(height: 2),
          Text(label,
              style: AppTypography.statLabel, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildStatDivider() {
    return Container(height: 28, width: 1, color: Colors.grey.shade200);
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final iconBgColor =
        isDestructive ? const Color(0xFFFFEAEA) : const Color(0xFFF0F4F9);
    final iconColor =
        isDestructive ? Colors.red.shade600 : AppColors.primaryBlue;
    final titleColor = isDestructive ? Colors.red.shade600 : Colors.black87;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: iconBgColor, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, size: 20, color: iconColor),
      ),
      title: Text(title,
          style: AppTypography.titleMedium.copyWith(color: titleColor)),
      subtitle: Text(subtitle, style: AppTypography.bodySmall),
      trailing: Icon(Icons.chevron_right_rounded,
          color: Colors.grey.shade400, size: 20),
    );
  }

  Widget _buildInputField({
    required String label,
    TextEditingController? controller,
    String? initialValue,
    required IconData icon,
    bool isReadOnly = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.labelUppercase),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          initialValue: controller == null ? initialValue : null,
          readOnly: isReadOnly,
          keyboardType: keyboardType,
          style: AppTypography.bodyMedium.copyWith(
            color: isReadOnly ? Colors.grey.shade600 : Colors.black87,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor:
                isReadOnly ? const Color(0xFFF4F6F9) : Colors.grey.shade50,
            prefixIcon: Icon(
              icon,
              size: 20,
              color: isReadOnly ? Colors.grey.shade400 : AppColors.primaryBlue,
            ),
            suffixIcon: isReadOnly
                ? Icon(Icons.lock_outline_rounded,
                    size: 18, color: Colors.grey.shade400)
                : null,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: AppColors.primaryBlue, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
