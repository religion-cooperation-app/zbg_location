// lib/api.dart

enum SamplingMode { outside, near, inside }

class LocationSample {
  final double lat;
  final double lng;
  final double accuracyM;
  final DateTime ts;
  const LocationSample(this.lat, this.lng, this.accuracyM, this.ts);
}

enum GeofenceEventType { enter, exit, dwell }

class GeofenceEvent {
  final String id;
  final GeofenceEventType type;
  final DateTime ts;
  const GeofenceEvent(this.id, this.type, this.ts);
}

/// Mirrors your Firestore runtime config (kept minimal for v1).
class RuntimeConfig {
  final bool enabled;
  final int dwellRequiredS;
  final int rateOutsideS;
  final int rateNearS;
  final int rateInsideS;
  final double accuracyDropM;

  /// Android: keep service alive after user swipes app away.
  /// iOS: lets OS relaunch on region/sig-change events.
  final bool startOnBoot;
  final bool stopOnTerminate;

  /// iOS-friendly battery saver when outside zones.
  final bool useSignificantChangeWhenOutside;

  const RuntimeConfig({
    required this.enabled,
    required this.dwellRequiredS,
    required this.rateOutsideS,
    required this.rateNearS,
    required this.rateInsideS,
    required this.accuracyDropM,
    this.startOnBoot = true,
    this.stopOnTerminate = false,
    this.useSignificantChangeWhenOutside = true,
  });
}

class GeofenceDef {
  final String id;
  final String type; // "circle" | "polygon"
  final double? lat;
  final double? lng;
  final double? radiusM;
  final List<List<double>>? polygon; // [[lat,lng], ...]

  GeofenceDef.circle({
    required this.id,
    required this.lat,
    required this.lng,
    required this.radiusM,
  })  : type = "circle",
        polygon = null;

  GeofenceDef.polygon({
    required this.id,
    required this.polygon,
  })  : type = "polygon",
        lat = null,
        lng = null,
        radiusM = null;
}

abstract class LocationEngine {
  Future<void> start();
  Future<void> stop();
  Future<void> setConfig(RuntimeConfig cfg);
  Future<void> addGeofences(List<GeofenceDef> defs);
  Future<void> removeGeofence(String id);

  Stream<LocationSample> onLocation();
  Stream<GeofenceEvent> onGeofence();

  Future<void> setSamplingMode(SamplingMode mode);
}
