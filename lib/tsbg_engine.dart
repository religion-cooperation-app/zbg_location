// zbg_location/lib/tsbg_engine.dart
// DROP-IN REPLACEMENT — applies hybrid significant-change rule,
// per-mode distance filters, SDK timestamps, and dwell alignment.
// Updated to implement "whatever's first" emission rule (distance OR time)
// and native HTTP uploads to Cloud Function (zbgIngest).

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'api.dart'; // RuntimeConfig, SamplingMode, GeofenceDef, GeofenceEvent, LocationSample

// Native HTTP upload config for background ingestion.
const String _zbgIngestUrl =
    'https://us-central1-religion-and-cooperation.cloudfunctions.net/zbgIngest';
// NOTE: For production, move this API key into a secure runtime channel / remote config.
const String _zbgApiKey = 'religion-and-cooperation-key-123';

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

  bool _ready = false;
  bool _started = false;

  Timer? _exitHysteresisTimer;

  /// Dwell milestone tracking
  DateTime? _enteredAt;
  String? _enteredFenceId;
  final Set<int> _firedMilestones = {};

  /// "Whatever's first" bookkeeping
  DateTime? _lastEmitUtc;
  double? _lastEmitLat;
  double? _lastEmitLng;

  // Identity for native HTTP uploads → Cloud Function.
  String? _uid;
  String? _regionId;

  /// Called by app layer before setConfig/start to tag native HTTP uploads
  /// with the signed-in user and active region.
  void setIdentity({required String uid, required String regionId}) {
    _uid = uid;
    _regionId = regionId;
  }

  /// --------------------------------------------
  /// Public API
  /// --------------------------------------------

  Future<void> setConfig(RuntimeConfig cfg) async {
    _cfg = cfg;

    // Snapshot identity for HTTP params at config-time.
    final uid = _uid;
    final regionId = _regionId;

    final httpParams = <String, dynamic>{};
    if (uid != null) httpParams['uid'] = uid;
    if (regionId != null) httpParams['regionId'] = regionId;
    httpParams['mode'] = geoSystemMode;

    if (kDebugMode) {
      debugPrint(
          '[TsbgEngine] HTTP params at setConfig: uid=$uid regionId=$regionId httpParams=$httpParams');
    }

    // One-time BG Geolocation init
    await fbg.BackgroundGeolocation.ready(
      fbg.Config(
        startOnBoot: cfg.startOnBoot,
        stopOnTerminate: cfg.stopOnTerminate,
        debug: false,
        desiredAccuracy: fbg.Config.DESIRED_ACCURACY_HIGH,
        disableElasticity: true,
        // Configurable from Firestore — how long before FBG stops GPS after no motion.
        stopTimeout: cfg.stopTimeoutMinutes,
        reset: !_ready,

        // Keep a foreground service so Android is more willing to deliver
        // frequent updates, especially screen-off.
        foregroundService: true,

        // iOS: prevent CoreLocation from pausing updates on stationary devices.
        pausesLocationUpdatesAutomatically: false,

        // Prevent FBG's own motion-based stop detection from killing GPS when
        // the device is stationary (e.g. participant sitting in a study room).
        disableStopDetection: true,

        // iOS: periodically invalidate/recreate CLLocationManager via the
        // background task API to prevent iOS from suspending the process
        // between GPS wakeups. Closes most remaining background data gaps.
        preventSuspend: true,

        // iOS: declare walking/non-automotive movement so CoreLocation applies
        // less aggressive power management in background. FBG silently ignores
        // this on Android — no platform guard needed.
        activityType: fbg.Config.ACTIVITY_TYPE_OTHER_NAVIGATION,

        // Always-on: ensures Android uses active GPS (foreground service) for
        // geofence EXIT detection. Without this, Android may miss EXIT events
        // when the device is stationary. Required in both full_tracking and
        // geofence_only modes.
        geofenceModeHighAccuracy: true,

        // Native HTTP → Cloud Function (background-safe).
        url: _zbgIngestUrl,
        headers: const {
          'X-Api-Key': _zbgApiKey,
        },

        // Sent with every request (query/body-level params)
        params: httpParams,

        // Sent with each recorded location/geofence as `.extras`
        extras: httpParams,

        autoSync: true,
        batchSync: cfg.batchSync,
        maxBatchSize: cfg.maxBatchSize,
        // NOTE: no httpRootProperty here; defaults to 'location'

        // Keep unsynced SQLite records for 30 days so locations accumulated
        // during extended offline periods are still recoverable on next open.
        maxDaysToPersist: 30,

        // 25s timeout fits within iOS SLC / background-fetch wakeup windows
        // (~30s), giving FBG the best chance of completing a POST before iOS
        // reclaims the process. Default of 60s exceeds the wakeup window.
        httpTimeout: 25000,

        // Suppress heads-up banner and status bar icon on Android.
        // The notification still appears in the shade (OS requirement for
        // foreground services) but is otherwise invisible during normal use.
        notification: fbg.Notification(
          title: 'Location Detection',
          text: 'SPARRC is tracking device location changes',
          priority: fbg.NotificationPriority.min,
          sticky: false,
        ),

        // Android: rationale shown when upgrading to Always Allow permission.
        // Only message is set — FBG defaults are used for title and buttons.
        backgroundPermissionRationale: fbg.PermissionRationale(
          message: 'SPARRC uses location to log entry and exit from study locations and to log participation events.',
        ),

        // iOS: rationale shown in FBG\'s location authorisation alert.
        // Only instructions is set — FBG defaults are used for all other keys.
        locationAuthorizationAlert: {
          'instructions': 'SPARRC uses location to log entry and exit from study locations and to log participation events.',
        },
      ),
    );

    if (!_ready) {
      _attachListeners();
      _ready = true;
    }

    // Apply the current mode’s config (outside by default).
    await _applyMode(_mode);
  }

  Future<void> addGeofences(List<GeofenceDef> defs) async {
    _defs
      ..clear()
      ..addAll(defs);
    // Clear any persisted FBG geofence state from previous sessions before
    // re-registering. Without this, FBG's SQLite may still show a geofence as
    // "inside" from an ENTER event that fired while Dart was dead, preventing
    // a new ENTER from being delivered when the session restarts.
    await fbg.BackgroundGeolocation.removeGeofences();
    for (final d in defs) {
      // Only circles for now. Polygons could be added here in future.
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
      }
    }
  }

  Future<void> start() async {
    if (_started) return;
    if (_cfg?.geofenceOnlyMode == true) {
      await fbg.BackgroundGeolocation.startGeofences();
    } else {
      await fbg.BackgroundGeolocation.start();
    }
    _started = true;
  }

  Future<void> stop() async {
    if (!_started) return;
    _exitHysteresisTimer?.cancel();
    _exitHysteresisTimer = null;
    await fbg.BackgroundGeolocation.stop();
    _started = false;
    // Reset dwell state so a subsequent session (e.g. sign-out/sign-in or user
    // switch) starts clean. Without this, stale _enteredAt / _enteredFenceId
    // from the previous user would immediately fire spurious dwell milestones.
    _enteredAt = null;
    _enteredFenceId = null;
    _firedMilestones.clear();
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
            def.radiusM == null) continue;
        final dist = _haversineM(lat, lng, def.lat!, def.lng!);
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
                '(${dist.toStringAsFixed(1)}m <= ${def.radiusM}m)');
          }
          break; // only one zone active at a time
        }
      }
    } catch (_) {
      // GPS unavailable or timed out — no synthetic ENTER; zbgIngest computed
      // path will detect the ENTER from the next breadcrumb batch.
    }
  }

  /// Flush any locations accumulated in FBG's SQLite buffer (e.g. from
  /// terminated-state significant-change wakeups) by forcing an immediate
  /// sync POST to zbgingest. Safe to call before start() — no-ops if not ready.
  Future<void> flushBuffer() async {
    if (!_ready) return;
    await fbg.BackgroundGeolocation.sync();
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
    await fbg.BackgroundGeolocation.removeGeofences();
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
      }
    }
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
      fbg.Config(extras: updatedExtras),
    );
  }

  /// --------------------------------------------
  /// Internal wiring
  /// --------------------------------------------

  void _attachListeners() {
    // LOCATION — gate emission by "whatever's first"
    fbg.BackgroundGeolocation.onLocation((fbg.Location l) async {
      _maybeEmitFromFBGLocation(l, reason: 'location');

      // Optional: promote to NEAR when close to any fence (if not already inside).
      final c = l.coords;
      if (_mode != SamplingMode.inside) {
        final near = _isNearAnyFence(c.latitude, c.longitude);
        if (near && _mode != SamplingMode.near) {
          await _applyMode(SamplingMode.near);
        } else if (!near && _mode == SamplingMode.near) {
          await _applyMode(SamplingMode.outside);
        }
      }
    });

    // HEARTBEAT — ensures timed emission even when stationary
    fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent e) async {
      // Prefer last known location from SDK; fall back to a lightweight fetch.
      fbg.Location? loc = e.location;
      if (loc == null) {
        try {
          loc = await fbg.BackgroundGeolocation.getCurrentPosition(
            samples: 1,
            persist: true,
          );
        } catch (_) {
          return;
        }
      }
      _maybeEmitFromFBGLocation(loc, reason: 'heartbeat');
    });

    // GEOFENCE
    fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) async {
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
      final ts =
          DateTime.tryParse(e.location.timestamp)?.toUtc() ?? DateTime.now().toUtc();

      // Dwell tracking state machine
      int? dwellSeconds;
      if (t == GeofenceEventType.enter) {
        _enteredAt = ts;
        _enteredFenceId = e.identifier;
        _firedMilestones.clear();
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
      _fenceCtl.add(GeofenceEvent(e.identifier, t, ts, dwellSeconds: dwellSeconds));

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
          _applyMode(SamplingMode.outside);
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
        useSignificantChangesOnly: useSigChange,
        distanceFilter: distanceM.toDouble(),
        heartbeatInterval:
            _hbMinutesFromSeconds(heartbeatS), // seconds -> minutes (Android)
        locationUpdateInterval:
            locationUpdateMs, // can be null in inside/near; active in outside
      ),
    );

    if (kDebugMode) {
      debugPrint(
          '[TsbgEngine] applyMode=$mode sc=$useSigChange hb=${heartbeatS}s df=${distanceM}m locUpdateMs=$locationUpdateMs');
    }

    _mode = mode;
  }

  /// Central gate for "whatever's first" (distance OR time) emission.
  void _maybeEmitFromFBGLocation(fbg.Location l, {required String reason}) {
    final cfg = _cfg;
    if (cfg == null || !cfg.enabled) return;

    final nowUtc =
        DateTime.tryParse(l.timestamp)?.toUtc() ?? DateTime.now().toUtc();
    final c = l.coords;

    final double lat = c.latitude;
    final double lng = c.longitude;
    final double acc = (c.accuracy ?? 9999.0);

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

    final bool timeDue = (lastTs == null)
        ? true
        : nowUtc.difference(lastTs).inSeconds >= rateS;

    final double movedM = (lastLat == null || lastLng == null)
        ? double.infinity
        : _haversineM(lastLat, lastLng, lat, lng);

    final bool distDue =
        (lastLat == null || lastLng == null) ? true : movedM >= distM;

    if (timeDue || distDue) {
      // Emit a sample to app layer (positional ctor: lat, lng, acc, ts)
      _locCtl.add(LocationSample(
        lat,
        lng,
        acc,
        nowUtc,
      ));

      // Reset the emission reference
      _lastEmitUtc = nowUtc;
      _lastEmitLat = lat;
      _lastEmitLng = lng;

      if (kDebugMode) {
        debugPrint(
            '[TsbgEngine] emit reason=$reason mode=$_mode timeDue=$timeDue distDue=$distDue moved=${movedM.toStringAsFixed(1)}m rate=${rateS}s dist=${distM}m acc=${acc}m');
      }
    } else {
      if (kDebugMode) {
        debugPrint(
            '[TsbgEngine] skip reason=$reason mode=$_mode timeDue=$timeDue distDue=$distDue');
      }
    }

    // Dwell milestone check — runs on every heartbeat/location callback.
    // Emits a synthetic DWELL event at each dwell_every_s boundary while inside.
    final dwellCfg = _cfg;
    final enteredAt = _enteredAt;
    final enteredFenceId = _enteredFenceId;
    if (dwellCfg != null && dwellCfg.dwellEveryS > 0 && enteredAt != null && enteredFenceId != null) {
      final elapsedS = nowUtc.difference(enteredAt).inSeconds;
      final milestone = (elapsedS ~/ dwellCfg.dwellEveryS) * dwellCfg.dwellEveryS;
      if (milestone > 0 && !_firedMilestones.contains(milestone)) {
        _firedMilestones.add(milestone); // boundary used as dedup key
        _fenceCtl.add(GeofenceEvent(
          enteredFenceId,
          GeofenceEventType.dwell,
          nowUtc,
          dwellSeconds: elapsedS, // actual elapsed time, not the rounded boundary
        ));
        if (kDebugMode) {
          debugPrint('[TsbgEngine] dwell milestone fired: ${milestone}s for fence $enteredFenceId');
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
      if (def != null && def.lat != null && def.lng != null && def.radiusM != null) {
        final distToCenter = _haversineM(lat, lng, def.lat!, def.lng!);
        if (distToCenter > def.radiusM! + 30.0) {
          final softExitEnteredAt = _enteredAt;
          final dwellSecs = softExitEnteredAt != null
              ? nowUtc.difference(softExitEnteredAt).inSeconds
              : null;
          // Clear state before emitting so a re-entrant callback cannot re-fire.
          _enteredAt = null;
          _enteredFenceId = null;
          _firedMilestones.clear();
          _fenceCtl.add(GeofenceEvent(
            softExitFenceId,
            GeofenceEventType.exit,
            nowUtc,
            dwellSeconds: dwellSecs,
          ));
          if (kDebugMode) {
            debugPrint(
                '[TsbgEngine] software EXIT: ${distToCenter.toStringAsFixed(1)}m > '
                '${def.radiusM! + 30.0}m threshold for fence $softExitFenceId');
          }
        }
      }
    }
  }

  bool _isNearAnyFence(double lat, double lng) {
    // Simple radial check against all circle geofences with a fixed NEAR radius
    const nearRadiusM = 150.0; // can be tuned or moved into RuntimeConfig
    for (final d in _defs) {
      if (d.type != 'circle' ||
          d.lat == null ||
          d.lng == null ||
          d.radiusM == null) continue;
      final dist = _haversineM(lat, lng, d.lat!, d.lng!);
      if (dist <= d.radiusM! + nearRadiusM) return true;
    }
    return false;
  }

  double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  double _deg2rad(double deg) => deg * (math.pi / 180.0);

  /// Convert your per-mode seconds to the plugin's heartbeat minutes (Android).
  /// Uses a floor of 1 minute; rounds to nearest minute for larger values.
  int _hbMinutesFromSeconds(int seconds) {
    if (seconds <= 60) return 1;
    return (seconds / 60).round();
  }
}
