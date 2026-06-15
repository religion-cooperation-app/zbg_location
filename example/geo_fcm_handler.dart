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
import 'package:zbg_location/zbg_location.dart';
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
const Duration _headlessWatchdogInterval = Duration(minutes: 2);
const Duration _headlessWatchdogStaleAfter = Duration(minutes: 2);
const int _headlessWatchdogTimeoutS = 30;
const double _headlessWatchdogMovedM = 60;
const Duration _nearEnterForceWakeCooldown = Duration(minutes: 10);
const Duration _nearEnterForceWakeStaleAfter = Duration(minutes: 5);
const int _nearEnterForceWakeTimeoutS = 20;
const double _nearEnterForceWakeMovedM = 60;

Future<bool> _runHeadlessHeartbeatWatchdog({fbg.HeartbeatEvent? event}) async {
  final now = DateTime.now().toUtc();
  const sourceName = 'fbg_heartbeat_headless';
  await fbg.Logger.notice('SPARRC headless_watchdog heartbeat_check');

  final lastRun = await GeoDiagnosticsWriter.readHeartbeatWatchdogRun(
    source: sourceName,
  );
  if (lastRun != null && now.difference(lastRun) < _headlessWatchdogInterval) {
    await fbg.Logger.notice(
      'SPARRC headless_watchdog skipped reason=rate_limited',
    );
    return false;
  }
  await GeoDiagnosticsWriter.storeHeartbeatWatchdogRun(
    source: sourceName,
    timestamp: now,
  );

  fbg.Location? loc;
  var locationSource = 'fresh_current_position';
  await fbg.Logger.notice(
    'SPARRC headless_watchdog get_current_position_start',
  );
  try {
    loc = await fbg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      timeout: _headlessWatchdogTimeoutS,
    );
    await fbg.Logger.notice(
      'SPARRC headless_watchdog get_current_position_success',
    );
  } catch (e) {
    locationSource = 'heartbeat_fallback';
    await fbg.Logger.notice(
      'SPARRC headless_watchdog get_current_position_error '
      'error=${e.runtimeType}',
    );
    loc = event?.location;
  }

  if (loc == null) {
    await fbg.Logger.notice(
      'SPARRC headless_watchdog skipped reason=no_location_available',
    );
    return false;
  }

  final lat = loc.coords.latitude;
  final lng = loc.coords.longitude;

  final identity = await GeoDiagnosticsWriter.readIdentity();
  final persistedRef = await GeoDiagnosticsWriter.readLastBreadcrumbCandidate(
    uid: identity?.uid,
  );
  if (persistedRef == null) {
    await fbg.Logger.notice(
      'SPARRC headless_watchdog skipped '
      'reason=no_last_breadcrumb_reference after_location_persisted=true',
    );
    return false;
  }

  final staleS = now.difference(persistedRef.timestamp).inSeconds;
  await fbg.Logger.notice(
    'SPARRC headless_watchdog reference '
    'source=local_persisted_candidate:${persistedRef.source ?? 'unknown'} '
    'stale_s=$staleS',
  );
  if (staleS < _headlessWatchdogStaleAfter.inSeconds) {
    await fbg.Logger.notice(
      'SPARRC headless_watchdog skipped '
      'reason=breadcrumb_not_stale stale_s=$staleS '
      'after_location_persisted=true',
    );
    return false;
  }

  final movedM = haversineMeters(persistedRef.lat, persistedRef.lng, lat, lng);
  await fbg.Logger.notice(
    'SPARRC headless_watchdog using_location source=$locationSource '
    'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
  );

  if (movedM < _headlessWatchdogMovedM) {
    await fbg.Logger.notice(
      'SPARRC headless_watchdog skipped reason=moved_too_little '
      'distance_m=${movedM.toStringAsFixed(1)} '
      'threshold_m=$_headlessWatchdogMovedM',
    );
    return false;
  }

  await fbg.Logger.notice(
    'SPARRC headless_watchdog should_force_pace=true '
    'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
  );
  return true;
}

