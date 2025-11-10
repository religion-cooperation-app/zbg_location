// zbg_location/lib/tsbg_engine.dart
//
// Emits breadcrumbs with a "whichever comes first" rule:
//   • time-based (heartbeat) at rate_{mode}_s
//   • movement-based when Δdistance ≥ distance_filter_{mode}_m
//
// Correct per-mode switching is handled by caller via setSamplingMode(...)
// (GeoBootstrap sets outside/near/inside).
//
// No writer dependency here — app-level code can listen to breadcrumbStream.
//
// Compatible with your api.dart (RuntimeConfig, GeofenceDef, GeofenceEvent, LocationSample).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'api.dart';

class TsbgEngine {
  TsbgEngine();

  RuntimeConfig? _cfg;
  SamplingMode _mode = SamplingMode.outside;

  // Baselines reset on every emission.
  DateTime? _lastEmitTs;
  double? _lastEmitLat;
  double? _lastEmitLng;

  // Latest raw SDK location (for movement check).
  double? _lastLocLat;
  double? _lastLocLng;
  DateTime? _lastLocTs;

  // Geofences
  List<GeofenceDef> _fences = const [];

  // Outbound streams
  final _geofenceCtl = StreamController<GeofenceEvent>.broadcast();
  Stream<GeofenceEvent> get geofenceStream => _geofenceCtl.stream;

  final _breadcrumbCtl = StreamController<LocationSample>.broadcast();
  Stream<LocationSample> get breadcrumbStream => _breadcrumbCtl.stream;

  bool get isStarted => _cfg != null;
  SamplingMode get mode => _mode;

  Future<void> start({
    required RuntimeConfig config,
    required List<GeofenceDef> fences,
    SamplingMode initialMode = SamplingMode.outside,
  }) async {
    _cfg = config;
    _fences = fences;
    _mode = initialMode;

    await _configureSdkFirstBoot();
    await _registerFences();
    await _applyMode(_mode);
    _attachListeners();
    await fbg.BackgroundGeolocation.start();
  }

  Future<void> stop() async {
    // This plugin exposes removeListeners() rather than returning StreamSubscriptions.
    fbg.BackgroundGeolocation.removeListeners();
    await fbg.BackgroundGeolocation.stop();

    await _breadcrumbCtl.close();
    await _geofenceCtl.close();

    _cfg = null;
  }

  Future<void> setSamplingMode(SamplingMode m) async {
    if (_mode == m) return;
    _mode = m;
    await _applyMode(m);
  }

  // ---------------------------------------------------------------------------

  Future<void> _configureSdkFirstBoot() async {
    // Use conservative defaults; your RuntimeConfig does not expose these toggles directly.
    await fbg.BackgroundGeolocation.ready(fbg.Config(
      debug: false,
      logLevel: fbg.Config.LOG_LEVEL_ERROR,
      startOnBoot: _cfg!.startOnBoot,
      stopOnTerminate: _cfg!.stopOnTerminate,
      preventSuspend: true,
      pausesLocationUpdatesAutomatically: false,
      reset: false,
    ));
  }

  Future<void> _registerFences() async {
    await fbg.BackgroundGeolocation.removeGeofences();
    for (final g in _fences) {
      // Defensive for nullable lat/lng/radiusM in your GeofenceDef.
      if (g.lat == null || g.lng == null || g.radiusM == null) continue;
      await fbg.BackgroundGeolocation.addGeofence(fbg.Geofence(
        identifier: g.ident,
        radius: (g.radiusM!).toDouble(),
        latitude: g.lat!,
        longitude: g.lng!,
        notifyOnEntry: true,
        notifyOnExit: true,
        notifyOnDwell: true,
        loiteringDelay: (_cfg?.dwellRequiredS ?? 60) * 1000, // ms
      ));
    }
  }

