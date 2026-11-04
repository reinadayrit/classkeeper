import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'constants/app_typography.dart';
import 'screens/splash_screen.dart';

Future<void> main() async {
  // Ensure Flutter bindings are initialized before calling async methods
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://ycffcjtyxntokvcuwvsy.supabase.co',
    publishableKey: 'sb_publishable_gTKgFvSSHrusTWYhO5ijFA_m9QP6l-E',
  );

  runApp(const ClassKeeperApp());
}

class ClassKeeperApp extends StatelessWidget {
  const ClassKeeperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Class Keeper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF003366)),
        useMaterial3: true,
        fontFamily: 'Poppins',
        textTheme: AppTypography.textTheme,
      ),
      home: const SplashScreen(),
    );
  }
}
