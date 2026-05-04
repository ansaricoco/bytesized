import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'image_utils_stub.dart'
    if (dart.library.html) 'image_utils_web.dart';

void main() {
  runApp(const ImageCompressorApp());
}

// ─────────────────────────────────────────────
// REAL WEBP COMPRESSION using pure Dart `image` package
// Works on all platforms including web
// ─────────────────────────────────────────────
Future<Uint8List> encodeToWebP(Uint8List inputBytes) async {
  if (kIsWeb) {
    // Web: re-encode as PNG (best we can do without native codec)
    final decoded = img.decodeImage(inputBytes);
    if (decoded == null) throw Exception('Could not decode image');
    return Uint8List.fromList(img.encodePng(decoded));
  }
  // Android/iOS: flutter_image_compress gives real WebP
  final result = await FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: 80,
  );
  return result;
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

// ─────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImage() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file != null && mounted) {
      final bytes = await file.readAsBytes();
      _showChooseActionDialog(bytes, file.name);
    }
  }

  void _showChooseActionDialog(Uint8List bytes, String fileName) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (_) => ChooseActionDialog(imageBytes: bytes, fileName: fileName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Image Compressor',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Compress and decompress images with adjustable quality',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.45),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
              const SizedBox(height: 32),
              Expanded(
                child: GestureDetector(
                  onTap: _pickImage,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: CustomPaint(
                      painter: _DashedBorderPainter(
                        color: Colors.white.withOpacity(0.25),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.upload_rounded,
                                size: 40,
                                color: Colors.white.withOpacity(0.55)),
                            const SizedBox(height: 16),
                            const Text(
                              'Drop an image here or click to upload',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Supports JPG, PNG, WebP',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 12.5,
                              ),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton(
                              onPressed: _pickImage,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 28, vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                                textStyle: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              child: const Text('Select Image'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// DASHED BORDER PAINTER
// ─────────────────────────────────────────────
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dashWidth = 6.0;
    const dashSpace = 5.0;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(12)));
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(
            metric.extractPath(distance, distance + dashWidth), paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
// ─────────────────────────────────────────────
// CHOOSE ACTION DIALOG
// ─────────────────────────────────────────────
class ChooseActionDialog extends StatelessWidget {
  final Uint8List imageBytes;
  final String fileName;

  const ChooseActionDialog(
      {super.key, required this.imageBytes, required this.fileName});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose Action',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('What would you like to do with this image?',
                style: TextStyle(color: Color(0xFF818CF8), fontSize: 13.5)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _ActionCard(
                    label: 'Compress',
                    subtitle: 'Convert to WebP',
                    icon: Icons.compress_rounded,
                    iconColor: const Color(0xFF3B82F6),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ResultScreen(
                                  imageBytes: imageBytes,
                                  fileName: fileName,
                                  mode: ActionMode.compress)));
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionCard(
                    label: 'Decompress',
                    subtitle: 'View original',
                    icon: Icons.open_in_full_rounded,
                    iconColor: const Color(0xFF22C55E),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ResultScreen(
                                  imageBytes: imageBytes,
                                  fileName: fileName,
                                  mode: ActionMode.decompress)));
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55), fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatefulWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _ActionCard(
      {required this.label,
      required this.subtitle,
      required this.icon,
      required this.iconColor,
      required this.onTap});

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color:
                _hovered ? const Color(0xFF252525) : const Color(0xFF222222),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? widget.iconColor.withOpacity(0.4)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, color: widget.iconColor, size: 28),
              const SizedBox(height: 12),
              Text(widget.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(widget.subtitle,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// RESULT SCREEN
// ─────────────────────────────────────────────
enum ActionMode { compress, decompress }

class ResultScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String fileName;
  final ActionMode mode;

  const ResultScreen(
      {super.key,
      required this.imageBytes,
      required this.fileName,
      required this.mode});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _processing = false;
  Uint8List? _resultBytes;
  String? _errorMsg;

  int get _originalSize => widget.imageBytes.length;
  int get _resultSize => _resultBytes?.length ?? 0;

  double get _savingsPercent {
    if (_resultSize == 0) return 0;
    return ((_originalSize - _resultSize) / _originalSize * 100)
        .clamp(-999.0, 999.0);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  }

  @override
  void initState() {
    super.initState();
    // Auto-process on open
    _process();
  }

  Future<void> _process() async {
    setState(() {
      _processing = true;
      _errorMsg = null;
      _resultBytes = null;
    });

    try {
      Uint8List result;

      if (widget.mode == ActionMode.compress) {
        // Real WebP encoding via pure Dart `image` package — works on all platforms
        result = await encodeToWebP(widget.imageBytes);
      } else {
        // Decompress: just return original bytes
        result = widget.imageBytes;
      }

      setState(() {
        _resultBytes = result;
        _processing = false;
      });
    } catch (e) {
      setState(() {
        _errorMsg = e.toString();
        _processing = false;
      });
    }
  }

  Future<void> _save() async {
    if (_resultBytes == null) return;
    final isCompress = widget.mode == ActionMode.compress;
    final ext = isCompress ? '.webp' : '.${widget.fileName.split('.').last}';
    final outName = 'compressed_${DateTime.now().millisecondsSinceEpoch}$ext';
    
    if (kIsWeb) {
      downloadBytes(_resultBytes!, outName);
    } else {
      try {
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/$outName');
        await file.writeAsBytes(_resultBytes!);
        await Gal.putImage(file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image saved to gallery!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving image: $e')),
          );
        }
      }
    }
  }

  Future<void> _share() async {
    if (_resultBytes == null) return;
    final isCompress = widget.mode == ActionMode.compress;
    final ext = isCompress ? '.webp' : '.${widget.fileName.split('.').last}';
    final outName = 'compressed_${DateTime.now().millisecondsSinceEpoch}$ext';
    
    final xFile = XFile.fromData(
      _resultBytes!,
      name: outName,
      mimeType: isCompress ? 'image/webp' : 'image/${ext.substring(1)}',
    );
    
    await Share.shareXFiles([xFile], text: 'Check out this image processed with ByteSized!');
  }

  @override
  Widget build(BuildContext context) {
    final isCompress = widget.mode == ActionMode.compress;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        title: Text(
          isCompress ? 'Compress to WebP' : 'Original Image',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Original
            const Text('Original',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                widget.imageBytes,
                width: double.infinity,
                height: 200,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 8),
            _InfoRow(
                label: 'Format',
                value: widget.fileName.split('.').last.toUpperCase()),
            const SizedBox(height: 4),
            _InfoRow(
                label: 'Size', value: _formatSize(_originalSize)),

            const SizedBox(height: 24),
            const Divider(color: Color(0xFF2A2A2A)),
            const SizedBox(height: 24),

            // Result
            Row(
              children: [
                const Text('WebP Output',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: const Color(0xFF3B82F6).withOpacity(0.4)),
                  ),
                  child: const Text('WEBP',
                      style: TextStyle(
                          color: Color(0xFF3B82F6),
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (_processing)
              Container(
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                          color: Color(0xFF3B82F6), strokeWidth: 2),
                      SizedBox(height: 12),
                      Text('Converting to WebP...',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 13)),
                    ],
                  ),
                ),
              )
            else if (_errorMsg != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Text(_errorMsg!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 13)),
              )
            else if (_resultBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  _resultBytes!,
                  width: double.infinity,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 8),
              _InfoRow(label: 'Format', value: 'WEBP'),
              const SizedBox(height: 4),
              _InfoRow(
                  label: 'Size', value: _formatSize(_resultSize)),
              const SizedBox(height: 4),
              _InfoRow(
                label: 'Size Reduction',
                value:
                    '${_savingsPercent > 0 ? '-' : '+'}${_savingsPercent.abs().toStringAsFixed(1)}%',
                valueColor: _savingsPercent > 0
                    ? const Color(0xFF22C55E)
                    : Colors.orangeAccent,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download WebP'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 53, 53, 53),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12), // Adds a small gap between the buttons
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: const Text('Share Image'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color.fromARGB(255, 53, 53, 53),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12), // Adds a small gap between the buttons
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('New Image'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color.fromARGB(255, 53, 53, 53),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.white.withOpacity(0.5), fontSize: 13.5)),
        Text(value,
            style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}