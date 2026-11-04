import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/announcement_read_service.dart';

class StudentAnnounceScreen extends StatefulWidget {
  const StudentAnnounceScreen({super.key});

  @override
  State<StudentAnnounceScreen> createState() => _StudentAnnounceScreenState();
}

class _StudentAnnounceScreenState extends State<StudentAnnounceScreen> {
  bool _isLoading = true;

  // FIXED: Added proper Map data types
  List<Map<String, dynamic>> _allAnnouncements = [];
  List<Map<String, dynamic>> _filteredAnnouncements = [];

  List<String> _classList = ['All Classes'];
  List<String> _teacherList = ['All Teachers'];

  String _selectedClass = 'All Classes';
  String _selectedTeacher = 'All Teachers';
  String _searchQuery = '';
  bool _sortNewestFirst = true;

  int _currentPage = 1;
  final int _itemsPerPage = 5;

  @override
  void initState() {
    super.initState();
    // Read status is shared with the notification bell
    AnnouncementReadService.readIds.addListener(_onReadStatusChanged);
    _loadAnnouncements();
  }

  @override
  void dispose() {
    AnnouncementReadService.readIds.removeListener(_onReadStatusChanged);
    super.dispose();
  }

  void _onReadStatusChanged() {
    if (mounted) setState(() {});
  }

  String _getAuthorName(Map<String, dynamic> item) {
    if (item['profiles'] != null && item['profiles'] is Map) {
      final profile = item['profiles'];

      if (profile['full_name'] != null &&
          profile['full_name'].toString().isNotEmpty) {
        return profile['full_name'].toString();
      }
    }

    if (item['author_name']?.toString().isNotEmpty == true) {
      return item['author_name'].toString();
    }

    return 'Instructor';
  }

  String _getClassCode(Map<String, dynamic> item) {
    if (item['classes'] != null && item['classes'] is Map) {
      final cls = item['classes'];

      if (cls['course_code'] != null &&
          cls['course_code'].toString().isNotEmpty) {
        return cls['course_code'].toString();
      }
    }

    if (item['code']?.toString().isNotEmpty == true) {
      return item['code'].toString();
    }

    return 'GENERAL';
  }