Future<void> _forceHeadlessHeartbeatMovingPace() async {
  const source = 'headless_heartbeat_watchdog';
  await fbg.Logger.notice('SPARRC force_pace attempt source=$source');

  try {
    final state = await fbg.BackgroundGeolocation.state;
    await fbg.Logger.notice(
      'SPARRC force_pace state source=$source enabled=${state.enabled} '
      'isMoving=${state.isMoving}',
    );
    if (state.enabled == true && state.isMoving == true) {
      await fbg.Logger.notice(
        'SPARRC force_pace skipped reason=already_moving source=$source',
      );
      return;
    }
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC force_pace state_unreadable source=$source '
      'error=${e.runtimeType}',
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

Future<void> _forceHeadlessMovingPace({required String source}) async {
  await fbg.Logger.notice('SPARRC force_pace attempt source=$source');

  try {
    final state = await fbg.BackgroundGeolocation.state;
    await fbg.Logger.notice(
      'SPARRC force_pace state source=$source enabled=${state.enabled} '
      'isMoving=${state.isMoving}',
    );
    if (state.enabled == true && state.isMoving == true) {
      await fbg.Logger.notice(
        'SPARRC force_pace skipped reason=already_moving source=$source',
      );
      return;
    }
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC force_pace state_unreadable source=$source '
      'error=${e.runtimeType}',
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

Future<void> _maybeForceWakeFromNearEnter({
  required fbg.GeofenceEvent event,
  required String uid,
}) async {
  final now = DateTime.now().toUtc();
  const sourceName = 'near_geofence_enter_forcewake';

  await fbg.Logger.notice(
    'SPARRC near_forcewake check fence=${event.identifier}',
  );

  try {
    final state = await fbg.BackgroundGeolocation.state;
    await fbg.Logger.notice(
      'SPARRC near_forcewake state enabled=${state.enabled} '
      'isMoving=${state.isMoving}',
    );
    if (state.enabled != true) {
      await fbg.Logger.notice(
        'SPARRC near_forcewake skipped reason=fbg_disabled',
      );
      return;
    }
    if (state.isMoving == true) {
      await fbg.Logger.notice(
        'SPARRC near_forcewake skipped reason=already_moving',
      );
      return;
    }
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake state_unreadable error=${e.runtimeType}',
    );
    return;
  }

  final lastRun = await GeoDiagnosticsWriter.readHeartbeatWatchdogRun(
    source: sourceName,
  );
  if (lastRun != null &&
      now.difference(lastRun) < _nearEnterForceWakeCooldown) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake skipped reason=rate_limited '
      'last_run_s=${now.difference(lastRun).inSeconds}',
    );
    return;
  }

  final comparisonRef = await GeoDiagnosticsWriter.readLastBreadcrumbCandidate(
    uid: uid,
  );

  await GeoDiagnosticsWriter.storeHeartbeatWatchdogRun(
    source: sourceName,
    timestamp: now,
  );

  await fbg.Logger.notice(
    'SPARRC near_forcewake get_current_position_start '
    'comparison_ref=${comparisonRef == null ? 'missing' : 'found'}',
  );
  fbg.Location? loc;
  try {
    loc = await fbg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      timeout: _nearEnterForceWakeTimeoutS,
    );
    await fbg.Logger.notice(
      'SPARRC near_forcewake get_current_position_success',
    );
  } catch (e) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake get_current_position_error '
      'error=${e.runtimeType}',
    );
  }

  if (loc == null) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake skipped reason=no_location_available',
    );
    return;
  }

  if (comparisonRef == null) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake skipped '
      'reason=no_last_breadcrumb_reference after_location_persisted=true',
    );
    return;
  }

  final staleS = now.difference(comparisonRef.timestamp).inSeconds;
  if (staleS < _nearEnterForceWakeStaleAfter.inSeconds) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake skipped reason=breadcrumb_not_stale '
      'stale_s=$staleS after_location_persisted=true',
    );
    return;
  }

  final movedM = haversineMeters(
    comparisonRef.lat,
    comparisonRef.lng,
    loc.coords.latitude,
    loc.coords.longitude,
  );
  await fbg.Logger.notice(
    'SPARRC near_forcewake using_location '
    'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
  );

  if (movedM < _nearEnterForceWakeMovedM) {
    await fbg.Logger.notice(
      'SPARRC near_forcewake skipped reason=moved_too_little '
      'distance_m=${movedM.toStringAsFixed(1)} '
      'threshold_m=$_nearEnterForceWakeMovedM',
    );
    return;
  }

  await fbg.Logger.notice(
    'SPARRC near_forcewake force_pace '
    'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
  );
  await _forceHeadlessMovingPace(source: sourceName);
}

