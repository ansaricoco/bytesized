import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

// ─────────────────────────────────────────────
// LIMITS
// A decoded RGBA pixel buffer costs width × height × 4 bytes.
// Peak RAM during compress+residual is ~3× the decoded size.
// These limits keep peak usage under ~450 MB on largeHeap Android.
// ─────────────────────────────────────────────

/// Maximum input file size we accept without forcing a downsize (40 MB).
const int kMaxInputBytes = 40 * 1024 * 1024;

/// Maximum pixel count before we must downsize (8000 × 8000 = 64 MP).
/// Decoded RGBA at this size = ~256 MB; peak ~450 MB with residual.
const int kMaxPixels = 8000 * 8000;

/// The long-edge cap we downsize TO when the image exceeds [kMaxPixels].
/// 5120 px long edge ≈ 26 MP — still very high quality.
const int kDownsizeLongEdge = 5120;

// ─────────────────────────────────────────────
// WEBP / JPEG COMPRESSION
// ─────────────────────────────────────────────

/// Encodes [inputBytes] to WebP (mobile) or JPEG (web) at [quality].
Future<Uint8List> encodeToWebP(Uint8List inputBytes,
    {int quality = 80}) async {
  if (kIsWeb) {
    return compute(
        _encodeFallbackTask, {'bytes': inputBytes, 'quality': quality});
  }
  return FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: quality,
    // Setting both to a very large number tells the codec NOT to resize —
    // it only downsizes when the image exceeds these dimensions.
    minWidth: 16000,
    minHeight: 16000,
  );
}

Uint8List _encodeFallbackTask(Map<String, dynamic> data) {
  final Uint8List inputBytes = data['bytes'];
  final int quality = data['quality'];
  final decoded = img.decodeImage(inputBytes);
  if (decoded == null) throw Exception('Could not decode image');
  return img.encodeJpg(decoded, quality: quality);
}

// ─────────────────────────────────────────────
// SINGLE-ISOLATE COMPRESS + RESIDUAL
// ─────────────────────────────────────────────

/// Compresses [inputBytes] and computes the residual in a single isolate pass.
/// Returns {'lossy': Uint8List, 'residual': Uint8List}.
Future<Map<String, Uint8List>> compressAndComputeResidual(
  Uint8List inputBytes, {
  int quality = 80,
}) async {
  if (kIsWeb) {
    return compute(
      _compressAndResidualPureDartTask,
      {'bytes': inputBytes, 'quality': quality},
    );
  }

  // Mobile: native WebP encode (memory-efficient OS codec),
  // then residual in isolate.
  final lossyBytes = await FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: quality,
    minWidth: 16000,
    minHeight: 16000,
  );

  final residualBytes = await compute(
    _computeResidualTask,
    {'orig': inputBytes, 'lossy': lossyBytes},
  );

  return {'lossy': lossyBytes, 'residual': residualBytes};
}

Map<String, Uint8List> _compressAndResidualPureDartTask(
    Map<String, dynamic> data) {
  final Uint8List inputBytes = data['bytes'];
  final int quality = data['quality'];

  final original = img.decodeImage(inputBytes);
  if (original == null) throw Exception('Could not decode image');

  final lossyBytes =
      Uint8List.fromList(img.encodeJpg(original, quality: quality));

  var lossyImg = img.decodeImage(lossyBytes);
  if (lossyImg == null) throw Exception('Could not decode lossy image');
  if (lossyImg.width != original.width ||
      lossyImg.height != original.height) {
    lossyImg = img.copyResize(lossyImg,
        width: original.width, height: original.height);
  }

  final origIter = original.iterator;
  final lossyIter = lossyImg.iterator;
  while (origIter.moveNext() && lossyIter.moveNext()) {
    final o = origIter.current;
    final l = lossyIter.current;
    o.r = (o.r.toInt() - l.r.toInt()) & 0xFF;
    o.g = (o.g.toInt() - l.g.toInt()) & 0xFF;
    o.b = (o.b.toInt() - l.b.toInt()) & 0xFF;
    o.a = (o.a.toInt() - l.a.toInt()) & 0xFF;
  }

  final residualBytes = Uint8List.fromList(img.encodePng(original));
  return {'lossy': lossyBytes, 'residual': residualBytes};
}

