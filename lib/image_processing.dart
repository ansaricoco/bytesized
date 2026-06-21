import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

// ─────────────────────────────────────────────
// LIMITS
// ─────────────────────────────────────────────

/// MAX CAP of Bytesized
const int kMaxInputBytes = 200 * 1024 * 1024;

/// Any file size above this skips the residual pipeline (wala nang reconstruction) so no dart-side memory crashes
const int kResidualPipelineLimit = 30 * 1024 * 1024; // 30 MB lang yung pwedeng dalin sa reconstruction


/// Pixel-count threshold (within the residual pipeline) above which the image is downsized before residual computation.
///const int kMaxPixels = 6000 * 4000; // mas stable
const int kMaxPixels = 2000 * 2000; // if gusto performance
///const int kMaxPixels = 13600 * 5500; // if gusto macompress gang 30 mb

/// Long-edge target when downsizing.
const int kDownsizeLongEdge = 2048;

/// Number of horizontal strips for parallel residual processing. concurrency
const int kResidualStrips = 4;

// ─────────────────────────────────────────────
// WEBP / JPEG COMPRESSION (native codec, safe for any size)
// ─────────────────────────────────────────────

/// Compresses [inputBytes] to WebP (mobile) or JPEG (web) at [quality]
/// using the native OS codec. Safe for very large images since it
/// never fully decodes to a Dart-side RGBA buffer.
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
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
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
// LARGE IMAGE PATH — native codec only, no residual
// ─────────────────────────────────────────────

/// Compresses [inputBytes] using only the native OS codec.
/// Used for images above [kResidualPipelineLimit] where decoding
/// the full image into Dart memory would risk an OOM crash.
/// Returns only the lossy output — no residual is computed.
Future<Uint8List> compressLargeImage(
  Uint8List inputBytes, {
  int quality = 80,
}) async {
  if (kIsWeb) {
    return compute(
        _encodeFallbackTask, {'bytes': inputBytes, 'quality': quality});
  }
  return FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: quality,
    minWidth: kDownsizeLongEdge, ///edit
    minHeight: kDownsizeLongEdge,
  );
}

// ─────────────────────────────────────────────
// SINGLE-ISOLATE COMPRESS + RESIDUAL (web fallback)
// ─────────────────────────────────────────────

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

  final origBytes = original.getBytes(order: img.ChannelOrder.rgba);
  final lossBytes = lossyImg.getBytes(order: img.ChannelOrder.rgba);
  final residualData = Uint8List(origBytes.length);
  for (int i = 0; i < origBytes.length; i++) {
    residualData[i] = (origBytes[i] - lossBytes[i]) & 0xFF;
  }

  final residualImg = img.Image.fromBytes(
    width: original.width,
    height: original.height,
    bytes: residualData.buffer,
    order: img.ChannelOrder.rgba,
  );

  final residualBytes = Uint8List.fromList(img.encodePng(residualImg));
  return {'lossy': lossyBytes, 'residual': residualBytes};
}

// ─────────────────────────────────────────────
// PARALLEL RESIDUAL COMPUTATION
// ─────────────────────────────────────────────

Future<Uint8List> _computeResidualParallel(
    Uint8List origBytes, Uint8List lossyBytes) async {
  final origImg = img.decodeImage(origBytes);
  var lossyImg = img.decodeImage(lossyBytes);

  if (origImg == null || lossyImg == null) {
    throw Exception('Could not decode images for residual computation.');
  }

  if (origImg.width != lossyImg.width ||
      origImg.height != lossyImg.height) {
    lossyImg = img.copyResize(lossyImg,
        width: origImg.width, height: origImg.height);
  }

  final height = origImg.height;
  final width = origImg.width;
  final numStrips = kResidualStrips;
  final stripHeight = (height / numStrips).ceil();

  final futures = <Future<Uint8List>>[];
  for (int i = 0; i < numStrips; i++) {
    final startY = i * stripHeight;
    if (startY >= height) break;
    final endY = (startY + stripHeight).clamp(0, height);

    final origStrip = img.copyCrop(origImg,
        x: 0, y: startY, width: width, height: endY - startY);
    final lossyStrip = img.copyCrop(lossyImg,
        x: 0, y: startY, width: width, height: endY - startY);

    futures.add(compute(_computeResidualStripTask, {
      'orig': Uint8List.fromList(img.encodePng(origStrip)),
      'lossy': Uint8List.fromList(img.encodePng(lossyStrip)),
    }));
  }

  final strips = await Future.wait(futures);

  final result = img.Image(width: width, height: height);
  int currentY = 0;
  for (final stripBytes in strips) {
    final strip = img.decodeImage(stripBytes);
    if (strip == null) continue;
    img.compositeImage(result, strip, dstY: currentY);
    currentY += strip.height;
  }

  return Uint8List.fromList(img.encodePng(result));
}

Uint8List _computeResidualStripTask(Map<String, dynamic> data) {
  final origImg = img.decodeImage(data['orig'] as Uint8List);
  final lossyImg = img.decodeImage(data['lossy'] as Uint8List);

  if (origImg == null || lossyImg == null) {
    throw Exception('Strip decode failed.');
  }

  final origBuffer = origImg.getBytes(order: img.ChannelOrder.rgba);
  final lossBuffer = lossyImg.getBytes(order: img.ChannelOrder.rgba);
  final residualBuffer = Uint8List(origBuffer.length);

  for (int i = 0; i < origBuffer.length; i++) {
    residualBuffer[i] = (origBuffer[i] - lossBuffer[i]) & 0xFF;
  }

  final residualImg = img.Image.fromBytes(
    width: origImg.width,
    height: origImg.height,
    bytes: residualBuffer.buffer,
    order: img.ChannelOrder.rgba,
  );

  return Uint8List.fromList(img.encodePng(residualImg));
}

