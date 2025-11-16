// zbg_location/lib/tsbg_engine.dart
// DROP-IN REPLACEMENT — applies hybrid significant-change rule,
// per-mode distance filters, SDK timestamps, and dwell alignment.
// Updated to implement "whatever's first" emission rule (distance OR time).

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

  // Identity for native HTTP uploads → Cloud Function.
  String? _uid;
  String? _regionId;

  /// Called by app layer before setConfig/start to tag native HTTP uploads
  /// with the signed-in user and active region.
  void setIdentity({required String uid, required String regionId}) {
    _uid = uid;
    _regionId = regionId;
  }

  /// Current effective runtime config (from Firestore via app layer).
  RuntimeConfig? _cfg;

  /// Track current sampling mode (outside by default).
  SamplingMode _mode = SamplingMode.outside;

  /// Keep geofence defs for optional "near" detection on location callbacks.
  final List<GeofenceDef> _defs = [];

  /// Streams exposed to app layer
  final _locCtl = StreamController<LocationSample>.broadcast();
  final _fenceCtl = StreamController<GeofenceEvent>.broadcast();

  /// Dwell alignment
  LocationSample? _lastSample;
  DateTime? _lastEmitTs;
  bool _started = false;
  bool _ready = false;

  /// Public API
  Future<void> setConfig(RuntimeConfig cfg) async {
    _cfg = cfg;

    // Snapshot identity for HTTP params at config-time.
    final uid = _uid;
    final regionId = _regionId;

    final httpParams = <String, dynamic>{};
    if (uid != null) httpParams['uid'] = uid;
    if (regionId != null) httpParams['regionId'] = regionId;

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
        reset: !_ready, // ✅ set here instead

        // Native HTTP → Cloud Function (background-safe).
        url: _zbgIngestUrl,
        headers: const {
          'X-Api-Key': _zbgApiKey,
        },
        params: httpParams,
        autoSync: true,
        batchSync: true,
        maxBatchSize: 50,
        httpRootProperty: '.', // zbgIngest expects root location / geofence objects
      ),
    );

    if (!_ready) {
      _attachListeners();
      _ready = true;
    }

    // Apply the current mode’s config (outside by default).
    await _applyMode(_mode);
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
    });

    // MOTIONCHANGE — typically high-quality transition sample
    fbg.BackgroundGeolocation.onMotionChange((fbg.Location l) async {
      _maybeEmitFromFBGLocation(l, reason: 'motionchange');
    });

    // GEOFENCE — ENTER/DWELL/EXIT
    fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) async {
      final cfg = _cfg;
      if (cfg == null || !cfg.enabled) return;

      final type = e.action;
      GeofenceEventType? t;
      if (type == 'ENTER') {
        t = GeofenceEventType.enter;
      } else if (type == 'DWELL') {
        t = GeofenceEventType.dwell;
      } else if (type == 'EXIT') {
        t = GeofenceEventType.exit;
      }

      if (t == null) return;

      // Switch mode in response to fence transitions
      if (t == GeofenceEventType.enter || t == GeofenceEventType.dwell) {
        await _applyMode(SamplingMode.inside);
      } else if (t == GeofenceEventType.exit) {
        await _applyMode(SamplingMode.outside);
      }

      // Use SDK timestamp for event time
      final ts =
          DateTime.tryParse(e.location.timestamp)?.toUtc() ?? DateTime.now().toUtc();

      // Emit to app
      _fenceCtl.add(
        GeofenceEvent(
          e.identifier,
          t,
          ts,
          e.location.coords.latitude,
          e.location.coords.longitude,
          e.location.coords.accuracy ?? 9999.0,
        ),
      );
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
  }

  Future<void> _applyMode(SamplingMode mode) async {
    final cfg = _cfg;
    if (cfg == null) return;

    bool useSigChange = false;
    int heartbeatS;
    int distanceM;

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
        // Outside uses hybrid: significant-change OR time-based heartbeats,
        // depending on your threshold.
        final allowSigChange =
            cfg.useSignificantChangeWhenOutside &&
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

    final nowUtc =
        DateTime.tryParse(l.timestamp)?.toUtc() ?? DateTime.now().toUtc();
    final c = l.coords;

    final double lat = c.latitude;
    final double lng = c.longitude;
    final double acc = (c.accuracy ?? 9999.0);

    // Accuracy gate
    if (acc > cfg.accuracyDropM) return;

    // Mode-specific thresholds
    final int rateS = () {
      switch (_mode) {
        case SamplingMode.inside:
          return cfg.rateInsideS;
        case SamplingMode.near:
          return cfg.rateNearS;
        case SamplingMode.outside:
          return cfg.rateOutsideS;
      }
    }();

    final int distM = () {
      switch (_mode) {
        case SamplingMode.inside:
          return cfg.distanceFilterInsideM;
        case SamplingMode.near:
          return cfg.distanceFilterNearM;
        case SamplingMode.outside:
          return cfg.distanceFilterOutsideM;
      }
    }();

    final last = _lastSample;
    final lastTs = _lastEmitTs ?? nowUtc;

    // Distance since last emitted sample
    final double movedM = (last == null)
        ? double.infinity
        : _haversineM(last.lat, last.lng, lat, lng);

    // Time since last emitted sample
    final dtS = nowUtc.difference(lastTs).inSeconds;

    final bool distDue = movedM >= distM;
    final bool timeDue = dtS >= rateS;

    if (!distDue && !timeDue && last != null) {
      if (kDebugMode) {
        debugPrint(
            '[TsbgEngine] skip reason=$reason mode=$_mode moved=${movedM.toStringAsFixed(1)}m<${distM}m dt=${dtS}s<${rateS}s');
      }
      return;
    }

    final sample = LocationSample(
      ts: nowUtc,
      lat: lat,
      lng: lng,
      accuracyM: acc,
      mode: _mode,
      reason: reason,
    );
    _lastSample = sample;
    _lastEmitTs = nowUtc;

    if (kDebugMode) {
      debugPrint(
          '[TsbgEngine] emit reason=$reason mode=$_mode timeDue=$timeDue distDue=$distDue moved=${movedM.toStringAsFixed(1)}m rate=${rateS}s dist=${distM}m acc=${acc}m');
    }

    _locCtl.add(sample);
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