// ─────────────────────────────────────────────
// RESIDUAL (mobile separate call)
// ─────────────────────────────────────────────

Uint8List _computeResidualTask(Map<String, Uint8List> data) {
  final originalBytes = data['orig']!;
  final lossyBytes = data['lossy']!;

  final origImg = img.decodeImage(originalBytes);
  var lossyImg = img.decodeImage(lossyBytes);

  if (origImg == null || lossyImg == null)
    throw Exception('Process failed!');

  if (origImg.width != lossyImg.width ||
      origImg.height != lossyImg.height) {
    lossyImg = img.copyResize(lossyImg,
        width: origImg.width, height: origImg.height);
  }

  final origIter = origImg.iterator;
  final lossyIter = lossyImg.iterator;
  while (origIter.moveNext() && lossyIter.moveNext()) {
    final o = origIter.current;
    final l = lossyIter.current;
    o.r = (o.r.toInt() - l.r.toInt()) & 0xFF;
    o.g = (o.g.toInt() - l.g.toInt()) & 0xFF;
    o.b = (o.b.toInt() - l.b.toInt()) & 0xFF;
    o.a = (o.a.toInt() - l.a.toInt()) & 0xFF;
  }

  return Uint8List.fromList(img.encodePng(origImg));
}

// ─────────────────────────────────────────────
// RECONSTRUCTION
// ─────────────────────────────────────────────

Future<Uint8List> reconstructFromResidual(
    Uint8List lossyBytes, Uint8List residualBytes) async {
  return compute(
      _reconstructTask, {'lossy': lossyBytes, 'residual': residualBytes});
}

Uint8List _reconstructTask(Map<String, Uint8List> data) {
  final lossyBytes = data['lossy']!;
  final residualBytes = data['residual']!;

  var lossyImg = img.decodeImage(lossyBytes);
  final residualImg = img.decodeImage(residualBytes);

  if (lossyImg == null || residualImg == null)
    throw Exception('Reconstruction failed!');

  if (lossyImg.width != residualImg.width ||
      lossyImg.height != residualImg.height) {
    lossyImg = img.copyResize(lossyImg,
        width: residualImg.width, height: residualImg.height);
  }

  final lossyIter = lossyImg.iterator;
  final resIter = residualImg.iterator;
  while (lossyIter.moveNext() && resIter.moveNext()) {
    final lP = lossyIter.current;
    final rP = resIter.current;
    rP.r = (lP.r.toInt() + rP.r.toInt()) & 0xFF;
    rP.g = (lP.g.toInt() + rP.g.toInt()) & 0xFF;
    rP.b = (lP.b.toInt() + rP.b.toInt()) & 0xFF;
    rP.a = (lP.a.toInt() + rP.a.toInt()) & 0xFF;
  }

  return Uint8List.fromList(img.encodeJpg(residualImg, quality: 95));
}

// ─────────────────────────────────────────────
// HEIC / HEIF NORMALIZATION
// The pure-Dart `image` package cannot decode HEIC/HEIF.
// Convert to JPEG first using the native OS codec so all
// subsequent Dart-side operations (residual, metrics) work normally.
// ─────────────────────────────────────────────

/// Converts HEIC/HEIF to JPEG if needed.
/// Returns [inputBytes] unchanged for all other formats.
Future<Uint8List> normalizeToDecodable(
    Uint8List inputBytes, String fileName) async {
  if (kIsWeb) return inputBytes; // web has no HEIC support anyway

  final ext = fileName.toLowerCase().split('.').last;
  if (ext != 'heic' && ext != 'heif') return inputBytes;

  return FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.jpeg,
    quality: 95,
    minWidth: 16000,
    minHeight: 16000,
  );
}

// ─────────────────────────────────────────────
// SAFETY DOWNSIZE — only called when image exceeds kMaxPixels.
// This is a last-resort, not a default step.
// ─────────────────────────────────────────────

