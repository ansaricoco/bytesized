import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_preset.dart';
import 'package:bytesized/file_utils.dart';
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

  @override
  void initState() {
    super.initState();
    _presets = AppPreset.getPresets();
    _selectedPreset = _presets.first;
    _loadRecentFiles();
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
      // Natively downsample the image in Android before Dart loads it into RAM.
      final List<XFile> files = await _picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
      );
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
                          'Image Compressor',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Compress and decompress images with adjustable quality',
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
              const SizedBox(height: 32),
              const Text(
                'Recent Files',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.file(
                                      file,
                                      fit: BoxFit.cover,
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