// example/geo_bootstrap.dart
// FlutterFlow custom code file — copy into your FlutterFlow project under
// custom_code/geo_bootstrap.dart
//
// Bootstrap orchestrator. Reads appConfig/runtime and geofences from Firestore
// to build a RuntimeConfig, configures the geofence engine, and writes
// session state to the user document. Also exposes an onZoneChange stream
// consumed by BtBootstrap for BLE proximity gating.

import 'dart:async';
import 'dart:io' show Platform;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'package:zbg_location/zbg_location.dart'; // barrel (api, engine, writers, geohash, etc.)
import 'package:zbg_proximity/zbg_proximity.dart'; // for ZoneState
import '/custom_code/zbg_firestore_adapter.dart'; // your shared WriteFn adapter
import '/custom_code/geo_fcm_handler.dart'; // FCM handler + background fetch headless task

class GeoBootstrap {
  GeoBootstrap._();
  static final instance = GeoBootstrap._();

  final _engine = TsbgEngine();
  FirestoreWriter? _writer;

  StreamSubscription<GeofenceEvent>? _fenceSub;
  StreamSubscription<LocationSample>? _locSub;
  StreamSubscription? _configSub;
  StreamSubscription? _geofenceSub;

  String? _uid;
  String? _currentZoneId;
  bool _inside = false;
  bool _starting = false; // concurrency guard — prevents overlapping startFromFirestore calls

  // Broadcasts zone state changes to any subscriber (e.g. BtBootstrap).
  // Purely in-memory — no network involved.
  final _zoneCtl = StreamController<ZoneState>.broadcast();
  Stream<ZoneState> get onZoneChange => _zoneCtl.stream;

  Future<void> startFromFirestore(String regionId) async {
    if (_starting) return; // prevent overlapping calls (e.g. rapid homepage reloads)
    _starting = true;
    try {
    await _startFromFirestoreInner(regionId);
    } finally {
      _starting = false;
    }
  }

