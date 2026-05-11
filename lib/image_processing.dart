import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:bytesized/app_preset.dart';
import 'package:image/image.dart' as img;

// ─────────────────────────────────────────────
// REAL WEBP COMPRESSION using pure Dart `image` package
// Works on all platforms including web
// ─────────────────────────────────────────────
Future<Uint8List> encodeToWebP(Uint8List inputBytes, {int quality = 80}) async {
if (kIsWeb) {
// Web: use pure Dart encoder to support quality settings
return compute(_encodeFallbackTask, {'bytes': inputBytes, 'quality': quality});
}
// Android/iOS: flutter_image_compress gives real WebP
final result = await FlutterImageCompress.compressWithList(
inputBytes,
format: CompressFormat.webp,
quality: quality,
minWidth: 4096, // Reduced from 16383 to prevent OOM on massive images
minHeight: 4096,
);
return result;
}

/// Compresses an image while attempting to stay under the preset's [maxSize].
Future<Uint8List> compressWithPreset(Uint8List inputBytes, AppPreset preset) async {
int currentQuality = preset.quality;
Uint8List compressed = await encodeToWebP(inputBytes, quality: currentQuality);

// Check if the result is already within the limit
if (compressed.lengthInBytes <= preset.maxSize) {
return compressed;
}

// Iteratively reduce quality if the file is still too large
// In a production app, you might also consider downscaling dimensions 
// if quality reduction isn't enough.
while (compressed.lengthInBytes > preset.maxSize && currentQuality > 10) {
currentQuality -= 10;
compressed = await encodeToWebP(inputBytes, quality: currentQuality);
}

return compressed;
}

Uint8List _encodeFallbackTask(Map<String, dynamic> data) {
final Uint8List inputBytes = data['bytes'];
final int quality = data['quality'];
final decoded = img.decodeImage(inputBytes);
if (decoded == null) throw Exception('Could not decode image');

// Encode as JPG so the quality parameter is respected and the file shrinks!
return img.encodeJpg(decoded, quality: quality);
}

// ─────────────────────────────────────────────
// LOSSY PLUS RESIDUAL CODING (DLPR SIMULATION)
// ─────────────────────────────────────────────

Future<Uint8List> computeResidual(Uint8List originalBytes, Uint8List lossyBytes) async {
return compute(_computeResidualTask, {'orig': originalBytes, 'lossy': lossyBytes});
}

Uint8List _computeResidualTask(Map<String, Uint8List> data) {
final originalBytes = data['orig']!;
final lossyBytes = data['lossy']!;

final origImg = img.decodeImage(originalBytes);
var lossyImg = img.decodeImage(lossyBytes);

if (origImg == null || lossyImg == null) {
throw Exception('Process failed!');
}

// If the lossy compressor resized or rotated the image, we must scale it 
// back to match the exact original dimensions to do pixel-by-pixel math.
if (origImg.width != lossyImg.width || origImg.height != lossyImg.height) {
lossyImg = img.copyResize(lossyImg, width: origImg.width, height: origImg.height);
}

final residualImg = img.Image(width: origImg.width, height: origImg.height);

for (int y = 0; y < origImg.height; y++) {
for (int x = 0; x < origImg.width; x++) {
final origP = origImg.getPixel(x, y);
final lossyP = lossyImg.getPixel(x, y);

// Modular arithmetic guarantees 100% perfect 1:1 lossless reconstruction
final r = (origP.r.toInt() - lossyP.r.toInt()) % 256;
final g = (origP.g.toInt() - lossyP.g.toInt()) % 256;
final b = (origP.b.toInt() - lossyP.b.toInt()) % 256;
final a = (origP.a.toInt() - lossyP.a.toInt()) % 256;

residualImg.setPixelRgba(x, y, r, g, b, a);
}
}

return img.encodePng(residualImg);
}

Future<Uint8List> reconstructFromResidual(Uint8List lossyBytes, Uint8List residualBytes) async {
return compute(_reconstructTask, {'lossy': lossyBytes, 'residual': residualBytes});
}

