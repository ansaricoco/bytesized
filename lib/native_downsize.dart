import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;

// ─────────────────────────────────────────────
// NATIVE SAMPLED DECODE / DOWNSIZE
// ─────────────────────────────────────────────
//
// Why this exists:
// FlutterImageCompress.compressWithFile / compressWithList both
// constrain OUTPUT size via minWidth/minHeight, but on many platform
// implementations the plugin still performs a full-resolution decode
// internally before applying that constraint. For images in the
// 200-400+ megapixel range (e.g. 21000x15158, 24000x17323), that full
// decode alone can require 1-1.6GB+ of native memory, which causes an
// intermittent native-level OOM kill ("Lost connection to device",
// tombstone in logs) that bypasses Dart's try/catch entirely.
//
// dart:ui's instantiateImageCodec, when given targetWidth/targetHeight,
// is backed by Skia's native codec and performs SCALED/SAMPLED
// decoding — it does not materialize the full-resolution bitmap before
// scaling down. This is the same mechanism behind
// Image.file(file, cacheWidth: ...) in the Flutter widget system.
//
// Strategy: run this BEFORE handing bytes to flutter_image_compress
// for any image whose dimensions are large enough to risk the native
// OOM. This guarantees the compressor only ever receives a
// already-reasonably-sized bitmap re-encoded as bytes, regardless of
// whether the compressor's own internals are doing sampled decode.

/// Long-edge target for the pre-downsize pass. Should be >= whatever
/// the downstream compressor's own minWidth/minHeight target is, so
/// this step doesn't become the binding constraint on output quality.
const int kNativeDownsizeLongEdge = 2048;

/// Pixel-count threshold above which we proactively run the
/// native-sampled downsize before doing anything else with the image.
/// Tune based on testing — this should be set comfortably below the
/// point where full decode would exceed safe native memory headroom.
/// ~30MP is a conservative starting point; raise only after confirming
/// stability on your actual target test devices, not just the
/// emulator/dev device.
const int kNativeDownsizeTriggerPixels = 30 * 1000 * 1000; // ~30MP

/// Reads just enough of [inputBytes] to determine its pixel
/// dimensions, without performing a full decode. Returns null if the
/// format/dimensions can't be determined.
///
/// NOTE: instantiateImageCodec still has to parse the header, which
/// for most formats (JPEG/PNG/WebP) is cheap and does not require
/// reading the full pixel data into memory.
Future<ui.Size?> probeImageDimensions(Uint8List inputBytes) async {
  try {
    final descriptor = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(inputBytes),
    );
    final size = ui.Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    return size;
  } catch (_) {
    return null;
  }
}

/// Reads just enough of the file at [path] to determine its pixel
/// dimensions, without performing a full decode. Returns null if the
/// format/dimensions can't be determined. This is the memory-efficient
/// alternative to [probeImageDimensions] for mobile platforms.
///
/// NOTE: Throws [UnsupportedError] on web.
Future<ui.Size?> probeImageDimensionsFromFile(String path) async {
  if (kIsWeb) {
    throw UnsupportedError(
        'probeImageDimensionsFromFile is not supported on the web.');
  }
  try {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = ui.Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    buffer.dispose();
    return size;
  } catch (_) {
    return null;
  }
}

/// Downsizes [inputBytes] using Skia's native scaled decode
/// (instantiateImageCodec with targetWidth/targetHeight), then
/// re-encodes as PNG bytes. Never allocates a full-resolution bitmap.
///
/// If the image is already at or below [kNativeDownsizeTriggerPixels],
/// returns the original bytes unchanged.
Future<Uint8List> nativeSampledDownsize(
  Uint8List inputBytes, {
  int longEdge = kNativeDownsizeLongEdge,
}) async {
  if (kIsWeb) {
    // dart:ui's instantiateImageCodec with targetWidth/targetHeight is
    // supported on web too via the CanvasKit/Skia backend, but if
    // you're using the HTML renderer this path may not apply. If you
    // hit issues specifically on web, fall back to your existing
    // compute()-based pure-Dart path for web and only use this
    // function on mobile.
  }

  final buffer = await ui.ImmutableBuffer.fromUint8List(inputBytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);

  final width = descriptor.width;
  final height = descriptor.height;
  final pixels = width * height;

  if (pixels <= kNativeDownsizeTriggerPixels) {
    descriptor.dispose();
    buffer.dispose();
    return inputBytes;
  }

  final isLandscape = width >= height;
  final targetWidth = isLandscape ? longEdge : (longEdge * width / height).round();
  final targetHeight = isLandscape ? (longEdge * height / width).round() : longEdge;

  final codec = await descriptor.instantiateCodec(
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );

  final frame = await codec.getNextFrame();
  final image = frame.image;

  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

  // Clean up native resources explicitly — these don't always get
  // promptly GC'd and large images make that lag costly.
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();

  if (byteData == null) {
    throw Exception('nativeSampledDownsize: failed to encode PNG output.');
  }

  return byteData.buffer.asUint8List();
}

/// Memory-efficiently downsizes the image at [path] using Skia's native
/// scaled decode, then re-encodes as PNG bytes. This function avoids
/// loading the full-resolution image into Dart memory.
///
/// If the image is already at or below [kNativeDownsizeTriggerPixels],
/// it will then read the original file and return its bytes.
///
/// NOTE: Throws [UnsupportedError] on web.
Future<Uint8List> nativeSampledDownsizeFromFile(
  String path, {
  int longEdge = kNativeDownsizeLongEdge,
}) async {
  if (kIsWeb) {
    throw UnsupportedError(
        'nativeSampledDownsizeFromFile is not supported on the web.');
  }

  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);

  final width = descriptor.width;
  final height = descriptor.height;
  final pixels = width * height;

  if (pixels <= kNativeDownsizeTriggerPixels) {
    descriptor.dispose();
    buffer.dispose();
    // Image is small enough, now we can read it without high risk of OOM.
    return await File(path).readAsBytes();
  }

  final isLandscape = width >= height;
  final targetWidth =
      isLandscape ? longEdge : (longEdge * width / height).round();
  final targetHeight =
      isLandscape ? (longEdge * height / width).round() : longEdge;

  final codec = await descriptor.instantiateCodec(
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );

  final frame = await codec.getNextFrame();
  final image = frame.image;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();

  if (byteData == null) {
    throw Exception('nativeSampledDownsize: failed to encode PNG output.');
  }

  return byteData.buffer.asUint8List();
}