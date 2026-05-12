import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../app_preset.dart';
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
    final count = widget.imageBytesList.length;
    _processingList = List.filled(count, true);
    _resultBytesList = List.filled(count, null);
    _residualBytesList = List.filled(count, null);
    _errorMsgList = List.filled(count, null);
    _inputResolutionList = List.filled(count, null);
    _resultResolutionList = List.filled(count, null);
    _mseList = List.filled(count, null);
    _ssimList = List.filled(count, null);

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
        
        final metrics = await computeImageMetrics(imageBytes, result);

        if (mounted) {
          setState(() {
            _residualBytesList[index] = residual;
            _mseList[index] = metrics['mse'];
            _ssimList[index] = metrics['ssim'];
          });
        }
      } else {
        if (fileName.toLowerCase().endsWith('.zip')) {
          final archive = await compute(_decodeZipTask, imageBytes);
          ArchiveFile? lossyFile;
          ArchiveFile? residualFile;
          ArchiveFile? originalFile;

          for (final file in archive) {
            if (file.name == 'image.webp') lossyFile = file;
            if (file.name == 'residual.png') residualFile = file;
            if (file.name == 'original_image') originalFile = file;
          }

          if (lossyFile != null && residualFile != null) {
            final lossyBytes = Uint8List.fromList(lossyFile.content as List<int>);
            final resBytes = Uint8List.fromList(residualFile.content as List<int>);
            result = await reconstructFromResidual(lossyBytes, resBytes);
            
            if (originalFile != null) {
              final origBytes = Uint8List.fromList(originalFile.content as List<int>);
              final metrics = await computeImageMetrics(origBytes, result);
              if (mounted) setState(() { _mseList[index] = metrics['mse']; _ssimList[index] = metrics['ssim']; });
            }
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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SaveDialog(
        title: 'Saved!',
        processingText: 'Saving image...',
        saveTask: () async {
          final isCompress = widget.mode == ActionMode.compress;
          final fileName = widget.fileNames[index];
          final ext = isCompress 
              ? '.webp' 
              : (fileName.toLowerCase().endsWith('.zip') || fileName.toLowerCase().endsWith('.bytesized') ? '.jpg' : '.${fileName.split('.').last}');
          final outName = '${isCompress ? 'compressed' : 'reconstructed'}_${DateTime.now().millisecondsSinceEpoch}$ext';
          
          if (kIsWeb) {
            downloadBytes(result, outName);
            return 'Image download started.';
          } else {
            final saveDir = await getAppSaveDirectory();
            final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
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
          if (widget.mode == ActionMode.decompress && widget.fileNames[index].toLowerCase().endsWith('.zip')) {
            final zipBytes = widget.imageBytesList[index];
            final outName = 'downloaded_archive_${DateTime.now().millisecondsSinceEpoch}.zip';

            if (kIsWeb) {
              downloadBytes(zipBytes, outName);
              return 'ZIP download started.';
            } else {
              final saveDir = await getAppSaveDirectory();
              final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
              final file = File('$dirPath/$outName');
              await file.writeAsBytes(zipBytes);
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
            'original': widget.imageBytesList[index],
          });
          
          if (zipBytesNullable == null) {
            throw Exception('Failed to encode ZIP archive.');
          }
          final zipBytes = zipBytesNullable;

          final outName = 'compressed_with_residual_${DateTime.now().millisecondsSinceEpoch}.zip';

          if (kIsWeb) {
            downloadBytes(Uint8List.fromList(zipBytes), outName);
            return 'ZIP download started.';
          } else {
            final saveDir = await getAppSaveDirectory();
            final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
            final file = File('$dirPath/$outName');
            await file.writeAsBytes(zipBytes);
            return 'ZIP saved to Downloads folder!';
          }
        },
      ),
    );
  }

  Future<void> _saveAll() async {
    if (_processingList.any((p) => p)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please wait for all images to finish processing.')));
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
              final saveDir = await getAppSaveDirectory();
              final dirPath = saveDir?.path ?? (await getTemporaryDirectory()).path;
              final file = File('$dirPath/$outName');
              await file.writeAsBytes(result);
              try { await Gal.putImage(file.path); } catch (_) {}
            }
            savedCount++;
          }
          
          if (savedCount == 0) throw Exception('No images to save.');
          return kIsWeb ? 'Started downloading $savedCount images!' : 'Saved $savedCount images successfully!';
        },
      ),
    );
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
// REAL-TIME SAVE DIALOG POPUP 
// (Edit this to change the UI of the download pop-ups)
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
          Text(_message, style: const TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
      );
    } else if (_step == 'success') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF22C55E), size: 48),
          const SizedBox(height: 16),
          Text(widget.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 16),
          Text(_message, style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          )
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
          const SizedBox(height: 16),
          const Text('Error', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 16),
          Text(_message, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF222222),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Close', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          )
        ],
      );
    }

    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
  final double? mse;
  final double? ssim;

  final VoidCallback onSave;
  final VoidCallback onSaveZip;

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
    required this.mse,
    required this.ssim,
    required this.onSave,
    required this.onSaveZip,
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
              if (mse != null && ssim != null) ...[
                const SizedBox(height: 4),
                _InfoRow(label: 'MSE (vs Original)', value: mse!.toStringAsFixed(2)),
                const SizedBox(height: 4),
                _InfoRow(label: 'SSIM (vs Original)', value: ssim!.toStringAsFixed(4)),
              ] else if (!isCompress) ...[
                const SizedBox(height: 4),
                const _InfoRow(label: 'Metrics', value: 'Original missing in ZIP', valueColor: Colors.white54),
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
                  if ((isCompress && residualBytes != null) || (!isCompress && fileName.toLowerCase().endsWith('.zip'))) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onSaveZip,
                        icon: const Icon(Icons.archive_rounded, size: 18),
                        label: Text(isCompress ? 'Download ZIP (WebP + Residual)' : 'Download Original ZIP'),
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