Future<void> _logHeadlessNativeGeofenceInventory(String source) async {
  try {
    final geofences = await fbg.BackgroundGeolocation.geofences;
    final ids = geofences.map((g) => g.identifier).whereType<String>().toList()
      ..sort();
    await fbg.Logger.notice(
      'SPARRC geofence_inventory source=$source native_count=${ids.length} '
      'ids=${ids.join(',')}',
    );
  } catch (e) {
    try {
      await fbg.Logger.notice(
        'SPARRC geofence_inventory_failed source=$source '
        'error=${e.runtimeType}',
      );
    } catch (_) {}
  }
}

bool _shouldLogHeadlessGeofenceInventory(String eventName) {
  return eventName == fbg.Event.LOCATION ||
      eventName == fbg.Event.HEARTBEAT ||
      eventName == fbg.Event.MOTIONCHANGE ||
      eventName == 'geofence' ||
      eventName == 'geofenceschange';
}

@pragma('vm:entry-point')
void geoFbgHeadlessTask(fbg.HeadlessEvent headlessEvent) async {
  await fbg.Logger.notice(
    'SPARRC headless_entry name=${headlessEvent.name} '
    'payload_type=${headlessEvent.event.runtimeType} '
    'isolate_started_at=${DateTime.now().toUtc().toIso8601String()}',
  );
  await fbg.Logger.notice(
    'SPARRC headless_event received name=${headlessEvent.name}',
  );
  if (_shouldLogHeadlessGeofenceInventory(headlessEvent.name)) {
    await _logHeadlessNativeGeofenceInventory('headless_${headlessEvent.name}');
  }

  if (headlessEvent.name == fbg.Event.PROVIDERCHANGE) {
    await GeoDiagnosticsHttp.recordHeadlessReceived(headlessEvent.name);
    await GeoDiagnosticsHttp.recordProviderChange(
      headlessEvent.event as fbg.ProviderChangeEvent,
    );
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

  if (headlessEvent.name == fbg.Event.HEARTBEAT) {
    final event = headlessEvent.event is fbg.HeartbeatEvent
        ? headlessEvent.event as fbg.HeartbeatEvent
        : null;
    await fbg.Logger.notice(
      'SPARRC headless_heartbeat received '
      'payload_type=${headlessEvent.event.runtimeType} '
      'has_location=${event?.location != null}',
    );
    await GeoDiagnosticsWriter.storeHeartbeatWatchdogRun(
      source: 'headless_heartbeat_received',
      timestamp: DateTime.now().toUtc(),
    );
    try {
      final state = await fbg.BackgroundGeolocation.state;
      await fbg.Logger.notice(
        'SPARRC heartbeat_state path=headless enabled=${state.enabled} '
        'isMoving=${state.isMoving}',
      );
    } catch (e) {
      await fbg.Logger.notice(
        'SPARRC heartbeat_state path=headless state_unreadable '
        'error=${e.runtimeType}',
      );
    }
    await GeoDiagnosticsHttp.recordHeadlessReceived(headlessEvent.name);
    await GeoDiagnosticsHttp.recordHeartbeatSnapshot(
      source: 'fbg_heartbeat_headless',
    );
    await fbg.Logger.notice('SPARRC headless_watchdog invoke');
    final shouldForcePace = await _runHeadlessHeartbeatWatchdog(event: event);
    await fbg.Logger.notice(
      'SPARRC headless_watchdog returned should_force_pace=$shouldForcePace',
    );
    if (shouldForcePace) {
      await _forceHeadlessHeartbeatMovingPace();
    } else {
      await fbg.Logger.notice(
        'SPARRC headless_watchdog force_pace_not_requested',
      );
    }
    return;
  }

  if (headlessEvent.name == fbg.Event.CONNECTIVITYCHANGE) {
    final event = headlessEvent.event;
    var connected = 'unknown';
    if (event is fbg.ConnectivityChangeEvent) {
      connected = event.connected.toString();
    }
    await fbg.Logger.notice(
      'SPARRC headless_event connectivitychange connected=$connected '
      'force_pace=false',
    );
    return;
  }

  if (headlessEvent.name == fbg.Event.MOTIONCHANGE) {
    final event = headlessEvent.event;
    var isMoving = 'unknown';
    if (event is fbg.Location) {
      isMoving = event.isMoving.toString();
    }
    await fbg.Logger.notice(
      'SPARRC headless_event motionchange isMoving=$isMoving '
      'force_pace=false',
    );
    return;
  }

  if (headlessEvent.name == fbg.Event.ACTIVITYCHANGE) {
    final event = headlessEvent.event as dynamic;
    var details = 'payload_type=${headlessEvent.event.runtimeType}';
    try {
      details = 'activity=${event.activity} confidence=${event.confidence}';
    } catch (_) {}
    await fbg.Logger.notice(
      'SPARRC headless_event activitychange $details force_pace=false',
    );
    return;
  }

  if (headlessEvent.name == fbg.Event.LOCATION) {
    final event = headlessEvent.event;
    await fbg.Logger.notice(
      'SPARRC headless_event location payload_type='
      '${headlessEvent.event.runtimeType} force_pace=false',
    );
    if (event is fbg.Location) {
      final rawExtras = event.extras;
      final extras = rawExtras is Map ? rawExtras : const <String, dynamic>{};
      final ts =
          DateTime.tryParse(event.timestamp)?.toUtc() ?? DateTime.now().toUtc();
      await GeoDiagnosticsWriter.storeLastBreadcrumbCandidate(
        lat: event.coords.latitude,
        lng: event.coords.longitude,
        accuracyM: event.coords.accuracy,
        timestamp: ts,
        source: 'headless_location',
        uid: extras['uid'] as String?,
        regionId: extras['regionId'] as String?,
      );
      await fbg.Logger.notice(
        'SPARRC headless_event location stored_last_breadcrumb_candidate '
        'source=headless_location',
      );
    }
    try {
      await fbg.BackgroundGeolocation.sync();
    } catch (_) {}
    return;
  }

  if (headlessEvent.name != 'geofence') return;
  await Firebase.initializeApp();
  final fs = FirebaseFirestore.instance;

  final event = headlessEvent.event as fbg.GeofenceEvent;
  final action = event.action;
  final fenceId = event.identifier;
  final isNearFence = fenceId.endsWith('_near');
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
  int rateInsideS = 45, rateNearS = 45, rateOutsideS = 120;
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
      rateInsideS = (breadcrumbs['rate_inside_zone_s'] as num?)?.toInt() ?? 45;
      rateNearS = (breadcrumbs['rate_near_zone_s'] as num?)?.toInt() ?? 45;
      rateOutsideS =
          (breadcrumbs['rate_outside_zone_s'] as num?)?.toInt() ?? 120;
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
      await _maybeForceWakeFromNearEnter(event: event, uid: uid);
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
