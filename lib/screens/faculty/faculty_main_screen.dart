import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../constants/app_colors.dart';
import '../../services/faculty_notice_refresh.dart';
import 'faculty_dashboard_screen.dart';
import 'faculty_classes_screen.dart';
import 'faculty_qr_screen.dart';
import 'faculty_records_screen.dart';
import 'faculty_announce_screen.dart';
import 'faculty_profile_screen.dart';

class FacultyMainScreen extends StatefulWidget {
  const FacultyMainScreen({super.key});

  @override
  State<FacultyMainScreen> createState() => _FacultyMainScreenState();
}

/// One item in the faculty notification bell.
class _FacultyNotice {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String time;
  final int tabIndex; // tab to open when tapped
  final bool actionable; // counts in the red badge

  const _FacultyNotice({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.tabIndex,
    required this.actionable,
  });
}

class _FacultyMainScreenState extends State<FacultyMainScreen> {
  int _selectedIndex = 0;
  List<_FacultyNotice> _notices = [];
  int _badgeTotal = 0; // real total (the list below is capped)
  RealtimeChannel? _noticeChannel;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _subscribeToChanges();
    FacultyNoticeRefresh.tick.addListener(_loadNotifications);
  }

  @override
  void dispose() {
    FacultyNoticeRefresh.tick.removeListener(_loadNotifications);
    _noticeChannel?.unsubscribe();
    super.dispose();
  }

  void _changeTab(int index) {
    setState(() {
      _selectedIndex = index;
    });
    _loadNotifications(); // keep the bell badge fresh
  }

  // Number shown in the red badge (only things that need an action)
  int get _badgeCount => _badgeTotal;

  // Refresh the bell when excuse letters or sessions change
  void _subscribeToChanges() {
    _noticeChannel = Supabase.instance.client
        .channel('faculty_notifications')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'absence_reasons',
          callback: (_) => _loadNotifications(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'attendance_sessions',
          callback: (_) => _loadNotifications(),
        )
        .subscribe();
  }

  String _timeAgo(String? iso) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  /// Builds the bell from live data:
  ///  1. excuse letters waiting for review
  ///  2. attendance sessions that are still open
  ///  3. students who joined a class in the last 7 days
  Future<void> _loadNotifications() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final classRes = await supabase
          .from('classes')
          .select('id, course_code, section, is_archived')
          .eq('faculty_id', user.id);

      final Map<String, Map<String, dynamic>> classes = {};
      for (final c in (classRes as List)) {
        if (c['is_archived'] == true) continue;
        classes[c['id'].toString()] = Map<String, dynamic>.from(c as Map);
      }

      if (classes.isEmpty) {
        if (mounted) {
          setState(() {
            _notices = [];
            _badgeTotal = 0;
          });
        }
        return;
      }

      final classIds = classes.keys.toList();
      final since = DateTime.now()
          .subtract(const Duration(days: 7))
          .toUtc()
          .toIso8601String();

      final pendingRes = await supabase
          .from('absence_reasons')
          .select('id, student_id, class_id, reason, created_at')
          .inFilter('class_id', classIds)
          .ilike('status', 'pending')
          .order('created_at', ascending: false);

      final openSessionsRes = await supabase
          .from('attendance_sessions')
          .select('id, class_id, created_at')
          .inFilter('class_id', classIds)
          .eq('is_ended', false)
          .order('created_at', ascending: false);

      final joinsRes = await supabase
          .from('class_enrollments')
          .select('student_id, class_id, joined_at')
          .inFilter('class_id', classIds)
          .gte('joined_at', since)
          .order('joined_at', ascending: false)
          .limit(10);

      // Student names for the excuse letters and new joins
      final Set<String> studentIds = {
        for (final r in (pendingRes as List)) r['student_id'].toString(),
        for (final r in (joinsRes as List)) r['student_id'].toString(),
      };

      final Map<String, String> names = {};
      if (studentIds.isNotEmpty) {
        final profilesRes = await supabase
            .from('profiles')
            .select('id, full_name')
            .inFilter('id', studentIds.toList());
        for (final p in (profilesRes as List)) {
          names[p['id'].toString()] =
              (p['full_name'] ?? 'A student').toString();
        }
      }

      String classLabel(String classId) {
        final c = classes[classId];
        if (c == null) return 'a class';
        final section = (c['section'] ?? '').toString();
        return section.isEmpty
            ? c['course_code'].toString()
            : '${c['course_code']} - $section';
      }

      final List<_FacultyNotice> notices = [];

      const int maxLetters = 20;
      final int pendingTotal = (pendingRes as List).length;

      for (final r in pendingRes.take(maxLetters)) {
        final reason = (r['reason'] ?? '').toString();
        notices.add(_FacultyNotice(
          icon: Icons.mark_email_unread_outlined,
          color: const Color(0xFFF59E0B),
          title: 'Excuse letter to review',
          subtitle:
              '${names[r['student_id'].toString()] ?? 'A student'} (${classLabel(r['class_id'].toString())})'
              '${reason.isEmpty ? '' : ': $reason'}',
          time: _timeAgo(r['created_at']?.toString()),
          tabIndex: 3, // Records
          actionable: true,
        ));
      }

      if (pendingTotal > maxLetters) {
        notices.add(_FacultyNotice(
          icon: Icons.more_horiz_rounded,
          color: const Color(0xFFF59E0B),
          title: '${pendingTotal - maxLetters} more excuse letters waiting',
          subtitle: 'Open the Records tab to review all of them.',
          time: '',
          tabIndex: 3, // Records
          actionable: false,
        ));
      }

      for (final r in (openSessionsRes as List)) {
        notices.add(_FacultyNotice(
          icon: Icons.qr_code_2_rounded,
          color: const Color(0xFFEF4444),
          title: 'Attendance session still open',
          subtitle:
              '${classLabel(r['class_id'].toString())} is still accepting scans. Tap to end it.',
          time: _timeAgo(r['created_at']?.toString()),
          tabIndex: 2, // QR
          actionable: true,
        ));
      }

      for (final r in joinsRes) {
        notices.add(_FacultyNotice(
          icon: Icons.person_add_alt_1_rounded,
          color: AppColors.primaryBlue,
          title: 'New student joined',
          subtitle:
              '${names[r['student_id'].toString()] ?? 'A student'} joined ${classLabel(r['class_id'].toString())}',
          time: _timeAgo(r['joined_at']?.toString()),
          tabIndex: 1, // Class
          actionable: false,
        ));
      }

      final int openSessionsTotal = openSessionsRes.length;

      if (mounted) {
        setState(() {
          _notices = notices;
          // Badge = ALL pending excuse letters + open sessions (not capped)
          _badgeTotal = pendingTotal + openSessionsTotal;
        });
      }
    } catch (e) {
      debugPrint('Error loading notifications: $e');
    }
  }

  Future<void> _openNotificationsDialog() async {
    await _loadNotifications();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          title: Row(
            children: [
              const Icon(Icons.notifications_active_rounded,
                  color: AppColors.primaryBlue, size: 22),
              const SizedBox(width: 8),
              Text(
                'Notifications',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: _notices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            size: 44, color: Colors.green.shade400),
                        const SizedBox(height: 10),
                        Text(
                          "You're all caught up!",
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'No excuse letters to review and\nno open attendance sessions.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _notices.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final n = _notices[index];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          _changeTab(n.tabIndex);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: n.color.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: n.color.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(n.icon, size: 20, color: n.color),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            n.title,
                                            style: GoogleFonts.poppins(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black87,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          n.time,
                                          style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      n.subtitle,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        color: Colors.grey.shade700,
                                        height: 1.35,
                                      ),
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
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
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      FacultyDashboardScreen(onTabSelected: _changeTab),
      const FacultyClassesScreen(),
      const FacultyQrScreen(),
      const FacultyRecordsScreen(),
      const FacultyAnnounceScreen(),
      const FacultyProfileScreen(),
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
        actions: <Widget>[
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.notifications_none,
                  size: 24,
                ),
                onPressed: _openNotificationsDialog,
              ),
              if (_badgeCount > 0)
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
                      '$_badgeCount',
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

      // --- FLOATING NAV BAR ---
      bottomNavigationBar: Container(
        margin: const EdgeInsets.only(left: 10, right: 10, bottom: 20),
        decoration: BoxDecoration(
          color: AppColors.primaryBlue,
          borderRadius: BorderRadius.circular(16),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppColors.primaryBlue.withValues(alpha: 0.35),
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
            selectedItemColor: Colors.white,
            unselectedItemColor: Colors.white70,
            selectedFontSize: 9,
            unselectedFontSize: 9,
            selectedLabelStyle: GoogleFonts.poppins(
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: GoogleFonts.poppins(
              fontSize: 9,
              fontWeight: FontWeight.w400,
            ),
            items: const <BottomNavigationBarItem>[
              BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.class_outlined),
                activeIcon: Icon(Icons.class_),
                label: 'Class',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_2),
                label: 'QR',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.description_outlined),
                activeIcon: Icon(Icons.description),
                label: 'Records',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.campaign_outlined),
                activeIcon: Icon(Icons.campaign),
                label: 'Announce',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person_outline),
                activeIcon: Icon(Icons.person),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
