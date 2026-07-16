// lib/custom_code/geo_bootstrap.dart
// bootstrap orchestrator. reads appconfig/runtime and geofences from firestore
// to build a runtime config, configures geofence engine and writes data to firestore
// also streams for bluetooth system. updated 2/23/26. Most recent backup in firestore_export/_backup and in github backup

import 'dart:async';
import 'dart:io' show Platform;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_installations/firebase_app_installations.dart';
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
  bool _starting =
      false; // concurrency guard — prevents overlapping startFromFirestore calls

  // Broadcasts zone state changes to any subscriber (e.g. BtBootstrap).
  // Purely in-memory — no network involved.
  final _zoneCtl = StreamController<ZoneState>.broadcast();
  Stream<ZoneState> get onZoneChange => _zoneCtl.stream;

  Future<void> startFromFirestore(String regionId) async {
    if (_starting) return;
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
    // NOTE: _uid is intentionally NOT set here. It is set only at step 7 after
    // full successful startup, so isRunning accurately reflects engine state.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('geo:no_user');

    // Fetch Firebase Installation ID for FID→UID attribution in zbgIngest.
    // Non-fatal: a failed fetch still allows bootstrap to continue.
    String? fid;
    try {
      fid = await FirebaseInstallations.instance.getId();
    } catch (e, st) {
      FirebaseCrashlytics.instance
          .recordError(e, st, fatal: false, reason: 'fid_fetch_failed');
    }

    // Tell the engine who we are, what region we're in, and our FID.
    _engine.setIdentity(uid: uid, regionId: regionId, fid: fid);

    // ----- 0b) Register background wakeup handlers -----
    // FCM silent-push handler: invoked by firebase_messaging when a
    // data-only 'geo_wakeup' message arrives (backgrounded/OS-terminated, not
    // force-quit). Idempotent — safe to call on every startFromFirestore.
    FirebaseMessaging.onBackgroundMessage(
        geoFirebaseMessagingBackgroundHandler);

    // Background fetch (iOS only): OS-triggered periodic wakeup ~every 15–30 min.
    // Complements silent push with time-based wakeups that require no server
    // infrastructure. fetch UIBackgroundMode is already in Info.plist.
    if (Platform.isIOS) {
      try {
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
        await BackgroundFetch.registerHeadlessTask(
            geoBackgroundFetchHeadlessTask);
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(e, st,
            fatal: false, reason: 'background_fetch_configure_failed');
        throw StateError('geo:background_fetch_failed');
      }
    }

    // FBG Android geofence headless task: invoked by FBG's native service when
    // a geofence event fires in terminated state. Handles event writes and
    // re-arms Android's Geofencing API on EXIT. Android-only — on iOS,
    // CLRegionMonitoring re-arms automatically and BackgroundFetch handles wakeups.
    if (Platform.isAndroid) {
      try {
        await fbg.BackgroundGeolocation.registerHeadlessTask(
            geoFbgHeadlessTask);
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(e, st,
            fatal: false, reason: 'headless_task_registration_failed');
        throw StateError('geo:headless_task_failed');
      }
    }

    // ----- 1) Check region exists -----
    final regionSnap = await fs.doc('appConfig_regions/$regionId').get();
    if (!regionSnap.exists) throw StateError('geo:missing_region');

    // ----- 1b) Attach runtime config listener -----
    // First emission initialises the engine; subsequent emissions update it
    // live so study coordinators can adjust sampling rates, distance filters,
    // or batch settings without restarting the app.
    _configSub?.cancel();
    final configReady = Completer<void>();
    _configSub = fs.doc('appConfig/runtime').snapshots().listen(
      (snap) {
        if (!snap.exists) {
          if (!configReady.isCompleted)
            configReady.completeError(StateError('geo:missing_runtime_config'));
          return;
        }
        RuntimeConfig cfg;
        try {
          cfg = _buildRuntimeConfig(snap.data()! as Map<String, dynamic>);
        } catch (e, st) {
          FirebaseCrashlytics.instance.recordError(e, st,
              fatal: false, reason: 'runtime_config_parse_failed');
          if (!configReady.isCompleted)
            configReady.completeError(StateError('geo:config_parse_failed'));
          return;
        }
        final fut = _engine.setConfig(cfg);
        if (!configReady.isCompleted) {
          fut
              .then((_) => configReady.complete())
              .catchError((Object e, StackTrace st) {
            FirebaseCrashlytics.instance
                .recordError(e, st, fatal: false, reason: 'fbg_init_failed');
            if (!configReady.isCompleted)
              configReady.completeError(StateError('geo:fbg_init_failed'));
          });
        } else {
          fut.catchError((Object e, StackTrace st) {
            FirebaseCrashlytics.instance.recordError(e, st,
                fatal: false, reason: 'live_config_update_failed');
          });
        }
      },
      onError: (e) {
        if (!configReady.isCompleted)
          configReady.completeError(StateError('geo:config_load_failed'));
      },
    );
    try {
      await configReady.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('geo:config_timeout');
    }

    // ----- 2) Writer (shared) -----
    _writer = FirestoreWriter(uid: uid, writeFn: firestoreWriteAdapter);

    // ----- 3) Listen → write geofence events & breadcrumbs -----
    // Attached before addGeofences() (step 4) so any ENTER that FBG fires
    // during geofence registration is caught here rather than dropped into
    // the broadcast stream with no subscriber.
    _fenceSub?.cancel();
    _fenceSub = _engine.onGeofence().listen((e) async {
      FirebaseCrashlytics.instance.log(
          'fence ${e.type.name} zone=${e.fenceId}${e.dwellSeconds != null ? ' dwell=${e.dwellSeconds}s' : ''}');
      FirebaseCrashlytics.instance
          .setCustomKey('last_fence_event', e.type.name);
      FirebaseCrashlytics.instance.setCustomKey('last_fence_id', e.fenceId);
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

    // ----- 4) Attach live geofence listener -----
    // Runs after _fenceSub is attached (step 3) so the ENTER that FBG may fire
    // during addGeofences() is not lost.
    // First emission registers geofences with the engine at startup.
    // Subsequent emissions re-register whenever a geofence document is added,
    // changed (center, radius), or removed in Firestore — no app restart needed.
    _geofenceSub?.cancel();
    final geofencesReady = Completer<void>();
    _geofenceSub =
        fs.collection('regions/$regionId/geofences').snapshots().listen(
      (snap) async {
        final defs = _parseGeofenceDocs(snap.docs);
        if (defs.isNotEmpty) await _engine.addGeofences(defs);
        if (!geofencesReady.isCompleted) geofencesReady.complete();
      },
      onError: (e) {
        if (!geofencesReady.isCompleted)
          geofencesReady.completeError(StateError('geo:geofences_load_failed'));
      },
    );
    try {
      await geofencesReady.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('geo:geofences_timeout');
    }

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
    try {
      await _engine.start();
    } catch (e, st) {
      FirebaseCrashlytics.instance
          .recordError(e, st, fatal: false, reason: 'engine_start_failed');
      throw StateError('geo:engine_start_failed');
    }

    // ----- 6b) Synthesize ENTER if already inside a fence at startup -----
    // FBG may fire an ENTER during addGeofences() (step 2) before _fenceSub is
    // attached (step 4). Since _fenceCtl is a broadcast stream, that event is
    // dropped — _enteredAt is never set and zone context stays wrong.
    // synthesizeEnterIfInside() checks current GPS position now that _fenceSub
    // is listening, and emits a synthetic ENTER if inside any registered fence.
    try {
      await _engine.synthesizeEnterIfInside();
    } catch (e, st) {
      FirebaseCrashlytics.instance
          .recordError(e, st, fatal: false, reason: 'synthesize_enter_failed');
      throw StateError('geo:synthesize_failed');
    }

    // ----- 7) Mark geo as running on user doc -----
    // _uid is set here — only after all prior steps succeed.
    // isRunning (== _uid != null) therefore only returns true on full success.
    // geoWakeupSweep queries geo_running == true to find users with breadcrumb
    // gaps. Written after engine.start() so it is only set if startup succeeded.
    // geo_session_started records the last time geo was started or restarted
    // (including homepage-triggered restarts — not just sign-in).
    // geo_mode records the active tracking mode so geoWakeupSweep can skip
    // users in geofence_only mode (they only emit breadcrumbs inside fences).
    FirebaseCrashlytics.instance.setUserIdentifier(uid);
    try {
      await Future.wait([
        fs.doc('geoSessions/$uid').set({
          'geo_running': true,
          'geo_session_started': FieldValue.serverTimestamp(),
          // tz_offset_minutes: device UTC offset in minutes (e.g. -300 for EST,
          // 330 for IST). Written each session start so it stays current across
          // DST changes. Used by geoWakeupSweep to evaluate local-time window.
          'tz_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
          'geo_mode': _engine.geoSystemMode,
          'uid': uid,
        }, SetOptions(merge: true)),
        fs.doc('users/$uid').set({
          'geo_running': true,
        }, SetOptions(merge: true)),
      ]);
      _uid = uid;
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(e, st,
          fatal: false, reason: 'user_doc_start_write_failed');
      throw StateError('geo:user_doc_write_failed');
    }
  }

  /// Ensures FBG Dart listeners are registered in this Dart VM session.
  /// Delegates to TsbgEngine.ensureListeners() — idempotent, safe before start().
  /// Call from registerLifecycleTracker on every app open.
  void ensureListeners() => _engine.ensureListeners();

  Future<void> stop() async {
    await _locSub?.cancel();
    await _fenceSub?.cancel();
    _configSub?.cancel();
    _configSub = null;
    _geofenceSub?.cancel();
    _geofenceSub = null;

    // Track the first error that occurs during cleanup so we can surface it
    // after all cleanup steps complete (never short-circuit on a single failure).
    String? errorCode;

    try {
      await _engine.stop();
    } catch (e, st) {
      FirebaseCrashlytics.instance
          .recordError(e, st, fatal: false, reason: 'engine_stop_failed');
      errorCode = 'geo:stop_engine_failed';
    }

    _currentZoneId = null;
    _inside = false;
    _zoneCtl.add(ZoneState.outside);

    // Mark geo as stopped so geoWakeupSweep no longer targets this user.
    if (_uid != null) {
      try {
        await Future.wait([
          FirebaseFirestore.instance.doc('geoSessions/$_uid').set(
            {
              'geo_running': false,
              'geo_session_stopped': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          ),
          FirebaseFirestore.instance.doc('users/$_uid').set(
            {
              'geo_running': false,
              'geo_session_stopped': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          ),
        ]);
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(e, st,
            fatal: false, reason: 'user_doc_stop_write_failed');
        errorCode ??= 'geo:stop_doc_write_failed';
      }
      _uid = null;
      FirebaseCrashlytics.instance.setUserIdentifier('');
    }

    if (errorCode != null) throw StateError(errorCode);
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
      rateOutsideS: 480, // TEMP: 8 min; restore: (breadcrumbs['rate_outside_zone_s'] ?? 300) as int
      rateNearS: 420, // TEMP: 7 min; restore: (breadcrumbs['rate_near_zone_s'] ?? 60) as int
      rateInsideS: 300, // TEMP: 5 min; restore: (breadcrumbs['rate_inside_zone_s'] ?? 30) as int
      accuracyDropM: (breadcrumbs['accuracy_drop_m'] ?? 50).toDouble(),
      distanceFilterInsideM:
          (breadcrumbs['distance_filter_inside_m'] ?? 10) as int,
      distanceFilterNearM: (breadcrumbs['distance_filter_near_m'] ?? 20) as int,
      distanceFilterOutsideM:
          (breadcrumbs['distance_filter_outside_m'] ?? 100) as int,
      startOnBoot: (platform['start_on_boot'] ?? true) as bool,
      stopOnTerminate: (platform['stop_on_terminate'] ?? false) as bool,
      useSignificantChangeWhenOutside:
          (platform['use_significant_change_outside'] ?? true) as bool,
      significantChangeOutsideThresholdS:
          (platform['significant_change_outside_threshold_s'] ?? 300) as int,
      stopTimeoutMinutes: 15, // TEMP: hardcoded; restore: (platform['stop_timeout_minutes'] ?? 60) as int
      batchSync: (platform['batch_sync'] ?? true) as bool,
      maxBatchSize: (platform['max_batch_size'] ?? 8) as int,
      autoSyncThreshold: 10, // TEMP: hardcoded; restore: (platform['auto_sync_threshold'] ?? 0) as int
      // Geofence-only mode — default false so existing builds are unaffected
      geofenceOnlyMode: (platform['geofence_only_mode'] ?? false) as bool,
      // preventSuspend kill switch — default true so existing behavior is preserved
      preventSuspendInsideZone:
          (platform['prevent_suspend_inside_zone'] ?? true) as bool,

      // API key sourced from Firestore — null if field absent
      ingestApiKey: r['ingest_api_key'] as String?,

      // Near-zone radius for outer geofences
      nearZoneRadiusM: (geoDetect['near_zone_radius_m'] ?? 100) as int,
    );
  }
}