/// Downsizes only if the image exceeds [kMaxPixels].
/// Preserves full resolution for anything under that cap.
Future<Uint8List> safeDownsizeIfNeeded(Uint8List inputBytes) async {
  if (kIsWeb) {
    return compute(_safeDownsizePureDartTask, inputBytes);
  }

  // Use native codec — far less RAM than decode-then-resize in Dart
  return FlutterImageCompress.compressWithList(
    inputBytes,
    // kDownsizeLongEdge on both axes; codec keeps aspect ratio
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
    quality: 95, // near-lossless downsize
  );
}

Uint8List _safeDownsizePureDartTask(Uint8List bytes) {
  var decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  final pixels = decoded.width * decoded.height;
  if (pixels <= kMaxPixels) return bytes;

  final isLandscape = decoded.width >= decoded.height;
  decoded = img.copyResize(
    decoded,
    width: isLandscape ? kDownsizeLongEdge : null,
    height: isLandscape ? null : kDownsizeLongEdge,
  );
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
}

// ─────────────────────────────────────────────
// IMAGE METRICS (MSE & SSIM)
// ─────────────────────────────────────────────

Future<Map<String, double>> computeImageMetrics(
    Uint8List bytes1, Uint8List bytes2) async {
  return compute(_computeMetricsTask, {'b1': bytes1, 'b2': bytes2});
}

Map<String, double> _computeMetricsTask(Map<String, dynamic> data) {
  final b1 = data['b1'] as Uint8List;
  final b2 = data['b2'] as Uint8List;

  var img1 = img.decodeImage(b1);
  var img2 = img.decodeImage(b2);

  if (img1 == null || img2 == null) return {'mse': 0.0, 'ssim': 0.0};

  if (img1.width != img2.width || img1.height != img2.height) {
    img2 = img.copyResize(img2, width: img1.width, height: img1.height);
  }

  double mse = 0.0;
  int count = 0;

  final iter1 = img1.iterator;
  final iter2 = img2.iterator;
  while (iter1.moveNext() && iter2.moveNext()) {
    final p1 = iter1.current;
    final p2 = iter2.current;
    final r = p1.r.toInt() - p2.r.toInt();
    final g = p1.g.toInt() - p2.g.toInt();
    final b = p1.b.toInt() - p2.b.toInt();
    mse += (r * r + g * g + b * b) / 3.0;
    count++;
  }
  mse = count > 0 ? mse / count : 0.0;

  double ssimTotal = 0.0;
  int windows = 0;
  const int winSize = 8;
  const double c1 = (0.01 * 255) * (0.01 * 255);
  const double c2 = (0.03 * 255) * (0.03 * 255);

  for (int y = 0; y <= img1.height - winSize; y += winSize) {
    for (int x = 0; x <= img1.width - winSize; x += winSize) {
      double sum1 = 0, sum2 = 0;
      double sumSq1 = 0, sumSq2 = 0, sumCross = 0;

      for (int wy = 0; wy < winSize; wy++) {
        for (int wx = 0; wx < winSize; wx++) {
          final p1 = img1.getPixel(x + wx, y + wy);
          final p2 = img2.getPixel(x + wx, y + wy);
          final l1 = 0.299 * p1.r + 0.587 * p1.g + 0.114 * p1.b;
          final l2 = 0.299 * p2.r + 0.587 * p2.g + 0.114 * p2.b;
          sum1 += l1;
          sum2 += l2;
          sumSq1 += l1 * l1;
          sumSq2 += l2 * l2;
          sumCross += l1 * l2;
        }
      }

      final double n = (winSize * winSize).toDouble();
      final mu1 = sum1 / n;
      final mu2 = sum2 / n;
      final var1 = (sumSq1 / n) - (mu1 * mu1);
      final var2 = (sumSq2 / n) - (mu2 * mu2);
      final cov = (sumCross / n) - (mu1 * mu2);

      final ssim = ((2 * mu1 * mu2 + c1) * (2 * cov + c2)) /
          ((mu1 * mu1 + mu2 * mu2 + c1) * (var1 + var2 + c2));
      ssimTotal += ssim;
      windows++;
    }
  }

  return {'mse': mse, 'ssim': windows > 0 ? ssimTotal / windows : 1.0};
}