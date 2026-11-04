import 'package:flutter/foundation.dart';

/// Tells the faculty notification bell to refresh right away.
///
/// Example: after the teacher approves or rejects an excuse letter in the
/// Records tab, call [bump] so the bell badge goes down immediately.
class FacultyNoticeRefresh {
  FacultyNoticeRefresh._();

  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  static void bump() => tick.value++;
}
