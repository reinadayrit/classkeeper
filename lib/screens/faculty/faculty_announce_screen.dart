import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../constants/app_colors.dart';

class FacultyAnnounceScreen extends StatefulWidget {
  const FacultyAnnounceScreen({super.key});

  @override
  State<FacultyAnnounceScreen> createState() => _FacultyAnnounceScreenState();
}

class _FacultyAnnounceScreenState extends State<FacultyAnnounceScreen> {
  // PASTE YOUR NEW GEMINI API KEY in place of PASTE_YOUR_GEMINI_API_KEY_HERE
  // (keep the quotes). You can also pass it with --dart-define=GEMINI_KEY=...
  static const String _apiKey = String.fromEnvironment(
    'GEMINI_KEY',
    defaultValue: 'AQ.Ab8RN6KgJv5yG-sTevlTgB_hx3vP3AwSJ5KaZMIzqxJdHDJTbA',
  );

  final TextEditingController _draftController = TextEditingController();
  final TextEditingController _resultController = TextEditingController();

  RealtimeChannel? _realtimeChannel;

  Map<String, String>? _selectedClass;
  bool _isGenerating = false;
  bool _isPosting = false;
  bool _isLoadingClasses = true;
  List<Map<String, String>> _myClasses = [];

  @override
  void initState() {
    super.initState();
    _fetchClasses();
    _setupRealtimeListener();
  }

  // --- SUPABASE REALTIME LISTENER ENGINE ---
  void _setupRealtimeListener() {
    _realtimeChannel = Supabase.instance.client
        .channel('public_faculty_announce_classes_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'classes',
          callback: (payload) {
            debugPrint(
                'Realtime change detected in classes (${payload.eventType}). Refreshing dropdown list...');
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
    _draftController.dispose();
    _resultController.dispose();
    super.dispose();
  }

  // Helper method to format date and time (YYYY-MM-DD • hh:mm AM/PM)
  String _formatTimestamp(String? rawIsoString) {
    if (rawIsoString == null || rawIsoString.trim().isEmpty) return '';
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

  // Styled Toast Alert matching application design
  void _showCustomToast(String text, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        backgroundColor:
            isError ? const Color(0xFFE56B6B) : const Color(0xFF48A868),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.wifi_off_rounded
                  : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Fetch ONLY active classes matching public.classes schema
  Future<void> _fetchClasses() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _isLoadingClasses = false);
        return;
      }

      final response = await Supabase.instance.client
          .from('classes')
          .select('id, course_code, course_name')
          .eq('faculty_id', user.id)
          .eq('is_archived', false)
          .order('created_at', ascending: false);

      final List<Map<String, String>> loadedClasses =
          (response as List).map((item) {
        final String id = item['id'].toString();
        final String code = item['course_code']?.toString() ?? '';
        final String name = item['course_name']?.toString() ?? '';
        final String displayName = code.isNotEmpty ? '$code - $name' : name;

        return {
          'id': id,
          'course_code': code,
          'course_name': name,
          'display_name': displayName,
        };
      }).toList();

      if (mounted) {
        setState(() {
          _myClasses = loadedClasses;

          // Retain current selection if it still exists in updated class list
          if (_selectedClass != null) {
            final exists = _myClasses
                .any((element) => element['id'] == _selectedClass!['id']);
            if (!exists) {
              _selectedClass = null;
            }
          }

          _isLoadingClasses = false;
        });
      }
    } catch (e) {
      final String err = e.toString().toLowerCase();
      final bool isNetworkError = err.contains('socketexception') ||
          err.contains('failed host lookup') ||
          err.contains('clientexception') ||
          err.contains('network');

      _showCustomToast(
        isNetworkError
            ? 'Unable to load classes. Please check your internet connection.'
            : 'Error loading classes: $e',
        isError: true,
      );
      if (mounted) setState(() => _isLoadingClasses = false);
    }
  }

  // Refine text using Gemini AI
  Future<void> _refineWithAI() async {
    if (_draftController.text.trim().isEmpty) {
      _showCustomToast('Please enter a rough draft first.', isError: true);
      return;
    }

    if (_apiKey.isEmpty || _apiKey == 'PASTE_YOUR_GEMINI_API_KEY_HERE') {
      _showCustomToast(
          'AI key is not set. Paste your Gemini API key in faculty_announce_screen.dart.',
          isError: true);
      return;
    }

    setState(() => _isGenerating = true);
    FocusScope.of(context).unfocus();

    try {
      final model = GenerativeModel(
        model: 'gemini-3.6-flash',
        apiKey: _apiKey,
      );

      final String systemPrompt = '''
You are a university professor. Rewrite the following rough notes into a concise, encouraging classroom announcement.
Do not include email subjects or greetings, just the announcement body text.
Notes: ${_draftController.text}
''';

      final content = [Content.text(systemPrompt)];

      final response = await model.generateContent(content).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException(
            'Network request timed out. Please check your connection.',
          );
        },
      );

