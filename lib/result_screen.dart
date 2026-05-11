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
  int _currentIndex = 0;

  late List<bool> _processingList;
  late List<Uint8List?> _resultBytesList;
  late List<Uint8List?> _residualBytesList;
  late List<String?> _errorMsgList;
  late List<String?> _inputResolutionList;
  late List<String?> _resultResolutionList;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final count = widget.imageBytesList.length;
    _processingList = List.filled(count, true);
    _resultBytesList = List.filled(count, null);
    _residualBytesList = List.filled(count, null);
    _errorMsgList = List.filled(count, null);
    _inputResolutionList = List.filled(count, null);
    _resultResolutionList = List.filled(count, null);

    for (int i = 0; i < count; i++) {
      _fetchInputResolution(i);
      _process(i);
    }
  }

  Future<void> _fetchInputResolution(int index) async {
    try {
      final img = await decodeImageFromList(widget.imageBytesList[index]);
      if (mounted) {
        setState(() => _inputResolutionList[index] = '${img.width} x ${img.height}');
      }
    } catch (_) {}
  }

  Future<void> _process(int index) async {
    try {
      Uint8List result;
      final imageBytes = widget.imageBytesList[index];
      final fileName = widget.fileNames[index];

      if (widget.mode == ActionMode.compress) {
        final quality = widget.preset?.quality ?? 80;
        result = await encodeToWebP(imageBytes, quality: quality);
        final residual = await computeResidual(imageBytes, result);
        if (mounted) {
          setState(() => _residualBytesList[index] = residual);
        }
      } else {
        if (fileName.toLowerCase().endsWith('.zip')) {
          final archive = await compute(_decodeZipTask, imageBytes);
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
          result = imageBytes;
        }
      }

      String? resResolution;
      try {
        final img = await decodeImageFromList(result);
        resResolution = '${img.width} x ${img.height}';
      } catch (_) {}

      if (mounted) {
        setState(() {
          _resultBytesList[index] = result;
          _resultResolutionList[index] = resResolution;
          _processingList[index] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsgList[index] = e.toString();
          _processingList[index] = false;
        });
      }
    }
  }

  Future<void> _save(int index) async {
    final result = _resultBytesList[index];
    if (result == null) return;
    final isCompress = widget.mode == ActionMode.compress;
    final fileName = widget.fileNames[index];
    final ext = isCompress 
        ? '.webp' 
        : (fileName.toLowerCase().endsWith('.zip') || fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${fileName.split('.').last}');
    final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}$ext';
    
    if (kIsWeb) {
      downloadBytes(result, outName);
    } else {
      try {
        final saveDir = await getAppSaveDirectory();
        final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
        final file = File('$dirPath/$outName');
        await file.writeAsBytes(result);
        
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

  Future<void> _saveZip(int index) async {
    final resultBytes = _resultBytesList[index];
    final residualBytes = _residualBytesList[index];
    if (resultBytes == null || residualBytes == null) return;
    
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

  Future<void> _share(int index) async {
    final result = _resultBytesList[index];
    if (result == null) return;
    final isCompress = widget.mode == ActionMode.compress;
    final fileName = widget.fileNames[index];
    final ext = isCompress 
        ? '.webp' 
        : (fileName.toLowerCase().endsWith('.zip') || fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${fileName.split('.').last}');
    final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}$ext';
    final mimeType = ext == '.png' 
        ? 'image/png' 
        : (ext == '.webp' 
            ? 'image/webp' 
            : (ext == '.jpg' || ext == '.jpeg' ? 'image/jpeg' : 'image/${ext.substring(1)}'));
    
    final xFile = XFile.fromData(result, name: outName, mimeType: mimeType);
    await Share.shareXFiles([xFile], text: 'Check out this image processed with ByteSized!');
  }

  Future<void> _saveAll() async {
    if (_processingList.any((p) => p)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please wait for all images to finish processing.')));
      return;
    }
    
    int savedCount = 0;
    for (int i = 0; i < widget.imageBytesList.length; i++) {
      final result = _resultBytesList[i];
      if (result == null) continue;

      final isCompress = widget.mode == ActionMode.compress;
      final fileName = widget.fileNames[i];
      final ext = isCompress 
          ? '.webp' 
          : (fileName.toLowerCase().endsWith('.zip') || fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${fileName.split('.').last}');
      final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}_$i$ext';
      
      if (kIsWeb) {
        downloadBytes(result, outName);
      } else {
        try {
          final saveDir = await getAppSaveDirectory();
          final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
          final file = File('$dirPath/$outName');
          await file.writeAsBytes(result);
          try { await Gal.putImage(file.path); } catch (_) {}
        } catch (e) {
          debugPrint('Error saving $outName: $e');
        }
      }
      savedCount++;
    }
    
    if (mounted && !kIsWeb && savedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved $savedCount images successfully!')));
    }
  }

  Future<void> _shareAll() async {
    if (_processingList.any((p) => p)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please wait for all images to finish processing.')));
      return;
    }
    
    List<XFile> filesToShare = [];
    for (int i = 0; i < widget.imageBytesList.length; i++) {
      final result = _resultBytesList[i];
      if (result == null) continue;

      final isCompress = widget.mode == ActionMode.compress;
      final fileName = widget.fileNames[i];
      final ext = isCompress 
          ? '.webp' 
          : (fileName.toLowerCase().endsWith('.zip') || fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${fileName.split('.').last}');
      final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}_$i$ext';
      final mimeType = ext == '.png' ? 'image/png' : (ext == '.webp' ? 'image/webp' : (ext == '.jpg' || ext == '.jpeg' ? 'image/jpeg' : 'image/${ext.substring(1)}'));
      
      filesToShare.add(XFile.fromData(result, name: outName, mimeType: mimeType));
    }
    
    if (filesToShare.isNotEmpty) {
      await Share.shareXFiles(filesToShare, text: 'Check out these images processed with ByteSized!');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompress = widget.mode == ActionMode.compress;
    final hasMultiple = widget.imageBytesList.length > 1;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        title: Text(
          hasMultiple 
              ? '${isCompress ? 'Compress' : 'Decompress'} (${_currentIndex + 1}/${widget.imageBytesList.length})'
              : (isCompress ? 'Compress to WebP' : 'Reconstructed (Lossy + Residual)'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        elevation: 0,
        actions: [
          if (hasMultiple)
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Save All',
              onPressed: _saveAll,
            ),
          if (hasMultiple)
            IconButton(
              icon: const Icon(Icons.share_rounded),
              tooltip: 'Share All',
              onPressed: _shareAll,
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemCount: widget.imageBytesList.length,
        itemBuilder: (context, index) {
          return _ResultItemView(
            key: PageStorageKey(index),
            imageBytes: widget.imageBytesList[index],
            fileName: widget.fileNames[index],
            mode: widget.mode,
            preset: widget.preset,
            processing: _processingList[index],
            resultBytes: _resultBytesList[index],
            residualBytes: _residualBytesList[index],
            errorMsg: _errorMsgList[index],
            inputResolution: _inputResolutionList[index],
            resultResolution: _resultResolutionList[index],
            onSave: () => _save(index),
            onSaveZip: () => _saveZip(index),
            onShare: () => _share(index),
          );
        },
      ),
    );
  }
}

class _ResultItemView extends StatelessWidget {
  final Uint8List imageBytes;
  final String fileName;
  final ActionMode mode;
  final AppPreset? preset;

  final bool processing;
  final Uint8List? resultBytes;
  final Uint8List? residualBytes;
  final String? errorMsg;
  final String? inputResolution;
  final String? resultResolution;

  final VoidCallback onSave;
  final VoidCallback onSaveZip;
  final VoidCallback onShare;

  const _ResultItemView({
    super.key,
    required this.imageBytes,
    required this.fileName,
    required this.mode,
    this.preset,
    required this.processing,
    required this.resultBytes,
    required this.residualBytes,
    required this.errorMsg,
    required this.inputResolution,
    required this.resultResolution,
    required this.onSave,
    required this.onSaveZip,
    required this.onShare,
  });

  int get _originalSize => imageBytes.length;
  int get _resultSize => resultBytes?.length ?? 0;

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
  Widget build(BuildContext context) {
    final isCompress = mode == ActionMode.compress;

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
            if (fileName.toLowerCase().endsWith('.zip'))
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
                    imageBytes,
                    width: double.infinity,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            _InfoRow(
                label: 'Format',
                value: fileName.split('.').last.toUpperCase()),
            const SizedBox(height: 4),
            _InfoRow(
                label: 'Size', value: _formatSize(_originalSize)),
            if (inputResolution != null) ...[
              const SizedBox(height: 4),
              _InfoRow(label: 'Resolution', value: inputResolution!),
            ],

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

            if (processing)
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
            else if (errorMsg != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Text(errorMsg!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 13)),
              )
            else if (resultBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: Image.memory(
                    resultBytes!,
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
              if (resultResolution != null) ...[
                const SizedBox(height: 4),
                _InfoRow(label: 'Resolution', value: resultResolution!),
              ],
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
                  onPressed: onSave,
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
                  if (isCompress && residualBytes != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onSaveZip,
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
                      onPressed: onShare,
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