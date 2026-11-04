import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps track of which announcements the logged-in student has opened.
///
/// It is shared by the notification bell and the Announcements tab, so
/// reading an announcement in one place clears it in the other, and the
/// teacher's "Seen by X of Y" count is updated (table: announcement_reads).
class AnnouncementReadService {
  AnnouncementReadService._();

  /// IDs of announcements this student has already opened.
  static final ValueNotifier<Set<String>> readIds =
      ValueNotifier<Set<String>>(<String>{});

  static String? _userId;

  /// Starts fresh if a different student logged in on this device.
  static void _syncUser(String userId) {
    if (_userId != userId) {
      _userId = userId;
      readIds.value = <String>{};
    }
  }

  static bool isRead(String id) => readIds.value.contains(id);

  /// Loads the saved read status from Supabase.
  static Future<void> load() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    _syncUser(user.id);

    try {
      final res = await Supabase.instance.client
          .from('announcement_reads')
          .select('announcement_id')
          .eq('student_id', user.id);

      final loaded =
          (res as List).map((r) => r['announcement_id'].toString()).toSet();

      // Keep anything marked locally that has not finished saving yet
      readIds.value = {...readIds.value, ...loaded};
    } catch (e) {
      debugPrint('Could not load read status: $e');
    }
  }

  /// Marks one or more announcements as read (opened by the student).
  static Future<void> markRead(Iterable<String> ids) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    _syncUser(user.id);

    final newIds = ids
        .where((id) => id.isNotEmpty && !readIds.value.contains(id))
        .toSet()
        .toList();
    if (newIds.isEmpty) return;

    // Update the screens immediately, then save
    readIds.value = {...readIds.value, ...newIds};

    try {
      await Supabase.instance.client.from('announcement_reads').upsert(
            newIds
                .map((id) => {'announcement_id': id, 'student_id': user.id})
                .toList(),
            onConflict: 'announcement_id,student_id',
            ignoreDuplicates: true,
          );
    } catch (e) {
      debugPrint('Could not save read status: $e');
    }
  }
}
