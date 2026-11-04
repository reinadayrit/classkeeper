import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../constants/app_colors.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _bubbleController;
  final List<_Bubble> _bubbles = [];
  final Random _random = Random();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _schoolIdController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  String _selectedRole = 'student';
  bool _isLoading = false;
  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;

  // Inline field errors (shown under the field in red)
  String? _nameError;
  String? _idError;
  String? _emailError;
  String? _passwordError;

  static const Color _errorColor = Color(0xFFEF4444);
  static const Color _successColor = Color(0xFF16A34A);

  // Only school emails ending in @davao.sti.edu.ph are accepted
  static final RegExp _schoolEmailRegex = RegExp(
    r'^[\w.+\-]+@davao\.sti\.edu\.ph$',
    caseSensitive: false,
  );

  bool get _isFaculty => _selectedRole == 'faculty';

  @override
  void initState() {
    super.initState();

    _bubbleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();

    // Softer ambient particles in Yellow and Blue
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
    _nameController.dispose();
    _schoolIdController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
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

  Future<void> _handleSignUp() async {
    final name = _nameController.text.trim();
    final schoolIdText = _isFaculty
        ? _schoolIdController.text.trim().toUpperCase()
        : _schoolIdController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    // Inline validation (red text under each field)
    String? nameErr;
    String? idErr;
    String? emailErr;
    String? passErr;

    if (name.isEmpty) nameErr = 'Please enter your full name.';

    if (schoolIdText.isEmpty) {
      idErr = 'Please enter your ${_isFaculty ? 'Faculty' : 'School'} ID.';
    } else if (_isFaculty) {
      // Faculty ID: 7 alphanumeric characters starting with DAV (e.g. DAV9607)
      if (!RegExp(r'^DAV[A-Z0-9]{4}$').hasMatch(schoolIdText)) {
        idErr = 'Faculty ID must be 7 characters starting with DAV.';
      }
    } else if (!RegExp(r'^\d{11}$').hasMatch(schoolIdText)) {
      idErr = 'School ID must be exactly 11 digits.';
    }

    if (email.isEmpty) {
      emailErr = 'Please enter your school email.';
    } else if (!_schoolEmailRegex.hasMatch(email)) {
      emailErr = 'Use your school email ending in @davao.sti.edu.ph';
    }

    if (password.isEmpty) {
      passErr = 'Please enter a password.';
    } else if (_passwordRules(password).any((r) => !r.met)) {
      passErr =
          'Use 8+ characters with upper & lower case, a number and a symbol.';
    }

    if (nameErr != null ||
        idErr != null ||
        emailErr != null ||
        passErr != null) {
      setState(() {
        _nameError = nameErr;
        _idError = idErr;
        _emailError = emailErr;
        _passwordError = passErr;
      });
      return;
    }

    if (password != confirm) {
      // The red "Passwords do not match" text is already shown live
      // under the Confirm Password field.
      _showNotification('Passwords do not match.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': name,
          'school_id': schoolIdText,
          'role': _selectedRole,
        },
      );

      final user = response.user;
      if (user != null) {
        // Fallback upsert directly into 'profiles' table to guarantee row creation
        await Supabase.instance.client.from('profiles').upsert({
          'id': user.id,
          'email': user.email,
          'full_name': name,
          'school_id': schoolIdText,
          'role': _selectedRole,
        });
      }

      if (!mounted) return;

      _showNotification('Registration successful! Please log in.',
          isError: false);

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context);
    } on SocketException catch (_) {
      if (mounted) {
        _showNotification(
            'No internet connection. Unable to connect to network.');
      }
    } on AuthException catch (e) {
      if (mounted) {
        final errLower = e.message.toLowerCase();
        if (errLower.contains('network') ||
            errLower.contains('connection') ||
            errLower.contains('failed to fetch') ||
            errLower.contains('socket') ||
            errLower.contains('host lookup')) {
          _showNotification(
              'No internet connection. Unable to connect to network.');
        } else if (errLower.contains('already registered') ||
            errLower.contains('already exists')) {
          setState(() => _emailError = 'This email is already registered.');
        } else {
          _showNotification(e.message);
        }
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
          _showNotification('An unexpected error occurred. Please try again.');
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Password rules: 8+ chars, upper, lower, number and special character.
  List<_PasswordRule> _passwordRules(String password) {
    return [
      _PasswordRule('8+ characters', password.length >= 8),
      _PasswordRule('Uppercase (A-Z)', RegExp(r'[A-Z]').hasMatch(password)),
      _PasswordRule('Lowercase (a-z)', RegExp(r'[a-z]').hasMatch(password)),
      _PasswordRule('Number (0-9)', RegExp(r'[0-9]').hasMatch(password)),
      _PasswordRule(
          'Special (!@#\$%...)', RegExp(r'[^A-Za-z0-9\s]').hasMatch(password)),
    ];
  }

  /// Compact password strength indicator (bar + label), shown only
  /// while the student is typing a password.
  Widget _buildStrengthIndicator() {
    final password = _passwordController.text;
    if (password.isEmpty) return const SizedBox.shrink();

    final score = _passwordRules(password).where((r) => r.met).length; // 0-5

    late final String label;
    late final Color color;
    late final int filled; // out of 4 segments

    if (score <= 2) {
      label = 'Weak';
      color = _errorColor;
      filled = 1;
    } else if (score == 3) {
      label = 'Fair';
      color = const Color(0xFFF59E0B);
      filled = 2;
    } else if (score == 4) {
      label = 'Good';
      color = const Color(0xFF3B82F6);
      filled = 3;
    } else {
      label = 'Strong';
      color = _successColor;
      filled = 4;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: List.generate(4, (i) {
                return Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 5,
                    margin: EdgeInsets.only(right: i == 3 ? 0 : 4),
                    decoration: BoxDecoration(
                      color: i < filled ? color : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    final confirmText = _confirmPasswordController.text;
    final passwordsMatch =
        confirmText.isNotEmpty && confirmText == _passwordController.text;
    final passwordsMismatch =
        confirmText.isNotEmpty && confirmText != _passwordController.text;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(color: Colors.white),
          ),
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
                      // Static Enlarged ClassKeeper Logo
                      Image.asset(
                        'assets/images/sign.png',
                        height: 120,
                        width: 240,
                        fit: BoxFit.contain,
                        errorBuilder: (ctx, err, stack) => const Icon(
                          Icons.qr_code_2_rounded,
                          size: 80,
                          color: AppColors.primaryBlue,
                        ),
                      ),

                      // "CREATE YOUR ACCOUNT" under the logo
                      Transform.translate(
                        offset: const Offset(0, -16),
                        child: Text(
                          'CREATE YOUR ACCOUNT',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: AppColors.primaryBlue,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Main Sign Up Card Container
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
                              'REGISTER AS',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.8,
                                color: AppColors.primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 10),

                            // Role Selector Tab (taller for easier tapping)
                            Container(
                              height: 48,
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  _buildRoleTab('Student', 'student'),
                                  _buildRoleTab('Faculty', 'faculty'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Full Name Field
                            _buildTextField(
                              controller: _nameController,
                              label: 'Full Name',
                              icon: Icons.person_outline_rounded,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.name],
                              errorText: _nameError,
                              onChanged: (_) {
                                if (_nameError != null) {
                                  setState(() => _nameError = null);
                                }
                              },
                            ),
                            const SizedBox(height: 12),

                            // School / Faculty ID Field
                            _buildTextField(
                              controller: _schoolIdController,
                              label: _isFaculty
                                  ? 'Faculty ID (e.g., DAV9607)'
                                  : 'School ID (e.g., 02000139794)',
                              icon: Icons.badge_outlined,
                              keyboardType: _isFaculty
                                  ? TextInputType.text
                                  : TextInputType.number,
                              textCapitalization: _isFaculty
                                  ? TextCapitalization.characters
                                  : TextCapitalization.none,
                              maxLength: _isFaculty ? 7 : 11,
                              inputFormatters: _isFaculty
                                  ? [
                                      FilteringTextInputFormatter.allow(
                                          RegExp(r'[A-Za-z0-9]')),
                                      _UpperCaseFormatter(),
                                    ]
                                  : [FilteringTextInputFormatter.digitsOnly],
                              textInputAction: TextInputAction.next,
                              errorText: _idError,
                              onChanged: (_) {
                                if (_idError != null) {
                                  setState(() => _idError = null);
                                }
                              },
                            ),
                            const SizedBox(height: 12),

                            // School Email Field
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
                            const SizedBox(height: 12),

                            // Password Field
                            _buildTextField(
                              controller: _passwordController,
                              label: 'Password',
                              icon: Icons.lock_outline_rounded,
                              isPassword: true,
                              isVisible: _isPasswordVisible,
                              textInputAction: TextInputAction.next,
                              errorText: _passwordError,
                              onChanged: (_) {
                                // rebuild so the confirm-password indicator
                                // stays in sync while typing
                                setState(() => _passwordError = null);
                              },
                              onToggleVisibility: () {
                                setState(() {
                                  _isPasswordVisible = !_isPasswordVisible;
                                });
                              },
                            ),
                            // Password strength indicator
                            _buildStrengthIndicator(),
                            const SizedBox(height: 12),

                            // Confirm Password Field (live match indicator)
                            _buildTextField(
                              controller: _confirmPasswordController,
                              label: 'Confirm Password',
                              icon: Icons.lock_outline_rounded,
                              isPassword: true,
                              isVisible: _isConfirmPasswordVisible,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) {
                                if (!_isLoading) _handleSignUp();
                              },
                              errorText: passwordsMismatch
                                  ? 'Passwords do not match.'
                                  : null,
                              helperText:
                                  passwordsMatch ? 'Passwords match' : null,
                              helperColor: _successColor,
                              helperIcon: passwordsMatch
                                  ? Icons.check_circle_rounded
                                  : null,
                              onChanged: (_) => setState(() {}),
                              onToggleVisibility: () {
                                setState(() {
                                  _isConfirmPasswordVisible =
                                      !_isConfirmPasswordVisible;
                                });
                              },
                            ),
                            const SizedBox(height: 22),

                            // Create Account Primary Button (dims while loading)
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
                                  onPressed: _isLoading ? null : _handleSignUp,
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
                                              'Create Account',
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
                            const SizedBox(height: 12),

                            // Terms line
                            Center(
                              child: Text(
                                'By creating an account, you agree to the\nTerms and Privacy Policy.',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.poppins(
                                  fontSize: 10.5,
                                  height: 1.4,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Sign In Redirect Link
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "Already have an account? ",
                                  style: GoogleFonts.poppins(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => Navigator.pop(context),
                                  child: Text(
                                    'Sign In',
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

  /// Reusable text field: darker label text, blue focus border,
  /// red inline errors and optional helper text.
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
    TextCapitalization textCapitalization = TextCapitalization.none,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
    String? errorText,
    String? helperText,
    Color? helperColor,
    IconData? helperIcon,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) {
    OutlineInputBorder border(Color color, [double width = 1.0]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    final hasHelper = helperText != null && errorText == null;
    final hColor = helperColor ?? Colors.grey.shade600;

    return TextFormField(
      controller: controller,
      obscureText: isPassword && !isVisible,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      maxLength: maxLength,
      inputFormatters: inputFormatters,
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
          color: errorText != null ? _errorColor : AppColors.primaryBlue,
        ),
        counterText: '',
        errorText: errorText,
        errorMaxLines: 2,
        errorStyle: GoogleFonts.poppins(
          fontSize: 11,
          color: _errorColor,
          fontWeight: FontWeight.w500,
        ),
        helper: hasHelper
            ? Row(
                children: [
                  if (helperIcon != null) ...[
                    Icon(helperIcon, size: 14, color: hColor),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      helperText,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: hColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              )
            : null,
        prefixIcon: Icon(
          icon,
          color: errorText != null ? _errorColor : AppColors.primaryBlue,
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
        errorBorder: border(_errorColor, 1.2),
        focusedErrorBorder: border(_errorColor, 1.8),
      ),
    );
  }

  Widget _buildRoleTab(String label, String value) {
    final isSelected = _selectedRole == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_selectedRole == value) return;
          setState(() {
            _selectedRole = value;
            // Student and Faculty IDs use different formats
            _schoolIdController.clear();
            _idError = null;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : [],
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected ? AppColors.primaryBlue : Colors.grey.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Forces typed characters to upper case (for the DAV faculty ID).
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

class _PasswordRule {
  final String label;
  final bool met;

  const _PasswordRule(this.label, this.met);
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
