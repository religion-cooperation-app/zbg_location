/// lib/writers.dart
/// Purpose:
/// - Build validated Firestore document maps for breadcrumbs & geofence events
/// - Keep the package pure Dart (no cloud_firestore dependency)
/// - Defer the actual write to an injected function so apps decide how to write
///
/// How to use from an app:
///   final writer = FirestoreWriter(uid: currentUserId, writeFn: firestoreWriteAdapter);
///   await writer.writeBreadcrumb(...);

typedef WriteFn = Future<String> Function(
  String collectionPath,
  Map<String, dynamic> data, {
  String? fixedId,
});

class FirestoreWriterConfig {
  final String breadcrumbsCol;
  final String geofenceEventsCol;

  const FirestoreWriterConfig({
    this.breadcrumbsCol = 'breadcrumbs',
    this.geofenceEventsCol = 'geofence_events',
  });
}

class FirestoreWriter {
  FirestoreWriter({
    required this.uid,
    required this.writeFn,
    this.config = const FirestoreWriterConfig(),
  });

  /// Must equal the signed-in user's UID when called from a client app.
  final String uid;

  /// App-provided function that actually writes to your backend (e.g., cloud_firestore).
  final WriteFn writeFn;

  final FirestoreWriterConfig config;

  /// Create a breadcrumb document (validating fields to match your Security Rules).
  Future<String> writeBreadcrumb({
    required String regionId,
    required String tsIso,         // ISO-8601 UTC string recommended
    required double lat,
    required double lng,
    required double accuracyM,
    required String geohashP7,
    String? geohashP8,
    String? zoneId,
    bool? insideZone,
    String source = 'app',
    Map<String, dynamic>? extra,   // room for future fields
    String? fixedId,               // set to produce a fixed doc id (useful in tests)
  }) async {
    final doc = _buildBreadcrumb(
      regionId: regionId,
      tsIso: tsIso,
      lat: lat,
      lng: lng,
      accuracyM: accuracyM,
      geohashP7: geohashP7,
      geohashP8: geohashP8,
      zoneId: zoneId,
      insideZone: insideZone,
      source: source,
      extra: extra,
    );
    _assertBreadcrumbShape(doc);
    return await writeFn(config.breadcrumbsCol, doc, fixedId: fixedId);
  }

  /// Create a geofence event (ENTER/DWELL/EXIT). Separate collection by default.
  Future<String> writeGeofenceEvent({
    required String regionId,
    required String event,   // 'ENTER' | 'DWELL' | 'EXIT'
    required String tsIso,
    String? zoneId,
    Map<String, dynamic>? extra,
    String? fixedId,
  }) async {
    _assertString(event, 'event');
    final doc = _buildGeofenceEvent(
      regionId: regionId,
      event: event,
      tsIso: tsIso,
      zoneId: zoneId,
      extra: extra,
    );
    return await writeFn(config.geofenceEventsCol, doc, fixedId: fixedId);
  }

  // ----------------- builders -----------------

  Map<String, dynamic> _buildBreadcrumb({
    required String regionId,
    required String tsIso,
    required double lat,
    required double lng,
    required double accuracyM,
    required String geohashP7,
    String? geohashP8,
    String? zoneId,
    bool? insideZone,
    String source = 'app',
    Map<String, dynamic>? extra,
  }) {
    final m = <String, dynamic>{
      'uid': uid,
      'regionId': regionId,
      'ts_iso': tsIso,
      'lat': lat,
      'lng': lng,
      'accuracy_m': accuracyM,
      'geohash_p7': geohashP7,
      'source': source,
    };
    if (geohashP8 != null) m['geohash_p8'] = geohashP8;
    if (zoneId != null) m['zoneId'] = zoneId;
    if (insideZone != null) m['inside_zone'] = insideZone;
    if (extra != null) m.addAll(extra);
    return m;
  }

  Map<String, dynamic> _buildGeofenceEvent({
    required String regionId,
    required String event,
    required String tsIso,
    String? zoneId,
    Map<String, dynamic>? extra,
  }) {
    final m = <String, dynamic>{
      'uid': uid,
      'regionId': regionId,
      'event': event,
      'ts_iso': tsIso,
    };
    if (zoneId != null) m['zoneId'] = zoneId;
    if (extra != null) m.addAll(extra);
    return m;
  }

  // ----------------- validators (mirror your Firestore Rules) -----------------

  void _assertBreadcrumbShape(Map<String, dynamic> d) {
    _assertString(d['uid'], 'uid');
    _assertString(d['regionId'], 'regionId');
    _assertString(d['ts_iso'], 'ts_iso');
    _assertNumber(d['lat'], 'lat', min: -90, max: 90);
    _assertNumber(d['lng'], 'lng', min: -180, max: 180);
    _assertNumber(d['accuracy_m'], 'accuracy_m');
    _assertString(d['geohash_p7'], 'geohash_p7');

    if (d.containsKey('geohash_p8')) _assertString(d['geohash_p8'], 'geohash_p8');
    if (d.containsKey('zoneId')) _assertString(d['zoneId'], 'zoneId');
    if (d.containsKey('inside_zone')) _assertBool(d['inside_zone'], 'inside_zone');
    if (d.containsKey('source')) _assertString(d['source'], 'source');
  }

  void _assertString(Object? v, String name) {
    if (v is! String || v.isEmpty) {
      throw ArgumentError('Field "$name" must be a non-empty String.');
    }
  }

  void _assertNumber(Object? v, String name, {double? min, double? max}) {
    if (v is! num) throw ArgumentError('Field "$name" must be a number.');
    if (min != null && v < min) {
      throw ArgumentError('Field "$name" = $v is < min $min.');
    }
    if (max != null && v > max) {
      throw ArgumentError('Field "$name" = $v is > max $max.');
    }
  }

  void _assertBool(Object? v, String name) {
    if (v is! bool) throw ArgumentError('Field "$name" must be a bool.');
    }
}
