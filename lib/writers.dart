// lib/writers.dart
//
// Step 1: STUB writers (no backend).
// Step 2 will provide real Firestore implementations.
// Keep this API stable so FlutterFlow actions can depend on it.

/// Canonical actions for geofence events
enum FenceAction { enter, exit, dwell }

String fenceActionToString(FenceAction a) {
  switch (a) {
    case FenceAction.enter:
      return 'ENTER';
    case FenceAction.exit:
      return 'EXIT';
    case FenceAction.dwell:
      return 'DWELL';
  }
}

/// Breadcrumb writer interface: one ping at a time.
abstract class BreadcrumbWriter {
  Future<void> writeBreadcrumb({
    required String uid,
    required String regionId,
    String? zoneId, // when inside a geofence
    required DateTime tsUtc,
    required double lat,
    required double lng,
    required double accuracyM,
    required String geohashP7,
    String? geohashP8,
    bool? insideZone, // null = unknown
    String source = 'fbg', // e.g., fbg, ios-scls, android-fg
  });
}

/// Geofence event writer interface (ENTER/EXIT/DWELL).
abstract class GeofenceEventWriter {
  Future<void> writeGeofenceEvent({
    required String uid,
    required String regionId,
    required String geofenceId,
    required FenceAction action,
    required DateTime tsUtc,
  });
}

/// ---- Step 1: No-op console writers (for sanity checks only) ----
/// Replace these with FirestoreWriter in Step 2.

class ConsoleBreadcrumbWriter implements BreadcrumbWriter {
  @override
  Future<void> writeBreadcrumb({
    required String uid,
    required String regionId,
    String? zoneId,
    required DateTime tsUtc,
    required double lat,
    required double lng,
    required double accuracyM,
    required String geohashP7,
    String? geohashP8,
    bool? insideZone,
    String source = 'fbg',
  }) async {
    // Pretend to persist by printing (keeps Step 1 testable).
    // ignore: avoid_print
    print('[BREADCRUMB] uid=$uid region=$regionId zone=${zoneId ?? "-"} '
        'ts=$tsUtc lat=$lat lng=$lng acc=$accuracyM p7=$geohashP7 '
        'p8=${geohashP8 ?? "-"} inside=${insideZone ?? false} src=$source');
  }
}

class ConsoleGeofenceEventWriter implements GeofenceEventWriter {
  @override
  Future<void> writeGeofenceEvent({
    required String uid,
    required String regionId,
    required String geofenceId,
    required FenceAction action,
    required DateTime tsUtc,
  }) async {
    // ignore: avoid_print
    print('[FENCE] uid=$uid region=$regionId geofence=$geofenceId '
        'action=${fenceActionToString(action)} ts=$tsUtc');
  }
}

/// ---- Step 2: Firestore writer (to be implemented later) ----
/// Example API surface (keep names stable):
///
/// class FirestoreWriter implements BreadcrumbWriter, GeofenceEventWriter {
///   final FirebaseFirestore db; // pass in instance
///   FirestoreWriter(this.db);
///
///   @override
///   Future<void> writeBreadcrumb({...}) async { /* TODO */ }
///
///   @override
///   Future<void> writeGeofenceEvent({...}) async { /* TODO */ }
/// }
