import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_preset.dart';
import '../image_utils_stub.dart' if (dart.library.html) '../image_utils_web.dart';
import 'package:bytesized/file_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bytesized/image_processing.dart';

// ─────────────────────────────────────────────
// TOP LEVEL COMPUTE TASKS FOR WEB SUPPORT
// ─────────────────────────────────────────────
List<int>? _encodeZipTask(Map<String, Uint8List> data) {
  final archive = Archive();
  archive.addFile(ArchiveFile('image.webp', data['result']!.length, data['result']!));
  archive.addFile(ArchiveFile('residual.png', data['residual']!.length, data['residual']!));
  return ZipEncoder().encode(archive);
}

Archive _decodeZipTask(Uint8List bytes) {
  return ZipDecoder().decodeBytes(bytes);
}

// ─────────────────────────────────────────────
// RESULT SCREEN
// ─────────────────────────────────────────────
enum ActionMode { compress, decompress }

class ResultScreen extends StatefulWidget {
  final List<Uint8List> imageBytesList;
  final List<String> fileNames;
  final ActionMode mode;
  final AppPreset? preset;

  const ResultScreen({
    super.key,
    required this.imageBytesList,
    required this.fileNames,
    required this.mode,
    this.preset,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final PageController _pageController = PageController();
  late final List<Uint8List> _limitedBytes;
  late final List<String> _limitedNames;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();

    // Strictly enforce a limit of 5 files for processing to maintain 
    // memory stability and comply with storage upload quotas.
    if (widget.imageBytesList.length > 5) {
      _limitedBytes = widget.imageBytesList.take(5).toList();
      _limitedNames = widget.fileNames.take(5).toList();

      // Notify the user about the strict truncation
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Strict limit: Only 5 files allowed for processing.')),
          );
        }
      });
    } else {
      _limitedBytes = widget.imageBytesList;
      _limitedNames = widget.fileNames;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCompress = widget.mode == ActionMode.compress;
    final hasMultiple = _limitedBytes.length > 1;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        title: Text(
          hasMultiple 
              ? '${isCompress ? 'Compress' : 'Decompress'} (${_currentIndex + 1}/${_limitedBytes.length})'
              : (isCompress ? 'Compress to WebP' : 'Reconstructed (Lossy + Residual)'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        elevation: 0,
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemCount: _limitedBytes.length,
        itemBuilder: (context, index) {
          return _ResultItemView(
            imageBytes: _limitedBytes[index],
            fileName: _limitedNames[index],
            mode: widget.mode,
            preset: widget.preset,
          );
        },
      ),
    );
  }
}

class _ResultItemView extends StatefulWidget {
  final Uint8List imageBytes;
  final String fileName;
  final ActionMode mode;
  final AppPreset? preset;

  const _ResultItemView({
    required this.imageBytes,
    required this.fileName,
    required this.mode,
    this.preset,
  });

  @override
  State<_ResultItemView> createState() => _ResultItemViewState();
}