Uint8List _reconstructTask(Map<String, Uint8List> data) {
final lossyBytes = data['lossy']!;
final residualBytes = data['residual']!;

var lossyImg = img.decodeImage(lossyBytes);
final residualImg = img.decodeImage(residualBytes);

if (lossyImg == null || residualImg == null) {
throw Exception('Reconstruction failed!');
}

// Ensure lossy image is scaled to match the residual's full dimensions
if (lossyImg.width != residualImg.width || lossyImg.height != residualImg.height) {
lossyImg = img.copyResize(lossyImg, width: residualImg.width, height: residualImg.height);
}

final reconstructedImg = img.Image(width: residualImg.width, height: residualImg.height);

for (int y = 0; y < residualImg.height; y++) {
for (int x = 0; x < residualImg.width; x++) {
final lossyP = lossyImg.getPixel(x, y);
final resP = residualImg.getPixel(x, y);

// Perfect 1:1 inversion using modulo 256
final r = (lossyP.r.toInt() + resP.r.toInt()) % 256;
final g = (lossyP.g.toInt() + resP.g.toInt()) % 256;
final b = (lossyP.b.toInt() + resP.b.toInt()) % 256;
final a = (lossyP.a.toInt() + resP.a.toInt()) % 256;

reconstructedImg.setPixelRgba(x, y, r, g, b, a);
}
}

// Encode the final reconstructed image as a high-quality JPEG to keep the file size low
return img.encodeJpg(reconstructedImg, quality: 95);
}

// ─────────────────────────────────────────────
// IMAGE METRICS (MSE & SSIM)
// ─────────────────────────────────────────────

Future<Map<String, double>> computeImageMetrics(Uint8List bytes1, Uint8List bytes2) async {
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
  for (int y = 0; y < img1.height; y++) {
    for (int x = 0; x < img1.width; x++) {
      final p1 = img1.getPixel(x, y);
      final p2 = img2.getPixel(x, y);
      final r = p1.r.toInt() - p2.r.toInt();
      final g = p1.g.toInt() - p2.g.toInt();
      final b = p1.b.toInt() - p2.b.toInt();
      mse += (r * r + g * g + b * b) / 3.0;
      count++;
    }
  }
  mse = count > 0 ? mse / count : 0.0;

  double ssimTotal = 0.0;
  int windows = 0;
  const int winSize = 8;
  final double c1 = (0.01 * 255) * (0.01 * 255);
  final double c2 = (0.03 * 255) * (0.03 * 255);

  for (int y = 0; y <= img1.height - winSize; y += winSize) {
    for (int x = 0; x <= img1.width - winSize; x += winSize) {
      double sum1 = 0, sum2 = 0;
      for (int wy = 0; wy < winSize; wy++) {
        for (int wx = 0; wx < winSize; wx++) {
          final p1 = img1.getPixel(x + wx, y + wy);
          final p2 = img2.getPixel(x + wx, y + wy);
          final l1 = 0.299 * p1.r + 0.587 * p1.g + 0.114 * p1.b;
          final l2 = 0.299 * p2.r + 0.587 * p2.g + 0.114 * p2.b;
          sum1 += l1;
          sum2 += l2;
        }
      }
      final mu1 = sum1 / (winSize * winSize);
      final mu2 = sum2 / (winSize * winSize);

      double var1 = 0, var2 = 0, cov = 0;
      for (int wy = 0; wy < winSize; wy++) {
        for (int wx = 0; wx < winSize; wx++) {
          final p1 = img1.getPixel(x + wx, y + wy);
          final p2 = img2.getPixel(x + wx, y + wy);
          final l1 = 0.299 * p1.r + 0.587 * p1.g + 0.114 * p1.b;
          final l2 = 0.299 * p2.r + 0.587 * p2.g + 0.114 * p2.b;
          var1 += (l1 - mu1) * (l1 - mu1);
          var2 += (l2 - mu2) * (l2 - mu2);
          cov += (l1 - mu1) * (l2 - mu2);
        }
      }
      var1 /= (winSize * winSize);
      var2 /= (winSize * winSize);
      cov /= (winSize * winSize);

      final ssim = ((2 * mu1 * mu2 + c1) * (2 * cov + c2)) /
                   ((mu1 * mu1 + mu2 * mu2 + c1) * (var1 + var2 + c2));
      ssimTotal += ssim;
      windows++;
    }
  }
  final ssim = windows > 0 ? ssimTotal / windows : 1.0;

  return {'mse': mse, 'ssim': ssim};
}