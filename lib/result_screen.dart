import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../image_utils_stub.dart' if (dart.library.html) '../image_utils_web.dart';
import 'package:bytesized/file_utils.dart';
import 'package:bytesized/image_processing.dart';

// ─────────────────────────────────────────────
// TOP LEVEL COMPUTE TASKS FOR WEB SUPPORT
// ─────────────────────────────────────────────
List<int>? _encodeZipTask(Map<String, dynamic> data) {
  final archive = Archive();
  final result = data['result'] as Uint8List;
  final residual = data['residual'] as Uint8List;
  archive.addFile(ArchiveFile('image.webp', result.length, result));
  archive.addFile(ArchiveFile('residual.png', residual.length, residual));
  if (data['original'] != null) {
    final original = data['original'] as Uint8List;
    archive.addFile(ArchiveFile('original_image', original.length, original));
  }
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
  final List<XFile> files;
  final ActionMode mode;
  /// Quality (1–100). Only used in compress mode.
  final int quality;

  const ResultScreen({
    super.key,
    required this.files,
    required this.mode,
    this.quality = 80,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  late List<bool> _processingList;
  late List<bool> _wasDownsizedList;
  late List<Uint8List?> _resultBytesList;
  late List<Uint8List?> _residualBytesList;
  late List<Uint8List?> _inputDisplayBytesList;
  late List<int?> _originalSizeList;
  late List<String?> _errorMsgList;
  late List<String?> _inputResolutionList;
  late List<String?> _resultResolutionList;
  late List<double?> _mseList;
  late List<double?> _ssimList;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final count = widget.files.length;
    _processingList = List.filled(count, true);
    _wasDownsizedList = List.filled(count, false);
    _resultBytesList = List.filled(count, null);
    _residualBytesList = List.filled(count, null);
    _inputDisplayBytesList = List.filled(count, null);
    _originalSizeList = List.filled(count, null);
    _errorMsgList = List.filled(count, null);
    _inputResolutionList = List.filled(count, null);
    _resultResolutionList = List.filled(count, null);
    _mseList = List.filled(count, null);
    _ssimList = List.filled(count, null);

    _processAllSequentially(count);
  }

  Future<void> _processAllSequentially(int count) async {
    for (int i = 0; i < count; i++) {
      await _fetchInputResolution(i);
      await _process(i);
    }
  }

  Future<void> _fetchInputResolution(int index) async {
    try {
      final len = await widget.files[index].length();
      if (mounted) setState(() => _originalSizeList[index] = len);

      // Skip image decoding for ZIP files
      final fileName = widget.files[index].name.toLowerCase();
      final bytes = await widget.files[index].readAsBytes();
      if (fileName.endsWith('.zip') || _looksLikeZip(bytes)) return;

      final buffer = kIsWeb
          ? await ui.ImmutableBuffer.fromUint8List(bytes)
          : await ui.ImmutableBuffer.fromFilePath(
              widget.files[index].path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (mounted) {
        setState(() => _inputResolutionList[index] =
            '${descriptor.width} x ${descriptor.height}');
      }
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {}
  }

  Future<void> _process(int index) async {
    try {
      Uint8List workingBytes = await widget.files[index].readAsBytes();
      final fileName = widget.files[index].name;
      final isZip = fileName.toLowerCase().endsWith('.zip') ||
          _looksLikeZip(workingBytes);

      if (!isZip) {
        // ── Check file size limit ────────────────────────────────────────
        if (workingBytes.lengthInBytes > kMaxInputBytes) {
          throw Exception(
            'File too large (${(workingBytes.lengthInBytes / 1048576).toStringAsFixed(1)} MB). '
            'Maximum supported input size is ${kMaxInputBytes ~/ 1048576} MB.',
          );
        }

        // ── Check pixel count — downsize only if truly over the limit ────
        int width = 0, height = 0;
        try {
          final buffer =
              await ui.ImmutableBuffer.fromUint8List(workingBytes);
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          width = descriptor.width;
          height = descriptor.height;
          descriptor.dispose();
          buffer.dispose();
        } catch (_) {}

        final pixels = width * height;
        if (pixels > kMaxPixels) {
          // Show a warning before downsizing
          if (mounted) {
            setState(() => _wasDownsizedList[index] = true);
          }
          workingBytes = await safeDownsizeIfNeeded(workingBytes);

          // Update resolution display after downsize
          try {
            final buffer =
                await ui.ImmutableBuffer.fromUint8List(workingBytes);
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            if (mounted) {
              setState(() {
                _originalSizeList[index] = workingBytes.lengthInBytes;
                _inputResolutionList[index] =
                    '${descriptor.width} x ${descriptor.height}';
              });
            }
            descriptor.dispose();
            buffer.dispose();
          } catch (_) {}
        }

        // ── Normalize HEIC/HEIF → JPEG so the image package can decode it ──
        workingBytes = await normalizeToDecodable(workingBytes, fileName);

        if (mounted) {
          setState(() => _inputDisplayBytesList[index] = workingBytes);
        }
      }

      Uint8List result;

      if (widget.mode == ActionMode.compress) {
        final output = await compressAndComputeResidual(
          workingBytes,
          quality: widget.quality,
        );

        result = output['lossy']!;
        final residual = output['residual']!;

        final metricsRef = workingBytes;
        workingBytes = Uint8List(0); // release for GC

        final metrics = await computeImageMetrics(metricsRef, result);

        if (mounted) {
          setState(() {
            _residualBytesList[index] = residual;
            _mseList[index] = metrics['mse'];
            _ssimList[index] = metrics['ssim'];
          });
        }
      } else {
        result = await _decompressFile(index, workingBytes);
        workingBytes = Uint8List(0);
      }

      String? resResolution;
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(result);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        resResolution = '${descriptor.width} x ${descriptor.height}';
        descriptor.dispose();
        buffer.dispose();
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

  /// Checks ZIP magic bytes (PK header).
  bool _looksLikeZip(Uint8List bytes) {
    return bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  Future<Uint8List> _decompressFile(int index, Uint8List bytes) async {
    final fileName = widget.files[index].name.toLowerCase();
    if (!fileName.endsWith('.zip') && !_looksLikeZip(bytes)) return bytes;

    Archive archive;
    try {
      archive = await compute(_decodeZipTask, bytes);
    } catch (e) {
      throw Exception('Could not open ZIP: $e');
    }

    ArchiveFile? lossyFile, residualFile, originalFile;

    for (final file in archive) {
      if (file.isFile) {
        final n = file.name.toLowerCase();
        if (n == 'image.webp') lossyFile = file;
        if (n == 'residual.png') residualFile = file;
        if (n == 'original_image') originalFile = file;
      }
    }

    if (lossyFile == null) {
      for (final file in archive) {
        if (file.isFile) {
          final n = file.name.toLowerCase();
          final isImage = n.endsWith('.webp') ||
              n.endsWith('.jpg') ||
              n.endsWith('.jpeg') ||
              n.endsWith('.png');
          if (isImage) {
            return Uint8List.fromList(file.content as List<int>);
          }
        }
      }
      throw Exception('No supported image found in ZIP.');
    }

    final lossyBytes =
        Uint8List.fromList(lossyFile.content as List<int>);
    if (residualFile == null) return lossyBytes;

    final resBytes =
        Uint8List.fromList(residualFile.content as List<int>);
    final result = await reconstructFromResidual(lossyBytes, resBytes);

    if (originalFile != null && mounted) {
      final origBytes =
          Uint8List.fromList(originalFile.content as List<int>);
      final metrics = await computeImageMetrics(origBytes, result);
      if (mounted) {
        setState(() {
          _mseList[index] = metrics['mse'];
          _ssimList[index] = metrics['ssim'];
          // Override the ZIP file size with the actual original image's size
          _originalSizeList[index] = origBytes.length;
        });
      }
    }

    return result;
  }

  // ── Save helpers ──────────────────────────────────────────────────────────

  Future<void> _save(int index) async {
    final result = _resultBytesList[index];
    if (result == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SaveDialog(
        title: 'Saved!',
        processingText: 'Saving image...',
        saveTask: () async {
          final isCompress = widget.mode == ActionMode.compress;
          final fileName = widget.files[index].name;
          final rawBytes = await widget.files[index].readAsBytes();
          final isZipDecompress = !isCompress &&
              (fileName.toLowerCase().endsWith('.zip') ||
                  _looksLikeZip(rawBytes));

          final ext = isCompress
              ? '.webp'
              : (isZipDecompress
                  ? '.jpg'
                  : '.${fileName.split('.').last}');
          final prefix = isCompress
              ? 'compressed'
              : (isZipDecompress ? 'reconstructed' : 'downloaded');
          final outName =
              '${prefix}_${DateTime.now().millisecondsSinceEpoch}$ext';

          if (kIsWeb) {
            downloadBytes(result, outName);
            return 'Image download started.';
          } else {
            final saveDir = await getAppSaveDirectory();
            final dirPath =
                saveDir?.path ?? (await getTemporaryDirectory()).path;
            final file = File('$dirPath/$outName');
            await file.writeAsBytes(result);
            try {
              await Gal.putImage(file.path);
            } catch (_) {}
            return 'Image saved successfully!';
          }
        },
      ),
    );
  }

  Future<void> _saveZip(int index) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SaveDialog(
        title: 'Saved!',
        processingText: 'Saving ZIP archive...',
        saveTask: () async {
          final fileName = widget.files[index].name;
          final rawBytes = await widget.files[index].readAsBytes();
          final isIncomingZip = widget.mode == ActionMode.decompress &&
              (fileName.toLowerCase().endsWith('.zip') ||
                  _looksLikeZip(rawBytes));

          if (isIncomingZip) {
            final outName =
                'downloaded_archive_${DateTime.now().millisecondsSinceEpoch}.zip';
            if (kIsWeb) {
              downloadBytes(rawBytes, outName);
              return 'ZIP download started.';
            } else {
              final saveDir = await getAppSaveDirectory();
              final dirPath =
                  saveDir?.path ?? (await getTemporaryDirectory()).path;
              final file = File('$dirPath/$outName');
              await file.writeAsBytes(rawBytes);
              return 'ZIP saved to Downloads folder!';
            }
          }

          final resultBytes = _resultBytesList[index];
          final residualBytes = _residualBytesList[index];
          if (resultBytes == null || residualBytes == null) {
            throw Exception('Processing not finished yet.');
          }

          final zipBytesNullable = await compute(_encodeZipTask, {
            'result': resultBytes,
            'residual': residualBytes,
            'original': await widget.files[index].readAsBytes(),
          });

          if (zipBytesNullable == null) {
            throw Exception('Failed to encode ZIP archive.');
          }

          final outName =
              'compressed_with_residual_${DateTime.now().millisecondsSinceEpoch}.zip';

          if (kIsWeb) {
            downloadBytes(Uint8List.fromList(zipBytesNullable), outName);
            return 'ZIP download started.';
          } else {
            final saveDir = await getAppSaveDirectory();
            final dirPath =
                saveDir?.path ?? (await getTemporaryDirectory()).path;
            final file = File('$dirPath/$outName');
            await file.writeAsBytes(zipBytesNullable);
            return 'ZIP saved to Downloads folder!';
          }
        },
      ),
    );
  }

  Future<void> _saveAll() async {
    if (_processingList.any((p) => p)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Please wait for all images to finish processing.')));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SaveDialog(
        title: 'Saved All!',
        processingText: 'Saving all images...',
        saveTask: () async {
          int savedCount = 0;
          for (int i = 0; i < widget.files.length; i++) {
            final result = _resultBytesList[i];
            if (result == null) continue;

            final isCompress = widget.mode == ActionMode.compress;
            final fileName = widget.files[i].name;
            final isZipDecompress =
                !isCompress && fileName.toLowerCase().endsWith('.zip');

            final ext = isCompress
                ? '.webp'
                : (isZipDecompress
                    ? '.jpg'
                    : '.${fileName.split('.').last}');
            final prefix = isCompress
                ? 'compressed'
                : (isZipDecompress ? 'reconstructed' : 'downloaded');
            final outName =
                '${prefix}_${DateTime.now().millisecondsSinceEpoch}_${i}$ext';

            if (kIsWeb) {
              downloadBytes(result, outName);
            } else {
              final saveDir = await getAppSaveDirectory();
              final dirPath =
                  saveDir?.path ?? (await getTemporaryDirectory()).path;
              final file = File('$dirPath/$outName');
              await file.writeAsBytes(result);
              try {
                await Gal.putImage(file.path);
              } catch (_) {}
            }
            savedCount++;
          }

          if (savedCount == 0) throw Exception('No images to save.');
          return kIsWeb
              ? 'Started downloading $savedCount images!'
              : 'Saved $savedCount images successfully!';
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompress = widget.mode == ActionMode.compress;
    final hasMultiple = widget.files.length > 1;
    final currentFileName =
        widget.files.isNotEmpty ? widget.files[_currentIndex].name : '';
    final isZipDecompress =
        !isCompress && currentFileName.toLowerCase().endsWith('.zip');

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        foregroundColor: Colors.white,
        title: Text(
          hasMultiple
              ? '${isCompress ? 'Compress' : (isZipDecompress ? 'Decompress' : 'View')} (${_currentIndex + 1}/${widget.files.length})'
              : (isCompress
                  ? 'Compress to WebP'
                  : (isZipDecompress
                      ? 'Reconstructed (Lossy + Residual)'
                      : 'Downloaded Image')),
          style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        elevation: 0,
        actions: [
          if (hasMultiple)
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Save All',
              onPressed: _saveAll,
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) =>
            setState(() => _currentIndex = index),
        itemCount: widget.files.length,
        itemBuilder: (context, index) {
          return _ResultItemView(
            key: PageStorageKey(index),
            file: widget.files[index],
            inputBytesForDisplay: _inputDisplayBytesList[index],
            originalSize: _originalSizeList[index],
            mode: widget.mode,
            quality: widget.quality,
            processing: _processingList[index],
            wasDownsized: _wasDownsizedList[index],
            resultBytes: _resultBytesList[index],
            residualBytes: _residualBytesList[index],
            errorMsg: _errorMsgList[index],
            inputResolution: _inputResolutionList[index],
            resultResolution: _resultResolutionList[index],
            mse: _mseList[index],
            ssim: _ssimList[index],
            onSave: () => _save(index),
            onSaveZip: () => _saveZip(index),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SAVE DIALOG
// ─────────────────────────────────────────────
class SaveDialog extends StatefulWidget {
  final Future<String> Function() saveTask;
  final String title;
  final String processingText;

  const SaveDialog({
    super.key,
    required this.saveTask,
    required this.title,
    required this.processingText,
  });

  @override
  State<SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<SaveDialog> {
  String _step = 'processing';
  String _message = '';

  @override
  void initState() {
    super.initState();
    _message = widget.processingText;
    _runTask();
  }

  Future<void> _runTask() async {
    try {
      final resultMessage = await widget.saveTask();
      if (mounted) {
        setState(() {
          _step = 'success';
          _message = resultMessage;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = 'error';
          _message = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_step == 'processing') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          const CircularProgressIndicator(color: Color(0xFF3B82F6)),
          const SizedBox(height: 24),
          Text(_message,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
      );
    } else if (_step == 'success') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded,
              color: Color(0xFF22C55E), size: 48),
          const SizedBox(height: 16),
          Text(widget.title,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 16),
          Text(_message,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Done',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.redAccent, size: 48),
          const SizedBox(height: 16),
          const Text('Error',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 16),
          Text(_message,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF222222),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Close',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    }

    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: content,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// RESULT ITEM VIEW
// ─────────────────────────────────────────────
class _ResultItemView extends StatelessWidget {
  final XFile file;
  final Uint8List? inputBytesForDisplay;
  final int? originalSize;
  final ActionMode mode;
  final int quality;

  final bool processing;
  final bool wasDownsized;
  final Uint8List? resultBytes;
  final Uint8List? residualBytes;
  final String? errorMsg;
  final String? inputResolution;
  final String? resultResolution;
  final double? mse;
  final double? ssim;

  final VoidCallback onSave;
  final VoidCallback onSaveZip;

  const _ResultItemView({
    super.key,
    required this.file,
    this.inputBytesForDisplay,
    required this.originalSize,
    required this.mode,
    required this.quality,
    required this.processing,
    required this.wasDownsized,
    required this.resultBytes,
    required this.residualBytes,
    required this.errorMsg,
    required this.inputResolution,
    required this.resultResolution,
    required this.mse,
    required this.ssim,
    required this.onSave,
    required this.onSaveZip,
  });

  int get _resultSize => resultBytes?.length ?? 0;

  double get _savingsPercent {
    if (_resultSize == 0 || originalSize == null || originalSize == 0)
      return 0;
    return ((originalSize! - _resultSize) / originalSize! * 100)
        .clamp(-999.0, 999.0);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  }

  Widget _buildInputImage() {
    if (inputBytesForDisplay != null) {
      return Image.memory(
        inputBytesForDisplay!,
        width: double.infinity,
        fit: BoxFit.contain,
      );
    }

    return kIsWeb
        ? Image.network(file.path,
            width: double.infinity, fit: BoxFit.contain)
        : Image.file(File(file.path),
            width: double.infinity, fit: BoxFit.contain);
  }

  @override
  Widget build(BuildContext context) {
    final fileName = file.name;
    final isCompress = mode == ActionMode.compress;
    final isZipDecompress =
        !isCompress && fileName.toLowerCase().endsWith('.zip');
    final isJustViewing = !isCompress && !isZipDecompress;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isJustViewing) ...[
            Row(
              children: [
                Text(
                  wasDownsized ? 'Downsized Input' : 'Input File',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
                if (wasDownsized) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: Colors.orangeAccent.withOpacity(0.5)),
                    ),
                    child: Text(
                      'Downsized to ${kDownsizeLongEdge}px',
                      style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
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
                    Icon(Icons.folder_zip_rounded,
                        size: 64, color: Color(0xFF818CF8)),
                    SizedBox(height: 12),
                    Text('ZIP Archive',
                        style: TextStyle(color: Colors.white70)),
                  ],
                ),
              )
            else
              ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildInputImage()),
            const SizedBox(height: 8),
            _InfoRow(
                label: 'Format',
                value: fileName.split('.').last.toUpperCase()),
            const SizedBox(height: 4),
            _InfoRow(
                label: 'Size',
                value: originalSize != null
                    ? _formatSize(originalSize!)
                    : 'Calculating...'),
            if (inputResolution != null) ...[
              const SizedBox(height: 4),
              _InfoRow(label: 'Resolution', value: inputResolution!),
            ],
            if (isCompress) ...[
              const SizedBox(height: 4),
              _InfoRow(label: 'Quality', value: '$quality / 100'),
            ],
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF2A2A2A)),
            const SizedBox(height: 24),
          ],

          // ── Result ────────────────────────────────────────────────────
          Row(
            children: [
              Text(
                isCompress
                    ? 'WebP Output'
                    : (isZipDecompress
                        ? 'Reconstructed Output'
                        : 'Downloaded Image'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: const Color(0xFF3B82F6).withOpacity(0.4)),
                ),
                child: Text(
                  isCompress
                      ? 'WEBP'
                      : (isZipDecompress
                          ? 'JPG'
                          : fileName.split('.').last.toUpperCase()),
                  style: const TextStyle(
                      color: Color(0xFF3B82F6),
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
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
                    Text(
                      isCompress
                          ? 'Converting to WebP...'
                          : 'Processing image...',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 13),
                    ),
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
            _InfoRow(
                label: 'Format',
                value: isCompress
                    ? 'WEBP'
                    : (isZipDecompress
                        ? 'JPG'
                        : fileName.split('.').last.toUpperCase())),
            const SizedBox(height: 4),
            _InfoRow(label: 'Size', value: _formatSize(_resultSize)),
            if (resultResolution != null) ...[
              const SizedBox(height: 4),
              _InfoRow(
                  label: 'Resolution', value: resultResolution!),
            ],
            if (mse != null && ssim != null) ...[
              const SizedBox(height: 4),
              _InfoRow(
                  label: 'MSE (vs Input)',
                  value: mse!.toStringAsFixed(2)),
              const SizedBox(height: 4),
              _InfoRow(
                  label: 'SSIM (vs Input)',
                  value: ssim!.toStringAsFixed(4)),
            ] else if (isZipDecompress) ...[
              const SizedBox(height: 4),
              const _InfoRow(
                  label: 'Metrics',
                  value: 'Original missing in ZIP',
                  valueColor: Colors.white54),
            ],
            if (isCompress || isZipDecompress) ...[
              const SizedBox(height: 4),
              _InfoRow(
                label: 'Size Reduction',
                value:
                    '${_savingsPercent > 0 ? '-' : '+'}${_savingsPercent.abs().toStringAsFixed(1)}%',
                valueColor: _savingsPercent > 0
                    ? const Color(0xFF22C55E)
                    : Colors.orangeAccent,
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(
                    isCompress ? 'Download WebP' : 'Download Image'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF353535),
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
            if ((isCompress && residualBytes != null) ||
                isZipDecompress) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onSaveZip,
                  icon: const Icon(Icons.archive_rounded, size: 18),
                  label: Text(isCompress
                      ? 'Download ZIP (WebP + Residual)'
                      : 'Download Original ZIP'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF353535),
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
                onPressed: () => Navigator.of(context)
                    .popUntil((route) => route.isFirst),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('New Image'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF353535),
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