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
    RemoteMessage message) async {
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
@pragma('vm:entry-point')
void geoFbgHeadlessTask(fbg.HeadlessEvent headlessEvent) async {
  if (headlessEvent.name == 'heartbeat') {
    try {
      await fbg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        persist: true,
        timeout: 25,
      );
      // sync() removed — fixes accumulate to autoSyncThreshold instead of
      // forcing a batch(1) upload on every heartbeat.
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

  // Read only geofence geometry config — breadcrumb rates are flat in this branch.
  int loiteringDelayMs = 60000;
  double nearZoneRadiusM = 100.0;
  try {
    final configSnap = await fs.doc('appConfig/runtime').get();
    if (configSnap.exists) {
      final data = configSnap.data()! as Map<String, dynamic>;
      final geoDetect = (data['geofenceDetect'] as Map?) ?? {};
      loiteringDelayMs =
          ((geoDetect['dwell_required_s'] as num?)?.toInt() ?? 60) * 1000;
      nearZoneRadiusM =
          (geoDetect['near_zone_radius_m'] as num?)?.toDouble() ?? 100.0;
    }
  } catch (_) {}

  // Near-zone fences: no Firestore event write. Rate is flat — no setConfig needed.
  if (isNearFence) return;

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

  // Rate is flat in this branch — no setConfig needed on ENTER/EXIT.

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
        await fbg.BackgroundGeolocation.addGeofence(fbg.Geofence(
          identifier: doc.id,
          latitude: lat,
          longitude: lng,
          radius: radiusM,
          notifyOnEntry: true,
          notifyOnExit: true,
          notifyOnDwell: true,
          loiteringDelay: loiteringDelayMs,
        ));
        await fbg.BackgroundGeolocation.addGeofence(fbg.Geofence(
          identifier: '${doc.id}_near',
          latitude: lat,
          longitude: lng,
          radius: radiusM + nearZoneRadiusM,
          notifyOnEntry: true,
          notifyOnExit: true,
          notifyOnDwell: false,
          loiteringDelay: 0,
        ));
      }
    } catch (_) {
      // Re-arm failed — zbgIngest GPS computation will still detect ENTER
      // from breadcrumbs when the device re-enters the zone.
    }
  }
}