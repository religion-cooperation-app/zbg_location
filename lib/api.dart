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

  /// Seconds of dwell at the time of this event.
  /// Set on DWELL events (initial threshold + milestones) and EXIT events
  /// (total time spent inside since ENTER).
  final int? dwellSeconds;

  GeofenceEvent(this.fenceId, this.type, this.ts, {this.dwellSeconds});
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

  /// After the initial DWELL, emit additional DWELL events every N seconds
  /// of continued presence. 0 = disabled (no repeat milestones).
  final int dwellEveryS;

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

  /// Minutes before FBG stops GPS engine after no motion detected.
  /// After this, heartbeat (persist:true) keeps breadcrumbs flowing.
  final int stopTimeoutMinutes;

  /// Native HTTP batch upload settings (transistorsoft batchSync).
  /// When true, fixes are buffered in SQLite and sent in a single HTTP POST
  /// when [maxBatchSize] fixes accumulate. Reduces HTTP request volume at scale.
  final bool batchSync;
  final int maxBatchSize;

  /// When true, only emit breadcrumbs while inside a geofence.
  /// Tracking engine calls startGeofences() instead of start().
  final bool geofenceOnlyMode;

  /// iOS only — allow preventSuspend to engage while inside a zone.
  /// When true (default), preventSuspend: true is set in inside mode so
  /// heartbeat breadcrumbs fire reliably while stationary. Set false via
  /// Firestore to disable preventSuspend entirely as a kill switch.
  final bool preventSuspendInsideZone;

  /// API key for the zbgIngest Cloud Function, fetched from appConfig/runtime.
  /// Null means the field is absent from Firestore — engine will throw on start.
  final String? ingestApiKey;

  /// Outer near-zone radius added to each geofence's radius for NEAR detection.
  /// Sourced from appConfig/runtime geofenceDetect.near_zone_radius_m (default 100m).
  final int nearZoneRadiusM;

  /// Minimum number of SQLite records to accumulate before FBG fires an upload.
  /// 0 = disabled (sync on every record). Sourced from appConfig/runtime
  /// platform.auto_sync_threshold. Reduces function invocations and radio
  /// wake-ups at the cost of a short upload delay.
  final int autoSyncThreshold;

  /// ---- Huawei reliability profile (laventure_huawei) ----
  /// Master switch for the Huawei-specific reliability profile. Only takes
  /// effect on devices whose manufacturer reports Huawei/Honor — other OEMs
  /// are unaffected regardless of this flag. Remotely controllable via
  /// appConfig/runtime platform.huawei_reliability_mode so the profile can be
  /// enabled/disabled without shipping a new APK.
  final bool huaweiReliabilityMode;

  /// Keep FBG continuously enabled on Huawei (start() instead of the daily
  /// startSchedule() window). Removes the fragile 05:00 foreground-service
  /// restart requirement. platform.huawei_keep_fbg_continuous.
  final bool huaweiKeepFbgContinuous;

  /// Force useSignificantChangesOnly:false in outside mode on Huawei.
  /// Significant-change tracking depends on passive OS wakeups, which are
  /// unreliable on aggressively managed EMUI/HarmonyOS devices.
  /// platform.huawei_disable_significant_changes.
  final bool huaweiDisableSignificantChanges;

  /// Call changePace(true) at activation/recovery points (startup, push wake,
  /// app foreground with stale tracking, geofence ENTER/EXIT, connectivity
  /// change, boot). platform.huawei_force_moving_on_recovery.
  final bool huaweiForceMovingOnRecovery;

  /// Enable push-wake recovery handling (Huawei Push Kit primary, FCM
  /// fallback). platform.huawei_push_recovery_enabled.
  final bool huaweiPushRecoveryEnabled;

  /// Requested cadence for server-side Huawei geo-wake pushes, in minutes.
  /// Advisory for the sender; Huawei may delay or suppress pushes.
  /// platform.huawei_push_location_interval_minutes.
  final int huaweiPushLocationIntervalMinutes;

  /// Construct full runtime config
  const RuntimeConfig({
    required this.enabled,
    required this.dwellRequiredS,
    this.dwellEveryS = 0,
    required this.rateOutsideS,
    required this.rateNearS,
    required this.rateInsideS,
    required this.accuracyDropM,
    required this.distanceFilterInsideM,
    required this.distanceFilterNearM,
    required this.distanceFilterOutsideM,
    required this.significantChangeOutsideThresholdS,
    required this.stopTimeoutMinutes,
    this.startOnBoot = true,
    this.stopOnTerminate = false,
    this.useSignificantChangeWhenOutside = true,
    this.batchSync = true,
    this.maxBatchSize = 8,
    this.geofenceOnlyMode = false,
    this.preventSuspendInsideZone = true,
    this.ingestApiKey,
    this.nearZoneRadiusM = 100,
    this.autoSyncThreshold = 0,
    this.huaweiReliabilityMode = false,
    this.huaweiKeepFbgContinuous = true,
    this.huaweiDisableSignificantChanges = true,
    this.huaweiForceMovingOnRecovery = true,
    this.huaweiPushRecoveryEnabled = true,
    this.huaweiPushLocationIntervalMinutes = 7,
  });

  /// Factory loader from Firestore or JSON blob
  /// Provides default values to prevent null crashes during rollout
  factory RuntimeConfig.fromMap(Map<String, dynamic> m) {
    return RuntimeConfig(
      enabled: m['enabled'] ?? true,
      dwellRequiredS: m['dwell_required_s'] ?? 60,
      dwellEveryS: m['dwell_every_s'] ?? 0,
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

      // Stop timeout — how long before FBG stops GPS after no motion
      stopTimeoutMinutes: m['stop_timeout_minutes'] ?? 60,

      // Existing flags
      startOnBoot: m['start_on_boot'] ?? true,
      stopOnTerminate: m['stop_on_terminate'] ?? false,
      useSignificantChangeWhenOutside:
          m['use_significant_change_outside'] ?? true,

      // Batch upload settings
      batchSync: m['batch_sync'] ?? true,
      maxBatchSize: m['max_batch_size'] ?? 8,

      // Geofence-only mode — default false so old builds are unaffected
      geofenceOnlyMode: m['platform']?['geofence_only_mode'] ?? false,
      // preventSuspend kill switch — default true so existing behavior is preserved
      preventSuspendInsideZone: m['platform']?['prevent_suspend_inside_zone'] ?? true,

      // API key sourced from Firestore — null if field absent
      ingestApiKey: m['ingest_api_key'] as String?,

      // Near-zone radius sourced from geofenceDetect sub-map
      nearZoneRadiusM: (m['geofenceDetect']?['near_zone_radius_m'] as num?)?.toInt() ?? 100,

      // Accumulate this many records before syncing; 0 = sync immediately
      autoSyncThreshold: (m['platform']?['auto_sync_threshold'] as num?)?.toInt() ?? 0,

      // Huawei reliability profile — all remotely controllable; master switch
      // defaults false so non-experiment builds behave identically.
      huaweiReliabilityMode:
          m['platform']?['huawei_reliability_mode'] ?? false,
      huaweiKeepFbgContinuous:
          m['platform']?['huawei_keep_fbg_continuous'] ?? true,
      huaweiDisableSignificantChanges:
          m['platform']?['huawei_disable_significant_changes'] ?? true,
      huaweiForceMovingOnRecovery:
          m['platform']?['huawei_force_moving_on_recovery'] ?? true,
      huaweiPushRecoveryEnabled:
          m['platform']?['huawei_push_recovery_enabled'] ?? true,
      huaweiPushLocationIntervalMinutes:
          (m['platform']?['huawei_push_location_interval_minutes'] as num?)
                  ?.toInt() ??
              7,
    );
  }
}