class _ResultItemViewState extends State<_ResultItemView> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _processing = false;
  Uint8List? _resultBytes;
  Uint8List? _residualBytes;
  bool _isUploading = false;
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
      _residualBytes = null;
    });

    try {
      Uint8List result;

      if (widget.mode == ActionMode.compress) {
        // Real WebP encoding via pure Dart `image` package — works on all platforms
        final quality = widget.preset?.quality ?? 80;
        result = await encodeToWebP(widget.imageBytes, quality: quality);
        // Calculate residual for potential zipping
        _residualBytes = await computeResidual(widget.imageBytes, result);
      } else {
        // Decompress: Handle ZIP metadata or direct image
        final lowerName = widget.fileName.toLowerCase();
        if (lowerName.endsWith('.zip') || lowerName.endsWith('.bytesized')) {
          final archive = await compute(_decodeZipTask, widget.imageBytes);
          ArchiveFile? lossyFile;
          ArchiveFile? residualFile;

          for (final file in archive) {
            if (file.name == 'image.webp') lossyFile = file;
            if (file.name == 'residual.png') residualFile = file;
          }

          if (lossyFile != null && residualFile != null) {
            final lossyBytes = Uint8List.fromList(lossyFile.content as List<int>);
            final resBytes = Uint8List.fromList(residualFile.content as List<int>);
            result = await reconstructFromResidual(lossyBytes, resBytes);
          } else if (lossyFile != null) {
            result = Uint8List.fromList(lossyFile.content as List<int>);
          } else {
            throw Exception('Invalid ZIP format: missing image.webp');
          }
        } else {
          // Decompress what it can (lossy output)
          result = widget.imageBytes;
        }
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
    final ext = isCompress 
        ? '.webp' 
        : (widget.fileName.toLowerCase().endsWith('.zip') || widget.fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${widget.fileName.split('.').last}');
    final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}$ext';
    
    if (kIsWeb) {
      downloadBytes(_resultBytes!, outName);
    } else {
      try {
        final saveDir = await getAppSaveDirectory();
        final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
        final file = File('$dirPath/$outName');
        await file.writeAsBytes(_resultBytes!);
        
        try {
          await Gal.putImage(file.path);
        } catch (_) {}
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image saved successfully!')),
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

  Future<void> _saveZip() async {
    if (_resultBytes == null || _residualBytes == null) return;
    
    final resultBytes = _resultBytes!;
    final residualBytes = _residualBytes!;

    // Offload heavy ZIP encoding to a background worker safe for Web/Desktop
    final zipBytesNullable = await compute(_encodeZipTask, {
      'result': resultBytes,
      'residual': residualBytes,
    });
    if (zipBytesNullable == null) return;
    final zipBytes = zipBytesNullable;

    final outName = 'compressed_with_residual_${DateTime.now().millisecondsSinceEpoch}.zip';

    if (kIsWeb) {
      downloadBytes(Uint8List.fromList(zipBytes), outName);
    } else {
      try {
        final saveDir = await getAppSaveDirectory();
        final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
        final file = File('$dirPath/$outName');
        await file.writeAsBytes(zipBytes);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ZIP saved to Downloads folder')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving ZIP: $e')));
        }
      }
    }
  }

  Future<void> _shareViaLink() async {
    if (_resultBytes == null || _residualBytes == null) return;

    setState(() => _isUploading = true);

    try {
      // 1. Create the .bytesized file (ZIP) in memory using background compute
      final zipBytes = await compute(_encodeZipTask, {
        'result': _resultBytes!,
        'residual': _residualBytes!,
      });
      
      if (zipBytes == null) {
        throw Exception('Failed to create archive for upload.');
      }

      // 2. Authenticate anonymously
      final authResponse = await Supabase.instance.client.auth.signInAnonymously();
      final userId = authResponse.user?.id;
      if (userId == null) {
        throw Exception('Authentication failed.');
      }

      // 3. Upload to Supabase Storage
      final fileName = 'reconstruction_${DateTime.now().millisecondsSinceEpoch}.bytesized';
      const bucketName = 'uploads'; // Ensure you have an 'uploads' bucket configured in Supabase Storage
      final path = '$userId/$fileName';

      await Supabase.instance.client.storage.from(bucketName).uploadBinary(
            path,
            Uint8List.fromList(zipBytes),
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: false,
            ),
          );

      // 4. Get download URL
      final downloadUrl = Supabase.instance.client.storage.from(bucketName).getPublicUrl(path);

      // 5. Share the link
      await Share.share(
        'Open this link with the ByteSized app to reconstruct the image:\n\n$downloadUrl',
        subject: 'ByteSized Image Reconstruction Link',
      );
    } on AuthException catch (e) {
      String message = 'Authentication failed: ${e.message}';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } on StorageException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Supabase Storage Error (${e.statusCode}): ${e.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share link: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _share() async {
    if (_resultBytes == null) return;
    final isCompress = widget.mode == ActionMode.compress;
    final ext = isCompress 
        ? '.webp' 
        : (widget.fileName.toLowerCase().endsWith('.zip') || widget.fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${widget.fileName.split('.').last}');
    final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}$ext';
    final mimeType = ext == '.png' 
        ? 'image/png' 
        : (ext == '.webp' 
            ? 'image/webp' 
            : (ext == '.jpg' || ext == '.jpeg' ? 'image/jpeg' : 'image/${ext.substring(1)}'));
    
    final xFile = XFile.fromData(
      _resultBytes!,
      name: outName,
      mimeType: mimeType,
    );
    
    await Share.shareXFiles([xFile], text: 'Check out this image processed with ByteSized!');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    final isCompress = widget.mode == ActionMode.compress;

    return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Input File
            const Text('Input File',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (widget.fileName.toLowerCase().endsWith('.zip') || widget.fileName.toLowerCase().endsWith('.bytesized'))
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_zip_rounded, size: 64, color: Color(0xFF818CF8)),
                    SizedBox(height: 12),
                    Text('ZIP Archive metadata', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: Image.memory(
                    widget.imageBytes,
                    width: double.infinity,
                    fit: BoxFit.contain,
                  ),
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
                Text(isCompress ? 'WebP Output' : 'Reconstructed Output',
                    style: const TextStyle(
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
                  child: Text(isCompress ? 'WEBP' : 'JPG',
                      style: const TextStyle(
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
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                          color: Color(0xFF3B82F6), strokeWidth: 2),
                      const SizedBox(height: 12),
                      Text(isCompress ? 'Converting to WebP...' : 'Reconstructing image...',
                          style: const TextStyle(
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: Image.memory(
                    _resultBytes!,
                    width: double.infinity,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _InfoRow(label: 'Format', value: isCompress ? 'WEBP' : 'JPG'),
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
                  label: Text(isCompress ? 'Download WebP' : 'Download Image'),
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
                  const SizedBox(height: 12),
                  if (isCompress && _residualBytes != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _saveZip,
                        icon: const Icon(Icons.archive_rounded, size: 18),
                        label: const Text('Download ZIP (WebP + Residual)'),
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
                    const SizedBox(height: 12),
                  ],
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
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isUploading ? null : _shareViaLink,
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: _isUploading
                          ? const Text('Generating Link...')
                          : const Text('Share via Link (for Messenger)'),
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
                  const SizedBox(height: 12),
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
        )
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

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