import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'image_processing.dart';

class SharingHandler {
  final _supabase = Supabase.instance.client;
  final _appLinks = AppLinks();

  /// Compresses and shares multiple images as a Master ZIP payload.
  Future<String?> shareImages({
    required List<XFile> files,
    required bool isZipFiles,
    Function(String)? onProgress,
  }) async {
    try {
      if (files.isEmpty) return null;
      onProgress?.call('Starting process...');

      // 1. Authenticate anonymously
      onProgress?.call('Authenticating to server...');
      if (_supabase.auth.currentSession == null) {
        await _supabase.auth.signInAnonymously();
      }

      final masterArchive = Archive();

      // 2. Process each file into the master payload
      for (int i = 0; i < files.length; i++) {
        onProgress?.call('Processing file ${i + 1} of ${files.length}...');
        final bytes = await files[i].readAsBytes();

        if (isZipFiles) {
          String name = files[i].name;
          if (!name.toLowerCase().endsWith('.zip')) {
            name = 'archive_$i.zip';
          }
          masterArchive.addFile(ArchiveFile(name, bytes.length, bytes));
        } else {
          onProgress?.call('Packaging file ${i + 1} for WebP compression...');
          masterArchive.addFile(ArchiveFile(files[i].name, bytes.length, bytes));
        }
      }

      onProgress?.call('Packaging files into archive...');
      final masterZipBytes = ZipEncoder().encode(masterArchive)!;

      // 3. Upload to Supabase and construct link payload
      onProgress?.call('Uploading package to Supabase...');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final masterPath = 'shared/${timestamp}_master.zip';
      const bucketName = 'uploads';

      await _supabase.storage.from(bucketName).uploadBinary(
        masterPath,
        Uint8List.fromList(masterZipBytes),
        fileOptions: const FileOptions(contentType: 'application/zip', upsert: false),
      );

      // 4. Create an HTTPS deep link
      onProgress?.call('Generating shareable link...');
      final typeStr = isZipFiles ? 'zip' : 'webp';
      final deepLink = 'https://bytesized.app/share?path=${Uri.encodeComponent(masterPath)}&type=$typeStr';

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
  void listenForDeepLinks(
      Function(List<Uint8List> bytesList, List<String> names, String type) onDataReceived,
      {Function(String)? onStatus}) {
    _appLinks.uriLinkStream.listen((uri) {
      _handleIncomingUri(uri, onDataReceived, onStatus: onStatus);
    });
  }

  /// Checks if the app was started by a deep link
  Future<void> checkInitialLink(
      Function(List<Uint8List> bytesList, List<String> names, String type) onDataReceived,
      {Function(String)? onStatus}) async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        _handleIncomingUri(uri, onDataReceived, onStatus: onStatus);
      }
    } catch (e) {
      debugPrint('Error checking initial link: $e');
      onStatus?.call('Error checking initial link');
    }
  }

  Future<void> _handleIncomingUri(
      Uri uri, Function(List<Uint8List> bytesList, List<String> names, String type) onDataReceived,
      {Function(String)? onStatus}) async {
    final isCustomScheme = uri.scheme == 'bytesized' && uri.host == 'reconstruct';
    final isAppLink = uri.scheme == 'https' && uri.host == 'bytesized.app' && uri.path.startsWith('/share');

    if (!(isCustomScheme || isAppLink)) return;

    final path = uri.queryParameters['path'];
    final type = uri.queryParameters['type'] ?? 'zip';
    
    if (path != null) {
      try {
        onStatus?.call('Downloading files...');
        if (_supabase.auth.currentSession == null) {
          await _supabase.auth.signInAnonymously();
        }
        final masterBytes = await _supabase.storage.from('uploads').download(path);
        
        onStatus?.call('Extracting files...');
        final archive = ZipDecoder().decodeBytes(masterBytes);

        List<Uint8List> bytesList = [];
        List<String> names = [];

        for (final file in archive) {
          if (file.isFile) {
            bytesList.add(Uint8List.fromList(file.content as List<int>));
            names.add(file.name);
          }
        }

        if (bytesList.isNotEmpty) {
          onDataReceived(bytesList, names, type);
        }
      } catch (e) {
        debugPrint('Failed to process incoming link: $e');
        onStatus?.call('Failed to open link');
      }
    }
  }
}