// lib/dwell_cooldown.dart
//
// Tiny state helper to turn ENTER→DWELL after N seconds and enforce EXIT cooldown.
// Use one instance per geofence you're tracking (or one global if you only care
// about "current zone" semantics).

enum DwellState { outside, insidePending, insideDwelled }

class DwellCooldown {
  final int dwellRequiredS; // seconds required to count as "dwell"
  final int cooldownS;      // seconds after exit before re-trigger allowed

  DateTime? _enteredAt;     // when we first detected "inside"
  DateTime? _exitedAt;      // last exit time (for cooldown)
  DwellState _state = DwellState.outside;

  DwellCooldown({required this.dwellRequiredS, required this.cooldownS});

  DwellState get state => _state;

  bool get inCooldown {
    if (_exitedAt == null) return false;
    return DateTime.now()
            .toUtc()
            .difference(_exitedAt!)
            .inSeconds < cooldownS;
  }

  /// Call this as location updates arrive with your own inside/outside flag.
  /// Returns:
  /// - "ENTER" exactly once when transitioning outside -> inside
  /// - "DWELL" exactly once when dwell threshold is hit
  /// - "EXIT" exactly once when transitioning inside* -> outside
  /// - null otherwise
  String? update({required bool inside, required DateTime tsUtc}) {
    // Outside path
    if (!inside) {
      if (_state != DwellState.outside) {
        _state = DwellState.outside;
        _enteredAt = null;
        _exitedAt = tsUtc;
        return "EXIT";
      }
      return null;
    }

    // Inside path
    // If we're inside but in cooldown from a very recent exit, still treat it as inside
    // but do NOT emit ENTER/DWELL until cooldown passes.
    final cooling =
        _exitedAt != null && tsUtc.difference(_exitedAt!).inSeconds < cooldownS;

    if (_state == DwellState.outside) {
      if (cooling) {
        // Ignore ENTER during cooldown; remain logically outside until cooldown ends.
        return null;
      }
      _state = DwellState.insidePending;
      _enteredAt = tsUtc;
      return "ENTER";
    }

    if (_state == DwellState.insidePending) {
      if (_enteredAt != null &&
          tsUtc.difference(_enteredAt!).inSeconds >= dwellRequiredS) {
        _state = DwellState.insideDwelled;
        return "DWELL";
      }
      return null;
    }

    // Already dwelled; remain in that state until we exit.
    return null;
  }

  /// Manual reset (rarely needed).
  void reset() {
    _state = DwellState.outside;
    _enteredAt = null;
    _exitedAt = null;
  }
}
