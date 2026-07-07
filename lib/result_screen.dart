import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../image_utils_stub.dart' if (dart.library.html) '../image_utils_web.dart';
import 'package:bytesized/file_utils.dart';
import 'package:bytesized/native_downsize.dart';
import 'package:bytesized/image_processing.dart';

// ─────────────────────────────────────────────
// TOP LEVEL COMPUTE TASKS
// ─────────────────────────────────────────────

/// Encodes the compress result, residual, and optional original into a ZIP.
/// [origW] and [origH] are the true pixel dimensions of the original image
/// BEFORE any downsize — stored in meta.json so reconstruction can upscale
/// back toward the original size.
List<int>? _encodeZipTask(Map<String, dynamic> data) {
  final archive = Archive();
  final result = data['result'] as Uint8List;
  final Uint8List? residual = data['residual'] as Uint8List?;
  final int origW = data['orig_w'] as int? ?? 0;
  final int origH = data['orig_h'] as int? ?? 0;

  archive.addFile(ArchiveFile('image.webp', result.length, result));

  // Residual is null for the large-image path — ZIP still valid without it.
  if (residual != null) {
    archive.addFile(ArchiveFile('residual.png', residual.length, residual));
  }

  // Store original dimensions as a tiny JSON file.
  // This lets the decompressor upscale toward the original resolution
  // (capped at kReconstructUpscaleCap) even when there is no residual.
  if (origW > 0 && origH > 0) {
    final metaJson = utf8.encode(jsonEncode({'orig_w': origW, 'orig_h': origH}));
    archive.addFile(ArchiveFile('meta.json', metaJson.length, metaJson));
  }

  if (data['original'] != null) {
    final original = data['original'] as Uint8List;
    // Detect the actual format from the file's magic bytes so the ZIP
    // entry gets a proper extension and can be opened directly by any
    // image viewer, instead of a bare "original_image" with no extension.
    final ext = _detectImageExtension(original);
    archive.addFile(
        ArchiveFile('original_image.$ext', original.length, original));
  }
  return ZipEncoder().encode(archive);
}

/// Sniffs the first few bytes of [bytes] to determine its image format,
/// so we can give the ZIP entry a real file extension.
String _detectImageExtension(Uint8List bytes) {
  if (bytes.length < 12) return 'bin';

  // PNG: 89 50 4E 47
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return 'png';
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'jpg';
  }
  // WebP: "RIFF" .... "WEBP"
  if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
    return 'webp';
  }
  // GIF: "GIF8"
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
    return 'gif';
  }
  // BMP: "BM"
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'bmp';
  }

  return 'bin'; // Unknown format — at least won't crash the ZIP encode.
}

Archive _decodeZipTask(Uint8List bytes) {
  return ZipDecoder().decodeBytes(bytes);
}

Uint8List? _decodeToJpegTask(Uint8List webpBytes) {
  final decoded = img.decodeImage(webpBytes);
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
}

// ─────────────────────────────────────────────
// RESULT SCREEN
// ─────────────────────────────────────────────
enum ActionMode { compress, decompress }

class ResultScreen extends StatefulWidget {
  final List<XFile> files;
  final ActionMode mode;
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
  late List<bool> _noResidualList;

  /// True pixel dimensions of the original image before any downsize.
  /// Stored so they can be written into meta.json inside the ZIP,
  /// enabling upscaling during reconstruction.
  late List<int> _origWidthList;
  late List<int> _origHeightList;

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
    _noResidualList = List.filled(count, false);
    _origWidthList = List.filled(count, 0);
    _origHeightList = List.filled(count, 0);

