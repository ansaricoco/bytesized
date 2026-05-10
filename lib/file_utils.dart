import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

Future<Directory?> getAppSaveDirectory() async {
  if (kIsWeb) return null;
  if (Platform.isAndroid) {
    return Directory('/storage/emulated/0/Download');
  } else if (Platform.isIOS) {
    return await getApplicationDocumentsDirectory();
  } else {
    return await getDownloadsDirectory();
  }
}