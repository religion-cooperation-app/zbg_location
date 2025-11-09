// zbg_location/lib/tsbg_engine.dart
// DROP-IN REPLACEMENT — applies hybrid significant-change rule,
// per-mode distance filters, SDK timestamps, and dwell alignment.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'api.dart'; // RuntimeConfig, SamplingMode, GeofenceDef, GeofenceEvent, LocationSample

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

  /// --------------------------------------------
  /// Public API
  /// --------------------------------------------

  Future<void> setConfig(RuntimeConfig cfg) async {
    _cfg = cfg;

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
      if (d.type == 'circle' && d.lat != null && d.lng != null && d.radiusM != null) {
        await fbg.BackgroundGeolocation.addGeofence(
          fbg.Geofence(
            identifier: d.ident,
            latitude: d.lat!,
            longitude: d.lng!,
            radius: d.radiusM!,
            notifyOnEntry: true,
            notifyOnExit: true,
            notifyOnDwell: true,
            // Align SDK dwell to your app-config dwell_required_s
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
    // LOCATION
    fbg.BackgroundGeolocation.onLocation((fbg.Location l) async {
      // Use SDK timestamp for truth (not DateTime.now()).
      final ts = DateTime.tryParse(l.timestamp)?.toUtc() ?? DateTime.now().toUtc();
      final c = l.coords;
      _locCtl.add(LocationSample(
        c.latitude,
        c.longitude,
        c.accuracy,
        ts,
      ));

      // Optional: promote to NEAR when close to any fence (if not already inside).
      if (_mode != SamplingMode.inside) {
        final near = _isNearAnyFence(c.latitude, c.longitude);
        if (near && _mode != SamplingMode.near) {
          await _applyMode(SamplingMode.near);
        } else if (!near && _mode == SamplingMode.near) {
          await _applyMode(SamplingMode.outside);
        }
      }
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
      final ts = DateTime.tryParse(e.location.timestamp)?.toUtc() ?? DateTime.now().toUtc();

      // Emit to app
      _fenceCtl.add(GeofenceEvent(e.identifier, t, ts));
    });

    // (Optional) Motion-change / provider-change handlers could be added here.
  }

  Future<void> _applyMode(SamplingMode mode) async {
    final cfg = _cfg;
    if (cfg == null) return;

    int heartbeatS;
    int distanceM;
    bool useSigChange;

    switch (mode) {
      case SamplingMode.inside:
        // Cadence guaranteed inside.
        heartbeatS = cfg.rateInsideS;
        distanceM = cfg.distanceFilterInsideM;
        useSigChange = false;
        break;

      case SamplingMode.near:
        // Cadence guaranteed near.
        heartbeatS = cfg.rateNearS;
        distanceM = cfg.distanceFilterNearM;
        useSigChange = false;
        break;

      case SamplingMode.outside:
        // Hybrid rule: allow significant-change only if BOTH:
        //  (1) config flag permits it, and
        //  (2) outside rate >= threshold
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
        heartbeatInterval: heartbeatS,
      ),
    );

    if (kDebugMode) {
      debugPrint(
          '[TsbgEngine] applyMode=$mode sc=$useSigChange hb=${heartbeatS}s df=${distanceM}m');
    }

    _mode = mode;
  }

  bool _isNearAnyFence(double lat, double lng) {
    // Small buffer around each circular fence radius for "near".
    // You can make this configurable later if desired.
    const marginM = 25;
    for (final d in _defs) {
      if (d.type == 'circle' && d.lat != null && d.lng != null && d.radiusM != null) {
        final dist = _haversineMeters(lat, lng, d.lat!, d.lng!);
        if (dist <= d.radiusM! + marginM) {
          return true;
        }
      }
    }
    return false;
  }

  /// Haversine distance in meters
  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius (m)
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
}
