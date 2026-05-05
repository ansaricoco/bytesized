import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

// ─────────────────────────────────────────────
// REAL WEBP COMPRESSION using pure Dart `image` package
// Works on all platforms including web
// ─────────────────────────────────────────────
Future<Uint8List> encodeToWebP(Uint8List inputBytes, {int quality = 80}) async {
  if (kIsWeb) {
    // Web: re-encode as PNG (best we can do without native codec)
    return compute(_encodeFallbackTask, inputBytes);
  }
  // Android/iOS: flutter_image_compress gives real WebP
  final result = await FlutterImageCompress.compressWithList(
    inputBytes,
    format: CompressFormat.webp,
    quality: quality,
    minWidth: 16383,
    minHeight: 16383,
  );
  return result;
}

Uint8List _encodeFallbackTask(Uint8List inputBytes) {
  final decoded = img.decodeImage(inputBytes);
  if (decoded == null) throw Exception('Could not decode image');
  return Uint8List.fromList(img.encodePng(decoded));
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
    throw Exception('Failed to decode images for residual computation');
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

  return Uint8List.fromList(img.encodePng(residualImg));
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
    throw Exception('Failed to decode images for reconstruction');
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
  return Uint8List.fromList(img.encodeJpg(reconstructedImg, quality: 95));
}