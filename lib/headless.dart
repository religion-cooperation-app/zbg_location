// lib/headless.dart
// Headless task for Android: runs when the UI is not alive (app killed/swiped).

import 'package:flutter/foundation.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

/// Top-level entry point required by flutter_background_geolocation.
/// MUST be top-level and annotated as an entry-point so the VM can find it
/// when the app process is recreated in the background.
@pragma('vm:entry-point')
void zbgHeadlessTask(fbg.HeadlessEvent event) async {
  if (kDebugMode) {
    debugPrint('[ZBG Headless] event=${event.name}');
  }

  switch (event.name) {
    case fbg.Event.LOCATION:
      final l = event.event as fbg.Location;
      if (kDebugMode) {
        debugPrint(
            '[ZBG Headless] LOCATION ${l.coords.latitude}, ${l.coords.longitude}, acc=${l.coords.accuracy}');
      }
      // TODO (advanced): here is where you’d either:
      //  - trigger native HTTP sync (if you've configured FBG's url/autoSync), or
      //  - call a very small Firestore-writing helper that doesn't depend on Flutter UI.
      break;

    case fbg.Event.GEOFENCE:
      final gf = event.event as fbg.GeofenceEvent;
      if (kDebugMode) {
        debugPrint(
            '[ZBG Headless] GEOFENCE ${gf.action} @ ${gf.identifier}');
      }
      break;

    case fbg.Event.HEARTBEAT:
      if (kDebugMode) {
        debugPrint('[ZBG Headless] HEARTBEAT');
      }
      break;

    default:
      // You can log or ignore other events (motionchange, http, schedule, etc.)
      if (kDebugMode) {
        debugPrint('[ZBG Headless] OTHER event=${event.name}');
      }
      break;
  }
}
