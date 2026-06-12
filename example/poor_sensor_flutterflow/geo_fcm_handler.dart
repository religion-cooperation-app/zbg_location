// lib/custom_code/geo_fcm_handler.dart
// FCM silent-push wakeup handler + flutter_background_fetch headless task.
//
// Both functions are top-level and annotated @pragma('vm:entry-point') so the
// Dart compiler does not tree-shake them in release builds.
//
// Registration happens inside GeoBootstrap.startFromFirestore() — no separate
// FlutterFlow action needed.
//
// FlutterFlow pubspec dependencies required:
//   background_fetch: ^1.2.1
//   firebase_core: (already a FlutterFlow dependency)
//   cloud_firestore: (already a FlutterFlow dependency)

import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import '/custom_code/geo_diagnostics_http.dart';

// ── Silent-push wakeup handler ────────────────────────────────────────────────
// Invoked by firebase_messaging when a data-only FCM message (content-available:1)
// arrives while the app is backgrounded or OS-terminated (NOT force-quit).
// The Cloud Function geoWakeupSweep sets data: { type: 'geo_wakeup' }.
//
// Execution order matters:
//   1. sync()                — flush SQLite buffer (primary purpose: recover
//                              locations FBG recorded but could not POST)
//   2. getCurrentPosition()  — capture a fresh fix right now as a bonus
//
// The iOS background window after a silent push is ~30 s.
// timeout:25 matches the httpTimeout set on FBG, leaving 5 s margin.
@pragma('vm:entry-point')
Future<void> geoFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  if (message.data['type'] != 'geo_wakeup') return;
  if (!Platform.isIOS) return; // Android FBG foreground service handles Android

  // 1. Flush SQLite — recover any locations FBG stored but could not POST
  try {
    await fbg.BackgroundGeolocation.sync();
  } catch (_) {}

  // 2. Capture a fresh fix and persist it; autoSync ships it immediately
  try {
    await fbg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      timeout: 25,
    );
  } catch (_) {
    // GPS timeout or unavailable — sync() above already flushed the buffer
  }
}

// ── Background-fetch headless task ────────────────────────────────────────────
// Invoked by flutter_background_fetch when iOS grants a periodic background-
// fetch wakeup (~every 15–30 min, OS-controlled). Runs even when the app is
// OS-terminated. No effect on force-quit apps.
//
// Registered via BackgroundFetch.registerHeadlessTask inside
// GeoBootstrap.startFromFirestore().
@pragma('vm:entry-point')
void geoBackgroundFetchHeadlessTask(HeadlessTask task) async {
  final taskId = task.taskId;

  // OS timeout guard — must call finish() quickly or iOS withdraws wakeup
  // privileges for future fetches.
  if (task.timeout) {
    BackgroundFetch.finish(taskId);
    return;
  }

  try {
    // 1. Flush SQLite buffer
    await fbg.BackgroundGeolocation.sync();

    // 2. Capture fresh fix (shorter timeout — background-fetch window is tighter)
    await fbg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      timeout: 20,
    );
  } catch (_) {
    // Timeout or GPS unavailable — sync() already flushed whatever was buffered
  } finally {
    BackgroundFetch.finish(taskId);
  }
}

// ── FBG Android geofence headless task ────────────────────────────────────────
// Invoked by FBG's native Android service when a geofence event fires while
// the app is OS-terminated (swipe-away). Runs in a fresh Dart isolate — cannot
// use GeoBootstrap or TsbgEngine singletons.
//
// Handles both inner fences and outer near-zone fences ({id}_near).
// Inner fence events: write to Firestore + apply sampling mode config.
// Near-zone fence events: apply mode config only (no Firestore write).
// EXIT (inner): apply near-mode config (user still in near zone) + re-arm all fences.
// EXIT (_near): apply outside-mode config.
//
// Registered via BackgroundGeolocation.registerHeadlessTask inside
// GeoBootstrap.startFromFirestore() — Android-only.
bool _headlessProviderUsable(fbg.ProviderChangeEvent e) {
  final authorized =
      e.status == fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS ||
          e.status == fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_WHEN_IN_USE;
  return e.enabled && authorized && (e.gps || e.network);
}

Future<void> _forceHeadlessMovingPace({required String source}) async {
  await fbg.Logger.notice('SPARRC force_pace attempt source=$source');

  try {
    final state = await fbg.BackgroundGeolocation.state;
    await fbg.Logger.notice(
      'SPARRC force_pace state source=$source enabled=${state.enabled} '
      'isMoving=${state.isMoving}',
    );
  } catch (_) {
    await fbg.Logger.notice(
      'SPARRC force_pace state_unreadable source=$source',
    );
  }

  try {
    await fbg.BackgroundGeolocation.changePace(true);
    await fbg.Logger.notice('SPARRC force_pace call_returned source=$source');
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC force_pace error source=$source error=${e.runtimeType}',
    );
  }
}

