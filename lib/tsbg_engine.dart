// zbg_location/lib/tsbg_engine.dart
//
// Hybrid emission rule (“whichever comes first”):
//   • Emit on heartbeat at rate_{mode}_s
//   • Emit immediately when movement since last emit ≥ distance_filter_{mode}_m
//
// Per-mode config applied on mode changes.
// Geofence: ENTER/DWELL → inside; EXIT → outside.
// Heartbeat is consumed (getCurrentPosition) to guarantee time-based cadence.
// Emits a breadcrumb stream that higher layers can use for “opportunistic” checks.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

import 'api.dart'; // expects: RuntimeConfig, SamplingMode, GeofenceDef, GeofenceEvent, LocationSample

typedef WriteFn = Future<void> Function(LocationSample sample);
typedef FenceWriteFn = Future<void> Function(GeofenceEvent event);

class TsbgEngine {
  TsbgEngine();

  RuntimeConfig? _cfg;
  SamplingMode _mode = SamplingMode.outside;

  WriteFn? _writeBreadcrumb;
  FenceWriteFn? _writeFenceEvent;

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

  // Subscriptions
  StreamSubscription<fbg.Location>? _locSub;
  StreamSubscription<fbg.HeartbeatEvent>? _heartbeatSub;
  StreamSubscription<fbg.GeofenceEvent>? _geofenceSub;
  StreamSubscription<fbg.EnabledChangeEvent>? _enabledSub;

  // Outbound streams
  final _geofenceCtl = StreamController<GeofenceEvent>.broadcast();
  Stream<GeofenceEvent> get geofenceStream => _geofenceCtl.stream;

  final _breadcrumbCtl = StreamController<LocationSample>.broadcast();
  Stream<LocationSample> get breadcrumbStream => _breadcrumbCtl.stream;

  bool get isStarted => _cfg != null;
  SamplingMode get mode => _mode;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> start({
    required RuntimeConfig config,
    required List<GeofenceDef> fences,
    required WriteFn writeBreadcrumb,
    FenceWriteFn? writeFenceEvent,
    SamplingMode initialMode = SamplingMode.outside,
  }) async {
    _cfg = config;
    _writeBreadcrumb = writeBreadcrumb;
    _writeFenceEvent = writeFenceEvent;
    _fences = fences;
    _mode = initialMode;

    await _configureSdkFirstBoot();
    await _registerFences();
    await _applyMode(_mode);
    _attachListeners();
    await fbg.BackgroundGeolocation.start();
  }

