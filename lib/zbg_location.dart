import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'headless.dart';

export 'api.dart';
export 'tsbg_engine.dart';
export 'utils.dart';
export 'geohash_utils.dart';
export 'dwell_cooldown.dart';
export 'writers.dart';

/// One-time registration of the headless task.
/// Call this once early in app startup, BEFORE you start the engine.
class ZbgHeadless {
  static bool _registered = false;

  static void register() {
    if (_registered) return;
    fbg.BackgroundGeolocation.registerHeadlessTask(zbgHeadlessTask);
    _registered = true;
  }
}
