import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

      // 2. Read each file for the master payload
      List<Map<String, dynamic>> filesData = [];
      for (int i = 0; i < files.length; i++) {
        onProgress?.call('Processing file ${i + 1} of ${files.length}...');
        final bytes = await files[i].readAsBytes();

        if (isZipFiles) {
          String name = files[i].name;
          if (!name.toLowerCase().endsWith('.zip')) {
            name = 'archive_$i.zip';
          }
          filesData.add({'name': name, 'bytes': bytes});
        } else {
          onProgress?.call('Packaging file ${i + 1} for compression...');
          filesData.add({'name': files[i].name, 'bytes': bytes});
        }
      }

      onProgress?.call('Packaging files into archive...');
      final masterZipBytes = await compute(_encodeZipTask, filesData);

      // 3. Upload to Supabase and construct link payload
      onProgress?.call('Uploading package to database...');
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
      final deepLink = 'https://ruling-teal-cdzsd03xyd.edgeone.app/?path=${Uri.encodeComponent(masterPath)}&type=$typeStr';

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
      {Function(String)? onStatus, Function()? onStarted, Function()? onDone}) {
    _appLinks.uriLinkStream.listen((uri) {
      _handleIncomingUri(uri, onDataReceived, onStatus: onStatus, onStarted: onStarted, onDone: onDone);
    });
  }

  /// Checks if the app was started by a deep link
  Future<void> checkInitialLink(
      Function(List<Uint8List> bytesList, List<String> names, String type) onDataReceived,
      {Function(String)? onStatus, Function()? onStarted, Function()? onDone}) async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        await _handleIncomingUri(uri, onDataReceived, onStatus: onStatus, onStarted: onStarted, onDone: onDone);
      }
    } catch (e) {
      debugPrint('Error checking initial link: $e');
      onStatus?.call('Error checking initial link');
    }
  }

  Future<void> _handleIncomingUri(
      Uri uri, Function(List<Uint8List> bytesList, List<String> names, String type) onDataReceived,
      {Function(String)? onStatus, Function()? onStarted, Function()? onDone}) async {
    final isCustomScheme = uri.scheme == 'bytesized' && uri.host == 'reconstruct';
    final isAppLink = uri.scheme == 'https' && uri.host == 'ruling-teal-cdzsd03xyd.edgeone.app';

    if (!(isCustomScheme || isAppLink)) return;

    onStarted?.call();

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
        final extractedData = await compute(_decodeZipTask, masterBytes);

        if (extractedData['bytesList'].isNotEmpty) {
          onDataReceived(extractedData['bytesList'], extractedData['names'], type);
        }
      } catch (e) {
        debugPrint('Failed to process incoming link: $e');
        onStatus?.call('Failed to open link');
      } finally {
        onDone?.call();
      }
    } else {
      onDone?.call();
    }
  }
}

// --- Isolate Tasks for CPU-intensive ZIP operations ---

List<int> _encodeZipTask(List<Map<String, dynamic>> filesData) {
  final archive = Archive();
  for (final fileData in filesData) {
    final name = fileData['name'] as String;
    final bytes = fileData['bytes'] as Uint8List;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}

Map<String, dynamic> _decodeZipTask(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  List<Uint8List> bytesList = [];
  List<String> names = [];

  for (final file in archive) {
    if (file.isFile) {
      bytesList.add(Uint8List.fromList(file.content as List<int>));
      names.add(file.name);
    }
  }
  
  return {'bytesList': bytesList, 'names': names};
}