  Future<void> _loadAnnouncements() async {
    setState(() => _isLoading = true);

    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            _allAnnouncements = [];
            _filteredAnnouncements = [];
            _isLoading = false;
          });
        }
        return;
      }

      // 1. Fetch class IDs where this student is enrolled
      final enrollmentsResponse = await supabase
          .from('class_enrollments')
          .select('class_id')
          .eq('student_id', user.id);

      final enrolledClassIds = (enrollmentsResponse as List)
          .map((e) => e['class_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();

      if (enrolledClassIds.isEmpty) {
        if (mounted) {
          setState(() {
            _allAnnouncements = [];
            _filteredAnnouncements = [];
            _classList = ['All Classes'];
            _teacherList = ['All Teachers'];
            _selectedClass = 'All Classes';
            _selectedTeacher = 'All Teachers';
            _isLoading = false;
          });
        }
        return;
      }

      // 2. Fetch announcements for enrolled classes
      final response = await supabase
          .from('announcements')
          .select('''
            *,
            classes!inner (
              course_code,
              course_name,
              section
            ),
            profiles!faculty_id (
              full_name
            )
          ''')
          .inFilter('class_id', enrolledClassIds)
          .order('created_at', ascending: false);

      // Which announcements this student has already opened (shared with the bell)
      await AnnouncementReadService.load();

      if (mounted) {
        // FIXED: Properly typed Supabase response
        final data = List<Map<String, dynamic>>.from(response);

        final classes = <String>{'All Classes'};
        final teachers = <String>{'All Teachers'};

        for (var item in data) {
          final code = _getClassCode(item);

          if (code.isNotEmpty && code != 'GENERAL') {
            classes.add(code);
          }

          final teacherName = _getAuthorName(item);

          if (teacherName.isNotEmpty && teacherName != 'Instructor') {
            teachers.add(teacherName);
          }
        }

        setState(() {
          _allAnnouncements = data;
          _classList = classes.toList();
          _teacherList = teachers.toList();

          if (!_classList.contains(_selectedClass)) {
            _selectedClass = 'All Classes';
          }

          if (!_teacherList.contains(_selectedTeacher)) {
            _selectedTeacher = 'All Teachers';
          }

          _applyFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading announcements: $e');

      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilters() {
    // FIXED: Properly typed results list
    List<Map<String, dynamic>> results =
        List<Map<String, dynamic>>.from(_allAnnouncements);

    // Filter by class
    if (_selectedClass != 'All Classes') {
      results = results.where((item) {
        return _getClassCode(item).toLowerCase() ==
            _selectedClass.toLowerCase();
      }).toList();
    }

    // Filter by teacher
    if (_selectedTeacher != 'All Teachers') {
      results = results.where((item) {
        return _getAuthorName(item).toLowerCase() ==
            _selectedTeacher.toLowerCase();
      }).toList();
    }

    // Search announcements
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();

      results = results.where((item) {
        final title = (item['title'] ?? '').toString().toLowerCase();
        final content = (item['content'] ?? '').toString().toLowerCase();
        final code = _getClassCode(item).toLowerCase();
        final author = _getAuthorName(item).toLowerCase();

        return title.contains(q) ||
            content.contains(q) ||
            code.contains(q) ||
            author.contains(q);
      }).toList();
    }

    // Sort announcements by date
    results.sort((a, b) {
      final dateA = DateTime.tryParse(a['created_at']?.toString() ?? '') ??
          DateTime.now();

      final dateB = DateTime.tryParse(b['created_at']?.toString() ?? '') ??
          DateTime.now();

      return _sortNewestFirst ? dateB.compareTo(dateA) : dateA.compareTo(dateB);
    });

    setState(() {
      _filteredAnnouncements = results;
      _currentPage = 1;
    });
  }

  // FIXED: Proper return type
  List<Map<String, dynamic>> get _paginatedAnnouncements {
    final startIndex = (_currentPage - 1) * _itemsPerPage;

    if (startIndex >= _filteredAnnouncements.length) {
      return [];
    }

    final endIndex =
        (startIndex + _itemsPerPage < _filteredAnnouncements.length)
            ? startIndex + _itemsPerPage
            : _filteredAnnouncements.length;

    return _filteredAnnouncements.sublist(startIndex, endIndex);
  }

  int get _totalPages {
    if (_filteredAnnouncements.isEmpty) return 1;

    return (_filteredAnnouncements.length / _itemsPerPage).ceil();
  }

  String _formatTime(String? rawDate) {
    if (rawDate == null || rawDate.isEmpty) {
      return 'Recently';
    }

    final parsed = DateTime.tryParse(rawDate);

    if (parsed == null) return rawDate;

    final diff = DateTime.now().difference(parsed);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}mins ago';
    } else if (diff.inHours < 24) {
      final hrs = diff.inHours;
      return hrs == 1 ? '1hr ago' : '${hrs}hrs ago';
    } else if (diff.inDays < 7) {
      final days = diff.inDays;
      return days == 1 ? '1 day ago' : '$days days ago';
    } else if (diff.inDays < 30) {
      final weeks = (diff.inDays / 7).floor();
      return weeks <= 1 ? '1 week ago' : '$weeks weeks ago';
    } else {
      return '${parsed.month}/${parsed.day}/${parsed.year}';
    }
  }

  /// Saves that this student opened the announcement (shown to the teacher
  /// as "Seen by X of Y"). Shared with the notification bell.
  void _markAsRead(Map<String, dynamic> item) {
    AnnouncementReadService.markRead([item['id'].toString()]);
  }

  void _showDetailModal(Map<String, dynamic> item) {
    _markAsRead(item);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: const EdgeInsets.all(20),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _getClassCode(item),
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                _formatTime(item['created_at']?.toString()),
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item['title'] ?? 'No Title',
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  item['content'] ?? '',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor:
                          AppColors.primaryBlue.withValues(alpha: 0.1),
                      child: const Icon(
                        Icons.person,
                        size: 14,
                        color: AppColors.primaryBlue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Posted by ${_getAuthorName(item)}',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Close',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ANNOUNCEMENT FEED',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                  letterSpacing: 0.8,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 18,
                  color: AppColors.primaryBlue,
                ),
                onPressed: _loadAnnouncements,
                tooltip: 'Refresh feed',
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Search field
          TextField(
            onChanged: (val) {
              _searchQuery = val;
              _applyFilters();
            },
            style: GoogleFonts.poppins(fontSize: 12),
            decoration: InputDecoration(
              hintText: 'Search announcements...',
              hintStyle: GoogleFonts.poppins(
                fontSize: 12,
                color: Colors.grey.shade400,
              ),
              prefixIcon: const Icon(
                Icons.search,
                size: 18,
                color: AppColors.primaryBlue,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const SizedBox(height: 10),

          // Filters and sorting
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _classList.contains(_selectedClass)
                          ? _selectedClass
                          : 'All Classes',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.black87,
                      ),
                      isDense: true,
                      items: _classList.map((c) {
                        return DropdownMenuItem(
                          value: c,
                          child: Text(c),
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
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _teacherList.contains(_selectedTeacher)
                          ? _selectedTeacher
                          : 'All Teachers',
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.black87,
                      ),
                      isDense: true,
                      items: _teacherList.map((t) {
                        return DropdownMenuItem(
                          value: t,
                          child: Text(t),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedTeacher = val);
                          _applyFilters();
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    setState(() {
                      _sortNewestFirst = !_sortNewestFirst;
                    });
                    _applyFilters();
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _sortNewestFirst
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          size: 14,
                          color: AppColors.primaryBlue,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _sortNewestFirst ? 'Newest' : 'Oldest',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
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

          // Announcement feed
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_filteredAnnouncements.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'No announcements found for your enrolled classes.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            )
          else
            Column(
              children: _paginatedAnnouncements.map((item) {
                return InkWell(
                  onTap: () => _showDetailModal(item),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                _getClassCode(item),
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlue,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!AnnouncementReadService.isRead(
                                    item['id'].toString()))
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryBlue,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'NEW',
                                      style: GoogleFonts.poppins(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                Text(
                                  _formatTime(item['created_at']?.toString()),
                                  style: GoogleFonts.poppins(
                                    fontSize: 11,
                                    color: Colors.grey.shade400,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item['title'] ?? 'No Title',
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item['content'] ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                            height: 1.4,
                          ),
                        ),
                        const Divider(height: 20, thickness: 0.8),
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 10,
                              backgroundColor:
                                  AppColors.primaryBlue.withValues(alpha: 0.1),
                              child: const Icon(
                                Icons.person_outline_rounded,
                                size: 12,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Posted by ${_getAuthorName(item)}',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              'Tap to read',
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),

          // Pagination
          if (!_isLoading && _filteredAnnouncements.isNotEmpty)
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

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
