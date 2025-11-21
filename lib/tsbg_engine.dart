// zbg_location/lib/tsbg_engine.dart
// DROP-IN REPLACEMENT — applies hybrid significant-change rule,
// per-mode distance filters, SDK timestamps, and dwell alignment.
// Updated to implement "whatever's first" emission rule (distance OR time)
// and native HTTP uploads to Cloud Function (zbgIngest).

import 'dart:async';
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
        // Keep idle relatively short so heartbeats are dependable.
        stopTimeout: 2,
        reset: !_ready,

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
        batchSync: true,
        maxBatchSize: 50,
        // NOTE: no httpRootProperty here; defaults to 'location'
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
    _defs.addAll(defs);
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
    await fbg.BackgroundGeolocation.start();
    _started = true;
  }

  Future<void> stop() async {
    if (!_started) return;
    await fbg.BackgroundGeolocation.stop();
    _started = false;
  }

  /// Expose streams
  Stream<LocationSample> onLocation() => _locCtl.stream;
  Stream<GeofenceEvent> onGeofence() => _fenceCtl.stream;

  /// Let the app switch modes directly (used by your app on ENTER/EXIT).
  Future<void> setSamplingMode(SamplingMode mode) async {
    await _applyMode(mode);
  }

  SamplingMode get currentMode => _mode;

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
            persist: false,
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

      // Switch mode in response to fence transitions
      if (t == GeofenceEventType.enter || t == GeofenceEventType.dwell) {
        await _applyMode(SamplingMode.inside);
      } else if (t == GeofenceEventType.exit) {
        await _applyMode(SamplingMode.outside);
      }

      // Use SDK timestamp for event time
      final ts =
          DateTime.tryParse(e.location.timestamp)?.toUtc() ?? DateTime.now().toUtc();

      // Emit to app (API: fenceId, type, ts)
      _fenceCtl.add(GeofenceEvent(e.identifier, t, ts));
    });
  }

  Future<void> _applyMode(SamplingMode mode) async {
    final cfg = _cfg;
    if (cfg == null) return;

    int heartbeatS;
    int distanceM;
    bool useSigChange;

    switch (mode) {
      case SamplingMode.inside:
        useSigChange = false;
        heartbeatS = cfg.rateInsideS;
        distanceM = cfg.distanceFilterInsideM;
        break;
      case SamplingMode.near:
        useSigChange = false;
        heartbeatS = cfg.rateNearS;
        distanceM = cfg.distanceFilterNearM;
        break;
      case SamplingMode.outside:
        final allowSigChange = cfg.useSignificantChangeWhenOutside &&
            (cfg.rateOutsideS >= cfg.significantChangeOutsideThresholdS);
        useSigChange = allowSigChange;
        heartbeatS = cfg.rateOutsideS;
        distanceM = cfg.distanceFilterOutsideM;
        break;
    }

    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(
        useSignificantChangesOnly: useSigChange,
        distanceFilter: distanceM.toDouble(),
        heartbeatInterval:
            _hbMinutesFromSeconds(heartbeatS), // <- convert seconds -> minutes
      ),
    );

    if (kDebugMode) {
      debugPrint(
          '[TsbgEngine] applyMode=$mode sc=$useSigChange hb=${heartbeatS}s df=${distanceM}m');
    }

    _mode = mode;
  }

  /// Central gate for "whatever's first" (distance OR time) emission.
  void _maybeEmitFromFBGLocation(fbg.Location l, {required String reason}) {
    final cfg = _cfg;
    if (cfg == null || !cfg.enabled) return;

    // SDK timestamp for the sample itself.
    final DateTime locTsUtc =
        DateTime.tryParse(l.timestamp)?.toUtc() ?? DateTime.now().toUtc();

    // For HEARTBEAT, use wall-clock time for the time gate so we don't get "stuck"
    // on a stale SDK timestamp. For LOCATION, use the location timestamp as before.
    final DateTime gateNowUtc =
        (reason == 'heartbeat') ? DateTime.now().toUtc() : locTsUtc;

    final c = l.coords;
    final double lat = c.latitude;
    final double lng = c.longitude;
    final double acc = (c.accuracy ?? 9999.0);

    // Accuracy gate
    if (acc > cfg.accuracyDropM) return;

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

    final int? dtS =
        (lastTs == null) ? null : gateNowUtc.difference(lastTs).inSeconds;

    final bool timeDue = (lastTs == null) ? true : (dtS! >= rateS);

    final double movedM = (lastLat == null || lastLng == null)
        ? double.infinity
        : _haversineM(lastLat, lastLng, lat, lng);

    bool distDue;
    if (lastLat == null || lastLng == null) {
      distDue = true;
    } else if (reason == 'heartbeat') {
      // 💡 For heartbeats, relax distance gating so that time-alone can trigger emits.
      distDue = true;
    } else {
      distDue = movedM >= distM;
    }

    if (timeDue || distDue) {
      // Emit a sample to app layer (positional ctor: lat, lng, acc, ts)
      _locCtl.add(LocationSample(
        lat,
        lng,
        acc,
        locTsUtc, // keep the actual location timestamp in the sample
      ));

      // Reset the emission reference using the gate time.
      _lastEmitUtc = gateNowUtc;
      _lastEmitLat = lat;
      _lastEmitLng = lng;

      if (kDebugMode) {
        final movedStr =
            movedM.isInfinite ? 'Inf' : movedM.toStringAsFixed(1);
        debugPrint(
            '[TsbgEngine] emit reason=$reason mode=$_mode '
            'locTs=$locTsUtc gateNow=$gateNowUtc '
            'timeDue=$timeDue distDue=$distDue '
            'dt=${dtS?.toString() ?? 'null'}s '
            'moved=${movedStr}m rate=${rateS}s dist=${distM}m acc=${acc}m');
      }
    } else {
      if (kDebugMode) {
        final movedStr =
            movedM.isInfinite ? 'Inf' : movedM.toStringAsFixed(1);
        debugPrint(
            '[TsbgEngine] skip reason=$reason mode=$_mode '
            'locTs=$locTsUtc gateNow=$gateNowUtc '
            'timeDue=$timeDue distDue=$distDue '
            'dt=${dtS?.toString() ?? 'null'}s '
            'moved=${movedStr}m rate=${rateS}s dist=${distM}m acc=${acc}m');
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
