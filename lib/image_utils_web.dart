import 'dart:html' as html;
import 'dart:typed_data';

Future<Uint8List> compressToWebP(Uint8List inputBytes) async {
  // Not used on web — pure Dart image package handles encoding in main.dart
  return inputBytes;
}

void downloadBytes(Uint8List bytes, String fileName) {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}