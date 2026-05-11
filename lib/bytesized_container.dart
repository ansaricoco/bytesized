import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class ByteSizedContainer {
  static const String lossyName = 'image.webp';
  static const String residualName = 'residual.png';
  static const String metadataName = 'metadata.json';

  static Uint8List createContainer({
    required Uint8List lossyBytes,
    required Uint8List residualBytes,
    required String originalName,
    required int originalSize,
    required int quality,
  }) {
    final archive = Archive();

    archive.addFile(
      ArchiveFile(lossyName, lossyBytes.length, lossyBytes),
    );

    archive.addFile(
      ArchiveFile(residualName, residualBytes.length, residualBytes),
    );

    final metadata = {
      'version': 1,
      'originalName': originalName,
      'originalSize': originalSize,
      'quality': quality,
      'createdAt': DateTime.now().toIso8601String(),
      'format': 'ByteSized',
    };

    final metadataBytes = utf8.encode(jsonEncode(metadata));

    archive.addFile(
      ArchiveFile(metadataName, metadataBytes.length, metadataBytes),
    );

    final zipBytes = ZipEncoder().encode(archive);

    return Uint8List.fromList(zipBytes);
  }
}