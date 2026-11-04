import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/app_colors.dart';
import 'login_screen.dart';
import 'sign_up_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late AnimationController _bgAnimController;
  late AnimationController _heroAnimController;

  late Animation<double> _pulseAnimation;
  late Animation<double> _floatAnimation;

  @override
  void initState() {
    super.initState();

    // Background continuous clouds & sparkles animation
    _bgAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    // Center Hero clouds & rings float/pulse animation
    _heroAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(parent: _heroAnimController, curve: Curves.easeInOut),
    );

    _floatAnimation = Tween<double>(begin: -10, end: 10).animate(
      CurvedAnimation(parent: _heroAnimController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _bgAnimController.dispose();
    _heroAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBlue, // Color(0xFF153376)
      body: Stack(
        children: [
          // 1. Dynamic Animated Clouds & Bubbles Background
          AnimatedBuilder(
            animation: _bgAnimController,
            builder: (context, child) {
              return CustomPaint(
                size: Size.infinite,
                painter: _AnimatedCloudBackgroundPainter(
                  progress: _bgAnimController.value,
                ),
              );
            },
          ),

          SafeArea(
            child: Column(
              children: [
                const Spacer(),

                // 2. Center Hero: Animated Cloud with Pulsing Concentric Circles
                AnimatedBuilder(
                  animation: _heroAnimController,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _floatAnimation.value),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Concentric Pulsing Radar Circles
                          Transform.scale(
                            scale: _pulseAnimation.value,
                            child: SizedBox(
                              width: 220,
                              height: 220,
                              child: CustomPaint(
                                painter: _PulsingCirclesPainter(),
                              ),
                            ),
                          ),

                          // Floating Central Cloud Illustration
                          SizedBox(
                            width: 170,
                            height: 120,
                            child: CustomPaint(
                              painter: _HeroCloudPainter(),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Greeting & Intro Subtitle
                Text(
                  'Hello!',
                  style: GoogleFonts.poppins(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36.0),
                  child: Text(
                    'QR Attendance System with AI Announcement & Analytics',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.90),
                      height: 1.4,
                    ),
                  ),
                ),

                const Spacer(),

                // 3. White Fluffy Bottom Cloud Sheet with Enlarged Logo & Professional Buttons
                ClipPath(
                  clipper: BottomCloudSheetClipper(),
                  child: Container(
                    width: double.infinity,
                    color: Colors.white,
                    padding: const EdgeInsets.only(
                      top: 44,
                      bottom: 32,
                      left: 28,
                      right: 28,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // PROMINENT LARGER CLASSKEEPER LOGO
                        Image.asset(
                          'assets/images/logo.png',
                          height: 110, // Enlarged height
                          width: 280, // Enlarged width
                          fit: BoxFit.contain,
                          errorBuilder: (ctx, err, stack) => Text(
                            'ClassKeeper',
                            style: GoogleFonts.poppins(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlue,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // PROFESSIONAL SIGN IN BUTTON (GRADIENT & SHADOW)
                        Container(
                          width: double.infinity,
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              colors: [
                                AppColors.primaryBlue,
                                Color(0xFF0E2353),
                              ],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primaryBlue
                                    .withValues(alpha: 0.35),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const LoginScreen(),
                                ),
                              );
                            },
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'SIGN IN',
                                  style: GoogleFonts.poppins(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        // PROFESSIONAL CREATE AN ACCOUNT BUTTON (OUTLINED)
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                color: AppColors.primaryBlue,
                                width: 1.8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              backgroundColor: Colors.white,
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const SignUpScreen(),
                                ),
                              );
                            },
                            child: Text(
                              'CREATE AN ACCOUNT',
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlue,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom Clipper for Fluffy Overlapping Bottom Cloud Cutout
class BottomCloudSheetClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, 32);

    // Left cloud bump
    path.quadraticBezierTo(size.width * 0.15, 0, size.width * 0.35, 18);

    // Center higher cloud bump
    path.quadraticBezierTo(size.width * 0.50, -2, size.width * 0.70, 22);

    // Right cloud bump
    path.quadraticBezierTo(size.width * 0.88, 5, size.width, 32);

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

/// Concentric Pulsing Circles Painter for Hero Stage
class _PulsingCirclesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final ringPaint1 = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final ringPaint2 = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final ringPaint3 = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(center, size.width * 0.48, ringPaint1);
    canvas.drawCircle(center, size.width * 0.38, ringPaint2);
    canvas.drawCircle(center, size.width * 0.28, ringPaint3);

    // Orbiting Bubble Accents
    final dotPaint = Paint()..color = Colors.white.withValues(alpha: 0.8);
    canvas.drawCircle(
        Offset(center.dx - size.width * 0.38, center.dy - 12), 5, dotPaint);
    canvas.drawCircle(
        Offset(center.dx + size.width * 0.42, center.dy + 18), 6, dotPaint);
    canvas.drawCircle(
        Offset(center.dx + size.width * 0.20, center.dy - size.height * 0.38),
        4,
        dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Vector Painter for the Center Fluffy Hero Cloud
class _HeroCloudPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

    final cloudPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height / 2 + 5);

    // Shadow Layer
    canvas.drawCircle(Offset(center.dx - 35, center.dy + 5), 28, shadowPaint);
    canvas.drawCircle(Offset(center.dx + 35, center.dy + 5), 28, shadowPaint);
    canvas.drawCircle(Offset(center.dx, center.dy - 10), 38, shadowPaint);

    // Cloud Circles Composition
    canvas.drawCircle(Offset(center.dx - 38, center.dy + 4), 26, cloudPaint);
    canvas.drawCircle(Offset(center.dx + 38, center.dy + 4), 26, cloudPaint);
    canvas.drawCircle(Offset(center.dx - 18, center.dy - 12), 34, cloudPaint);
    canvas.drawCircle(Offset(center.dx + 18, center.dy - 12), 34, cloudPaint);
    canvas.drawCircle(Offset(center.dx, center.dy + 8), 30, cloudPaint);

    // Cute Eye Accents inside the Hero Cloud
    final eyePaint = Paint()..color = AppColors.primaryBlue;
    canvas.drawCircle(Offset(center.dx - 14, center.dy + 2), 3.5, eyePaint);
    canvas.drawCircle(Offset(center.dx + 14, center.dy + 2), 3.5, eyePaint);

    // Cute Smiling Mouth Path
    final mouthPath = Path();
    mouthPath.moveTo(center.dx - 6, center.dy + 8);
    mouthPath.quadraticBezierTo(
        center.dx, center.dy + 14, center.dx + 6, center.dy + 8);
    final mouthPaint = Paint()
      ..color = AppColors.primaryBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(mouthPath, mouthPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Dynamic Custom Painter for Background Drifting Clouds & Ambient Circles
class _AnimatedCloudBackgroundPainter extends CustomPainter {
  final double progress;

  _AnimatedCloudBackgroundPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final cloudPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;

    final floatOffset = sin(progress * pi * 2) * 12;

    // Background Clouds
    canvas.drawCircle(
      Offset(size.width * 0.1, size.height * 0.12 + floatOffset),
      55,
      cloudPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.28, size.height * 0.09 - floatOffset),
      75,
      cloudPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.88, size.height * 0.18 + floatOffset),
      65,
      cloudPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.72, size.height * 0.22 - floatOffset),
      85,
      cloudPaint,
    );

    // Ambient Floating Circles & Sparkles
    final circlePaint = Paint()
      ..color = Colors.white
          .withValues(alpha: 0.45 + (sin(progress * pi * 2) * 0.15));

    canvas.drawCircle(
      Offset(size.width * 0.16, size.height * 0.28 + (floatOffset * 0.5)),
      6,
      circlePaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.84, size.height * 0.36 - (floatOffset * 0.5)),
      8,
      circlePaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.22, size.height * 0.52 + floatOffset),
      5,
      circlePaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.54 - floatOffset),
      7,
      circlePaint,
    );

    canvas.drawCircle(
        Offset(size.width * 0.35, size.height * 0.18), 3, circlePaint);
    canvas.drawCircle(
        Offset(size.width * 0.65, size.height * 0.14), 4, circlePaint);
    canvas.drawCircle(
        Offset(size.width * 0.12, size.height * 0.42), 3, circlePaint);
  }

  @override
  bool shouldRepaint(covariant _AnimatedCloudBackgroundPainter oldDelegate) =>
      true;
}
