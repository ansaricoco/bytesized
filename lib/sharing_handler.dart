import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:app_links/app_links.dart';
import 'image_processing.dart';

class SharingHandler {
  final _picker = ImagePicker();
  final _storage = FirebaseStorage.instance;
  final _appLinks = AppLinks();

  /// Picks an image, computes reconstruction data, and uploads both parts.
  Future<String?> pickAndShareImage({
    required VoidCallback onUploadStarted,
    required VoidCallback onUploadComplete,
  }) async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return null;

      onUploadStarted();
      final Uint8List originalBytes = await image.readAsBytes();

      // 1. Generate Lossy version & Residual (for reconstruction)
      final lossyBytes = await encodeToWebP(originalBytes);
      final residualBytes = await computeResidual(originalBytes, lossyBytes);

      // 2. Upload both to Firebase
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final lossyRef = _storage.ref().child('shared/$timestamp\_lossy.webp');
      final resRef = _storage.ref().child('shared/$timestamp\_res.png');

      await lossyRef.putData(lossyBytes);
      await resRef.putData(residualBytes);

      // 3. Get URLs
      final lossyUrl = await lossyRef.getDownloadURL();
      final resUrl = await resRef.getDownloadURL();

      // 4. Create an HTTPS deep link for App Links / Universal Links
      final deepLink = 'https://bytesized.app/share?'
          'lossy=${Uri.encodeComponent(lossyUrl)}&'
          'res=${Uri.encodeComponent(resUrl)}';

      onUploadComplete();
      await Share.share('I shared a Bytesized image with you! Open it here: $deepLink');
      return deepLink;
    } catch (e) {
      debugPrint('Error in sharing flow: $e');
      return null;
    }
  }

  /// Copies the given [text] to the system clipboard.
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Listens for incoming deep links
  void listenForDeepLinks(Function(String lossyUrl, String resUrl) onDataReceived) {
    _appLinks.uriLinkStream.listen((uri) {
      _handleIncomingUri(uri, onDataReceived);
    });
  }

  /// Checks if the app was started by a deep link
  Future<void> checkInitialLink(Function(String lossyUrl, String resUrl) onDataReceived) async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        _handleIncomingUri(uri, onDataReceived);
      }
    } catch (e) {
      debugPrint('Error checking initial link: $e');
    }
  }

  void _handleIncomingUri(Uri uri, Function(String lossyUrl, String resUrl) onDataReceived) {
    final isCustomScheme = uri.scheme == 'bytesized' && uri.host == 'reconstruct';
    final isAppLink = uri.scheme == 'https' && uri.host == 'bytesized.app' && uri.path.startsWith('/share');

    final lossy = uri.queryParameters['lossy'];
    final res = uri.queryParameters['res'];

    if ((isCustomScheme || isAppLink) && lossy != null && res != null) {
      onDataReceived(lossy, res);
    }
  }
}