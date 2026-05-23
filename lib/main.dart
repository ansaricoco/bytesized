import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bytesized/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Increase Flutter's image cache to 250 MB so large images can fit into
  // the cache without causing endless loading loops.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 250 * 1024 * 1024;

  await Supabase.initialize(
    url: 'https://zkkzuknacdpinvmxlhkl.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpra3p1a25hY2RwaW52bXhsaGtsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0OTM1ODIsImV4cCI6MjA5NDA2OTU4Mn0.YxvGNFyT-r6M7YxLRZK_ApUEZdtNOifoMFtXV_n-Wig',
  );

  runApp(const ImageCompressorApp());
}

class ImageCompressorApp extends StatelessWidget {
  const ImageCompressorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ByteSized',
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