@pragma('vm:entry-point')
void geoFbgHeadlessTask(fbg.HeadlessEvent headlessEvent) async {
  await fbg.Logger.notice(
    'SPARRC headless_event received name=${headlessEvent.name}',
  );

  if (headlessEvent.name == fbg.Event.PROVIDERCHANGE) {
    await GeoDiagnosticsHttp.recordHeadlessReceived(headlessEvent.name);
    final event = headlessEvent.event as fbg.ProviderChangeEvent;
    await GeoDiagnosticsHttp.recordProviderChange(event);
    if (_headlessProviderUsable(event)) {
      await _forceHeadlessMovingPace(source: 'headless_provider_change_usable');
    } else {
      await fbg.Logger.notice(
        'SPARRC force_pace not_applicable '
        'source=headless_provider_change reason=provider_not_usable',
      );
    }
    return;
  }

  if (headlessEvent.name == fbg.Event.POWERSAVECHANGE) {
    await GeoDiagnosticsHttp.recordHeadlessReceived(headlessEvent.name);
    await GeoDiagnosticsHttp.recordPowerSaveChange(headlessEvent.event as bool);
    return;
  }

  if (headlessEvent.name == fbg.Event.ENABLEDCHANGE) {
    await GeoDiagnosticsHttp.recordHeadlessReceived(headlessEvent.name);
    await GeoDiagnosticsHttp.recordFbgEnabledChange(
      headlessEvent.event as bool,
    );
    return;
  }

  if (headlessEvent.name == fbg.Event.CONNECTIVITYCHANGE) {
    final event = headlessEvent.event as fbg.ConnectivityChangeEvent;
    if (!event.connected) {
      await _forceHeadlessMovingPace(
        source: 'headless_connectivity_disconnected',
      );
    } else {
      await fbg.Logger.notice(
        'SPARRC force_pace not_applicable '
        'source=headless_connectivity_connected reason=connected',
      );
      try {
        await fbg.BackgroundGeolocation.sync();
      } catch (_) {}
    }
    return;
  }

  if (headlessEvent.name == fbg.Event.MOTIONCHANGE) {
    final location = headlessEvent.event as fbg.Location;
    if (location.isMoving) {
      await _forceHeadlessMovingPace(source: 'headless_motion_change_moving');
    } else {
      await fbg.Logger.notice(
        'SPARRC force_pace not_applicable '
        'source=headless_motion_change reason=not_moving',
      );
    }
    return;
  }

  if (headlessEvent.name == fbg.Event.HEARTBEAT) {
    await GeoDiagnosticsHttp.recordHeartbeatSnapshot(
      source: 'fbg_heartbeat_headless',
    );
    return;
  }

  if (headlessEvent.name != 'geofence') return;
  await Firebase.initializeApp();
  final fs = FirebaseFirestore.instance;

  final event = headlessEvent.event as fbg.GeofenceEvent;
  final action = event.action;
  final fenceId = event.identifier;
  final isNearFence = fenceId.endsWith('_near');
  await _forceHeadlessMovingPace(
    source: isNearFence
        ? 'headless_geofence_near_$action'
        : 'headless_geofence_$action',
  );
  final ts = DateTime.tryParse(event.location.timestamp)?.toUtc() ??
      DateTime.now().toUtc();
  final tsIso = ts.toIso8601String();

  final extras = (event.location.extras ?? {}) as Map<String, dynamic>;
  final uid = extras['uid'] as String?;
  final regionId = extras['regionId'] as String?;
  final mode = extras['mode'] as String?;

  if (uid == null || uid.isEmpty) return;

  // Read config once — used for mode switching and fence registration.
  int loiteringDelayMs = 60000;
  int rateInsideS = 30, rateNearS = 60, rateOutsideS = 300;
  int distFilterInsideM = 10, distFilterNearM = 20, distFilterOutsideM = 100;
  double nearZoneRadiusM = 100.0;
  try {
    final configSnap = await fs.doc('appConfig/runtime').get();
    if (configSnap.exists) {
      final data = configSnap.data()!;
      final geoDetect = (data['geofenceDetect'] as Map?) ?? {};
      final breadcrumbs = (data['breadcrumbs'] as Map?) ?? {};
      loiteringDelayMs =
          ((geoDetect['dwell_required_s'] as num?)?.toInt() ?? 60) * 1000;
      nearZoneRadiusM =
          (geoDetect['near_zone_radius_m'] as num?)?.toDouble() ?? 100.0;
      rateInsideS = (breadcrumbs['rate_inside_zone_s'] as num?)?.toInt() ?? 30;
      rateNearS = (breadcrumbs['rate_near_zone_s'] as num?)?.toInt() ?? 60;
      rateOutsideS =
          (breadcrumbs['rate_outside_zone_s'] as num?)?.toInt() ?? 300;
      distFilterInsideM =
          (breadcrumbs['distance_filter_inside_m'] as num?)?.toInt() ?? 10;
      distFilterNearM =
          (breadcrumbs['distance_filter_near_m'] as num?)?.toInt() ?? 20;
      distFilterOutsideM =
          (breadcrumbs['distance_filter_outside_m'] as num?)?.toInt() ?? 100;
    }
  } catch (_) {}

  // Near-zone fences: mode switch only, no Firestore event write.
  if (isNearFence) {
    if (action == 'ENTER') {
      try {
        await fbg.BackgroundGeolocation.setConfig(
          fbg.Config(
            geolocation: fbg.GeoConfig(
              distanceFilter: distFilterNearM.toDouble(),
              locationUpdateInterval: rateNearS * 1000,
            ),
            app: fbg.AppConfig(heartbeatInterval: rateNearS.toDouble()),
          ),
        );
      } catch (_) {}
    } else if (action == 'EXIT') {
      try {
        await fbg.BackgroundGeolocation.setConfig(
          fbg.Config(
            geolocation: fbg.GeoConfig(
              distanceFilter: distFilterOutsideM.toDouble(),
              locationUpdateInterval: rateOutsideS * 1000,
            ),
            app: fbg.AppConfig(heartbeatInterval: rateOutsideS.toDouble()),
          ),
        );
      } catch (_) {}
    }
    return;
  }

  // Inner fence: write event to Firestore.
  await fs.collection('geofence_events').add({
    'uid': uid,
    if (regionId != null) 'regionId': regionId,
    'ts_iso': tsIso,
    'event': action,
    'zoneId': fenceId,
    'source': 'bg_headless',
    if (mode != null) 'mode': mode,
  });

  // Apply sampling mode config based on event type.
  if (action == 'ENTER') {
    try {
      await fbg.BackgroundGeolocation.setConfig(
        fbg.Config(
          geolocation: fbg.GeoConfig(
            distanceFilter: distFilterInsideM.toDouble(),
            locationUpdateInterval: rateInsideS * 1000,
          ),
          app: fbg.AppConfig(heartbeatInterval: rateInsideS.toDouble()),
        ),
      );
    } catch (_) {}
  } else if (action == 'EXIT') {
    // Apply near mode — user is likely still within the near zone.
    // The _near EXIT event will switch to outside mode when they fully leave.
    try {
      await fbg.BackgroundGeolocation.setConfig(
        fbg.Config(
          geolocation: fbg.GeoConfig(
            distanceFilter: distFilterNearM.toDouble(),
            locationUpdateInterval: rateNearS * 1000,
          ),
          app: fbg.AppConfig(heartbeatInterval: rateNearS.toDouble()),
        ),
      );
    } catch (_) {}
  }

  // EXIT: re-arm Android's Geofencing API including outer near-zone fences.
  if (action == 'EXIT' && regionId != null) {
    try {
      final snap = await fs.collection('regions/$regionId/geofences').get();
      await fbg.BackgroundGeolocation.removeGeofences();
      for (final doc in snap.docs) {
        final d = doc.data();
        final type = (d['type'] ?? 'circle') as String;
        if (type != 'circle') continue;
        final center = (d['center'] as Map?) ?? {};
        final lat = (center['lat'] as num?)?.toDouble();
        final lng = (center['lng'] as num?)?.toDouble();
        final radiusM = (d['radius_m'] as num?)?.toDouble();
        if (lat == null || lng == null || radiusM == null) continue;
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: doc.id,
            latitude: lat,
            longitude: lng,
            radius: radiusM,
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: true,
            loiteringDelay: loiteringDelayMs,
          ),
        );
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: '${doc.id}_near',
            latitude: lat,
            longitude: lng,
            radius: radiusM + nearZoneRadiusM,
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: false,
            loiteringDelay: 0,
          ),
        );
      }
    } catch (_) {
      // Re-arm failed — zbgIngest GPS computation will still detect ENTER
      // from breadcrumbs when the device re-enters the zone.
    }
  }
}
