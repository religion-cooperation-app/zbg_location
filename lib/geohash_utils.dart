// lib/geohash_utils.dart
//
// Minimal, dependency-free geohash encoder + neighbors for p7/p8 use.
// p7 ~150m cells; p8 ~38m (lon) x ~19m (lat) near equator.

const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
const _neighbor = {
  'n': ['p0r21436x8zb9dcf5h7kjnmqesgutwvy', 'bc01fg45238967deuvhjyznpkmstqrwx'],
  's': ['14365h7k9dcfesgujnmqp0r2twvyx8zb', '238967debc01fg45kmstqrwxuvhjyznp'],
  'e': ['bc01fg45238967deuvhjyznpkmstqrwx', 'p0r21436x8zb9dcf5h7kjnmqesgutwvy'],
  'w': ['238967debc01fg45kmstqrwxuvhjyznp', '14365h7k9dcfesgujnmqp0r2twvyx8zb'],
};
const _border = {
  'n': ['prxz', 'bcfguvyz'],
  's': ['028b', '0145hjnp'],
  'e': ['bcfguvyz', 'prxz'],
  'w': ['0145hjnp', '028b'],
};

String geohashEncode(double lat, double lng, int precision) {
  assert(precision > 0 && precision <= 12);
  var latMin = -90.0, latMax = 90.0;
  var lngMin = -180.0, lngMax = 180.0;

  var ch = 0;
  var bit = 0;
  var even = true;
  final buffer = StringBuffer();

  while (buffer.length < precision) {
    if (even) {
      final mid = (lngMin + lngMax) / 2;
      if (lng >= mid) { ch = (ch << 1) + 1; lngMin = mid; } else { ch = (ch << 1); lngMax = mid; }
    } else {
      final mid = (latMin + latMax) / 2;
      if (lat >= mid) { ch = (ch << 1) + 1; latMin = mid; } else { ch = (ch << 1); latMax = mid; }
    }
    even = !even;

    if (++bit == 5) {
      buffer.write(_base32[ch]);
      bit = 0;
      ch = 0;
    }
  }
  return buffer.toString();
}

String geohashP7(double lat, double lng) => geohashEncode(lat, lng, 7);
String geohashP8(double lat, double lng) => geohashEncode(lat, lng, 8);

// ---- Neighbors (8 surrounding cells) ----

String _adjacent(String hash, String dir) {
  assert(hash.isNotEmpty);
  final last = hash[hash.length - 1];
  final type = (hash.length % 2 == 0) ? 1 : 0; // even length => type 1
  var base = hash.substring(0, hash.length - 1);

  if (_border[dir]![type].contains(last)) {
    if (base.isNotEmpty) base = _adjacent(base, dir);
  }
  final n = _neighbor[dir]![type];
  final idx = n.indexOf(last);
  return base + _base32[idx];
}

List<String> geohashNeighbors(String hash) {
  final n  = _adjacent(hash, 'n');
  final s  = _adjacent(hash, 's');
  final e  = _adjacent(hash, 'e');
  final w  = _adjacent(hash, 'w');
  return [
    n,
    s,
    e,
    w,
    _adjacent(w, 'n'),
    _adjacent(e, 'n'),
    _adjacent(w, 's'),
    _adjacent(e, 's'),
  ];
}