// ─────────────────────────────────────────────
// MAIN COMPRESS + RESIDUAL ENTRY POINT
// Only used for images within kResidualPipelineLimit.
// ─────────────────────────────────────────────

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

  final lossyBytes = await FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: quality,
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
  );

  final residualBytes =
      await _computeResidualParallel(inputBytes, lossyBytes);

  return {'lossy': lossyBytes, 'residual': residualBytes};
}

// ─────────────────────────────────────────────
// PARALLEL RECONSTRUCTION
// ─────────────────────────────────────────────

Future<Uint8List> reconstructFromResidual(
    Uint8List lossyBytes, Uint8List residualBytes) async {
  final lossyImg = img.decodeImage(lossyBytes);
  var residualImg = img.decodeImage(residualBytes);

  if (lossyImg == null || residualImg == null) {
    throw Exception('Reconstruction failed: could not decode images.');
  }

  if (lossyImg.width != residualImg.width ||
      lossyImg.height != residualImg.height) {
    residualImg = img.copyResize(residualImg,
        width: lossyImg.width, height: lossyImg.height);
  }

  final height = lossyImg.height;
  final width = lossyImg.width;
  final numStrips = kResidualStrips;
  final stripHeight = (height / numStrips).ceil();

  final futures = <Future<Uint8List>>[];
  for (int i = 0; i < numStrips; i++) {
    final startY = i * stripHeight;
    if (startY >= height) break;
    final endY = (startY + stripHeight).clamp(0, height);

    final lossyStrip = img.copyCrop(lossyImg,
        x: 0, y: startY, width: width, height: endY - startY);
    final residualStrip = img.copyCrop(residualImg,
        x: 0, y: startY, width: width, height: endY - startY);

    futures.add(compute(_reconstructStripTask, {
      'lossy': Uint8List.fromList(img.encodePng(lossyStrip)),
      'residual': Uint8List.fromList(img.encodePng(residualStrip)),
    }));
  }

  final strips = await Future.wait(futures);

  final result = img.Image(width: width, height: height);
  int currentY = 0;
  for (final stripBytes in strips) {
    final strip = img.decodeImage(stripBytes);
    if (strip == null) continue;
    img.compositeImage(result, strip, dstY: currentY);
    currentY += strip.height;
  }

  return Uint8List.fromList(img.encodeJpg(result, quality: 95));
}

Uint8List _reconstructStripTask(Map<String, dynamic> data) {
  final lossyImg = img.decodeImage(data['lossy'] as Uint8List);
  final residualImg = img.decodeImage(data['residual'] as Uint8List);

  if (lossyImg == null || residualImg == null) {
    throw Exception('Strip reconstruction failed.');
  }

  final lossyBuffer = lossyImg.getBytes(order: img.ChannelOrder.rgba);
  final residualBuffer =
      residualImg.getBytes(order: img.ChannelOrder.rgba);
  final resultBuffer = Uint8List(lossyBuffer.length);

  for (int i = 0; i < lossyBuffer.length; i++) {
    resultBuffer[i] = (lossyBuffer[i] + residualBuffer[i]) & 0xFF;
  }

  final resultImg = img.Image.fromBytes(
    width: lossyImg.width,
    height: lossyImg.height,
    bytes: resultBuffer.buffer,
    order: img.ChannelOrder.rgba,
  );

  return Uint8List.fromList(img.encodePng(resultImg));
}

// ─────────────────────────────────────────────
// HEIC / HEIF NORMALIZATION
// ─────────────────────────────────────────────

Future<Uint8List> normalizeToDecodable(
    Uint8List inputBytes, String fileName) async {
  if (kIsWeb) return inputBytes;

  final ext = fileName.toLowerCase().split('.').last;
  if (ext != 'heic' && ext != 'heif') return inputBytes;

  return FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.jpeg,
    quality: 95,
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
  );
}

// ─────────────────────────────────────────────
// SAFETY DOWNSIZE (within residual pipeline)
// ─────────────────────────────────────────────

/// Downsizes [inputBytes] to [kDownsizeLongEdge] using the native codec.
/// Safe for large inputs since it never fully decodes to Dart RGBA.
Future<Uint8List> safeDownsizeIfNeeded(Uint8List inputBytes) async {
  if (kIsWeb) {
    return compute(_safeDownsizePureDartTask, inputBytes);
  }

  return FlutterImageCompress.compressWithList(
    inputBytes,
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
    quality: 92,
  );
}

/// Downsizes a residual PNG using the native codec.
/// NOTE: this introduces lossy compression to the residual itself,
/// which is a documented trade-off for large reconstructions.
Future<Uint8List> safeDownsizeResidual(Uint8List residualBytes) async {
  if (kIsWeb) {
    return compute(_safeDownsizePureDartTask, residualBytes);
  }
  return FlutterImageCompress.compressWithList(
    residualBytes,
    format: CompressFormat.png,
    minWidth: kDownsizeLongEdge,
    minHeight: kDownsizeLongEdge,
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

  final buf1 = img1.getBytes(order: img.ChannelOrder.rgb);
  final buf2 = img2.getBytes(order: img.ChannelOrder.rgb);

  double mse = 0.0;
  for (int i = 0; i < buf1.length; i++) {
    final diff = buf1[i].toInt() - buf2[i].toInt();
    mse += diff * diff;
  }
  mse = buf1.isNotEmpty ? mse / buf1.length : 0.0;

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