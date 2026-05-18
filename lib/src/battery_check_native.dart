import 'dart:io' show Platform;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

Future<bool> isIgnoringBatteryOptimizations() async {
  if (!Platform.isAndroid) return true;
  try {
    final ds = await fbg.BackgroundGeolocation.deviceSettings;
    return ds.isIgnoringBatteryOptimizations;
  } catch (_) {
    return true;
  }
}
