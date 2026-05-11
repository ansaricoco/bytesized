import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bytesized/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase with dummy values or hardcoded keys if dotenv is unavailable.
  // Replace these with your actual project credentials or a secure configuration method.
  await Supabase.initialize(
    url: 'https://ahethxfibhsgcztlepzw.supabase.co',
    anonKey: 'sb_publishable_MwBXLpCeSNyBhtdxs2dRwA_YDis7IkM',
  );
  runApp(const ImageCompressorApp());
}

class ImageCompressorApp extends StatelessWidget {
  const ImageCompressorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Compressor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          surface: Color(0xFF1A1A1A),
          primary: Color(0xFF2563EB),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}