      if (!mounted) return;

      if (response.text != null && response.text!.isNotEmpty) {
        setState(() {
          _resultController.text = response.text!.trim();
        });
      } else {
        _showCustomToast('No content generated. Please try again.',
            isError: true);
      }
    } on TimeoutException {
      _showCustomToast(
        'Connection timed out. Please check your internet connection.',
        isError: true,
      );
    } catch (e) {
      final String errStr = e.toString().toLowerCase();
      final bool isNetworkIssue = errStr.contains('socketexception') ||
          errStr.contains('failed host lookup') ||
          errStr.contains('clientexception') ||
          errStr.contains('network') ||
          errStr.contains('connection');

      if (isNetworkIssue) {
        _showCustomToast(
          'Network connection error. Please check your internet connection and try again.',
          isError: true,
        );
      } else {
        _showCustomToast('AI Error: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  // Post announcement
  Future<void> _postAnnouncement() async {
    if (_selectedClass == null) {
      _showCustomToast('Please select a target class.', isError: true);
      return;
    }

    if (_resultController.text.trim().isEmpty) {
      _showCustomToast('Please refine your draft before posting.',
          isError: true);
      return;
    }

    setState(() => _isPosting = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;

      await Supabase.instance.client.from('announcements').insert({
        'class_id': _selectedClass!['id'],
        'faculty_id': user?.id,
        'title': '${_selectedClass!['course_code']} Announcement',
        'content': _resultController.text.trim(),
        'created_at': DateTime.now().toIso8601String(),
      });

      _showCustomToast('Announcement broadcasted successfully!');
      if (mounted) {
        setState(() {
          _draftController.clear();
          _resultController.clear();
          _selectedClass = null;
        });
      }
    } catch (e) {
      final String err = e.toString().toLowerCase();
      final bool isNetworkIssue = err.contains('socketexception') ||
          err.contains('failed host lookup') ||
          err.contains('clientexception') ||
          err.contains('network');

      _showCustomToast(
        isNetworkIssue
            ? 'Unable to post. Please check your internet connection.'
            : 'Error broadcasting: $e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isPosting = false);
      }
    }
  }

  // Dialog to Edit existing Announcement with BLUE OUTLINES
  void _showEditDialog(Map<String, dynamic> announcement) {
    final titleController =
        TextEditingController(text: announcement['title'] ?? '');
    final contentController =
        TextEditingController(text: announcement['content'] ?? '');
    bool isUpdating = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                'Edit Announcement',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: AppColors.primaryBlue,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      style: GoogleFonts.poppins(fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'Title',
                        labelStyle: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.primaryBlue,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: contentController,
                      maxLines: 4,
                      style: GoogleFonts.poppins(fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'Content',
                        labelStyle: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.primaryBlue,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: AppColors.primaryBlue, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.poppins(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: isUpdating
                      ? null
                      : () async {
                          final updatedTitle = titleController.text.trim();
                          final updatedContent = contentController.text.trim();

                          if (updatedTitle.isEmpty || updatedContent.isEmpty) {
                            _showCustomToast('Fields cannot be empty',
                                isError: true);
                            return;
                          }

                          setDialogState(() => isUpdating = true);
                          try {
                            await Supabase.instance.client
                                .from('announcements')
                                .update({
                              'title': updatedTitle,
                              'content': updatedContent,
                            }).eq('id', announcement['id']);

                            if (context.mounted) Navigator.pop(context);
                            _showCustomToast('Announcement updated!');
                          } catch (e) {
                            _showCustomToast('Error updating: $e',
                                isError: true);
                          } finally {
                            setDialogState(() => isUpdating = false);
                          }
                        },
                  child: isUpdating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Save Changes',
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Dialog to Delete Announcement
  void _showDeleteDialog(String id) {
    showDialog(
      context: context,
      builder: (context) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                'Delete Announcement',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.redAccent,
                ),
              ),
              content: Text(
                'Are you sure you want to delete this announcement? Students will no longer see it.',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: Colors.grey.shade700,
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.poppins(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: isDeleting
                      ? null
                      : () async {
                          setDialogState(() => isDeleting = true);
                          try {
                            await Supabase.instance.client
                                .from('announcements')
                                .delete()
                                .eq('id', id);

                            if (context.mounted) Navigator.pop(context);
                            _showCustomToast(
                                'Announcement deleted successfully!');
                          } catch (e) {
                            _showCustomToast('Error deleting: $e',
                                isError: true);
                          } finally {
                            setDialogState(() => isDeleting = false);
                          }
                        },
                  child: isDeleting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Delete',
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = Supabase.instance.client.auth.currentUser;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: RefreshIndicator(
        onRefresh: _fetchClasses,
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
                          'AI Announcements',
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Draft a quick note and let AI format it professionally for your students.',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded,
                        color: AppColors.primaryBlue),
                    onPressed: _fetchClasses,
                    tooltip: 'Refresh Classes',
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Target Class Dropdown
              Text(
                'TARGET CLASS',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<Map<String, String>>(
                    isExpanded: true,
                    hint: Text(
                      _isLoadingClasses
                          ? 'Loading your classes...'
                          : _myClasses.isEmpty
                              ? 'No active classes found'
                              : 'Choose a class...',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                    value: _selectedClass,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppColors.primaryBlue,
                      size: 22,
                    ),
                    items: _myClasses.map((Map<String, String> classItem) {
                      return DropdownMenuItem<Map<String, String>>(
                        value: classItem,
                        child: Text(
                          classItem['display_name'] ?? '',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: _myClasses.isEmpty
                        ? null
                        : (val) => setState(() => _selectedClass = val),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Rough Notes Box (Clean Borders)
              Text(
                'ROUGH NOTES',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _draftController,
                maxLines: 3,
                style: GoogleFonts.poppins(fontSize: 12),
                decoration: InputDecoration(
                  hintText:
                      'e.g., Remind students about Friday midterm exam...',
                  hintStyle: GoogleFonts.poppins(
                      fontSize: 12, color: Colors.grey.shade400),
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
                    borderSide: const BorderSide(
                        color: AppColors.primaryBlue, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // AI Refine Action Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isGenerating ? null : _refineWithAI,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome,
                          color: Colors.white, size: 18),
                  label: Text(
                    _isGenerating ? 'Refining...' : 'Refine with AI',
                    style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Result Preview Textfield (Clean Borders)
              Text(
                'FINAL ANNOUNCEMENT',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _resultController,
                maxLines: 4,
                style: GoogleFonts.poppins(fontSize: 12),
                decoration: InputDecoration(
                  hintText:
                      'Your polished broadcast announcement will appear here...',
                  hintStyle: GoogleFonts.poppins(
                      fontSize: 12, color: Colors.grey.shade400),
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
                    borderSide: const BorderSide(
                        color: AppColors.primaryBlue, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Post Broadcast Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isPosting ? null : _postAnnouncement,
                  child: _isPosting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          'Post Announcement',
                          style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                ),
              ),
              const SizedBox(height: 32),

              // REALTIME POSTED ANNOUNCEMENTS LIST
              Text(
                'POSTED ANNOUNCEMENTS',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),

              if (currentUser != null)
                StreamBuilder<List<Map<String, dynamic>>>(
                  stream: Supabase.instance.client
                      .from('announcements')
                      .stream(primaryKey: ['id'])
                      .eq('faculty_id', currentUser.id)
                      .order('created_at', ascending: false),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20.0),
                          child: CircularProgressIndicator(
                            color: AppColors.primaryBlue,
                          ),
                        ),
                      );
                    }

                    final announcements = snapshot.data ?? [];

                    if (announcements.isEmpty) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Center(
                          child: Text(
                            'No posted announcements yet.',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: announcements.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final item = announcements[index];
                        final String title = item['title'] ?? 'Announcement';
                        final String content = item['content'] ?? '';
                        final String createdAt =
                            _formatTimestamp(item['created_at']?.toString());

                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      title,
                                      style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlue,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        constraints: const BoxConstraints(),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                          color: AppColors.primaryBlue,
                                        ),
                                        onPressed: () => _showEditDialog(item),
                                      ),
                                      IconButton(
                                        constraints: const BoxConstraints(),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                          color: Colors.redAccent,
                                        ),
                                        onPressed: () => _showDeleteDialog(
                                          item['id'].toString(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (createdAt.isNotEmpty) ...[
                                Text(
                                  createdAt,
                                  style: GoogleFonts.poppins(
                                    fontSize: 10,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              Text(
                                content,
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                              if ((item['class_id']?.toString() ?? '')
                                  .isNotEmpty) ...[
                                const SizedBox(height: 12),
                                _SeenCounter(
                                  announcementId: item['id'].toString(),
                                  classId: item['class_id'].toString(),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),

              const SizedBox(height: 100),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Seen by X of Y students" chip. Updates live while students open the
/// announcement. Tap it to see who has and has not read it.
class _SeenCounter extends StatefulWidget {
  final String announcementId;
  final String classId;

  const _SeenCounter({
    required this.announcementId,
    required this.classId,
  });

  @override
  State<_SeenCounter> createState() => _SeenCounterState();
}

class _SeenCounterState extends State<_SeenCounter> {
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _loadTotal();
  }

  Future<void> _loadTotal() async {
    try {
      final res = await Supabase.instance.client
          .from('class_enrollments')
          .select('student_id')
          .eq('class_id', widget.classId);
      if (mounted) setState(() => _total = (res as List).length);
    } catch (e) {
      debugPrint('Could not count enrolled students: $e');
    }
  }

  String _formatReadTime(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '';
    final int h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final String period = dt.hour >= 12 ? 'PM' : 'AM';
    final String minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} $h12:$minute $period';
  }

  Future<Map<String, List<Map<String, dynamic>>>> _loadRoster() async {
    final supabase = Supabase.instance.client;

    final enrollments = await supabase
        .from('class_enrollments')
        .select('student_id')
        .eq('class_id', widget.classId);

    final ids =
        (enrollments as List).map((e) => e['student_id'].toString()).toList();

    if (ids.isEmpty) {
      return {
        'seen': <Map<String, dynamic>>[],
        'unseen': <Map<String, dynamic>>[]
      };
    }

    final profiles = await supabase
        .from('profiles')
        .select('id, full_name, school_id')
        .inFilter('id', ids);

    final reads = await supabase
        .from('announcement_reads')
        .select('student_id, read_at')
        .eq('announcement_id', widget.announcementId);

    final Map<String, String> readMap = {};
    for (final r in (reads as List)) {
      readMap[r['student_id'].toString()] = r['read_at']?.toString() ?? '';
    }

    final List<Map<String, dynamic>> seen = [];
    final List<Map<String, dynamic>> unseen = [];

    for (final p in (profiles as List)) {
      final m = Map<String, dynamic>.from(p as Map);
      final id = m['id'].toString();
      if (readMap.containsKey(id)) {
        m['read_at'] = readMap[id];
        seen.add(m);
      } else {
        unseen.add(m);
      }
    }

    int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
        (a['full_name'] ?? '').toString().compareTo(
              (b['full_name'] ?? '').toString(),
            );
    seen.sort(byName);
    unseen.sort(byName);

    return {'seen': seen, 'unseen': unseen};
  }

  Widget _rosterSection({
    required String title,
    required Color color,
    required IconData icon,
    required List<Map<String, dynamic>> people,
    required bool showTime,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                '$title (${people.length})',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        if (people.isEmpty)
          Text(
            'No students.',
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: Colors.grey.shade500,
            ),
          )
        else
          ...people.map((p) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      (p['full_name'] ?? 'Unknown').toString(),
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    showTime
                        ? _formatReadTime(p['read_at']?.toString())
                        : (p['school_id'] ?? '').toString(),
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  void _showDetails() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.75,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: FutureBuilder<Map<String, List<Map<String, dynamic>>>>(
              future: _loadRoster(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 120,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primaryBlue,
                      ),
                    ),
                  );
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'Could not load the list. Check your connection.',
                        style: GoogleFonts.poppins(fontSize: 12),
                      ),
                    ),
                  );
                }

                final seen = snapshot.data!['seen'] ?? [];
                final unseen = snapshot.data!['unseen'] ?? [];

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Who has read this?',
                        style: GoogleFonts.poppins(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      _rosterSection(
                        title: 'Not yet seen',
                        color: Colors.redAccent,
                        icon: Icons.visibility_off_outlined,
                        people: unseen,
                        showTime: false,
                      ),
                      _rosterSection(
                        title: 'Seen',
                        color: const Color(0xFF16A34A),
                        icon: Icons.done_all_rounded,
                        people: seen,
                        showTime: true,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client.from('announcement_reads').stream(
          primaryKey: ['id']).eq('announcement_id', widget.announcementId),
      builder: (context, snapshot) {
        final int seen = snapshot.data?.length ?? 0;
        final bool allSeen = _total > 0 && seen >= _total;
        final Color color =
            allSeen ? const Color(0xFF16A34A) : AppColors.primaryBlue;

        return InkWell(
          onTap: _showDetails,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  allSeen ? Icons.done_all_rounded : Icons.visibility_outlined,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                Text(
                  'Seen by $seen of $_total students',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 16, color: color),
              ],
            ),
          ),
        );
      },
    );
  }
}
