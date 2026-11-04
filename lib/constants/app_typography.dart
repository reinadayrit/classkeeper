import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTypography {
  // --- HEADERS & TITLES ---
  /// Main screen titles & user display names (e.g., "Alex Johnson", "Edit Profile")
  static TextStyle get headerLarge => GoogleFonts.poppins(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: AppColors.primaryBlue,
      );

  /// Card section titles & modal headers (e.g., "Edit Profile Details")
  static TextStyle get titleMedium => GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Colors.black87,
      );

  // --- STATS OVERVIEW ---
  /// Large numeric stats (e.g., "4", "95%", "18")
  static TextStyle get statValue => GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppColors.primaryBlue,
      );

  /// Labels underneath stats numbers (e.g., "Enrolled Courses", "Total Students")
  static TextStyle get statLabel => GoogleFonts.poppins(
        fontSize: 11,
        color: Colors.grey.shade500,
      );

  // --- BODY & SUBTEXT ---
  /// Menu item subtitles and descriptive content
  static TextStyle get bodySmall => GoogleFonts.poppins(
        fontSize: 11,
        color: Colors.grey.shade500,
      );

  /// Standard body text & text field inputs
  static TextStyle get bodyMedium => GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: Colors.black87,
      );

  // --- LABELS & BADGES ---
  /// All-caps input labels (e.g., "FULL NAME", "STUDENT ID")
  static TextStyle get labelUppercase => GoogleFonts.poppins(
        fontSize: 10,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.8,
        color: Colors.grey.shade600,
      );

  /// Rounded pill/badge text (e.g., "Student ID: 2024-00123")
  static TextStyle get badgeText => GoogleFonts.poppins(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.primaryBlue,
      );

  // --- GLOBAL TEXT THEME ---
  /// Exportable TextTheme to plug into MaterialApp main theme
  static TextTheme get textTheme => TextTheme(
        headlineMedium: headerLarge,
        titleMedium: titleMedium,
        bodyMedium: bodyMedium,
        bodySmall: bodySmall,
        labelSmall: labelUppercase,
      );
}
