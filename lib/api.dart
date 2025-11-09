// api.dart
// COMPLETE UPDATED VERSION — READY TO PASTE
// Only RuntimeConfig and related sections were modified/expanded.
// Other parts preserved unless required for compatibility.

import 'dart:async';

/// ------------------------------------------------------------
/// TYPES & ENUMS
/// ------------------------------------------------------------

/// Zone state used by the engine
enum SamplingMode {
  outside,
  near,
  inside,
}

/// Types of geofence events
enum GeofenceEventType {
  enter,
  dwell,
  exit,
}

/// A geofence definition
class GeofenceDef {
  final String ident;
  final double? lat;
  final double? lng;
  final double? radiusM;
  final String type;

  GeofenceDef({
    required this.ident,
    required this.type,
    this.lat,
    this.lng,
    this.radiusM,
  });
}

/// A geofence event emitted by the engine
class GeofenceEvent {
  final String fenceId;
  final GeofenceEventType type;
  final DateTime ts;

  GeofenceEvent(this.fenceId, this.type, this.ts);
}

/// A location sample emitted by the engine
class LocationSample {
  final double lat;
  final double lng;
  final double accuracyM;
  final DateTime ts;

  LocationSample(this.lat, this.lng, this.accuracyM, this.ts);
}

/// ------------------------------------------------------------
/// RUNTIME CONFIG — FULL EXPANDED VERSION (Option B)
/// ------------------------------------------------------------

/// This class mirrors your Firestore config in full.
/// All values used by tsbg_engine.dart are declared here.
/// Any new geolocation behavior must be expressed here.
class RuntimeConfig {
  // Core enable flag
  final bool enabled;

  /// Required dwell duration before a DWELL event fires
  final int dwellRequiredS;

  /// Sampling rates (seconds) applied depending on zone state
  final int rateOutsideS;
  final int rateNearS;
  final int rateInsideS;

  /// Maximum accuracy allowed; points above this threshold are ignored
  final double accuracyDropM;

  /// Flags controlling background behavior
  final bool startOnBoot;
  final bool stopOnTerminate;

  /// Apply OS-level significant-change behavior when OUTSIDE geofences?
  /// Hybrid rule: may be superseded by threshold logic.
  final bool useSignificantChangeWhenOutside;

  /// NEW — threshold after which significant-change outside is allowed
  /// (only applies when useSignificantChangeWhenOutside = true)
  final int significantChangeOutsideThresholdS;

  /// NEW — distance filter per zone-state (meters)
  final int distanceFilterInsideM;
  final int distanceFilterNearM;
  final int distanceFilterOutsideM;

  /// Construct full runtime config
  const RuntimeConfig({
    required this.enabled,
    required this.dwellRequiredS,
    required this.rateOutsideS,
    required this.rateNearS,
    required this.rateInsideS,
    required this.accuracyDropM,
    required this.distanceFilterInsideM,
    required this.distanceFilterNearM,
    required this.distanceFilterOutsideM,
    required this.significantChangeOutsideThresholdS,
    this.startOnBoot = true,
    this.stopOnTerminate = false,
    this.useSignificantChangeWhenOutside = true,
  });

  /// Factory loader from Firestore or JSON blob
  /// Provides default values to prevent null crashes during rollout
  factory RuntimeConfig.fromMap(Map<String, dynamic> m) {
    return RuntimeConfig(
      enabled: m['enabled'] ?? true,
      dwellRequiredS: m['dwell_required_s'] ?? 60,
      rateOutsideS: m['rate_outside_zone_s'] ?? 60,
      rateNearS: m['rate_near_zone_s'] ?? 60,
      rateInsideS: m['rate_inside_zone_s'] ?? 60,
      accuracyDropM: (m['accuracy_drop_m'] ?? 50).toDouble(),

      // NEW distance filters with defaults for safe operation
      distanceFilterInsideM: m['distance_filter_inside_m'] ?? 10,
      distanceFilterNearM: m['distance_filter_near_m'] ?? 20,
      distanceFilterOutsideM: m['distance_filter_outside_m'] ?? 100,

      // NEW hybrid threshold
      significantChangeOutsideThresholdS:
          m['significant_change_outside_threshold_s'] ?? 300,

      // Existing flags
      startOnBoot: m['start_on_boot'] ?? true,
      stopOnTerminate: m['stop_on_terminate'] ?? false,
      useSignificantChangeWhenOutside:
          m['use_significant_change_outside'] ?? true,
    );
  }
}

/// ------------------------------------------------------------
/// API returned to FlutterFlow
/// ------------------------------------------------------------

/// Returned by the engine — metadata about user presence in geofences
class UserZoneStatus {
  final bool insideAny;
  final String? fenceId;
  final bool nearAny;

  UserZoneStatus({
    required this.insideAny,
    required this.nearAny,
    this.fenceId,
  });
}

/// A façade object consumed by FlutterFlow custom actions
class ZbgAPI {
  /// These controllers funnel events from the engine
  final StreamController<LocationSample> _locCtl;
  final StreamController<GeofenceEvent> _fenceCtl;

  /// Latest status
  UserZoneStatus? _status;

  const ZbgAPI(
      this._locCtl,
      this._fenceCtl,
      );

  Stream<LocationSample> get locationStream => _locCtl.stream;
  Stream<GeofenceEvent> get geofenceStream => _fenceCtl.stream;

  UserZoneStatus? get status => _status;

  void updateStatus(UserZoneStatus s) {
    _status = s;
  }
}

