// lib/custom_code/geo_bootstrap.dart
// bootstrap orchestrator. reads appconfig/runtime and geofences from firestore
// to build a runtime config, configures geofence engine and writes data to firestore
// also streams for bluetooth system. updated 2/23/26. Most recent backup in firestore_export/_backup and in github backup

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'package:zbg_location/zbg_location.dart'; // barrel (api, engine, writers, geohash, etc.)
import 'package:zbg_proximity/zbg_proximity.dart'; // for ZoneState
import '/custom_code/zbg_firestore_adapter.dart'; // your shared WriteFn adapter
import '/custom_code/geo_fcm_handler.dart'; // FCM handler + background fetch headless task
import 'package:flutter/widgets.dart';

class GeoBootstrap with WidgetsBindingObserver {
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
  String? _regionId;
  bool _lifecycleObserverRegistered = false;

  static List<String> _expectedNativeGeofenceIds(List<GeofenceDef> defs) {
    final ids = <String>[];
    for (final d in defs) {
      ids
        ..add(d.ident)
        ..add('${d.ident}_near');
    }
    ids.sort();
    return ids;
  }

  // Broadcasts zone state changes to any subscriber (e.g. BtBootstrap).
  // Purely in-memory — no network involved.
  final _zoneCtl = StreamController<ZoneState>.broadcast();
  Stream<ZoneState> get onZoneChange => _zoneCtl.stream;

