// zbg_location/lib/tsbg_engine.dart
// DROP-IN REPLACEMENT — applies hybrid significant-change rule,
// per-mode distance filters, SDK timestamps, and dwell alignment.
// Updated to implement "whatever's first" emission rule (distance OR time)
// and native HTTP uploads to Cloud Function (zbgIngest).

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'api.dart'; // RuntimeConfig, SamplingMode, GeofenceDef, GeofenceEvent, LocationSample
import 'geo_diagnostics_writer.dart';
import 'utils.dart'; // haversineMeters

// Native HTTP upload config for background ingestion.
const String _zbgIngestUrl =
    'https://us-central1-religion-and-cooperation.cloudfunctions.net/zbgIngest';

class TsbgEngine {
  TsbgEngine();

  /// Current effective runtime config (from Firestore via app layer).
  RuntimeConfig? _cfg;

  /// Track current sampling mode (outside by default).
  SamplingMode _mode = SamplingMode.outside;

  /// Keep geofence defs for optional "near" detection on location callbacks.
  final List<GeofenceDef> _defs = [];

  /// Streams exposed to app layer
  final _locCtl = StreamController<LocationSample>.broadcast();
  final _fenceCtl = StreamController<GeofenceEvent>.broadcast();

  bool _listenersAttached = false;
  bool _ready = false;
  bool _started = false;

  Timer? _exitHysteresisTimer;

  /// Dwell milestone tracking
  DateTime? _enteredAt;
  String? _enteredFenceId;
  final Set<int> _firedMilestones = {};

  // Near-zone tracking (Fix 2)
  final Set<String> _activeNearFences = {};

  // Inside-mode position reconciliation counter (Fix 3b)
  int _insideFixCount = 0;
  String? _insideFixFenceId;

  /// "Whatever's first" bookkeeping
  DateTime? _lastEmitUtc;
  double? _lastEmitLat;
  double? _lastEmitLng;
  DateTime? _lastHeartbeatWatchdogUtc;

  static const Duration _heartbeatWatchdogInterval = Duration(minutes: 2);
  static const Duration _heartbeatWatchdogStaleAfter = Duration(minutes: 2);
  static const int _heartbeatWatchdogTimeoutS = 30;
  static const double _heartbeatWatchdogMovedM = 60;
  static const Duration _nearEnterForceWakeCooldown = Duration(minutes: 10);
  static const Duration _nearEnterForceWakeStaleAfter = Duration(minutes: 5);
  static const int _nearEnterForceWakeTimeoutS = 20;
  static const double _nearEnterForceWakeMovedM = 60;

  // Identity for native HTTP uploads → Cloud Function.
  String? _uid;
  String? _regionId;

  /// Called by app layer before setConfig/start to tag native HTTP uploads
  /// with the signed-in user and active region.
  void setIdentity({required String uid, required String regionId}) {
    _uid = uid;
    _regionId = regionId;
    unawaited(GeoDiagnosticsWriter.storeIdentity(uid: uid, regionId: regionId));
  }

  /// --------------------------------------------
  /// Public API
  /// --------------------------------------------

  static List<String> _nativeIdsForDefs(Iterable<GeofenceDef> defs) {
    final ids = <String>[];
    for (final d in defs) {
      ids
        ..add(d.ident)
        ..add('${d.ident}_near');
    }
    ids.sort();
    return ids;
  }

  static String _formatIds(Iterable<String> ids) => ids.join(',');

  Future<List<String>> nativeGeofenceIds() async {
    final geofences = await fbg.BackgroundGeolocation.geofences;
    final ids = geofences.map((g) => g.identifier).whereType<String>().toList()
      ..sort();
    return ids;
  }

