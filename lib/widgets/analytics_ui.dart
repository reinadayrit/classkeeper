import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/app_colors.dart';

/// Colors used for attendance statuses everywhere in the app.
class AnalyticsColors {
  AnalyticsColors._();

  static const Color present = Color(0xFF10B981); // green
  static const Color late = Color(0xFFF59E0B); // amber
  static const Color excused = Color(0xFF8B5CF6); // purple
  static const Color absent = Color(0xFFEF4444); // red
  static const Color blue = Color(0xFF3B82F6);
  static const Color teal = Color(0xFF14B8A6);
  static const Color pink = Color(0xFFEC4899);
  static const Color orange = Color(0xFFF97316);

  /// green / amber / red depending on an attendance rate (0 to 1)
  static Color forRate(double rate) {
    if (rate >= 0.85) return present;
    if (rate >= 0.70) return late;
    return absent;
  }
}

// ---------------------------------------------------------------
// Blue + white building blocks
// ---------------------------------------------------------------
class BlueUI {
  BlueUI._();

  static const Color navy = AppColors.primaryBlue;
  static const Color mid = Color(0xFF2563EB);
  static const Color sky = Color(0xFF60A5FA);
  static const Color soft = Color(0xFFDBEAFE);
  static const Color light = Color(0xFFEFF6FF);
}

/// Navy-to-blue gradient card with white content.
class BlueGradientCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const BlueGradientCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BlueUI.navy, BlueUI.mid],
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: BlueUI.navy.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Blue gradient stat card (white icon chip, big white number).
class BlueStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String caption;
  final bool compact;

  const BlueStatCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return BlueGradientCard(
      radius: 16,
      padding: EdgeInsets.all(compact ? 10 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(compact ? 5 : 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: Colors.white, size: compact ? 14 : 18),
          ),
          SizedBox(height: compact ? 8 : 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: GoogleFonts.poppins(
                fontSize: compact ? 17 : 21,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: compact ? 9.5 : 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          ),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: compact ? 8.5 : 9.5,
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// White mini tile used inside the dashboard "Metrics & Usage" cards.
class MiniMetricTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final bool vertical; // true = icon on top (3 per row), false = icon on left

  const MiniMetricTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.vertical = false,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: EdgeInsets.all(vertical ? 5 : 6),
      decoration: BoxDecoration(
        color: BlueUI.light,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: BlueUI.mid, size: vertical ? 16 : 18),
    );

    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(
            fontSize: vertical ? 9 : 10,
            color: Colors.grey.shade600,
          ),
        ),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(
            fontSize: vertical ? 11 : 12,
            fontWeight: FontWeight.bold,
            color: BlueUI.navy,
          ),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(vertical ? 10 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: vertical
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [chip, const SizedBox(height: 6), texts],
            )
          : Row(
              children: [
                chip,
                const SizedBox(width: 8),
                Expanded(child: texts)
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------
// Donut chart with a widget in the middle (animated)
// ---------------------------------------------------------------
class DonutSegment {
  final double value;
  final Color color;
  const DonutSegment(this.value, this.color);
}

class DonutChart extends StatelessWidget {
  final List<DonutSegment> segments;
  final double size;
  final double thickness;
  final Widget? center;

  const DonutChart({
    super.key,
    required this.segments,
    this.size = 130,
    this.thickness = 16,
    this.center,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) {
              return CustomPaint(
                size: Size(size, size),
                painter: _DonutPainter(
                  segments: segments,
                  thickness: thickness,
                  progress: t,
                ),
              );
            },
          ),
          if (center != null) center!,
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<DonutSegment> segments;
  final double thickness;
  final double progress;

  _DonutPainter({
    required this.segments,
    required this.thickness,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      thickness / 2,
      thickness / 2,
      size.width - thickness,
      size.height - thickness,
    );

    // light track behind the segments
    canvas.drawArc(
      rect,
      0,
      2 * pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..color = Colors.grey.shade100,
    );

    final double total = segments.fold(0.0, (sum, s) => sum + s.value);
    if (total <= 0) return;

    final visible = segments.where((s) => s.value > 0).toList();
    final double gap = visible.length > 1 ? 0.06 : 0; // radians between pieces
    double start = -pi / 2;

    for (final seg in visible) {
      final double fullSweep = (seg.value / total) * 2 * pi;
      final double sweep = max(0.0, fullSweep - gap) * progress;

      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.round
          ..color = seg.color,
      );
      start += fullSweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress || old.segments != segments;
}

// ---------------------------------------------------------------
// "How is this computed?" sheet
// ---------------------------------------------------------------
class FormulaItem {
  final IconData icon;
  final Color color;
  final String title;
  final String formula;
  final String example;

  const FormulaItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.formula,
    required this.example,
  });
}

Future<void> showFormulaSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<FormulaItem> items,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        margin: const EdgeInsets.only(top: 40),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBlue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.calculate_rounded,
                      color: AppColors.primaryBlue, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: BlueUI.light,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: BlueUI.soft),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [BlueUI.navy, BlueUI.mid],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(item.icon, color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: GoogleFonts.poppins(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF1E293B),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  item.formula,
                                  style: GoogleFonts.poppins(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: BlueUI.navy,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.example,
                                style: GoogleFonts.poppins(
                                  fontSize: 10.5,
                                  color: Colors.grey.shade700,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