  Future<void> stop() async {
    await _detachListeners();
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
  // Internals
  // ---------------------------------------------------------------------------

  Future<void> _configureSdkFirstBoot() async {
    final c = _cfg!;
    await fbg.BackgroundGeolocation.ready(fbg.Config(
      debug: c.platformDebugLogs,
      logLevel: c.platformDebugLogs
          ? fbg.Config.LOG_LEVEL_VERBOSE
          : fbg.Config.LOG_LEVEL_ERROR,
      startOnBoot: c.platformStartOnBoot,
      stopOnTerminate: c.platformStopOnTerminate,
      preventSuspend: true,        // keep Dart running in background
      pausesLocationUpdatesAutomatically: false,
      reset: false,
    ));
  }

  Future<void> _registerFences() async {
    await fbg.BackgroundGeolocation.removeGeofences();
    for (final g in _fences) {
      await fbg.BackgroundGeolocation.addGeofence(fbg.Geofence(
        identifier: g.id,
        radius: g.radiusM.toDouble(),
        latitude: g.centerLat,
        longitude: g.centerLng,
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
      // Boolean-only behavior: SC outside if enabled; off otherwise.
      useSignificantChangesOnly:
          (m == SamplingMode.outside) ? c.useSignificantChangeOutside : false,
      disableElasticity: true,  // keep heartbeats punctual
      stopTimeout: 2,           // resume quickly from background
    ));

    // Start timing from now if unset (first boot).
    _lastEmitTs ??= DateTime.now().toUtc();
  }

  void _attachListeners() {
    _locSub?.cancel();
    _heartbeatSub?.cancel();
    _geofenceSub?.cancel();
    _enabledSub?.cancel();

    _locSub = fbg.BackgroundGeolocation.onLocation((fbg.Location l) async {
      _lastLocLat = l.coords.latitude;
      _lastLocLng = l.coords.longitude;
      _lastLocTs = _parseIso(l.timestamp);

      // Movement-first: emit if moved enough since last emit.
      if (_shouldEmitForMovement()) {
        await _emitFromSdkLocation(l, source: 'location');
      }
    }, onError: (e) {
      if (kDebugMode) print('[BG] onLocation error: $e');
    });

    _heartbeatSub = fbg.BackgroundGeolocation.onHeartbeat((fbg.HeartbeatEvent hb) async {
      final now = DateTime.now().toUtc();
      if (_shouldEmitForTime(now)) {
        try {
          final l = await fbg.BackgroundGeolocation.getCurrentPosition(
            samples: 1,
            persist: false,
            timeout: 30 * 1000,
          );
          await _emitFromSdkLocation(l, source: 'heartbeat');
        } catch (e) {
          if (kDebugMode) print('[BG] getCurrentPosition() on heartbeat failed: $e');
        }
      }
    });

    _geofenceSub = fbg.BackgroundGeolocation.onGeofence((fbg.GeofenceEvent e) async {
      final evt = GeofenceEvent(
        fenceId: e.identifier,
        type: switch (e.action) {
          'ENTER' => 'ENTER',
          'EXIT' => 'EXIT',
          'DWELL' => 'DWELL',
          _ => e.action ?? 'UNKNOWN',
        },
        ts: DateTime.now().toUtc(),
      );
      _geofenceCtl.add(evt);
      if (_writeFenceEvent != null) {
        await _writeFenceEvent!(evt);
      }

      // Default mode switching
      if (evt.type == 'ENTER' || evt.type == 'DWELL') {
        await setSamplingMode(SamplingMode.inside);
      } else if (evt.type == 'EXIT') {
        await setSamplingMode(SamplingMode.outside);
      }
    });

    _enabledSub = fbg.BackgroundGeolocation.onEnabledChange((e) {
      if (kDebugMode) print('[BG] enabledChange: ${e.enabled}');
    });
  }

  Future<void> _detachListeners() async {
    await _locSub?.cancel();
    await _heartbeatSub?.cancel();
    await _geofenceSub?.cancel();
    await _enabledSub?.cancel();
    _locSub = null;
    _heartbeatSub = null;
    _geofenceSub = null;
    _enabledSub = null;
  }

  // ---------------------------------------------------------------------------
  // Emission rules
  // ---------------------------------------------------------------------------

  bool _shouldEmitForTime(DateTime now) {
    if (_lastEmitTs == null) return true;
    final rateS = switch (_mode) {
      SamplingMode.inside => _cfg!.rateInsideS,
      SamplingMode.near => _cfg!.rateNearS,
      SamplingMode.outside => _cfg!.rateOutsideS,
    };
    final dtMs = now.difference(_lastEmitTs!).inMilliseconds;
    // small slack to avoid double-fire when heartbeat & onLocation arrive together
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

  Future<void> _emitFromSdkLocation(fbg.Location l, {required String source}) async {
    final ts = _parseIso(l.timestamp) ?? DateTime.now().toUtc();
    final lat = l.coords.latitude;
    final lng = l.coords.longitude;
    final acc = l.coords.accuracy?.toDouble() ?? 0.0;

    final s = LocationSample(
      ts: ts,
      lat: lat,
      lng: lng,
      accuracyM: acc,
      source: source,
    );

    // Write + fan-out
    await _writeBreadcrumb?.call(s);
    _breadcrumbCtl.add(s);

    // Reset baselines for both time & movement.
    _lastEmitTs = ts;
    _lastEmitLat = lat;
    _lastEmitLng = lng;
  }

  // ---------------------------------------------------------------------------
  // Utils
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