    _processAllSequentially(count);
  }

  Future<void> _processAllSequentially(int count) async {
    for (int i = 0; i < count; i++) {
      await _fetchInputResolution(i);
      await _process(i);
    }
  }

  /// Computes residual and metrics after the initial compression is already shown.
  Future<void> _computeAndSetPostProcessData(
      int index, Uint8List original, Uint8List lossy) async {
    final residual = await computeResidualOnDemand(original, lossy);
    final metrics = await computeImageMetrics(original, lossy);

    if (mounted) {
      setState(() {
        _residualBytesList[index] = residual;
        _mseList[index] = metrics['mse'];
        _ssimList[index] = metrics['ssim'];
      });
    }
  }

  Future<void> _fetchInputResolution(int index) async {
    try {
      final len = await widget.files[index].length();
      if (mounted) setState(() => _originalSizeList[index] = len);

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

  /// Main processing entry point.
  Future<void> _process(int index) async {
    try {
      final fileLength = await widget.files[index].length();
      final fileName = widget.files[index].name;
      final filePath = widget.files[index].path;

      if (fileLength > kMaxInputBytes) {
        throw Exception(
          'File too large (${(fileLength / 1048576).toStringAsFixed(1)} MB). '
          'Maximum supported input size is ${kMaxInputBytes ~/ 1048576} MB.',
        );
      }

      // PRE-PROCESS VERY LARGE IMAGES to prevent OOM crash from readAsBytes()
      if (widget.mode == ActionMode.compress && !kIsWeb) {
        ui.Size? dimensions;
        try {
          dimensions = await probeImageDimensionsFromFile(filePath);
        } catch (_) {}

        if (dimensions != null &&
            (dimensions.width * dimensions.height) >
                kNativeDownsizeTriggerPixels) {

          // Capture the true original dimensions BEFORE downsize so they
          // can be embedded in meta.json for upscaling on reconstruct.
          final trueW = dimensions.width.toInt();
          final trueH = dimensions.height.toInt();

          if (mounted) {
            setState(() {
              _wasDownsizedList[index] = true;
              _noResidualList[index] = true;
              _origWidthList[index] = trueW;
              _origHeightList[index] = trueH;
            });
          }

          final downsizedBytes = await nativeSampledDownsizeFromFile(filePath);
          final result =
              await compressLargeImage(downsizedBytes, quality: widget.quality);
          await _handleCompressionSuccess(index, result, null, fileLength, downsizedBytes);
          return;
        }
      }

      Uint8List workingBytes = await widget.files[index].readAsBytes();
      final isZip = fileName.toLowerCase().endsWith('.zip') || _looksLikeZip(workingBytes);

      // ── COMPRESS MODE ──────────────────────────────────────────────
      if (!isZip && widget.mode == ActionMode.compress) {
        if (mounted) {
          setState(() => _inputDisplayBytesList[index] = workingBytes);
        }

        Uint8List result;
        Uint8List? residual;

        if (fileLength > kResidualPipelineLimit) {
          // ── LARGE IMAGE PATH: native codec only, no residual ──
          if (mounted) setState(() => _noResidualList[index] = true);

          // Probe true dimensions before any processing so we can store them.
          try {
            final buffer = await ui.ImmutableBuffer.fromUint8List(workingBytes);
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            if (mounted) {
              setState(() {
                _origWidthList[index] = descriptor.width;
                _origHeightList[index] = descriptor.height;
              });
            }
            descriptor.dispose();
            buffer.dispose();
          } catch (_) {}

          result = await compressLargeImage(
            workingBytes,
            quality: widget.quality,
          );
          residual = null;
        } else {
          // ── SMALL IMAGE PATH: full residual pipeline ──
          workingBytes = await normalizeToDecodable(workingBytes, fileName);

          // Probe dimensions to decide whether to downsize.
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

          // Store the true original dimensions (pre-downsize).
          if (mounted) {
            setState(() {
              _origWidthList[index] = width;
              _origHeightList[index] = height;
            });
          }

          if (width * height > kMaxPixels) {
            if (mounted) setState(() => _wasDownsizedList[index] = true);
            workingBytes = await safeDownsizeIfNeeded(workingBytes);

            if (mounted) {
              setState(() => _inputDisplayBytesList[index] = workingBytes);
            }

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

          // 1. Compress and immediately show the result to the user.
          result = await compressImageOnly(
            workingBytes,
            quality: widget.quality,
          );
          await _handleCompressionSuccess(
              index, result, null, fileLength, workingBytes);

          // 2. In the background, compute the heavy stuff.
          _computeAndSetPostProcessData(index, workingBytes, result);
          return;
        }

        await _handleCompressionSuccess(index, result, residual, fileLength, workingBytes);
        return;
      }

      // ── DECOMPRESS / ZIP / VIEW MODE ────────────────────────────────
      if (!isZip) {
        if (fileLength > kMaxPixels) {
          if (mounted) setState(() => _wasDownsizedList[index] = true);
          workingBytes = await safeDownsizeIfNeeded(workingBytes);
        }
        workingBytes = await normalizeToDecodable(workingBytes, fileName);
        if (mounted) {
          setState(() => _inputDisplayBytesList[index] = workingBytes);
        }
      }

      final result = await _decompressFile(index, workingBytes);
      workingBytes = Uint8List(0);

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

  Future<void> _handleCompressionSuccess(int index, Uint8List result,
      Uint8List? residual, int originalFileLength,
      [Uint8List? inputBytes]) async {
    String? resResolution;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(result);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      resResolution = '${descriptor.width} x ${descriptor.height}';
      descriptor.dispose();
      buffer.dispose();
    } catch (e, s) {
      debugPrint('Could not get result resolution: $e\n$s');
    }

    if (mounted) {
      setState(() {
        _resultBytesList[index] = result;
        _residualBytesList[index] = residual;
        _resultResolutionList[index] = resResolution;
        if (_originalSizeList[index] == null) {
          _originalSizeList[index] = originalFileLength;
        }
        if (inputBytes != null) _inputDisplayBytesList[index] = inputBytes;
        _processingList[index] = false;
      });
    }
  }

  bool _looksLikeZip(Uint8List bytes) {
    return bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  /// Decompresses/reconstructs from a ZIP.
  /// Reads meta.json (if present) for the original dimensions, then passes
  /// them to [reconstructFromResidual] so the result is upscaled toward
  /// the original resolution (capped at [kReconstructUpscaleCap]).
  Future<Uint8List> _decompressFile(int index, Uint8List bytes) async {
    final fileName = widget.files[index].name.toLowerCase();
    if (!fileName.endsWith('.zip') && !_looksLikeZip(bytes)) return bytes;

    Archive archive;
    try {
      archive = await compute(_decodeZipTask, bytes);
    } catch (e) {
      throw Exception('Could not open ZIP: $e');
    }

    ArchiveFile? lossyFile, residualFile, originalFile, metaFile;

    for (final file in archive) {
      if (file.isFile) {
        final n = file.name.toLowerCase();
        if (n == 'image.webp') lossyFile = file;
        if (n == 'residual.png') residualFile = file;
        if (n == 'original_image' || n.startsWith('original_image.')) {
          originalFile = file;
        }
        if (n == 'meta.json') metaFile = file;
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

    var lossyBytes = Uint8List.fromList(lossyFile.content as List<int>);

    // ── Show a preview of the archive's contents instead of a generic ──
    // ZIP icon. Prefer the true original image if it was bundled; fall
    // back to the lossy WebP/JPEG otherwise (e.g. large-image path).
    if (mounted) {
      final previewBytes = originalFile != null
          ? Uint8List.fromList(originalFile.content as List<int>)
          : lossyBytes;
      setState(() => _inputDisplayBytesList[index] = previewBytes);
    }

    if (residualFile == null) {
      // No residual in ZIP — this was a large-image-path compress.
      // We can still upscale the lossy WebP if meta.json has the target dims.
      if (metaFile != null) {
        lossyBytes = await _upscaleFromMeta(lossyBytes, metaFile);
      }
      return lossyBytes;
    }

    var resBytes = Uint8List.fromList(residualFile.content as List<int>);

    // ── Read original dimensions from meta.json ──────────────────────
    int metaOrigW = 0;
    int metaOrigH = 0;
    if (metaFile != null) {
      try {
        final metaStr = utf8.decode(metaFile.content as List<int>);
        final metaMap = jsonDecode(metaStr) as Map<String, dynamic>;
        metaOrigW = (metaMap['orig_w'] as num?)?.toInt() ?? 0;
        metaOrigH = (metaMap['orig_h'] as num?)?.toInt() ?? 0;
      } catch (_) {}
    }

    // ── Check dimensions before reconstruction ──────────────────────
    int width = 0, height = 0;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(lossyBytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {}

    if (width * height > kMaxPixels) {
      if (mounted) setState(() => _wasDownsizedList[index] = true);
      lossyBytes = await safeDownsizeIfNeeded(lossyBytes);
      resBytes = await safeDownsizeResidual(resBytes);
    }

    // ── Reconstruct + upscale ────────────────────────────────────────
    // Pass the stored original dims so reconstructFromResidual can upscale
    // the result toward the original resolution (capped at kReconstructUpscaleCap).
    final result = await reconstructFromResidual(
      lossyBytes,
      resBytes,
      targetWidth: metaOrigW,
      targetHeight: metaOrigH,
    );

    if (originalFile != null && mounted) {
      final origBytes =
          Uint8List.fromList(originalFile.content as List<int>);
      final metrics = await computeImageMetrics(origBytes, result);
      if (mounted) {
        setState(() {
          _mseList[index] = metrics['mse'];
          _ssimList[index] = metrics['ssim'];
          _originalSizeList[index] = origBytes.length;
        });
      }
    }

    return result;
  }

  /// Upscales [lossyBytes] toward the original dimensions stored in [metaFile],
  /// capped at [kReconstructUpscaleCap]. Used when a ZIP has no residual
  /// (large-image path) but does have meta.json.
  Future<Uint8List> _upscaleFromMeta(
      Uint8List lossyBytes, ArchiveFile metaFile) async {
    int metaOrigW = 0;
    int metaOrigH = 0;
    try {
      final metaStr = utf8.decode(metaFile.content as List<int>);
      final metaMap = jsonDecode(metaStr) as Map<String, dynamic>;
      metaOrigW = (metaMap['orig_w'] as num?)?.toInt() ?? 0;
      metaOrigH = (metaMap['orig_h'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return lossyBytes; // Can't read meta — return as-is
    }

    if (metaOrigW <= 0 || metaOrigH <= 0) return lossyBytes;

    // Determine capped upscale target.
    final isLandscape = metaOrigW >= metaOrigH;
    int upW, upH;
    if (isLandscape) {
      upW = metaOrigW.clamp(1, kReconstructUpscaleCap);
      upH = (upW * metaOrigH / metaOrigW).round();
    } else {
      upH = metaOrigH.clamp(1, kReconstructUpscaleCap);
      upW = (upH * metaOrigW / metaOrigH).round();
    }

    // Only upscale if the target is actually larger than what we have.
    return compute(_upscaleImageTask, {
      'bytes': lossyBytes,
      'target_w': upW,
      'target_h': upH,
    });
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
              ? ((!kIsWeb && Platform.isIOS) ? '.jpg' : '.webp')
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
            Uint8List bytesToSave = result;
            if (isCompress && !kIsWeb && Platform.isIOS) {
              try {
                final decoded = await compute(_decodeToJpegTask, result);
                if (decoded != null) bytesToSave = decoded;
              } catch (_) {}
            }

            final saveDir = await getAppSaveDirectory();
            final dirPath =
                saveDir?.path ?? (await getTemporaryDirectory()).path;
            final file = File('$dirPath/$outName');
            await file.writeAsBytes(bytesToSave);

            try {
              final hasAccess = await Gal.hasAccess();
              if (!hasAccess) await Gal.requestAccess();
              await Gal.putImage(file.path);
            } catch (e) {
              debugPrint('Gal error: $e');
            }

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
        title: 'Ready!',
        processingText: 'Preparing ZIP archive...',
        saveTask: () async {
          final fileName = widget.files[index].name;
          final rawBytes = await widget.files[index].readAsBytes();
          final isIncomingZip = widget.mode == ActionMode.decompress &&
              (fileName.toLowerCase().endsWith('.zip') ||
                  _looksLikeZip(rawBytes));

          late Uint8List zipBytes;
          late String outName;

          if (isIncomingZip) {
            zipBytes = rawBytes;
            outName =
                'downloaded_archive_${DateTime.now().millisecondsSinceEpoch}.zip';
          } else {
            final resultBytes = _resultBytesList[index];
            final residualBytes = _residualBytesList[index];
            // resultBytes must exist; residualBytes may be null for the
            // large-image (noResidual) path — _encodeZipTask handles null.
            if (resultBytes == null) {
              throw Exception('No compressed output available yet.');
            }

            // Include the true original dimensions so decompressors can upscale.
            final encoded = await compute(_encodeZipTask, {
              'result': resultBytes,
              'residual': residualBytes, // may be null — handled in task
              'orig_w': _origWidthList[index],
              'orig_h': _origHeightList[index],
              // Skip bundling the large original when there is no residual —
              // it would double the ZIP size with no reconstruction benefit.
              'original': residualBytes != null
                  ? await widget.files[index].readAsBytes()
                  : null,
            });

            if (encoded == null) throw Exception('Failed to encode ZIP.');
            zipBytes = Uint8List.fromList(encoded);
            outName = residualBytes != null
                ? 'compressed_with_residual_${DateTime.now().millisecondsSinceEpoch}.zip'
                : 'compressed_${DateTime.now().millisecondsSinceEpoch}.zip';
          }

          if (kIsWeb) {
            downloadBytes(zipBytes, outName);
            return 'ZIP download started.';
          }

          final tempDir = await getTemporaryDirectory();
          final file = File('${tempDir.path}/$outName');
          await file.writeAsBytes(zipBytes);

          if (!kIsWeb && Platform.isIOS) {
            await Share.shareXFiles(
              [XFile(file.path, mimeType: 'application/zip')],
              subject: outName,
            );
            return 'Use the share sheet to save to Files or another app.';
          } else {
            final saveDir = await getAppSaveDirectory();
            final dirPath =
                saveDir?.path ?? (await getTemporaryDirectory()).path;
            final dest = File('$dirPath/$outName');
            await dest.writeAsBytes(zipBytes);
            return 'ZIP saved to Downloads folder!';
          }
        },
      ),
    );
  }

  /// Converts the compressed result (WebP/JPEG) to a standard JPEG and
  /// opens the OS share sheet.
  Future<void> _exportAsJpeg(int index) async {
    final result = _resultBytesList[index];
    if (result == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SaveDialog(
        title: 'Ready to share!',
        processingText: 'Converting to JPEG...',
        saveTask: () async {
          final jpegBytes = await compute(_decodeToJpegTask, result) ??
              await FlutterImageCompress.compressWithList(
                result,
                format: CompressFormat.jpeg,
                quality: 95,
                minWidth: 16000,
                minHeight: 16000,
              );

          final outName =
              'bytesized_export_${DateTime.now().millisecondsSinceEpoch}.jpg';

          if (kIsWeb) {
            downloadBytes(jpegBytes, outName);
            return 'JPEG download started.';
          }

          final tempDir = await getTemporaryDirectory();
          final file = File('${tempDir.path}/$outName');
          await file.writeAsBytes(jpegBytes);

          await Share.shareXFiles(
            [XFile(file.path, mimeType: 'image/jpeg')],
            subject: outName,
          );
          return 'Use the share sheet to send via Messenger or save it.';
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
                ? ((!kIsWeb && Platform.isIOS) ? '.jpg' : '.webp')
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
              Uint8List bytesToSave = result;
              if (isCompress && !kIsWeb && Platform.isIOS) {
                try {
                  final decoded =
                      await compute(_decodeToJpegTask, result);
                  if (decoded != null) bytesToSave = decoded;
                } catch (_) {}
              }

              final saveDir = await getAppSaveDirectory();
              final dirPath =
                  saveDir?.path ?? (await getTemporaryDirectory()).path;
              final file = File('$dirPath/$outName');
              await file.writeAsBytes(bytesToSave);

              try {
                final hasAccess = await Gal.hasAccess();
                if (!hasAccess) await Gal.requestAccess();
                await Gal.putImage(file.path);
              } catch (e) {
                debugPrint('Gal error: $e');
              }
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
          // Build a human-readable upscale target label for the UI,
          // e.g. "→ 8192 × 5872 (capped)" or "→ 21000 × 15158".
          final origW = _origWidthList[index];
          final origH = _origHeightList[index];
          String? upscaleLabel;
          if (origW > 0 && origH > 0) {
            final isLandscape = origW >= origH;
            final capW = isLandscape
                ? origW.clamp(1, kReconstructUpscaleCap)
                : (origH.clamp(1, kReconstructUpscaleCap) * origW / origH).round();
            final capH = isLandscape
                ? (origW.clamp(1, kReconstructUpscaleCap) * origH / origW).round()
                : origH.clamp(1, kReconstructUpscaleCap);
            final capped = capW < origW || capH < origH;
            upscaleLabel =
                '→ $capW × $capH${capped ? ' (capped at ${kReconstructUpscaleCap}px)' : ''}';
          }

          return _ResultItemView(
            key: PageStorageKey(index),
            file: widget.files[index],
            inputBytesForDisplay: _inputDisplayBytesList[index],
            originalSize: _originalSizeList[index],
            mode: widget.mode,
            quality: widget.quality,
            processing: _processingList[index],
            wasDownsized: _wasDownsizedList[index],
            noResidual: _noResidualList[index],
            resultBytes: _resultBytesList[index],
            residualBytes: _residualBytesList[index],
            errorMsg: _errorMsgList[index],
            inputResolution: _inputResolutionList[index],
            resultResolution: _resultResolutionList[index],
            mse: _mseList[index],
            ssim: _ssimList[index],
            upscaleLabel: upscaleLabel,
            onSave: () => _save(index),
            onSaveZip: () => _saveZip(index),
            onExportJpeg: () => _exportAsJpeg(index),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// TOP-LEVEL ISOLATE: upscale a decoded image
// ─────────────────────────────────────────────

/// Upscales [bytes] to ([target_w], [target_h]) using cubic interpolation.
/// Runs in a separate isolate via [compute].
Uint8List _upscaleImageTask(Map<String, dynamic> data) {
  final bytes = data['bytes'] as Uint8List;
  final targetW = data['target_w'] as int;
  final targetH = data['target_h'] as int;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  // Only upscale if the target is larger on at least one axis.
  if (targetW <= decoded.width && targetH <= decoded.height) return bytes;

  final resized = img.copyResize(
    decoded,
    width: targetW,
    height: targetH,
    interpolation: img.Interpolation.cubic,
  );
  return Uint8List.fromList(img.encodeJpg(resized, quality: 95));
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
  final bool noResidual;
  final Uint8List? resultBytes;
  final Uint8List? residualBytes;
  final String? errorMsg;
  final String? inputResolution;
  final String? resultResolution;
  final double? mse;
  final double? ssim;

  /// Human-readable label showing what resolution the ZIP will reconstruct to,
  /// e.g. "→ 8192 × 5872 (capped at 8192px)". Null when not applicable.
  final String? upscaleLabel;

  final VoidCallback onSave;
  final VoidCallback onSaveZip;
  final VoidCallback onExportJpeg;

  const _ResultItemView({
    super.key,
    required this.file,
    this.inputBytesForDisplay,
    required this.originalSize,
    required this.mode,
    required this.quality,
    required this.processing,
    required this.wasDownsized,
    required this.noResidual,
    required this.resultBytes,
    required this.residualBytes,
    required this.errorMsg,
    required this.inputResolution,
    required this.resultResolution,
    required this.mse,
    required this.ssim,
    this.upscaleLabel,
    required this.onSave,
    required this.onSaveZip,
    required this.onExportJpeg,
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
      return Image.memory(inputBytesForDisplay!,
          width: double.infinity, fit: BoxFit.contain);
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

    final outputFormatLabel = isCompress
        ? ((!kIsWeb && Platform.isIOS) ? 'JPG' : 'WEBP')
        : (isZipDecompress
            ? 'JPG'
            : fileName.split('.').last.toUpperCase());

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
            if (fileName.toLowerCase().endsWith('.zip') &&
                inputBytesForDisplay == null)
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
                    Text('Extracting preview...',
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

          // ── Result ──
          Row(
            children: [
              Text(
                isCompress
                    ? 'Output'
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
                  outputFormatLabel,
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
                          ? 'Compressing...'
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
                child: Image.memory(resultBytes!,
                    width: double.infinity, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 8),
            _InfoRow(label: 'Format', value: outputFormatLabel),
            const SizedBox(height: 4),
            _InfoRow(label: 'Size', value: _formatSize(_resultSize)),
            if (resultResolution != null) ...[
              const SizedBox(height: 4),
              _InfoRow(label: 'Resolution', value: resultResolution!),
            ],
            if (isCompress && !noResidual) ...[
              if (mse != null && ssim != null) ...[
                const SizedBox(height: 4),
                _InfoRow(
                    label: 'MSE (vs Input)', value: mse!.toStringAsFixed(2)),
                const SizedBox(height: 4),
                _InfoRow(
                    label: 'SSIM (vs Input)', value: ssim!.toStringAsFixed(4)),
              ] else ...[
                const SizedBox(height: 4),
                const _InfoRow(label: 'MSE (vs Input)', value: 'Calculating...'),
                const SizedBox(height: 4),
                const _InfoRow(label: 'SSIM (vs Input)', value: 'Calculating...'),
              ]
            ] else if (isZipDecompress) ...[
              if (mse != null && ssim != null) ...[
                const SizedBox(height: 4),
                _InfoRow(
                    label: 'MSE (vs Original)', value: mse!.toStringAsFixed(2)),
                const SizedBox(height: 4),
                _InfoRow(
                    label: 'SSIM (vs Original)', value: ssim!.toStringAsFixed(4)),
              ] else ...[
                const SizedBox(height: 4),
                const _InfoRow(label: 'Metrics', value: 'Original missing in ZIP', valueColor: Colors.white54),
              ],
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
            // ── Upscale info banner ──────────────────────────────────
            if (isCompress && upscaleLabel != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F2744),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFF3B82F6).withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.open_in_full_rounded,
                        color: Color(0xFF3B82F6), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Reconstruction will upscale $upscaleLabel',
                        style: const TextStyle(
                            color: Color(0xFF93C5FD), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isCompress && noResidual) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Text(
                  'Residual-based reconstruction is unavailable for images '
                  'above 30 MB to ensure stable performance. The ZIP will '
                  'contain the compressed output and dimensions metadata for upscaling.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download Image'),
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
            if (isCompress) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onExportJpeg,
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Export as JPEG (for Messenger, etc.)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
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
            const SizedBox(height: 12),
            // Show ZIP button for:
            //   - Compress: always (residual available OR noResidual with meta)
            //   - Decompress of a ZIP: show the original ZIP download
            if (isCompress || isZipDecompress) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onSaveZip,
                  icon: const Icon(Icons.archive_rounded, size: 18),
                  label: Text(isCompress
                      ? (noResidual
                          ? 'Download ZIP (WebP + Metadata)'
                          : 'Download ZIP (WebP + Residual)')
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