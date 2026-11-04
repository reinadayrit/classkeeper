// 1. Add this import at the very top
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  // 2. Define the supabase client here
  static final supabase = Supabase.instance.client;

  static Future<void> createAnnouncement({
    required String title,
    required String content,
    required String authorId,
  }) async {
    await supabase.from('announcements').insert({
      'title': title,
      'content': content,
      'author_id': authorId,
    });
  }

  // 4. Log QR Code Attendance (Student)
  static Future<void> markAttendance({
    required String studentId,
    required String classId,
    String status = 'Present',
  }) async {
    await supabase.from('attendance').insert({
      'student_id': studentId,
      'class_id': classId,
      'status': status,
    });
  }
}
