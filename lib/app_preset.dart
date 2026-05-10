class AppPreset {
  final String name;
  final int maxSize; // in bytes
  final int quality;
  final String description;

  AppPreset({
    required this.name,
    required this.maxSize,
    required this.quality,
    required this.description,
  });

  static List<AppPreset> getPresets() {
    return [
      AppPreset(
        name: "WhatsApp",
        maxSize: 16 * 1024 * 1024,
        quality: 75,
        description: "16MB limit",
      ),
      AppPreset(
        name: "Discord",
        maxSize: 8 * 1024 * 1024,
        quality: 70,
        description: "8MB limit (free)",
      ),
      AppPreset(
        name: "Instagram",
        maxSize: 8 * 1024 * 1024,
        quality: 80,
        description: "8MB limit",
      ),
      AppPreset(
        name: "Messenger",
        maxSize: 25 * 1024 * 1024,
        quality: 60,
        description: "25MB",
      ),
    ];
  }
}
