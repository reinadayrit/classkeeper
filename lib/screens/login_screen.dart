import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_colors.dart';
import 'faculty/faculty_main_screen.dart';
import 'student/student_main_screen.dart';
import 'sign_up_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _bubbleController;
  final List<_Bubble> _bubbles = [];
  final Random _random = Random();

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isPasswordVisible = false;

  // Only school emails ending in @davao.sti.edu.ph are accepted
  static final RegExp _schoolEmailRegex = RegExp(
    r'^[\w.+\-]+@davao\.sti\.edu\.ph$',
    caseSensitive: false,
  );

  // Inline field errors (shown under the field in red)
  String? _emailError;
  String? _passwordError;

  @override
  void initState() {
    super.initState();

    _bubbleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();

    // Softer ambient particles in Yellow & Blue (fewer + fainter so the
    // form stays the focus)
    for (int i = 0; i < 20; i++) {
      final isYellow = _random.nextBool();
      _bubbles.add(_Bubble(
        x: _random.nextDouble(),
        size: _random.nextDouble() * 26 + 8,
        speed: _random.nextDouble() * 0.7 + 0.3,
        opacity: isYellow ? 0.12 : 0.08,
        color: isYellow ? const Color(0xFFFFE082) : const Color(0xFF81D4FA),
      ));
    }
  }

  @override
  void dispose() {
    _bubbleController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showNotification(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor:
            isError ? const Color(0xFFEF4444) : AppColors.primaryBlue,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        elevation: 6,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    // Inline validation (red text under the field)
    String? emailErr;
    String? passErr;

    if (email.isEmpty) {
      emailErr = 'Please enter your school email.';
    } else if (!_schoolEmailRegex.hasMatch(email)) {
      emailErr = 'Use your school email ending in @davao.sti.edu.ph';
    }
    if (password.isEmpty) {
      passErr = 'Please enter your password.';
    }

    if (emailErr != null || passErr != null) {
      setState(() {
        _emailError = emailErr;
        _passwordError = passErr;
      });
      return;
    }

    setState(() {
      _emailError = null;
      _passwordError = null;
      _isLoading = true;
    });

    try {
      final supabase = Supabase.instance.client;

      final authResponse = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = authResponse.user;
      if (user == null) {
        throw Exception('Login failed. No user returned.');
      }

      final profileData = await supabase
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();

      String dbRole;

      if (profileData == null) {
        final metaRole = user.userMetadata?['role'] as String?;
        dbRole = metaRole ?? 'student';

        await supabase.from('profiles').upsert({
          'id': user.id,
          'role': dbRole,
          'full_name': user.userMetadata?['full_name'] ??
              user.email?.split('@').first ??
              'New User',
        });
      } else {
        dbRole = profileData['role'] as String;
      }

      if (!mounted) return;

      if (dbRole == 'faculty') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const FacultyMainScreen()),
        );
      } else if (dbRole == 'student') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const StudentMainScreen()),
        );
      } else {
        throw Exception('Unrecognized role detected ($dbRole).');
      }
    } on SocketException catch (_) {
      if (mounted) {
        _showNotification(
            'No internet connection. Unable to connect to network.');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      final supabase = Supabase.instance.client;

      final errLower = e.message.toLowerCase();
      if (errLower.contains('network') ||
          errLower.contains('connection') ||
          errLower.contains('failed to fetch') ||
          errLower.contains('socket') ||
          errLower.contains('host lookup')) {
        _showNotification(
            'No internet connection. Unable to connect to network.');
        return;
      }

      if (e.code == 'invalid_credentials' ||
          e.message.toLowerCase().contains('invalid login credentials')) {
        try {
          final profileCheck = await supabase
              .from('profiles')
              .select('id')
              .eq('email', email)
              .maybeSingle();

          if (!mounted) return;
          if (profileCheck == null) {
            setState(() => _emailError = 'No account found with this email.');
          } else {
            setState(
                () => _passwordError = 'Incorrect password. Please try again.');
          }
        } catch (_) {
          if (!mounted) return;
          setState(
              () => _passwordError = 'Incorrect email or password. Try again.');
        }
      } else if (e.code == 'email_not_confirmed' ||
          e.message.toLowerCase().contains('email not confirmed')) {
        _showNotification(
            'Your email is not verified yet. Please check your inbox.');
      } else if (e.code == 'too_many_requests' ||
          e.code == 'over_request_rate_limit') {
        _showNotification(
            'Too many failed attempts. Please wait a moment and try again.');
      } else {
        _showNotification(e.message);
      }
    } catch (e) {
      if (mounted) {
        final errStr = e.toString().toLowerCase();
        if (errStr.contains('socketexception') ||
            errStr.contains('clientexception') ||
            errStr.contains('failed host lookup') ||
            errStr.contains('network') ||
            errStr.contains('connection')) {
          _showNotification(
              'No internet connection. Unable to connect to network.');
        } else {
          _showNotification(
              'Error: ${e.toString().replaceAll('Exception: ', '')}');
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Pure White Canvas Background
          Positioned.fill(
            child: Container(color: Colors.white),
          ),

          // Yellow & Blue Ambient Bubbles Custom Painter
          AnimatedBuilder(
            animation: _bubbleController,
            builder: (context, child) {
              return CustomPaint(
                size: size,
                painter: _BubblePainter(
                  bubbles: _bubbles,
                  progress: _bubbleController.value,
                ),
              );
            },
          ),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24.0, vertical: 20.0),
                // Keeps the layout phone-sized when opened in Chrome
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 1. Enlarged Static Logo
                      Image.asset(
                        'assets/images/sign.png',
                        height: 130,
                        width: 270,
                        fit: BoxFit.contain,
                        errorBuilder: (ctx, err, stack) => const Icon(
                          Icons.qr_code_2_rounded,
                          size: 90,
                          color: AppColors.primaryBlue,
                        ),
                      ),

                      // 2. Subtitle shifted up to close the PNG padding gap
                      Transform.translate(
                        offset: const Offset(0, -16),
                        child: Text(
                          'QR Attendance System with\nAI Announcement and Analytics',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.blueGrey.shade800,
                            height: 1.2,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // 3. Sign In Card Container
                      Container(
                        padding: const EdgeInsets.all(24.0),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: const Color(0xFFF1F5F9),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  AppColors.primaryBlue.withValues(alpha: 0.08),
                              blurRadius: 30,
                              offset: const Offset(0, 12),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SIGN IN TO YOUR ACCOUNT',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.8,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 18),

                            // Email Field
                            _buildTextField(
                              controller: _emailController,
                              label: 'School Email',
                              hintText: 'name@davao.sti.edu.ph',
                              icon: Icons.email_outlined,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.email],
                              errorText: _emailError,
                              onChanged: (_) {
                                if (_emailError != null) {
                                  setState(() => _emailError = null);
                                }
                              },
                            ),
                            const SizedBox(height: 16),

                            // Password Field
                            _buildTextField(
                              controller: _passwordController,
                              label: 'Password',
                              icon: Icons.lock_outline_rounded,
                              isPassword: true,
                              isVisible: _isPasswordVisible,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              errorText: _passwordError,
                              onSubmitted: (_) => _handleLogin(),
                              onChanged: (_) {
                                if (_passwordError != null) {
                                  setState(() => _passwordError = null);
                                }
                              },
                              onToggleVisibility: () {
                                setState(() {
                                  _isPasswordVisible = !_isPasswordVisible;
                                });
                              },
                            ),

                            // Forgot password link (right aligned)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: GestureDetector(
                                  onTap: () => _showNotification(
                                    'Please contact your teacher or school admin to reset your password.',
                                    isError: false,
                                  ),
                                  child: Text(
                                    'Forgot password?',
                                    style: GoogleFonts.poppins(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Sign In Button (dims while loading)
                            AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: _isLoading ? 0.7 : 1.0,
                              child: Container(
                                width: double.infinity,
                                height: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  gradient: const LinearGradient(
                                    colors: [
                                      AppColors.primaryBlue,
                                      Color(0xFF1E40AF),
                                    ],
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primaryBlue
                                          .withValues(alpha: 0.3),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    disabledBackgroundColor: Colors.transparent,
                                    shadowColor: Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: _isLoading ? null : _handleLogin,
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 22,
                                          width: 22,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2.5,
                                          ),
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              'Sign In',
                                              style: GoogleFonts.poppins(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
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
                            ),
                            const SizedBox(height: 22),

                            // Sign Up Redirection Link
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "Don't have an account? ",
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            const SignUpScreen(),
                                      ),
                                    );
                                  },
                                  child: Text(
                                    'Sign Up',
                                    style: GoogleFonts.poppins(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Reusable text field with darker label text, blue focus border and
  /// red inline error styling.
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hintText,
    bool isPassword = false,
    bool isVisible = false,
    VoidCallback? onToggleVisibility,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.next,
    Iterable<String>? autofillHints,
    String? errorText,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) {
    const errorColor = Color(0xFFEF4444);

    OutlineInputBorder border(Color color, [double width = 1.0]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return TextFormField(
      controller: controller,
      obscureText: isPassword && !isVisible,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      style: GoogleFonts.poppins(
        fontSize: 13,
        color: const Color(0xFF1E293B),
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(
          fontSize: 12,
          color: Colors.grey.shade700,
        ),
        hintText: hintText,
        hintStyle: GoogleFonts.poppins(
          fontSize: 12,
          color: Colors.grey.shade500,
        ),
        floatingLabelStyle: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: errorText != null ? errorColor : AppColors.primaryBlue,
        ),
        errorText: errorText,
        errorMaxLines: 2,
        errorStyle: GoogleFonts.poppins(
          fontSize: 11,
          color: errorColor,
          fontWeight: FontWeight.w500,
        ),
        prefixIcon: Icon(
          icon,
          color: errorText != null ? errorColor : AppColors.primaryBlue,
          size: 20,
        ),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  isVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: Colors.grey.shade600,
                  size: 20,
                ),
                onPressed: onToggleVisibility,
              )
            : null,
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14,
          horizontal: 16,
        ),
        enabledBorder: border(Colors.grey.shade300),
        focusedBorder: border(AppColors.primaryBlue, 1.8),
        errorBorder: border(errorColor, 1.2),
        focusedErrorBorder: border(errorColor, 1.8),
      ),
    );
  }
}

class _Bubble {
  final double x;
  final double size;
  final double speed;
  final double opacity;
  final Color color;

  _Bubble({
    required this.x,
    required this.size,
    required this.speed,
    required this.opacity,
    required this.color,
  });
}

class _BubblePainter extends CustomPainter {
  final List<_Bubble> bubbles;
  final double progress;

  _BubblePainter({
    required this.bubbles,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var bubble in bubbles) {
      final yProgress = (1.0 - ((progress * bubble.speed) % 1.0));
      final dx = bubble.x * size.width;
      final dy = yProgress * (size.height + bubble.size * 2) - bubble.size;

      final paint = Paint()
        ..color = bubble.color.withValues(alpha: bubble.opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(dx, dy), bubble.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) => true;
}
