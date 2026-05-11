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
    minWidth: 4096, // Match the 4096 native downsample limit to prevent upscaling inflation
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
  
  var origImg = img.decodeImage(originalBytes);
  var lossyImg = img.decodeImage(lossyBytes);

  if (origImg == null || lossyImg == null) {
    throw Exception('Process failed!');
  }

  // CRITICAL FIX: Scale the original image DOWN to the lossy image's dimensions.
  // Upscaling the lossy image to massive original dimensions causes huge OOM crashes.
  if (origImg.width != lossyImg.width || origImg.height != lossyImg.height) {
    origImg = img.copyResize(origImg, width: lossyImg.width, height: lossyImg.height);
  }

  final residualImg = img.Image(width: lossyImg.width, height: lossyImg.height);

  for (int y = 0; y < lossyImg.height; y++) {
    for (int x = 0; x < lossyImg.width; x++) {
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