  Future<void> logNativeGeofenceInventory(String source) async {
    try {
      final ids = await nativeGeofenceIds();
      await fbg.Logger.notice(
        'SPARRC geofence_inventory source=$source native_count=${ids.length} '
        'ids=${_formatIds(ids)}',
      );
    } catch (e, st) {
      try {
        await fbg.Logger.notice(
          'SPARRC geofence_inventory_failed source=$source '
          'error=${e.runtimeType}',
        );
      } catch (_) {}
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'geofence_inventory_failed',
      );
    }
  }

  Future<void> setConfig(RuntimeConfig cfg) async {
    _cfg = cfg;
    await fbg.Logger.notice(
      'SPARRC engine_set_config start ready=$_ready '
      'listeners_attached=$_listenersAttached started=$_started',
    );

    // Snapshot identity for HTTP params at config-time.
    final uid = _uid;
    final regionId = _regionId;

    final httpParams = <String, dynamic>{};
    if (uid != null) httpParams['uid'] = uid;
    if (regionId != null) httpParams['regionId'] = regionId;
    httpParams['mode'] = geoSystemMode;

    if (kDebugMode) {
      debugPrint(
        '[TsbgEngine] HTTP params at setConfig: uid=$uid regionId=$regionId httpParams=$httpParams',
      );
    }

    // One-time BG Geolocation init
    // Attach listeners before ready() so events fired during init are not missed.
    // _listenersAttached ensures this only happens once — FBG listener registration
    // is additive and calling onGeofence/onLocation twice stacks duplicate handlers.
    if (!_listenersAttached) {
      await fbg.Logger.notice('SPARRC engine_attach_listeners start');
      _attachListeners();
      _listenersAttached = true;
      await fbg.Logger.notice(
        'SPARRC engine_attach_listeners registered '
        'onLocation/onMotionChange/onHeartbeat/onGeofence',
      );
    }

    try {
      await fbg.BackgroundGeolocation.ready(
        fbg.Config(
          // reset and foregroundService remain on Config (not deprecated in v5)
          reset: !_ready,
          foregroundService: true,

          geolocation: fbg.GeoConfig(
            desiredAccuracy: fbg.DesiredAccuracy.high,
            // Allow FBG to scale distanceFilter with speed (elasticity).
            // At rest/walking: baseline distanceFilter applies. At speed: FBG
            // multiplies it proportionally, reducing GPS polling when moving fast.
            // distanceFilter per mode is the minimum floor — never scaled below it.
            disableElasticity: false,
            // Configurable from Firestore — how long before FBG stops GPS after no motion.
            stopTimeout: cfg.stopTimeoutMinutes,
            // iOS: prevent CoreLocation from pausing updates on stationary devices.
            pausesLocationUpdatesAutomatically: false,
            // iOS: declare walking/non-automotive movement so CoreLocation applies
            // less aggressive power management in background. FBG silently ignores
            // this on Android — no platform guard needed.
            activityType: fbg.ActivityType.otherNavigation,
            // Minimum distance device must move from stationary position before
            // FBG transitions to moving state. 25 is FBG's enforced minimum.
            // iOS applies its own ~200m floor in terminated state regardless.
            stationaryRadius: 25,
            // Fire ENTER immediately if device is already inside a fence when
            // geofences are registered. Complements synthesizeEnterIfInside()
            // with a native-layer check that requires no GPS fetch.
            geofenceInitialTriggerEntry: true,
            // Android-only per FBG docs — enables active GPS for geofence EXIT
            // detection. Has no effect on iOS (CLRegionMonitoring handles that).
            geofenceModeHighAccuracy: Platform.isAndroid,
            // iOS: request Always authorisation explicitly and provide all required
            // dialog keys so FBG can render the upgrade prompt on iOS 13+.
            // Without the full key set, FBG cannot show the Settings shortcut for
            // users who previously denied or downgraded permission.
            locationAuthorizationRequest: 'Always',
            locationAuthorizationAlert: {
              'titleWhenNotEnabled': 'Location services disabled',
              'titleWhenInUse': 'Background location required',
              'instructions':
                  'SPARRC uses location to detect entry and exit from study locations. Please enable Always Allow.',
              'cancelButton': 'Cancel',
              'settingsButton': 'Settings',
            },
          ),

          app: fbg.AppConfig(
            startOnBoot: cfg.startOnBoot,
            stopOnTerminate: cfg.stopOnTerminate,
            // Android: required to invoke geoFbgHeadlessTask in terminated state.
            // Always pair with stopOnTerminate: false per FBG docs.
            enableHeadless: true,
            // iOS: periodically invalidate/recreate CLLocationManager via the
            // background task API to prevent iOS from suspending the process
            // between GPS wakeups. Closes most remaining background data gaps.
            preventSuspend: true,
            // Suppress heads-up banner and status bar icon on Android.
            // The notification still appears in the shade (OS requirement for
            // foreground services) but is otherwise invisible during normal use.
            notification: fbg.Notification(
              title: 'Location Detection',
              text: 'SPARRC is tracking device location changes',
              smallIcon: 'drawable/ic_stat_ic_launcher_foreground',
              priority: fbg.NotificationPriority.min,
              sticky: false,
            ),
            // Android: rationale shown when upgrading to Always Allow permission.
            backgroundPermissionRationale: fbg.PermissionRationale(
              message:
                  'SPARRC uses location to log entry and exit from study locations and to log participation events.',
            ),
          ),

          http: fbg.HttpConfig(
            // Native HTTP → Cloud Function (background-safe).
            url: _zbgIngestUrl,
            headers: {
              'X-Api-Key': cfg.ingestApiKey ??
                  (throw StateError(
                    'ingestApiKey is null — add ingest_api_key to appConfig/runtime',
                  )),
            },
            // Sent with every request (query/body-level params)
            params: httpParams,
            autoSync: true,
            batchSync: cfg.batchSync,
            maxBatchSize: cfg.maxBatchSize,
            autoSyncThreshold: cfg.autoSyncThreshold,
            // NOTE: no rootProperty here; defaults to 'location'
            // 25s timeout fits within iOS SLC / background-fetch wakeup windows
            // (~30s), giving FBG the best chance of completing a POST before iOS
            // reclaims the process. Default of 60s exceeds the wakeup window.
            timeout: 25000,
          ),

          persistence: fbg.PersistenceConfig(
            // Sent with each recorded location/geofence as .extras
            extras: httpParams,
            // Keep unsynced SQLite records for 30 days so locations accumulated
            // during extended offline periods are still recoverable on next open.
            maxDaysToPersist: 30,
          ),

          activity: fbg.ActivityConfig(
            // Allow FBG to enter low-power stationary mode when the device stops
            // moving. The heartbeat handles breadcrumb emission while stationary;
            // the accelerometer wakes FBG when motion resumes. Keeping this true
            // burns maximum battery and causes iOS to throttle/kill the process.
            disableStopDetection: false,
          ),

          logger: fbg.LoggerConfig(debug: false),
        ),
      );
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'fbg_ready_failed',
      );
      rethrow;
    }

    // Only mark ready after success — if ready() threw, _ready stays false
    // so the next start attempt retries with reset: true.
    _ready = true;
    await fbg.Logger.notice('SPARRC engine_ready_success');

    FirebaseCrashlytics.instance.setCustomKey(
      'geofence_only_mode',
      cfg.geofenceOnlyMode.toString(),
    );
    FirebaseCrashlytics.instance.setCustomKey(
      'auto_sync_threshold',
      cfg.autoSyncThreshold,
    );
    FirebaseCrashlytics.instance.setCustomKey(
      'batch_sync',
      cfg.batchSync.toString(),
    );
    FirebaseCrashlytics.instance.setCustomKey(
      'prevent_suspend_inside',
      cfg.preventSuspendInsideZone.toString(),
    );

    // Fix 1: Explicitly clear any stale persistence.extras from a previous session.
    // ready() with reset:false silently ignores extras changes; direct setConfig() always applies.
    // autoSyncThreshold is also applied here so live Firestore config changes propagate
    // to the running engine (ready() with reset:false does not re-apply these).
    try {
      await fbg.BackgroundGeolocation.setConfig(
        fbg.Config(
          autoSyncThreshold: cfg.autoSyncThreshold,
          persistence: fbg.PersistenceConfig(extras: httpParams),
        ),
      );
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'fbg_setconfig_failed',
      );
    }

    // Apply the current mode’s config (outside by default).
    await fbg.Logger.notice(
      'SPARRC engine_set_config applying_mode=${_mode.name}',
    );
    await _applyMode(_mode);
    await fbg.Logger.notice(
      'SPARRC engine_set_config complete mode=${_mode.name}',
    );
  }

  Future<void> addGeofences(List<GeofenceDef> defs) async {
    try {
      // Diff incoming defs against current _defs so we only add/remove what
      // actually changed. Calling removeGeofences() on every update tears down
      // CLRegionMonitoring entirely on iOS, creating a blind window where
      // crossings are missed until re-registration completes.
      final incoming = <String, GeofenceDef>{
        for (final d in defs)
          if (d.type == 'circle' &&
              d.lat != null &&
              d.lng != null &&
              d.radiusM != null)
            d.ident: d,
      };
      final current = <String, GeofenceDef>{for (final d in _defs) d.ident: d};
      final expectedNativeIds = _nativeIdsForDefs(incoming.values);
      var removedNativeCount = 0;
      var addedNativeCount = 0;

      await fbg.Logger.notice(
        'SPARRC geofence_engine add_geofences start defs=${defs.length} '
        'valid_defs=${incoming.length} expected_native=${expectedNativeIds.length} '
        'ids=${_formatIds(expectedNativeIds)}',
      );

      // Remove fences that are no longer in the incoming list (inner + outer near-zone)
      for (final ident in current.keys) {
        if (!incoming.containsKey(ident)) {
          await fbg.BackgroundGeolocation.removeGeofence(ident);
          await fbg.BackgroundGeolocation.removeGeofence('${ident}_near');
          removedNativeCount += 2;
        }
      }

      // Add fences that are new or whose geometry has changed
      for (final d in incoming.values) {
        final existing = current[d.ident];
        final changed = existing == null ||
            existing.lat != d.lat ||
            existing.lng != d.lng ||
            existing.radiusM != d.radiusM;
        if (changed) {
          await fbg.BackgroundGeolocation.addGeofence(
            fbg.Geofence(
              identifier: d.ident,
              latitude: d.lat!,
              longitude: d.lng!,
              radius: d.radiusM!,
              notifyOnEntry: true,
              notifyOnExit: true,
              notifyOnDwell: true,
              loiteringDelay: (_cfg?.dwellRequiredS ?? 60) * 1000,
            ),
          );
          final nearRadiusM = (_cfg?.nearZoneRadiusM ?? 100).toDouble();
          await fbg.BackgroundGeolocation.addGeofence(
            fbg.Geofence(
              identifier: '${d.ident}_near',
              latitude: d.lat!,
              longitude: d.lng!,
              radius: d.radiusM! + nearRadiusM,
              notifyOnEntry: true,
              notifyOnExit: true,
              notifyOnDwell: false,
              loiteringDelay: 0,
            ),
          );
          addedNativeCount += 2;
        }
      }

      _defs
        ..clear()
        ..addAll(defs);
      FirebaseCrashlytics.instance.setCustomKey('fence_count', _defs.length);
      await fbg.Logger.notice(
        'SPARRC geofence_engine add_geofences result removed_native=$removedNativeCount '
        'added_native=$addedNativeCount cached_defs=${_defs.length}',
      );
      await logNativeGeofenceInventory('engine_after_add');
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'geofence_registration_failed',
      );
      rethrow;
    }
  }

  Future<void> start() async {
    if (_started) {
      // Guard against _started drifting out of sync with the native layer
      // (e.g. after a failed stop or process restart). If FBG reports it is
      // not actually running, reset our flag and proceed with a real start.
      final state = await fbg.BackgroundGeolocation.state;
      if (state.enabled) return;
      _started = false;
    }
    try {
      if (_cfg?.geofenceOnlyMode == true) {
        await fbg.BackgroundGeolocation.startGeofences();
      } else {
        await fbg.BackgroundGeolocation.start();
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'fbg_start_failed',
      );
      rethrow;
    }
    _started = true;

    // Startup diagnostics — silent; must not block normal startup path.
    try {
      final state = await fbg.BackgroundGeolocation.state;
      if (!state.enabled) {
        FirebaseCrashlytics.instance.recordError(
          StateError('fbg_not_enabled_after_start'),
          StackTrace.current,
          fatal: false,
        );
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_started) return;
    _exitHysteresisTimer?.cancel();
    _exitHysteresisTimer = null;
    try {
      await fbg.BackgroundGeolocation.stop();
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'fbg_stop_failed',
      );
      rethrow;
    } finally {
      // Always clear all state — even if the native stop() threw — so a
      // subsequent start() call is not blocked by a stale _started flag.
      _started = false;
      // Reset dwell state so a subsequent session (e.g. sign-out/sign-in or
      // user switch) starts clean. Without this, stale _enteredAt /
      // _enteredFenceId from the previous user would immediately fire spurious
      // dwell milestones.
      _enteredAt = null;
      _enteredFenceId = null;
      _firedMilestones.clear();
      _activeNearFences.clear();
      _insideFixCount = 0;
      _insideFixFenceId = null;
      _mode = SamplingMode.outside;
      _lastEmitUtc = null;
      _lastEmitLat = null;
      _lastEmitLng = null;
    }
  }

  /// Check current GPS position and emit a synthetic ENTER if the device is
  /// already inside a registered geofence but _enteredAt is not set.
  ///
  /// Call this from GeoBootstrap after engine.start() with _fenceSub attached.
  /// Catches the race where FBG fires an ENTER during addGeofences() (step 2)
  /// before the broadcast stream listener is attached (step 4), causing the
  /// event to be silently dropped.
  Future<void> synthesizeEnterIfInside() async {
    if (!_ready || _enteredFenceId != null || _defs.isEmpty) return;
    try {
      final loc = await fbg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        persist: false,
        timeout: 10,
      );
      final lat = loc.coords.latitude;
      final lng = loc.coords.longitude;
      for (final def in _defs) {
        if (def.type != 'circle' ||
            def.lat == null ||
            def.lng == null ||
            def.radiusM == null) {
          continue;
        }
        final dist = haversineMeters(lat, lng, def.lat!, def.lng!);
        if (dist <= def.radiusM!) {
          final ts = DateTime.now().toUtc();
          _enteredAt = ts;
          _enteredFenceId = def.ident;
          _firedMilestones.clear();
          _fenceCtl.add(GeofenceEvent(def.ident, GeofenceEventType.enter, ts));
          await _applyMode(SamplingMode.inside);
          if (kDebugMode) {
            debugPrint(
              '[TsbgEngine] synthesizeEnterIfInside: inside ${def.ident} '
              '(${dist.toStringAsFixed(1)}m <= ${def.radiusM}m)',
            );
          }
          break; // only one zone active at a time
        }
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'synthesize_enter_gps_unavailable',
      );
    }
  }

  /// Flush any locations accumulated in FBG's SQLite buffer (e.g. from
  /// terminated-state significant-change wakeups) by forcing an immediate
  /// sync POST to zbgingest. Safe to call before start() — no-ops if not ready.
  Future<void> flushBuffer() async {
    if (!_ready) return;
    await fbg.BackgroundGeolocation.sync();
  }

  /// Force FBG into moving pace without re-running ready/start/geofence setup.
  ///
  /// Used by the foreground heartbeat watchdog when it has evidence that the
  /// device moved while FBG still appears passive/stationary.
  Future<String> forceMovingPace({String source = 'foreground'}) async {
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
        FirebaseCrashlytics.instance.log(
          'force_moving_pace_skipped: already_moving $source',
        );
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_skip_reason',
          'already_moving',
        );
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_source',
          source,
        );
        return 'already_moving';
      }
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC force_pace state_unreadable source=$source '
        '${_describeForcePaceError(e)}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'force_moving_pace_state_unreadable',
      );
    }

    try {
      await fbg.BackgroundGeolocation.changePace(true);
      await fbg.Logger.notice('SPARRC force_pace call_returned source=$source');
      FirebaseCrashlytics.instance.log('force_moving_pace_success: $source');
      FirebaseCrashlytics.instance.setCustomKey(
        'last_force_moving_pace_source',
        source,
      );
      FirebaseCrashlytics.instance.setCustomKey(
        'last_force_moving_pace_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      return 'success';
    } catch (e, st) {
      final errorDescription = _describeForcePaceError(e);
      await fbg.Logger.notice(
        'SPARRC force_pace error source=$source $errorDescription',
      );
      if (e is PlatformException) {
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_error_code',
          e.code,
        );
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_error_message',
          e.message ?? '',
        );
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_error_details',
          '${e.details}',
        );
      } else {
        FirebaseCrashlytics.instance.setCustomKey(
          'last_force_moving_pace_error_type',
          e.runtimeType.toString(),
        );
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'force_moving_pace_failed',
      );
      return 'error:${e.runtimeType}';
    }
  }

  String _describeForcePaceError(Object error) {
    if (error is PlatformException) {
      return 'error=PlatformException code=${error.code} '
          'message=${error.message} details=${error.details}';
    }
    return 'error=${error.runtimeType} value=$error';
  }

  Future<void> _runHeartbeatWatchdog(fbg.HeartbeatEvent event) async {
    final now = DateTime.now().toUtc();
    await fbg.Logger.notice('SPARRC watchdog heartbeat_check');

    final lastCheck = _lastHeartbeatWatchdogUtc;
    if (lastCheck != null &&
        now.difference(lastCheck) < _heartbeatWatchdogInterval) {
      await fbg.Logger.notice('SPARRC watchdog skipped reason=rate_limited');
      return;
    }
    _lastHeartbeatWatchdogUtc = now;

    fbg.Location? loc;
    var source = 'fresh_current_position';
    await fbg.Logger.notice('SPARRC watchdog get_current_position_start');
    try {
      loc = await fbg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        persist: true,
        timeout: _heartbeatWatchdogTimeoutS,
      );
      await fbg.Logger.notice('SPARRC watchdog get_current_position_success');
    } catch (e, st) {
      source = 'heartbeat_fallback';
      await fbg.Logger.notice(
        'SPARRC watchdog get_current_position_error error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'heartbeat_watchdog_current_position_failed',
      );
      loc = event.location;
    }

    if (loc == null) {
      await fbg.Logger.notice(
        'SPARRC watchdog skipped reason=no_location_available',
      );
      return;
    }

    final lat = loc.coords.latitude;
    final lng = loc.coords.longitude;

    final persistedRef = await GeoDiagnosticsWriter.readLastBreadcrumbCandidate(
      uid: _uid,
    );
    if (persistedRef == null) {
      await fbg.Logger.notice(
        'SPARRC watchdog skipped '
        'reason=no_last_breadcrumb_reference after_location_persisted=true',
      );
      return;
    }

    final staleS = now.difference(persistedRef.timestamp).inSeconds;
    await fbg.Logger.notice(
      'SPARRC watchdog reference '
      'source=local_persisted_candidate:${persistedRef.source ?? 'unknown'} '
      'stale_s=$staleS',
    );
    if (staleS < _heartbeatWatchdogStaleAfter.inSeconds) {
      await fbg.Logger.notice(
        'SPARRC watchdog skipped reason=breadcrumb_not_stale '
        'stale_s=$staleS after_location_persisted=true',
      );
      return;
    }

    final movedM =
        haversineMeters(persistedRef.lat, persistedRef.lng, lat, lng);
    await fbg.Logger.notice(
      'SPARRC watchdog using_location source=$source '
      'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
    );

    if (movedM < _heartbeatWatchdogMovedM) {
      await fbg.Logger.notice(
        'SPARRC watchdog skipped reason=moved_too_little '
        'distance_m=${movedM.toStringAsFixed(1)} threshold_m=$_heartbeatWatchdogMovedM',
      );
      return;
    }

    await fbg.Logger.notice(
      'SPARRC watchdog force_pace source=heartbeat_watchdog '
      'distance_m=${movedM.toStringAsFixed(1)} stale_s=$staleS',
    );
    await forceMovingPace(source: 'heartbeat_watchdog');
  }

  Future<void> _maybeForceWakeFromNearEnter(fbg.GeofenceEvent event) async {
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
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC near_forcewake state_unreadable error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'near_forcewake_state_unreadable',
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

    final comparisonRef =
        await GeoDiagnosticsWriter.readLastBreadcrumbCandidate(
      uid: _uid,
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
    } catch (e, st) {
      await fbg.Logger.notice(
        'SPARRC near_forcewake get_current_position_error '
        'error=${e.runtimeType}',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        fatal: false,
        reason: 'near_forcewake_current_position_failed',
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
    await forceMovingPace(source: sourceName);
  }

  /// Expose streams
  Stream<LocationSample> onLocation() => _locCtl.stream;
  Stream<GeofenceEvent> onGeofence() => _fenceCtl.stream;

  /// Let the app switch modes directly (used by your app on ENTER/EXIT).
  Future<void> setSamplingMode(SamplingMode mode) async {
    await _applyMode(mode);
  }

  SamplingMode get currentMode => _mode;

  /// Returns 'geofence_only' or 'full_tracking' — written into extras so
  /// zbgIngest can apply mode-specific server-side logic per breadcrumb.
  String get geoSystemMode =>
      (_cfg?.geofenceOnlyMode == true) ? 'geofence_only' : 'full_tracking';

  /// Re-registers all geofences with the FBG plugin.
  /// Call after an EXIT event to force Android's Geofencing API to re-arm
  /// ENTER monitoring. Works around FBG's internal re-arming failure after
  /// the DWELL → EXIT state transition.
  Future<void> refreshGeofences() async {
    final nearRadiusM = (_cfg?.nearZoneRadiusM ?? 100).toDouble();
    final expectedNativeIds = _nativeIdsForDefs(_defs);
    await fbg.Logger.notice(
      'SPARRC geofence_engine refresh_geofences start defs=${_defs.length} '
      'expected_native=${expectedNativeIds.length} ids=${_formatIds(expectedNativeIds)}',
    );
    await fbg.BackgroundGeolocation.removeGeofences();
    var addedNativeCount = 0;
    for (final d in _defs) {
      if (d.type == 'circle' &&
          d.lat != null &&
          d.lng != null &&
          d.radiusM != null) {
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: d.ident,
            latitude: d.lat!,
            longitude: d.lng!,
            radius: d.radiusM!,
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: true,
            loiteringDelay: (_cfg?.dwellRequiredS ?? 60) * 1000,
          ),
        );
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: '${d.ident}_near',
            latitude: d.lat!,
            longitude: d.lng!,
            radius: d.radiusM! + nearRadiusM,
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: false,
            loiteringDelay: 0,
          ),
        );
        addedNativeCount += 2;
      }
    }
    await fbg.Logger.notice(
      'SPARRC geofence_engine refresh_geofences result added_native=$addedNativeCount',
    );
    await logNativeGeofenceInventory('engine_after_refresh');
  }

  /// Update native HTTP extras with current zone context so zbgIngest
  /// breadcrumbs carry correct zoneId and inside_zone fields.
  /// Call this from the app layer whenever a geofence event fires.
  Future<void> setZoneContext({
    required String? zoneId,
    required bool insideZone,
  }) async {
    final uid = _uid;
    final regionId = _regionId;
    final updatedExtras = <String, dynamic>{
      if (uid != null) 'uid': uid,
      if (regionId != null) 'regionId': regionId,
      if (zoneId != null) 'zoneId': zoneId,
      'inside_zone': insideZone,
      'mode': geoSystemMode,
    };
    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(persistence: fbg.PersistenceConfig(extras: updatedExtras)),
    );
  }

  /// --------------------------------------------
  /// Internal wiring
  /// --------------------------------------------

  void _attachListeners() {
    // LOCATION — gate emission by "whatever's first"
    fbg.BackgroundGeolocation.onLocation((fbg.Location l) async {
      await _maybeEmitFromFBGLocation(l, reason: 'location');
    });

    fbg.BackgroundGeolocation.onMotionChange((fbg.Location l) async {
      FirebaseCrashlytics.instance.log(
        'motion_change: moving=${l.isMoving} ts=${DateTime.now().toUtc().toIso8601String()}',
      );
      await fbg.Logger.notice(
        'SPARRC motionchange observed moving=${l.isMoving}',
      );
      await _maybeEmitFromFBGLocation(l, reason: 'motion_change');
    });

    // HEARTBEAT — ensures timed emission even when stationary
    fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent e) async {
      await fbg.Logger.notice(
        'SPARRC foreground_heartbeat received has_location=${e.location != null} '
        'mode=${_mode.name} ready=$_ready started=$_started',
      );
      await GeoDiagnosticsWriter.storeHeartbeatWatchdogRun(
        source: 'foreground_heartbeat_received',
        timestamp: DateTime.now().toUtc(),
      );
      try {
        final state = await fbg.BackgroundGeolocation.state;
        await fbg.Logger.notice(
          'SPARRC heartbeat_state path=foreground enabled=${state.enabled} '
          'isMoving=${state.isMoving}',
        );
      } catch (e) {
        await fbg.Logger.notice(
          'SPARRC heartbeat_state path=foreground state_unreadable '
          'error=${e.runtimeType}',
        );
      }
      FirebaseCrashlytics.instance.log(
        'hb mode=${_mode.name} ts=${DateTime.now().toUtc().toIso8601String()}',
      );
      await fbg.Logger.notice('SPARRC foreground_watchdog invoke');
      await _runHeartbeatWatchdog(e);
      await fbg.Logger.notice('SPARRC foreground_watchdog returned');

      // Prefer last known location from SDK; fall back to a lightweight fetch.
      fbg.Location? loc = e.location;
      if (loc == null) {
        try {
          loc = await fbg.BackgroundGeolocation.getCurrentPosition(
            samples: 1,
            persist: true,
            timeout: _heartbeatWatchdogTimeoutS,
          );
        } catch (e, st) {
          FirebaseCrashlytics.instance.recordError(
            e,
            st,
            fatal: false,
            reason: 'heartbeat_gps_unavailable',
          );
          return;
        }
      }
      await _maybeEmitFromFBGLocation(loc, reason: 'heartbeat');
    });

    // OEM / OS interference monitoring
    fbg.BackgroundGeolocation.onPowerSaveChange((bool isPowerSave) {
      FirebaseCrashlytics.instance.log('power_save: $isPowerSave');
      unawaited(
        GeoDiagnosticsWriter.recordPowerSaveChange(isPowerSave, uid: _uid),
      );
      if (isPowerSave) {
        FirebaseCrashlytics.instance.recordError(
          StateError('oem_power_save_enabled'),
          StackTrace.current,
          fatal: false,
          reason:
              'Device entered power-save mode — OEM may kill background service',
        );
      }
    });

    fbg.BackgroundGeolocation.onProviderChange((fbg.ProviderChangeEvent e) {
      FirebaseCrashlytics.instance.log(
        'provider: gps=${e.gps} network=${e.network} enabled=${e.enabled} status=${e.status} accuracy=${e.accuracyAuthorization}',
      );
      unawaited(GeoDiagnosticsWriter.recordProviderChange(e, uid: _uid));
      if (!e.enabled) {
        FirebaseCrashlytics.instance.recordError(
          StateError('location_provider_disabled'),
          StackTrace.current,
          fatal: false,
          reason: 'Location provider disabled (airplane mode or user toggle)',
        );
      }
    });

    fbg.BackgroundGeolocation.onEnabledChange((bool enabled) {
      FirebaseCrashlytics.instance.log('fbg_enabled: $enabled');
      unawaited(
        GeoDiagnosticsWriter.recordFbgEnabledChange(enabled, uid: _uid),
      );
      if (!enabled && _started) {
        FirebaseCrashlytics.instance.recordError(
          StateError('fbg_disabled_while_running'),
          StackTrace.current,
          fatal: false,
          reason:
              'FBG was disabled while engine believed it was running — possible OEM kill',
        );
      }
    });

    // GEOFENCE
    fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) async {
      // Handle outer near-zone fence events (Fix 2) — internal mode switching only, not emitted.
      if (e.identifier.endsWith('_near')) {
        if (e.action == 'ENTER') {
          _activeNearFences.add(e.identifier);
          if (_enteredFenceId == null) await _applyMode(SamplingMode.near);
          await _maybeForceWakeFromNearEnter(e);
        } else if (e.action == 'EXIT') {
          _activeNearFences.remove(e.identifier);
          if (_enteredFenceId == null && _activeNearFences.isEmpty) {
            await _applyMode(SamplingMode.outside);
          }
        }
        return;
      }

      final GeofenceEventType t;
      switch (e.action) {
        case 'ENTER':
          t = GeofenceEventType.enter;
          break;
        case 'DWELL':
          t = GeofenceEventType.dwell;
          break;
        case 'EXIT':
          t = GeofenceEventType.exit;
          break;
        default:
          t = GeofenceEventType.enter;
      }

      // Use SDK timestamp for event time
      final ts = DateTime.tryParse(e.location.timestamp)?.toUtc() ??
          DateTime.now().toUtc();

      // Dwell tracking state machine
      int? dwellSeconds;
      if (t == GeofenceEventType.enter) {
        _enteredAt = ts;
        _enteredFenceId = e.identifier;
        _firedMilestones.clear();
        _insideFixCount = 0;
        _insideFixFenceId = null;
      } else if (t == GeofenceEventType.dwell) {
        // Initial FBG dwell: record actual elapsed time since ENTER.
        // Add dwellRequiredS to firedMilestones so the heartbeat-based milestone
        // check doesn't re-fire near the same boundary.
        final cfg = _cfg;
        final enteredAt = _enteredAt;
        dwellSeconds = enteredAt != null
            ? ts.difference(enteredAt).inSeconds
            : cfg?.dwellRequiredS;
        final threshold = cfg?.dwellRequiredS;
        if (threshold != null) _firedMilestones.add(threshold);
      } else if (t == GeofenceEventType.exit) {
        // Record total time inside since ENTER
        final enteredAt = _enteredAt;
        if (enteredAt != null) {
          dwellSeconds = ts.difference(enteredAt).inSeconds;
        }
        _enteredAt = null;
        _enteredFenceId = null;
        _firedMilestones.clear();
      }

      // Emit to app FIRST — before calling setConfig back into FBG native,
      // so geo_bootstrap can update zone context while FBG callback is still clean.
      _fenceCtl.add(
        GeofenceEvent(e.identifier, t, ts, dwellSeconds: dwellSeconds),
      );

      // Switch mode AFTER emitting, so _applyMode's setConfig() call does not
      // re-enter FBG native while the geofence callback is still mid-execution.
      if (t == GeofenceEventType.enter || t == GeofenceEventType.dwell) {
        // Cancel any pending exit — device is still inside the geofence.
        _exitHysteresisTimer?.cancel();
        _exitHysteresisTimer = null;
        await _applyMode(SamplingMode.inside);
      } else if (t == GeofenceEventType.exit) {
        // Delay the outside-mode switch by 2 minutes. GPS jitter can fire a
        // spurious EXIT while the device is physically still inside the fence;
        // if a new ENTER arrives before the timer fires we stay in inside mode.
        _exitHysteresisTimer?.cancel();
        _exitHysteresisTimer = Timer(const Duration(minutes: 2), () {
          if (_activeNearFences.isEmpty) {
            _applyMode(SamplingMode.outside);
          } else {
            _applyMode(SamplingMode.near);
          }
          _exitHysteresisTimer = null;
        });
      }
    });
  }

  Future<void> _applyMode(SamplingMode mode) async {
    final cfg = _cfg;
    if (cfg == null) return;

    // In geofence-only mode, startGeofences() + geofenceModeHighAccuracy manage
    // GPS entirely. Applying outside/near configs would conflict with that and
    // waste power. Only inside-mode config (closer heartbeat/distance filter) is
    // meaningful while the user is actually inside a fence.
    if (cfg.geofenceOnlyMode && mode != SamplingMode.inside) {
      _mode = mode;
      return;
    }

    int heartbeatS;
    int distanceM;
    bool useSigChange;
    int? locationUpdateMs; // NEW: per-mode locationUpdateInterval

    switch (mode) {
      case SamplingMode.inside:
        useSigChange = false;
        heartbeatS = cfg.rateInsideS;
        distanceM = cfg.distanceFilterInsideM;
        locationUpdateMs = (heartbeatS > 0) ? heartbeatS * 1000 : null;
        break;
      case SamplingMode.near:
        useSigChange = false;
        heartbeatS = cfg.rateNearS;
        distanceM = cfg.distanceFilterNearM;
        locationUpdateMs = (heartbeatS > 0) ? heartbeatS * 1000 : null;
        break;
      case SamplingMode.outside:
        final allowSigChange = cfg.useSignificantChangeWhenOutside &&
            (cfg.rateOutsideS >= cfg.significantChangeOutsideThresholdS);
        useSigChange = allowSigChange;
        heartbeatS = cfg.rateOutsideS;
        distanceM = cfg.distanceFilterOutsideM;

        // NEW: when you're "outside", ask the plugin for more frequent updates
        // tied to your configured rate (in seconds).
        locationUpdateMs = (heartbeatS > 0) ? heartbeatS * 1000 : null;
        break;
    }

    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(
        geolocation: fbg.GeoConfig(
          useSignificantChangesOnly: useSigChange,
          distanceFilter: distanceM.toDouble(),
          locationUpdateInterval: locationUpdateMs,
        ),
        app: fbg.AppConfig(
          heartbeatInterval: heartbeatS
              .toDouble(), // seconds, per AppConfig v5 API (Android min: 60s)
          // iOS only — engage preventSuspend while inside a zone so heartbeat
          // breadcrumbs fire reliably while stationary. Off outside/near so iOS
          // manages the process normally and CLRegionMonitoring handles wakeups.
          // cfg.preventSuspendInsideZone is a Firestore kill switch (default true).
          preventSuspend:
              (mode == SamplingMode.inside) && cfg.preventSuspendInsideZone,
        ),
      ),
    );

    if (kDebugMode) {
      debugPrint(
        '[TsbgEngine] applyMode=$mode sc=$useSigChange hb=${heartbeatS}s df=${distanceM}m locUpdateMs=$locationUpdateMs',
      );
    }

    _mode = mode;
    FirebaseCrashlytics.instance.setCustomKey('zone_state', mode.name);
    FirebaseCrashlytics.instance.log('zone_transition: ${mode.name}');
  }

  /// Central gate for "whatever's first" (distance OR time) emission.
  Future<void> _maybeEmitFromFBGLocation(
    fbg.Location l, {
    required String reason,
  }) async {
    final cfg = _cfg;
    if (cfg == null || !cfg.enabled) return;

    final nowUtc =
        DateTime.tryParse(l.timestamp)?.toUtc() ?? DateTime.now().toUtc();
    final c = l.coords;

    final double lat = c.latitude;
    final double lng = c.longitude;
    final double acc = c.accuracy;

    // Accuracy gate
    if (acc > cfg.accuracyDropM) return;

    // Geofence-only mode: suppress breadcrumb emission while outside all fences.
    // Server-side zbgIngest applies the same rule, but gating here avoids writing
    // to the app-layer stream and prevents SQLite accumulation of outside fixes.
    if (cfg.geofenceOnlyMode && _enteredFenceId == null) return;

    // Mode-specific thresholds
    final int rateS;
    final int distM;
    switch (_mode) {
      case SamplingMode.inside:
        rateS = cfg.rateInsideS;
        distM = cfg.distanceFilterInsideM;
        break;
      case SamplingMode.near:
        rateS = cfg.rateNearS;
        distM = cfg.distanceFilterNearM;
        break;
      case SamplingMode.outside:
        rateS = cfg.rateOutsideS;
        distM = cfg.distanceFilterOutsideM;
        break;
    }

    final lastLat = _lastEmitLat;
    final lastLng = _lastEmitLng;
    final lastTs = _lastEmitUtc;

    final bool timeDue =
        (lastTs == null) ? true : nowUtc.difference(lastTs).inSeconds >= rateS;

    final double movedM = (lastLat == null || lastLng == null)
        ? double.infinity
        : haversineMeters(lastLat, lastLng, lat, lng);

    final bool distDue =
        (lastLat == null || lastLng == null) ? true : movedM >= distM;

    if (timeDue || distDue) {
      // Emit a sample to app layer (positional ctor: lat, lng, acc, ts)
      _locCtl.add(LocationSample(lat, lng, acc, nowUtc));

      // Reset the emission reference
      _lastEmitUtc = nowUtc;
      _lastEmitLat = lat;
      _lastEmitLng = lng;
      await GeoDiagnosticsWriter.storeLastBreadcrumbCandidate(
        lat: lat,
        lng: lng,
        accuracyM: acc,
        timestamp: nowUtc,
        source: reason,
        uid: _uid,
        regionId: _regionId,
      );

      if (kDebugMode) {
        debugPrint(
          '[TsbgEngine] emit reason=$reason mode=$_mode timeDue=$timeDue distDue=$distDue moved=${movedM.toStringAsFixed(1)}m rate=${rateS}s dist=${distM}m acc=${acc}m',
        );
      }
    } else {
      if (kDebugMode) {
        debugPrint(
          '[TsbgEngine] skip reason=$reason mode=$_mode timeDue=$timeDue distDue=$distDue',
        );
      }
    }

    // Fix 3a: Near mode reconciliation — if GPS shows us inside the near radius but
    // the outer geofence ENTER was missed (e.g. device was already nearby when fences
    // were registered), switch to near mode now.
    if (_enteredFenceId == null &&
        _activeNearFences.isEmpty &&
        _mode == SamplingMode.outside) {
      final nearRadiusM = (_cfg?.nearZoneRadiusM ?? 100).toDouble();
      for (final d in _defs) {
        if (d.type != 'circle' ||
            d.lat == null ||
            d.lng == null ||
            d.radiusM == null) {
          continue;
        }
        if (haversineMeters(lat, lng, d.lat!, d.lng!) <=
            d.radiusM! + nearRadiusM) {
          await _applyMode(SamplingMode.near);
          if (kDebugMode) {
            debugPrint(
              '[TsbgEngine] near-mode reconciliation: within near zone of ${d.ident}',
            );
          }
          break;
        }
      }
    }

    // Fix 3b: Inside mode reconciliation — N=2 consecutive GPS fixes inside a fence
    // synthesizes an ENTER. Guards against missed native ENTER events (FBG accuracy
    // limitations, fence registered after user was already inside).
    if (_enteredFenceId == null) {
      String? containingFence;
      for (final d in _defs) {
        if (d.type != 'circle' ||
            d.lat == null ||
            d.lng == null ||
            d.radiusM == null) {
          continue;
        }
        if (haversineMeters(lat, lng, d.lat!, d.lng!) <= d.radiusM!) {
          containingFence = d.ident;
          break;
        }
      }
      if (containingFence != null && containingFence == _insideFixFenceId) {
        _insideFixCount++;
        if (_insideFixCount >= 2) {
          _insideFixCount = 0;
          _insideFixFenceId = null;
          _enteredAt = nowUtc;
          _enteredFenceId = containingFence;
          _firedMilestones.clear();
          _fenceCtl.add(
            GeofenceEvent(containingFence, GeofenceEventType.enter, nowUtc),
          );
          await _applyMode(SamplingMode.inside);
          if (kDebugMode) {
            debugPrint(
              '[TsbgEngine] synthetic ENTER (reconciliation): $containingFence',
            );
          }
        }
      } else {
        _insideFixFenceId = containingFence;
        _insideFixCount = containingFence != null ? 1 : 0;
      }
    }

    // Dwell milestone check — runs on every heartbeat/location callback.
    // Emits a synthetic DWELL event at each dwell_every_s boundary while inside.
    final dwellCfg = _cfg;
    final enteredAt = _enteredAt;
    final enteredFenceId = _enteredFenceId;
    if (dwellCfg != null &&
        dwellCfg.dwellEveryS > 0 &&
        enteredAt != null &&
        enteredFenceId != null) {
      final elapsedS = nowUtc.difference(enteredAt).inSeconds;
      final milestone =
          (elapsedS ~/ dwellCfg.dwellEveryS) * dwellCfg.dwellEveryS;
      if (milestone > 0 && !_firedMilestones.contains(milestone)) {
        _firedMilestones.add(milestone); // boundary used as dedup key
        _fenceCtl.add(
          GeofenceEvent(
            enteredFenceId,
            GeofenceEventType.dwell,
            nowUtc,
            dwellSeconds:
                elapsedS, // actual elapsed time, not the rounded boundary
          ),
        );
        if (kDebugMode) {
          debugPrint(
            '[TsbgEngine] dwell milestone fired: ${milestone}s for fence $enteredFenceId',
          );
        }
      }
    }

    // Software EXIT check — Android only.
    // Guards against Android's Geofencing API missing EXIT events after DWELL.
    // If we believe we're inside a fence but GPS shows us beyond radius + 30m,
    // synthesize an EXIT so geo_bootstrap can update zone context and call
    // refreshGeofences() to re-arm Android ENTER monitoring.
    //
    // Not used on iOS: CLRegionMonitoring re-arms EXIT detection automatically,
    // and calling removeGeofences() on iOS resets region monitoring state —
    // preventing timely ENTER detection for other zones (e.g. food_coop) that
    // the user enters shortly after leaving the previous zone.
    final softExitFenceId = Platform.isAndroid ? _enteredFenceId : null;
    if (softExitFenceId != null) {
      GeofenceDef? def;
      for (final d in _defs) {
        if (d.ident == softExitFenceId) {
          def = d;
          break;
        }
      }
      if (def != null &&
          def.lat != null &&
          def.lng != null &&
          def.radiusM != null) {
        final distToCenter = haversineMeters(lat, lng, def.lat!, def.lng!);
        if (distToCenter > def.radiusM! + 30.0) {
          final softExitEnteredAt = _enteredAt;
          final dwellSecs = softExitEnteredAt != null
              ? nowUtc.difference(softExitEnteredAt).inSeconds
              : null;
          // Clear state before emitting so a re-entrant callback cannot re-fire.
          _enteredAt = null;
          _enteredFenceId = null;
          _firedMilestones.clear();
          _fenceCtl.add(
            GeofenceEvent(
              softExitFenceId,
              GeofenceEventType.exit,
              nowUtc,
              dwellSeconds: dwellSecs,
            ),
          );
          if (kDebugMode) {
            debugPrint(
              '[TsbgEngine] software EXIT: ${distToCenter.toStringAsFixed(1)}m > '
              '${def.radiusM! + 30.0}m threshold for fence $softExitFenceId',
            );
          }
        }
      }
    }
  }
}
