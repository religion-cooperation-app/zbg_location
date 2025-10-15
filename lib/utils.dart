// lib/utils.dart
import 'dart:math' as math;

double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const R = 6371000.0; // meters
  double toRad(double d) => d * math.pi / 180.0;
  final dLat = toRad(lat2 - lat1);
  final dLng = toRad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(toRad(lat1)) *
          math.cos(toRad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * R * math.asin(math.sqrt(a));
}

/// Basic ray-casting point-in-polygon.
/// polygon is [[lat,lng], ...]
bool pointInPolygon(double lat, double lng, List<List<double>> polygon) {
  bool inside = false;
  for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i][1], yi = polygon[i][0];
    final xj = polygon[j][1], yj = polygon[j][0];
    final intersect = ((yi > lat) != (yj > lat)) &&
        (lng < (xj - xi) * (lat - yi) / ((yj - yi) + 1e-12) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}
