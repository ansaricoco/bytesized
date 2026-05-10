import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:app_links/app_links.dart';

class SharingHandler {
  final _picker = ImagePicker();
  final _storage = FirebaseStorage.instance;
  final _appLinks = AppLinks();

  /// Picks an image from the gallery, uploads it to Firebase, 
  /// and opens the native share sheet with a deep link.
  Future<String?> pickAndShareImage() async {
    try {
      // 1. Pick image from gallery
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return null;

      // 2. Upload to Firebase Storage
      final file = File(image.path);
      final fileName = 'uploads/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage.ref().child(fileName);
      
      // Uploading the file
      await ref.putFile(file);

      // 3. Get download URL
      final downloadUrl = await ref.getDownloadURL();

      // 4. Create an HTTPS deep link for App Links / Universal Links
      final deepLink = 'https://bytesized.app/share?url=${Uri.encodeComponent(downloadUrl)}';

      // 5. Display shareable link via native share dialog
      await Share.share('I shared an image via Bytesized! Open it here: $deepLink');
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

  /// Listens for incoming deep links while the app is in the foreground or background.
  void listenForDeepLinks(Function(String imageUrl) onImageReceived) {
    _appLinks.uriLinkStream.listen((uri) {
      _handleIncomingUri(uri, onImageReceived);
    });
  }

  /// Checks if the app was started by clicking a deep link (Cold Start).
  Future<void> checkInitialLink(Function(String imageUrl) onImageReceived) async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        _handleIncomingUri(uri, onImageReceived);
      }
    } catch (e) {
      debugPrint('Error checking initial link: $e');
    }
  }

  void _handleIncomingUri(Uri uri, Function(String imageUrl) onImageReceived) {
    final isCustomScheme = uri.scheme == 'bytesized' && uri.host == 'reconstruct';
    final isAppLink = uri.scheme == 'https' && uri.host == 'bytesized.app' && uri.path.startsWith('/share');

    final imageUrl = uri.queryParameters['url'];
    if ((isCustomScheme || isAppLink) && imageUrl != null) {
      onImageReceived(imageUrl);
    }
  }
}