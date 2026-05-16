import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:bytesized/app_preset.dart';
import 'package:bytesized/file_utils.dart';
import 'package:bytesized/sharing_handler.dart';
import 'result_screen.dart';

// ─────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  List<File> _recentFiles = [];
  bool _loadingHistory = true;
  AppPreset? _selectedPreset;
  late final List<AppPreset> _presets;
  final SharingHandler _sharingHandler = SharingHandler();

  @override
  void initState() {
    super.initState();
    _presets = AppPreset.getPresets();
    _selectedPreset = _presets.first;
    _loadRecentFiles();

    _sharingHandler.listenForDeepLinks((bytesList, names, type) {
      if (mounted) {
        final mode = type == 'webp' ? ActionMode.compress : ActionMode.decompress;
        _navigateToResult(bytesList, names, mode);
      }
    });
    _sharingHandler.checkInitialLink((bytesList, names, type) {
      if (mounted) {
        final mode = type == 'webp' ? ActionMode.compress : ActionMode.decompress;
        _navigateToResult(bytesList, names, mode);
      }
    });
  }

  Future<void> _loadRecentFiles() async {
    if (kIsWeb) {
      setState(() => _loadingHistory = false);
      return;
    }
    try {
      final dir = await getAppSaveDirectory();
      if (dir != null && await dir.exists()) {
        final files = dir.listSync().whereType<File>().where((file) {
          final name = file.path.toLowerCase();
          return name.contains('compressed_') && 
                 (name.endsWith('.webp') || name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.jpeg'));
        }).toList();
        
        files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        
        if (mounted) {
          setState(() {
            _recentFiles = files;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading history: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  Future<void> _pickImage(ActionMode mode) async {
    if (mode == ActionMode.compress) {
      // By default pickMultiImage returns the unmodified file. Specifying maxWidth
      // or maxHeight forces the OS to re-encode the image, inflating its size.
      final List<XFile> files = await _picker.pickMultiImage();
      if (files.isNotEmpty && mounted) {
        List<Uint8List> bytesList = [];
        List<String> names = [];
        for (var file in files.take(5)) {
          bytesList.add(await file.readAsBytes());
          names.add(file.name);
        }
        await _navigateToResult(bytesList, names, mode);
      }
    } else {
      // Use file_picker for decompression to allow selecting .zip archives
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      
      if (result != null && mounted) {
        List<Uint8List> bytesList = [];
        List<String> names = [];
        for (var file in result.files.take(5)) {
          Uint8List? bytes = file.bytes;
          if (bytes == null && file.path != null) {
            bytes = await File(file.path!).readAsBytes();
          }
          if (bytes != null) {
            bytesList.add(bytes);
            names.add(file.name);
          }
        }
        if (bytesList.isNotEmpty) {
          await _navigateToResult(bytesList, names, mode);
        }
      }
    }
  }

  Future<void> _navigateToResult(List<Uint8List> bytesList, List<String> fileNames, ActionMode mode) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResultScreen(
          imageBytesList: bytesList,
          fileNames: fileNames,
          mode: mode,
          preset: mode == ActionMode.compress ? _selectedPreset : null,
        ),
      ),
    );
    _loadRecentFiles(); // Reload when returning from ResultScreen
  }

  Future<void> _shareImage() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const ShareDialog(),
    );
  }

  Future<void> _clearRecentFiles() async {
    bool confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Clear History', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to clear all recent files? This will delete them from your device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    ) ?? false;

    if (!confirm) return;

    setState(() => _loadingHistory = true);
    try {
      for (var file in _recentFiles) {
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      if (mounted) {
        setState(() {
          _recentFiles.clear();
        });
      }
    } catch (e) {
      debugPrint('Error clearing files: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  void _showImagePreview(File file) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      cacheWidth: 1080, // High quality for preview, but still capped to prevent OOM
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 24),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                // Since the file is already stored in the app's Download directory
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('File is already saved at:\n${file.path}'),
                    duration: const Duration(seconds: 4),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download / Save'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ByteSized',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Compress and decompress images!',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.45),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AppPreset>(
                    value: _selectedPreset,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF222222),
                    icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                    items: _presets.map((preset) {
                      return DropdownMenuItem<AppPreset>(
                        value: preset,
                        child: Text(
                          '${preset.name} - ${preset.description}',
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      );
                    }).toList(),
                    onChanged: (AppPreset? newValue) {
                      setState(() {
                        _selectedPreset = newValue;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _ActionCard(
                      label: 'Compress',
                      subtitle: 'Convert to WebP',
                      icon: Icons.compress_rounded,
                      iconColor: const Color(0xFF3B82F6),
                      onTap: () => _pickImage(ActionMode.compress),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _ActionCard(
                      label: 'Decompress',
                      subtitle: 'Reconstruct original',
                      icon: Icons.open_in_full_rounded,
                      iconColor: const Color(0xFF22C55E),
                      onTap: () => _pickImage(ActionMode.decompress),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ActionCard(
                      label: 'Share Link',
                      subtitle: 'Upload and generate URL',
                      icon: Icons.cloud_upload_rounded,
                      iconColor: const Color(0xFFA855F7),
                      onTap: _shareImage,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Recent Files',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_recentFiles.isNotEmpty)
                    TextButton.icon(
                      onPressed: _clearRecentFiles,
                      icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 20),
                      label: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _loadingHistory
                    ? const Center(child: CircularProgressIndicator())
                    : _recentFiles.isEmpty
                        ? Center(
                            child: Text(
                              'No recent images found.',
                              style: TextStyle(color: Colors.white.withOpacity(0.4)),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 1,
                            ),
                            itemCount: _recentFiles.length,
                            itemBuilder: (context, index) {
                              final file = _recentFiles[index];
                              return GestureDetector(
                                onTap: () => _showImagePreview(file),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.file(
                                        file,
                                        fit: BoxFit.cover,
                                        cacheWidth: 300, // PERFORMANCE FIX: Stops the app from lagging when scrolling
                                        errorBuilder: (_, __, ___) => Container(
                                          color: const Color(0xFF1A1A1A),
                                          child: const Icon(Icons.broken_image, color: Colors.white54),
                                        ),
                                      ),
                                      Positioned(
                                      bottom: 0, left: 0, right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                          ),
                                        ),
                                        child: Text(
                                          file.path.split(Platform.pathSeparator).last,
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// REAL-TIME SHARE DIALOG POPUP
// ─────────────────────────────────────────────
class ShareDialog extends StatefulWidget {
  const ShareDialog({super.key});

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  final SharingHandler _sharingHandler = SharingHandler();
  final ImagePicker _picker = ImagePicker();

  String _step = 'selection';
  String _progressText = '';
  String _generatedLink = '';

  Future<void> _pickAndShare(bool asZip) async {
    List<XFile> selectedFiles = [];

    try {
      if (asZip) {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip'],
          allowMultiple: true,
        );
        if (result != null) {
          selectedFiles = result.files.take(5).where((f) => f.path != null).map((f) => XFile(f.path!)).toList();
        }
      } else {
        final List<XFile> files = await _picker.pickMultiImage();
        selectedFiles = files.take(5).toList();
      }

      if (selectedFiles.isEmpty) return;

      setState(() {
        _step = 'processing';
        _progressText = 'Initializing request...';
      });

      final link = await _sharingHandler.shareImages(
        files: selectedFiles,
        isZipFiles: asZip,
        onProgress: (status) {
          if (mounted) {
            setState(() => _progressText = status);
          }
        },
      );

      if (mounted) {
        if (link != null) {
          setState(() {
            _step = 'success';
            _generatedLink = link;
          });
        } else {
          setState(() {
            _step = 'error';
            _progressText = 'Failed to generate a secure link.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = 'error';
          _progressText = 'Error encountered: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_step == 'selection') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Share Files', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_library_rounded, color: Color(0xFF3B82F6)),
            title: const Text('Share as WebP', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Lossy compression only (up to 5 images)', style: TextStyle(color: Colors.white54)),
            onTap: () => _pickAndShare(false),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_zip_rounded, color: Color(0xFFA855F7)),
            title: const Text('Share as ZIP', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Upload up to 5 .zip files', style: TextStyle(color: Colors.white54)),
            onTap: () => _pickAndShare(true),
          ),
        ],
      );
    } else if (_step == 'processing') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          const CircularProgressIndicator(color: Color(0xFF3B82F6)),
          const SizedBox(height: 24),
          Text(_progressText, style: const TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
      );
    } else if (_step == 'success') {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF22C55E), size: 48),
          const SizedBox(height: 16),
          const Text('Link Generated!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _generatedLink,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, color: Color(0xFF3B82F6)),
                  onPressed: () {
                    _sharingHandler.copyToClipboard(_generatedLink);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied to clipboard!')),
                    );
                  },
                )
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          )
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
          const SizedBox(height: 16),
          const Text('Error', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 16),
          Text(_progressText, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF222222),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Close', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          )
        ],
      );
    }

    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: content,
        ),
      ),
    );
  }
}

class _ActionCard extends StatefulWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color:
                _hovered ? const Color(0xFF252525) : const Color(0xFF222222),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? widget.iconColor.withOpacity(0.4)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, color: widget.iconColor, size: 28),
              const SizedBox(height: 12),
              Text(widget.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(widget.subtitle,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}