export 'image_utils_io.dart'
    if (dart.library.html) 'image_utils_web.dart';

// This file uses conditional exports to provide the correct implementation
// for web and non-web (IO) platforms.