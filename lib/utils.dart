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