  Future<void> startFromFirestore(String regionId) async {
    if (_starting) return;
    _starting = true;
    try {
      await _startFromFirestoreInner(regionId);
    } catch (e) {
      // Change D: cancel any subscriptions opened during the failed bootstrap
      // so they don't fire as orphaned listeners after the error.
      _configSub?.cancel();
      _configSub = null;
      _fenceSub?.cancel();
      _geofenceSub?.cancel();
      _geofenceSub = null;
      await _locSub?.cancel();
      _uid = null;
      _regionId = null;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> _startFromFirestoreInner(String regionId) async {
    final fs = FirebaseFirestore.instance;
    await fbg.Logger.notice(
      'SPARRC geofence_bootstrap start regionId=$regionId',
    );

    // ----- 0) Get user + set identity FIRST -----
    // NOTE: _uid is intentionally NOT set here. It is set only at step 7 after
    // full successful startup, so isRunning accurately reflects engine state.
    // _regionId is set early so the lifecycle observer and forcewake methods
    // have region context even when bootstrap fails before step 7.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('geo:no_user');
    _regionId = regionId;

    // Tell the engine who we are + what region we're in
    _engine.setIdentity(uid: uid, regionId: regionId);

    // Pre-flight: stop native FBG if it is already running from a prior Dart
    // session (_uid == null means this session never completed a bootstrap).
    // Gives start() in step 6 a clean slate. TsbgEngine.start() (Change A) is
    // the safety net if this stop fails or races.
    try {
      final state = await fbg.BackgroundGeolocation.state;
      if (state.enabled && _uid == null) {
        await fbg.Logger.notice(
          'SPARRC geo_preflight_stop native_running_no_dart_session',
        );
        await fbg.BackgroundGeolocation.stop();
      }
    } catch (e) {
      await fbg.Logger.notice(
        'SPARRC geo_preflight_stop_failed error=${e.runtimeType} — continuing',
      );
    }

    // ----- 0b) Register background wakeup handlers -----
    // FCM silent-push handler: invoked by firebase_messaging when a
    // data-only 'geo_wakeup' message arrives (backgrounded/OS-terminated, not
    // force-quit). Idempotent — safe to call on every startFromFirestore.
    FirebaseMessaging.onBackgroundMessage(
      geoFirebaseMessagingBackgroundHandler,
    );

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
          geoBackgroundFetchHeadlessTask,
        );
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          fatal: false,
          reason: 'background_fetch_configure_failed',
        );
        throw StateError('geo:background_fetch_failed');
      }
    }

    // FBG Android geofence headless task: invoked by FBG's native service when
    // a geofence event fires in terminated state. Handles event writes and
    // re-arms Android's Geofencing API on EXIT. Android-only — on iOS,
    // CLRegionMonitoring re-arms automatically and BackgroundFetch handles wakeups.
    if (Platform.isAndroid) {
      try {
        await fbg.Logger.notice(
          'SPARRC headless_task_register_start source=geo_bootstrap',
        );
        await fbg.BackgroundGeolocation.registerHeadlessTask(
          geoFbgHeadlessTask,
        );
        await fbg.Logger.notice(
          'SPARRC headless_task_registered source=geo_bootstrap',
        );
      } catch (e, st) {
        try {
          await fbg.Logger.notice(
            'SPARRC headless_task_registration_failed error=${e.runtimeType}',
          );
        } catch (_) {}
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          fatal: false,
          reason: 'headless_task_registration_failed',
        );
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
            configReady.completeError(
              StateError('geo:missing_runtime_config'),
            );
          return;
        }
        RuntimeConfig cfg;
        try {
          cfg = _buildRuntimeConfig(snap.data()! as Map<String, dynamic>);
        } catch (e, st) {
          FirebaseCrashlytics.instance.recordError(
            e,
            st,
            fatal: false,
            reason: 'runtime_config_parse_failed',
          );
          if (!configReady.isCompleted)
            configReady.completeError(
              StateError('geo:config_parse_failed'),
            );
          return;
        }
        final rawData = snap.data()! as Map<String, dynamic>;
        final fut = _engine.setConfig(cfg);
        if (!configReady.isCompleted) {
          fut.then((_) {
            configReady.complete();
            _persistConfigCache(rawData);
          }).catchError((
            Object e,
            StackTrace st,
          ) {
            FirebaseCrashlytics.instance.recordError(
              e,
              st,
              fatal: false,
              reason: 'fbg_init_failed',
            );
            if (!configReady.isCompleted)
              configReady.completeError(StateError('geo:fbg_init_failed'));
          });
        } else {
          fut
              .then((_) => _persistConfigCache(rawData))
              .catchError((Object e, StackTrace st) {
            FirebaseCrashlytics.instance.recordError(
              e,
              st,
              fatal: false,
              reason: 'live_config_update_failed',
            );
          });
        }
      },
      onError: (e) {
        if (!configReady.isCompleted)
          configReady.completeError(StateError('geo:config_load_failed'));
      },
    );
    try {
      await configReady.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      final cached = await _loadCachedRuntimeConfig();
      if (cached != null) {
        await fbg.Logger.notice(
          'SPARRC geo_config_timeout_fallback using_sqlite_cache',
        );
        final cfg = _buildRuntimeConfig(cached);
        await _engine.setConfig(cfg);
      } else {
        throw StateError('geo:config_timeout');
      }
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
        'fence ${e.type.name} zone=${e.fenceId}${e.dwellSeconds != null ? ' dwell=${e.dwellSeconds}s' : ''}',
      );
      FirebaseCrashlytics.instance.setCustomKey(
        'last_fence_event',
        e.type.name,
      );
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
      await _engine.setZoneContext(zoneId: _currentZoneId, insideZone: _inside);

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
        final expectedNativeIds = _expectedNativeGeofenceIds(defs);
        await fbg.Logger.notice(
          'SPARRC geofence_bootstrap firestore_snapshot '
          'docs=${snap.docs.length} defs=${defs.length} '
          'expected_native=${expectedNativeIds.length} '
          'ids=${expectedNativeIds.join(',')}',
        );
        if (defs.isNotEmpty) {
          await fbg.Logger.notice(
            'SPARRC geofence_bootstrap add_geofences count=${defs.length} '
            'expected_native=${expectedNativeIds.length}',
          );
          await _engine.addGeofences(defs);
          await _engine.logNativeGeofenceInventory('bootstrap_after_add');
        }
        if (!geofencesReady.isCompleted) geofencesReady.complete();
      },
      onError: (e) {
        if (!geofencesReady.isCompleted)
          geofencesReady.completeError(
            StateError('geo:geofences_load_failed'),
          );
      },
    );
    try {
      await geofencesReady.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      // Before aborting, check if FBG already has geofences registered natively
      // (e.g. restored by ready() from a prior session's persisted state).
      // If so, proceed — _geofenceSub stays alive and will re-register with
      // fresh Firestore defs when connectivity recovers.
      try {
        final existing = await fbg.BackgroundGeolocation.geofences;
        if (existing.isNotEmpty) {
          await fbg.Logger.notice(
            'SPARRC geo_geofences_timeout_fallback '
            'using_native_count=${existing.length}',
          );
        } else {
          throw StateError('geo:geofences_timeout');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError('geo:geofences_timeout');
      }
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
        extra: {
          'source_dart': 'bg',
          'mode': _engine.geoSystemMode,
          if (s.activityType != null) 'activity_type': s.activityType,
          if (s.activityConfidence != null) 'activity_confidence': s.activityConfidence,
          if (s.fbgIsMoving != null) 'fbg_is_moving': s.fbgIsMoving,
          if (s.fbgEvent != null) 'fbg_event': s.fbgEvent,
        },
        fixedId: '${uid}_$tsIso',
      );
    });

    // ----- 6) Start engine -----
    try {
      await _engine.start();
      await _engine.logNativeGeofenceInventory('bootstrap_after_start');
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'engine_start_failed',
      );
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
      await _engine.logNativeGeofenceInventory('bootstrap_after_synthesize');
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'synthesize_enter_failed',
      );
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
    const kStep7MaxAttempts = 3;
    for (var attempt = 1; attempt <= kStep7MaxAttempts; attempt++) {
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
        await fbg.Logger.notice(
          'SPARRC geo_bootstrap step7_ok attempt=$attempt',
        );
        break;
      } catch (e, st) {
        if (attempt == kStep7MaxAttempts) {
          FirebaseCrashlytics.instance.recordError(
            e,
            st,
            fatal: false,
            reason: 'session_doc_start_write_failed_all_attempts',
          );
          throw StateError('geo:user_doc_write_failed');
        }
        await fbg.Logger.notice(
          'SPARRC geo_bootstrap step7_retry attempt=$attempt '
          'error=${e.runtimeType}',
        );
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
    }
  }

  Future<void> stop() async {
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    _regionId = null;
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
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'engine_stop_failed',
      );
      errorCode = 'geo:stop_engine_failed';
    }

    _currentZoneId = null;
    _inside = false;
    _zoneCtl.add(ZoneState.outside);

    // Mark geo as stopped so geoWakeupSweep no longer targets this user.
    if (_uid != null) {
      try {
        await Future.wait([
          FirebaseFirestore.instance.doc('geoSessions/$_uid').set({
            'geo_running': false,
            'geo_session_stopped': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)),
          FirebaseFirestore.instance.doc('users/$_uid').set({
            'geo_running': false,
          }, SetOptions(merge: true)),
        ]);
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          fatal: false,
          reason: 'session_doc_stop_write_failed',
        );
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

  /// Applies a pre-fetched appConfig/runtime data map to the FBG engine even
  /// when isRunning=false. When isRunning=true, delegates to refreshConfigFromMap.
  /// When isRunning=false, checks state.enabled and calls _engine.setConfig
  /// directly if FBG is running natively from a prior session.
  Future<String> refreshConfigFromMapForced(Map<String, dynamic> data) async {
    if (isRunning) {
      await refreshConfigFromMap(data);
      return 'ok';
    }
    try {
      final state = await fbg.BackgroundGeolocation.state;
      if (!state.enabled) return 'skipped:fbg_not_enabled';

      // Re-establish identity before calling setConfig. Without this, httpParams
      // is built with only {mode:...} because _uid/_regionId are null after a
      // force-kill + Dart restart. Calling setConfig without uid overwrites
      // http.params and persistence.extras on the native plugin, causing all
      // subsequent uploads to fail with "Missing uid".
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      final regionId = _regionId;
      if (currentUid == null || regionId == null) {
        await fbg.Logger.notice(
          'SPARRC geo_refresh_config_forced skipped'
          ' uid_null=${currentUid == null} region_null=${regionId == null}',
        );
        return 'skipped:no_identity';
      }
      _engine.setIdentity(uid: currentUid, regionId: regionId);

      await fbg.Logger.notice('SPARRC geo_refresh_config_forced start');
      final cfg = _buildRuntimeConfig(data);
      await _engine.setConfig(cfg);
      await fbg.Logger.notice('SPARRC geo_refresh_config_forced done');
      return 'ok_forced';
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e, st, fatal: false, reason: 'geo_refresh_config_forced_failed',
      );
      return 'error:${e.runtimeType}';
    }
  }

  /// Applies a pre-fetched appConfig/runtime Firestore data map to the
  /// running FBG engine. No-ops if geo is not running.
  ///
  /// Use this when the caller has already fetched the doc (e.g., the
  /// applyAppConfigRuntime custom action) to avoid a second Firestore read.
  Future<void> refreshConfigFromMap(Map<String, dynamic> data) async {
    if (!isRunning) return;
    await fbg.Logger.notice('SPARRC geo_refresh_config_from_map start');
    try {
      final cfg = _buildRuntimeConfig(data);
      await _engine.setConfig(cfg);
      await fbg.Logger.notice('SPARRC geo_refresh_config_from_map done');
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC geo_refresh_config_from_map error error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'geo_refresh_config_failed',
      );
    }
  }

  /// One-shot Firestore fetch of appConfig/runtime → applies RuntimeConfig
  /// to the running FBG engine. No-ops if geo is not running.
  ///
  /// Complements [_configSub] as a reliable forced-refresh path when the
  /// listener dies in the background. Called by the applyAppConfigRuntime
  /// custom action on every homepage open (with a 1h SQLite cooldown).
  Future<void> refreshConfigFromFirestore() async {
    if (!isRunning) {
      await fbg.Logger.notice(
        'SPARRC geo_refresh_config skipped reason=not_running',
      );
      return;
    }
    await fbg.Logger.notice('SPARRC geo_refresh_config start');
    try {
      final snap =
          await FirebaseFirestore.instance.doc('appConfig/runtime').get();
      if (!snap.exists) {
        await fbg.Logger.notice(
          'SPARRC geo_refresh_config skipped reason=doc_missing',
        );
        return;
      }
      await refreshConfigFromMap(snap.data()!);
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC geo_refresh_config error error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'geo_refresh_config_failed',
      );
    }
  }

  Future<String> forceMovingPace({String source = 'foreground'}) {
    return _engine.forceMovingPace(source: source);
  }

  /// Fires on every app foreground (AppLifecycleState.resumed).
  /// Triggers a lightweight geofence sync so newly-added Firestore fences
  /// are picked up even when the real-time listener died with the isolate.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final regionId = _regionId;
    if (regionId == null) return;
    refreshGeofencesFromFirestore(regionId);
  }

  /// One-shot Firestore fetch of the geofences collection, then diffs against
  /// what FBG currently has registered. Does NOT restart listeners or re-init
  /// any other engine state — safe to call from foreground, FCM handler, or
  /// any path that needs to pick up newly-added Firestore fences.
  Future<void> refreshGeofencesFromFirestore(String regionId) async {
    if (!isRunning) {
      // Bootstrap failed but FBG may still be running natively from a prior
      // session. Register geofences directly if state.enabled is true.
      try {
        final state = await fbg.BackgroundGeolocation.state;
        if (!state.enabled) {
          await fbg.Logger.notice(
            'SPARRC geo_refresh_geofences skipped reason=not_running_fbg_disabled',
          );
          return;
        }
        await fbg.Logger.notice(
          'SPARRC geo_refresh_geofences fallback_start regionId=$regionId',
        );
        final snap = await FirebaseFirestore.instance
            .collection('regions/$regionId/geofences')
            .get();
        final defs = _parseGeofenceDocs(snap.docs);
        await _engine.addGeofences(defs);
        await fbg.Logger.notice(
          'SPARRC geo_refresh_geofences fallback_done defs=${defs.length}',
        );
      } catch (e, st) {
        await fbg.Logger.notice(
          'SPARRC geo_refresh_geofences fallback_error error=${e.runtimeType}',
        );
        FirebaseCrashlytics.instance.recordError(
          e, st, fatal: false, reason: 'geo_refresh_geofences_fallback_failed',
        );
      }
      return;
    }
    await fbg.Logger.notice(
      'SPARRC geo_refresh_geofences start regionId=$regionId',
    );
    try {
      final snap = await FirebaseFirestore.instance
          .collection('regions/$regionId/geofences')
          .get();
      final defs = _parseGeofenceDocs(snap.docs);
      await _engine.addGeofences(defs);
      await fbg.Logger.notice(
        'SPARRC geo_refresh_geofences done defs=${defs.length}',
      );
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC geo_refresh_geofences error error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'geo_refresh_geofences_failed',
      );
    }
  }

  /// Parses a geofences collection snapshot into GeofenceDef list.
  /// Called on every emission of the geofence listener.
  List<GeofenceDef> _parseGeofenceDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
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
          defs.add(
            GeofenceDef(
              ident: d.id,
              type: 'circle',
              lat: lat,
              lng: lng,
              radiusM: radiusM,
            ),
          );
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
      rateOutsideS: (breadcrumbs['rate_outside_zone_s'] ?? 120) as int,
      rateNearS: (breadcrumbs['rate_near_zone_s'] ?? 90) as int,
      rateInsideS: (breadcrumbs['rate_inside_zone_s'] ?? 60) as int,
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
      stopTimeoutMinutes: (platform['stop_timeout_minutes'] ?? 60) as int,
      batchSync: (platform['batch_sync'] ?? true) as bool,
      maxBatchSize: (platform['max_batch_size'] ?? 8) as int,
      autoSyncThreshold: (platform['auto_sync_threshold'] ?? 0) as int,
      // Geofence-only mode — default false so existing builds are unaffected
      geofenceOnlyMode: (platform['geofence_only_mode'] ?? false) as bool,
      // preventSuspend kill switch — default true so existing behavior is preserved
      preventSuspendInsideZone:
          (platform['prevent_suspend_inside_zone'] ?? true) as bool,

      // API key sourced from Firestore — null if field absent
      ingestApiKey: r['ingest_api_key'] as String?,

      // Near-zone radius for outer geofences
      nearZoneRadiusM: (geoDetect['near_zone_radius_m'] ?? 100) as int,

      // Disable stop detection — controlled globally via Firestore; default false
      disableStopDetection:
          (platform['disable_stop_detection'] ?? false) as bool,
    );
  }

  static const _configCacheKey = 'geo_runtime_config_cache_json';

  Future<void> _persistConfigCache(Map<String, dynamic> data) async {
    try {
      final db = await _openKvDb();
      await db.insert(
        'kv_store',
        {'key': _configCacheKey, 'value': jsonEncode(data)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.close();
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _loadCachedRuntimeConfig() async {
    try {
      final db = await _openKvDb();
      final rows = await db.query(
        'kv_store',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [_configCacheKey],
        limit: 1,
      );
      await db.close();
      if (rows.isEmpty) return null;
      final raw = rows.first['value'] as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Database> _openKvDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      path_helper.join(dbPath, 'sparrc_offline.db'),
      version: 1,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }
}