  Future<void> _startFromFirestoreInner(String regionId) async {
    final fs = FirebaseFirestore.instance;

    // ----- 0) Get user + set identity FIRST -----
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('No signed-in user.');

    // Tell the engine who we are + what region we're in
    _engine.setIdentity(uid: uid, regionId: regionId);
    _uid = uid;

    // ----- 0b) Register background wakeup handlers -----
    // FCM silent-push handler: invoked by firebase_messaging when a
    // data-only 'geo_wakeup' message arrives (backgrounded/OS-terminated, not
    // force-quit). Idempotent — safe to call on every startFromFirestore.
    FirebaseMessaging.onBackgroundMessage(geoFirebaseMessagingBackgroundHandler);

    // Background fetch (iOS only): OS-triggered periodic wakeup ~every 15–30 min.
    // Complements silent push with time-based wakeups that require no server
    // infrastructure. fetch UIBackgroundMode is already in Info.plist.
    if (Platform.isIOS) {
      await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: 15,
          stopOnTerminate: false, // keep running when app is OS-terminated
          enableHeadless: true, // allow headless task in terminated state
          startOnBoot: true,
        ),
        (String taskId) async {
          // Foreground/background callback (app is running)
          await GeoBootstrap.instance.flushBuffer();
          BackgroundFetch.finish(taskId);
        },
        (String taskId) async {
          // Timeout — must finish quickly
          BackgroundFetch.finish(taskId);
        },
      );
      await BackgroundFetch.registerHeadlessTask(geoBackgroundFetchHeadlessTask);
    }

    // FBG Android geofence headless task: invoked by FBG's native service when
    // a geofence event fires in terminated state. Handles event writes and
    // re-arms Android's Geofencing API on EXIT. Android-only — on iOS,
    // CLRegionMonitoring re-arms automatically and BackgroundFetch handles wakeups.
    if (Platform.isAndroid) {
      await fbg.BackgroundGeolocation.registerHeadlessTask(geoFbgHeadlessTask);
    }

    // ----- 1) Check region exists -----
    final regionSnap = await fs.doc('appConfig_regions/$regionId').get();
    if (!regionSnap.exists) {
      throw StateError('Missing appConfig_regions/$regionId');
    }

    // ----- 1b) Attach runtime config listener -----
    // First emission initialises the engine; subsequent emissions update it
    // live so study coordinators can adjust sampling rates, distance filters,
    // or batch settings without restarting the app.
    _configSub?.cancel();
    final configReady = Completer<void>();
    _configSub = fs.doc('appConfig/runtime').snapshots().listen(
      (snap) {
        if (!snap.exists) {
          if (!configReady.isCompleted) {
            configReady.completeError(StateError('Missing appConfig/runtime'));
          }
          return;
        }
        final fut = _engine.setConfig(
          _buildRuntimeConfig(snap.data()! as Map<String, dynamic>),
        );
        if (!configReady.isCompleted) {
          fut.then((_) => configReady.complete());
        }
      },
      onError: (e) {
        if (!configReady.isCompleted) configReady.completeError(e);
      },
    );
    await configReady.future;

    // ----- 2) Attach live geofence listener -----
    // First emission registers geofences with the engine at startup.
    // Subsequent emissions re-register whenever a geofence document is added,
    // changed (center, radius), or removed in Firestore — no app restart needed.
    _geofenceSub?.cancel();
    final geofencesReady = Completer<void>();
    _geofenceSub = fs.collection('regions/$regionId/geofences').snapshots().listen(
      (snap) async {
        final defs = _parseGeofenceDocs(snap.docs);
        if (defs.isNotEmpty) await _engine.addGeofences(defs);
        if (!geofencesReady.isCompleted) geofencesReady.complete();
      },
      onError: (e) {
        if (!geofencesReady.isCompleted) geofencesReady.completeError(e);
      },
    );
    await geofencesReady.future;

    // ----- 3) Writer (shared) -----
    _writer = FirestoreWriter(uid: uid, writeFn: firestoreWriteAdapter);

    // ----- 4) Listen → write geofence events & breadcrumbs -----
    _fenceSub?.cancel();
    _fenceSub = _engine.onGeofence().listen((e) async {
      final isEnterOrDwell = (e.type == GeofenceEventType.enter ||
          e.type == GeofenceEventType.dwell);
      _inside = isEnterOrDwell;
      // Fix 1: clear zoneId on EXIT so downstream breadcrumbs are not tagged
      // with a stale zone after the user has left.
      _currentZoneId = isEnterOrDwell ? e.fenceId : null;

      // Update native HTTP extras so zbgIngest breadcrumbs carry correct
      // zoneId and inside_zone from this point forward.
      // On EXIT: zoneId is null, so the 'zoneId' key is omitted from extras.
      await _engine.setZoneContext(
        zoneId: _currentZoneId,
        insideZone: _inside,
      );

      // After EXIT, force-re-register all geofences so Android's Geofencing API
      // re-arms ENTER monitoring for the next visit. Android-only: on iOS,
      // CLRegionMonitoring re-arms automatically, and calling removeGeofences()
      // resets iOS region monitoring state — preventing timely ENTER detection
      // for zones the user enters shortly after leaving the previous one.
      if (e.type == GeofenceEventType.exit && Platform.isAndroid) {
        await _engine.refreshGeofences();
      }

      // Notify BtBootstrap (and any other subscribers) of the zone change.
      _zoneCtl.add(ZoneState(zoneId: _currentZoneId, insideZone: _inside));

      await _writer!.writeGeofenceEvent(
        regionId: regionId,
        event: switch (e.type) {
          GeofenceEventType.enter => 'ENTER',
          GeofenceEventType.exit => 'EXIT',
          GeofenceEventType.dwell => 'DWELL',
        },
        tsIso: e.ts.toUtc().toIso8601String(),
        zoneId: e.fenceId,
        dwellSeconds: e.dwellSeconds,
        extra: {'mode': _engine.geoSystemMode},
      );
    });

    // ----- 5) Dart breadcrumb writes (foreground + background) -----
    // Uses the same fixed document ID as zbgingest ({uid}_{tsIso}) so there
    // are never duplicate documents — whichever path writes second is an
    // identical overwrite. source_dart: 'bg' is preserved regardless of which
    // path wins, letting you see whether the Dart path delivered each fix.
    _locSub?.cancel();
    _locSub = _engine.onLocation().listen((s) async {
      final tsIso = s.ts.toUtc().toIso8601String();
      final gh7 = geohashP7(s.lat, s.lng);
      await _writer!.writeBreadcrumb(
        regionId: regionId,
        tsIso: tsIso,
        lat: s.lat,
        lng: s.lng,
        accuracyM: s.accuracyM,
        geohashP7: gh7,
        zoneId: _currentZoneId,
        insideZone: _inside,
        source: 'bg',
        extra: {'source_dart': 'bg', 'mode': _engine.geoSystemMode},
        fixedId: '${uid}_$tsIso',
      );
    });

    // ----- 6) Start engine -----
    await _engine.start();

    // ----- 6b) Synthesize ENTER if already inside a fence at startup -----
    // FBG may fire an ENTER during addGeofences() (step 2) before _fenceSub is
    // attached (step 4). Since _fenceCtl is a broadcast stream, that event is
    // dropped — _enteredAt is never set and zone context stays wrong.
    // synthesizeEnterIfInside() checks current GPS position now that _fenceSub
    // is listening, and emits a synthetic ENTER if inside any registered fence.
    await _engine.synthesizeEnterIfInside();

    // ----- 7) Mark geo as running on user doc -----
    // geoWakeupSweep queries geo_running == true to find users with breadcrumb
    // gaps. Written after engine.start() so it is only set if startup succeeded.
    // geo_session_started records the last time geo was started or restarted
    // (including homepage-triggered restarts — not just sign-in).
    // geo_mode records the active tracking mode so geoWakeupSweep can skip
    // users in geofence_only mode (they only emit breadcrumbs inside fences).
    await fs.doc('users/$uid').set(
      {
        'geo_running': true,
        'geo_session_started': FieldValue.serverTimestamp(),
        // tz_offset_minutes: device UTC offset in minutes (e.g. -300 for EST,
        // 330 for IST). Written each session start so it stays current across
        // DST changes. Used by geoWakeupSweep to evaluate local-time window.
        'tz_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
        'geo_mode': _engine.geoSystemMode,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> stop() async {
    await _locSub?.cancel();
    await _fenceSub?.cancel();
    _configSub?.cancel();
    _configSub = null;
    _geofenceSub?.cancel();
    _geofenceSub = null;
    await _engine.stop();
    _currentZoneId = null;
    _inside = false;
    _zoneCtl.add(ZoneState.outside);

    // Mark geo as stopped so geoWakeupSweep no longer targets this user.
    if (_uid != null) {
      await FirebaseFirestore.instance.doc('users/$_uid').set(
        {'geo_running': false, 'geo_session_stopped': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
      _uid = null;
    }
  }

  /// Returns true if geo is currently running in this process.
  /// False after force-quit, swipe-away reopen, or sign-out.
  bool get isRunning => _uid != null;

  /// Flush any locations accumulated in FBG's SQLite buffer to zbgingest.
  /// Call from the geoFlushBuffer custom action on every homepage visit to
  /// recover terminated-state locations written during significant-change wakeups.
  Future<void> flushBuffer() async => _engine.flushBuffer();

  /// Parses a geofences collection snapshot into GeofenceDef list.
  /// Called on every emission of the geofence listener.
  List<GeofenceDef> _parseGeofenceDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final defs = <GeofenceDef>[];
    for (final d in docs) {
      final m = d.data();
      final type = (m['type'] ?? 'circle') as String;
      if (type == 'circle') {
        final center = (m['center'] as Map?) ?? const {};
        final lat = (center['lat'] as num?)?.toDouble();
        final lng = (center['lng'] as num?)?.toDouble();
        final radiusM = (m['radius_m'] as num?)?.toDouble();
        if (lat != null && lng != null && radiusM != null) {
          defs.add(GeofenceDef(
            ident: d.id,
            type: 'circle',
            lat: lat,
            lng: lng,
            radiusM: radiusM,
          ));
        }
      }
      // polygons are optional later
    }
    return defs;
  }

  /// Builds a RuntimeConfig from a live appConfig/runtime snapshot.
  /// Called on every emission of the config listener — both at startup and
  /// whenever a field changes in Firestore.
  RuntimeConfig _buildRuntimeConfig(Map<String, dynamic> r) {
    final breadcrumbs = (r['breadcrumbs'] as Map?) ?? const {};
    final platform = (r['platform'] as Map?) ?? const {};
    final geoDetect = (r['geofenceDetect'] as Map?) ?? const {};
    return RuntimeConfig(
      enabled: (breadcrumbs['enabled'] == true),
      dwellRequiredS: (geoDetect['dwell_required_s'] ?? 60) as int,
      dwellEveryS: (geoDetect['dwell_every_s'] ?? 0) as int,
      rateOutsideS: (breadcrumbs['rate_outside_zone_s'] ?? 300) as int,
      rateNearS: (breadcrumbs['rate_near_zone_s'] ?? 60) as int,
      rateInsideS: (breadcrumbs['rate_inside_zone_s'] ?? 30) as int,
      accuracyDropM: (breadcrumbs['accuracy_drop_m'] ?? 50).toDouble(),
      distanceFilterInsideM:
          (breadcrumbs['distance_filter_inside_m'] ?? 10) as int,
      distanceFilterNearM:
          (breadcrumbs['distance_filter_near_m'] ?? 20) as int,
      distanceFilterOutsideM:
          (breadcrumbs['distance_filter_outside_m'] ?? 100) as int,
      startOnBoot: (platform['start_on_boot'] ?? true) as bool,
      stopOnTerminate: (platform['stop_on_terminate'] ?? false) as bool,
      useSignificantChangeWhenOutside:
          (platform['use_significant_change_outside'] ?? true) as bool,
      significantChangeOutsideThresholdS:
          (platform['significant_change_outside_threshold_s'] ?? 300) as int,
      stopTimeoutMinutes: (platform['stop_timeout_minutes'] ?? 60) as int,
      batchSync: (platform['batch_sync'] ?? true) as bool,
      maxBatchSize: (platform['max_batch_size'] ?? 8) as int,
      // Geofence-only mode — default false so existing builds are unaffected
      geofenceOnlyMode: (platform['geofence_only_mode'] ?? false) as bool,
    );
  }
}
