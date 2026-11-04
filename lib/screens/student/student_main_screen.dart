import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/announcement_read_service.dart';

import 'student_dashboard_screen.dart';
import 'student_classes_screen.dart';
import 'student_qr_screen.dart';
import 'student_announce_screen.dart';
import 'student_profile_screen.dart';

class StudentMainScreen extends StatefulWidget {
  const StudentMainScreen({super.key});

  @override
  State<StudentMainScreen> createState() => _StudentMainScreenState();
}

class _StudentMainScreenState extends State<StudentMainScreen> {
  int _selectedIndex = 0;
  List<Map<String, dynamic>> _announcements = [];
  Set<String> _enrolledClassIds = {};
  RealtimeChannel? _announcementChannel;

  @override
  void initState() {
    super.initState();
    // Read status is shared with the Announcements tab and saved in Supabase
    AnnouncementReadService.readIds.addListener(_onReadStatusChanged);
    AnnouncementReadService.load();
    _fetchAnnouncements();
    _subscribeToAnnouncements();
  }

  @override
  void dispose() {
    AnnouncementReadService.readIds.removeListener(_onReadStatusChanged);
    _announcementChannel?.unsubscribe();
    super.dispose();
  }

  void _onReadStatusChanged() {
    if (mounted) setState(() {});
  }

  // Calculate total unread count
  int get _unreadCount {
    final read = AnnouncementReadService.readIds.value;
    return _announcements.where((a) {
      final id = a['id']?.toString() ?? '';
      return !read.contains(id);
    }).length;
  }

  // Fetch past announcements
  Future<void> _fetchAnnouncements() async {
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Only announcements from the classes this student is enrolled in
      final enrollments = await supabase
          .from('class_enrollments')
          .select('class_id')
          .eq('student_id', user.id);

      final classIds =
          (enrollments as List).map((e) => e['class_id'].toString()).toSet();
      _enrolledClassIds = classIds;

      if (classIds.isEmpty) {
        if (mounted) setState(() => _announcements = []);
        return;
      }

      final data = await supabase
          .from('announcements')
          .select()
          .inFilter('class_id', classIds.toList())
          .order('created_at', ascending: false)
          .limit(20);

      if (mounted) {
        setState(() {
          _announcements = List<Map<String, dynamic>>.from(data);
        });
      }
    } catch (e) {
      debugPrint('Error fetching announcements: $e');
    }
  }

  // Real-time broadcast listener
  void _subscribeToAnnouncements() {
    _announcementChannel = Supabase.instance.client
        .channel('public:announcements')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'announcements',
          callback: (payload) {
            final newRecord = Map<String, dynamic>.from(payload.newRecord);

            // Ignore announcements from classes the student is not in
            if (!_enrolledClassIds
                .contains(newRecord['class_id']?.toString())) {
              return;
            }
            // Ignore duplicates
            final newId = newRecord['id']?.toString();
            if (_announcements.any((a) => a['id']?.toString() == newId)) {
              return;
            }

            if (mounted) {
              setState(() {
                _announcements.insert(0, newRecord);
              });

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '📢 New Notice: ${newRecord['title'] ?? 'Class Broadcast'}',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  backgroundColor: AppColors.primaryBlue,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
        )
        .subscribe();
  }

  void _changeTab(int index) {
    setState(() => _selectedIndex = index);
  }

  // Opening an announcement in the bell counts as "seen" for the teacher
  void _markAsRead(String id) {
    AnnouncementReadService.markRead([id]);
  }

  void _markAllAsRead() {
    AnnouncementReadService.markRead(
      _announcements.map((a) => a['id']?.toString() ?? ''),
    );
  }

  // Stacked Notifications Dialog
  Future<void> _openNotificationsDialog() async {
    // Refresh so announcements read in the Announce tab show as read here
    await AnnouncementReadService.load();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              title: Row(
                children: [
                  const Icon(Icons.campaign_rounded,
                      color: AppColors.primaryBlue, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Class Broadcasts',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_unreadCount > 0) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        _markAllAsRead();
                        setDialogState(() {});
                      },
                      child: Text(
                        'Mark all as read',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 380,
                child: _announcements.isEmpty
                    ? Center(
                        child: Text(
                          'No announcements found.',
                          style: GoogleFonts.poppins(
                              fontSize: 12, color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _announcements.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = _announcements[index];
                          final id = item['id']?.toString() ?? '';
                          final isUnread = !AnnouncementReadService.isRead(id);

                          return InkWell(
                            onTap: () {
                              _markAsRead(id);
                              setDialogState(() {});
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isUnread
                                    ? AppColors.primaryBlue
                                        .withValues(alpha: 0.08)
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isUnread
                                      ? AppColors.primaryBlue
                                          .withValues(alpha: 0.35)
                                      : Colors.grey.shade300,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      if (isUnread)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(right: 6),
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: AppColors.primaryBlue,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          item['title'] ?? 'Class Broadcast',
                                          style: GoogleFonts.poppins(
                                            fontSize: 12,
                                            fontWeight: isUnread
                                                ? FontWeight.bold
                                                : FontWeight.w600,
                                            color: isUnread
                                                ? AppColors.primaryBlue
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        isUnread ? 'Unread' : 'Read',
                                        style: GoogleFonts.poppins(
                                          fontSize: 10,
                                          color: isUnread
                                              ? AppColors.primaryBlue
                                              : Colors.grey.shade600,
                                          fontWeight: isUnread
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    item['content'] ?? '',
                                    style: GoogleFonts.poppins(
                                      fontSize: 11,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Close',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
    final List<Widget> pages = [
      StudentDashboardScreen(onTabSelected: _changeTab),
      StudentClassesScreen(onTabSelected: _changeTab),
      const StudentQrScreen(),
      const StudentAnnounceScreen(),
      const StudentProfileScreen(),
    ];

    return Scaffold(
      extendBody: true,
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        backgroundColor: AppColors.primaryBlue,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: Image.asset(
          'assets/images/logo_home.png',
          height: 90,
          fit: BoxFit.contain,
        ),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_none, size: 24),
                onPressed: _openNotificationsDialog,
              ),
              if (_unreadCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '$_unreadCount',
                      style: GoogleFonts.poppins(
                        color: AppColors.primaryBlue,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: _changeTab,
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconSize: 20,
            selectedItemColor: AppColors.primaryBlue,
            unselectedItemColor: AppColors.primaryBlue.withValues(alpha: 0.45),
            selectedFontSize: 10,
            unselectedFontSize: 10,
            selectedLabelStyle:
                GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600),
            unselectedLabelStyle:
                GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w400),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.grid_view_outlined),
                activeIcon: Icon(Icons.grid_view_rounded),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.school_outlined),
                activeIcon: Icon(Icons.school_rounded),
                label: 'Classes',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_scanner_outlined),
                activeIcon: Icon(Icons.qr_code_scanner_rounded),
                label: 'Scan QR',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.campaign_outlined),
                activeIcon: Icon(Icons.campaign_rounded),
                label: 'Announce',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person_outline),
                activeIcon: Icon(Icons.person_rounded),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