  Future<void> _applyMode(SamplingMode m) async {
    final c = _cfg!;
    final heartbeatS = switch (m) {
      SamplingMode.inside => c.rateInsideS,
      SamplingMode.near => c.rateNearS,
      SamplingMode.outside => c.rateOutsideS,
    };
    final distanceM = switch (m) {
      SamplingMode.inside => c.distanceFilterInsideM,
      SamplingMode.near => c.distanceFilterNearM,
      SamplingMode.outside => c.distanceFilterOutsideM,
    };

    await fbg.BackgroundGeolocation.setConfig(fbg.Config(
      heartbeatInterval: heartbeatS,
      distanceFilter: distanceM.toDouble(),
      // Boolean-only significant-change outside per your RuntimeConfig:
      useSignificantChangesOnly:
          (m == SamplingMode.outside) ? c.useSignificantChangeWhenOutside : false,
      disableElasticity: true,
      stopTimeout: 2,
    ));

    _lastEmitTs ??= DateTime.now().toUtc();
  }

  void _attachListeners() {
    // onLocation(success, error) → returns void in your plugin version
    fbg.BackgroundGeolocation.onLocation((fbg.Location l) async {
      _lastLocLat = l.coords.latitude;
      _lastLocLng = l.coords.longitude;
      _lastLocTs = _parseIso(l.timestamp);

      if (_shouldEmitForMovement()) {
        await _emitFromSdkLocation(l);
      }
    }, (e) {
      if (kDebugMode) print('[BG] onLocation error: $e');
    });

    // onHeartbeat → returns void
    fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent hb) async {
      final now = DateTime.now().toUtc();
      if (_shouldEmitForTime(now)) {
        try {
          final l = await fbg.BackgroundGeolocation.getCurrentPosition(
            samples: 1,
            persist: false,
            timeout: 30 * 1000,
          );
          await _emitFromSdkLocation(l);
        } catch (e) {
          if (kDebugMode) print('[BG] getCurrentPosition on heartbeat failed: $e');
        }
      }
    });

    // onGeofence → returns void; map to your GeofenceEvent (with enum)
    fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) async {
      final typ = switch (e.action) {
        'ENTER' => GeofenceEventType.enter,
        'DWELL' => GeofenceEventType.dwell,
        'EXIT' => GeofenceEventType.exit,
        _ => GeofenceEventType.enter,
      };
      final evt = GeofenceEvent(e.identifier, typ, DateTime.now().toUtc());
      _geofenceCtl.add(evt);
    });

    // onEnabledChange(bool enabled) → returns void
    fbg.BackgroundGeolocation.onEnabledChange((bool enabled) {
      if (kDebugMode) print('[BG] enabledChange: $enabled');
    });
  }

  // ---------------------------------------------------------------------------

  bool _shouldEmitForTime(DateTime now) {
    if (_lastEmitTs == null) return true;
    final rateS = switch (_mode) {
      SamplingMode.inside => _cfg!.rateInsideS,
      SamplingMode.near => _cfg!.rateNearS,
      SamplingMode.outside => _cfg!.rateOutsideS,
    };
    final dtMs = now.difference(_lastEmitTs!).inMilliseconds;
    return dtMs >= (rateS * 1000 * 0.95);
  }

  bool _shouldEmitForMovement() {
    if (_lastEmitLat == null ||
        _lastEmitLng == null ||
        _lastLocLat == null ||
        _lastLocLng == null) {
      return true; // first sample
    }
    final dist = _haversineM(
      _lastEmitLat!, _lastEmitLng!, _lastLocLat!, _lastLocLng!,
    );
    final gateM = switch (_mode) {
      SamplingMode.inside => _cfg!.distanceFilterInsideM,
      SamplingMode.near => _cfg!.distanceFilterNearM,
      SamplingMode.outside => _cfg!.distanceFilterOutsideM,
    };
    return dist >= gateM;
  }

  Future<void> _emitFromSdkLocation(fbg.Location l) async {
    final ts = _parseIso(l.timestamp) ?? DateTime.now().toUtc();
    final lat = l.coords.latitude;
    final lng = l.coords.longitude;
    final acc = l.coords.accuracy?.toDouble() ?? 0.0;

    final s = LocationSample(lat, lng, acc, ts);
    _breadcrumbCtl.add(s);

    // Reset baselines
    _lastEmitTs = ts;
    _lastEmitLat = lat;
    _lastEmitLng = lng;
  }

  // ---------------------------------------------------------------------------

  DateTime? _parseIso(String? iso) {
    if (iso == null) return null;
    try {
      return DateTime.parse(iso).toUtc();
    } catch (_) {
      return null;
    }
  }

  double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // meters
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
