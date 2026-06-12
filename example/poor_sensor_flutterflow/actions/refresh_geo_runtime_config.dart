// FlutterFlow custom action: refreshGeoRuntimeConfig
//
// Return type: String
// Arguments: none
//
// Purpose:
//   Foreground-only runtime config refresh for FBG. This reads
//   appConfig/runtime and appConfig/runtime/deviceOverrides/{uid}, computes
//   the effective disableStopDetection value, then pushes that value into
//   native Flutter Background Geolocation with BackgroundGeolocation.setConfig.
//
// Required existing dependencies:
//   cloud_firestore
//   firebase_auth
//   firebase_crashlytics
//   flutter_background_geolocation

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;

Future<String> refreshGeoRuntimeConfig() async {
  if (kIsWeb) return 'not_applicable:web';

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return 'skipped:no_user';

  final fs = FirebaseFirestore.instance;
  final runtimeRef = fs.doc('appConfig/runtime');
  final overrideRef = fs.doc('appConfig/runtime/deviceOverrides/$uid');
  final now = DateTime.now();
  final clientTsIso = now.toUtc().toIso8601String();

  try {
    await fbg.Logger.notice('SPARRC runtime_config_refresh start uid=$uid');

    final stateBefore = await _safeFbgState();
    await fbg.Logger.notice(
      'SPARRC runtime_config_refresh state_before '
      'enabled=${stateBefore.enabled} isMoving=${stateBefore.isMoving}',
    );

    final runtimeSnap = await runtimeRef.get();
    if (!runtimeSnap.exists || runtimeSnap.data() == null) {
      await fbg.Logger.notice(
        'SPARRC runtime_config_refresh skipped reason=missing_runtime',
      );
      return 'skipped:missing_runtime';
    }

    final runtime = runtimeSnap.data()!;
    final platform = _asStringMap(runtime['platform']);

    final overrideSnap = await overrideRef.get();
    final override =
        overrideSnap.exists ? _asStringMap(overrideSnap.data()) : null;

    final result = _computeDisableStopDetection(
      platform: platform,
      deviceOverride: override,
      now: now,
    );

    await fbg.Logger.notice(
      'SPARRC runtime_config_refresh computed '
      'disableStopDetection=${result.effectiveDisableStopDetection} '
      'requested=${result.anyRequested} '
      'global=${result.globalRequested} '
      'device_override=${result.deviceOverrideRequested} '
      'recommended=${result.recommendedRequested} '
      'schedule_enabled=${result.scheduleEnabled} '
      'schedule_active=${result.scheduleActive} '
      'active_hours_only=${result.activeHoursOnly} '
      'reason=${result.reason ?? ""}',
    );

    await fbg.BackgroundGeolocation.setConfig(
      fbg.Config(
        activity: fbg.ActivityConfig(
          disableStopDetection: result.effectiveDisableStopDetection,
        ),
      ),
    );

    final stateAfter = await _safeFbgState();
    await fbg.Logger.notice(
      'SPARRC runtime_config_refresh applied '
      'disableStopDetection=${result.effectiveDisableStopDetection} '
      'enabled=${stateAfter.enabled} isMoving=${stateAfter.isMoving}',
    );

    await _writeDiagnostics(
      fs: fs,
      uid: uid,
      clientTsIso: clientTsIso,
      result: result,
      stateBefore: stateBefore,
      stateAfter: stateAfter,
    );

    FirebaseCrashlytics.instance.setCustomKey(
      'disable_stop_detection_refresh_effective',
      result.effectiveDisableStopDetection.toString(),
    );
    FirebaseCrashlytics.instance.setCustomKey(
      'disable_stop_detection_refresh_source',
      'foreground_refresh',
    );
    FirebaseCrashlytics.instance.setCustomKey(
      'disable_stop_detection_refresh_at',
      clientTsIso,
    );

    return 'success:disable_stop_detection='
        '${result.effectiveDisableStopDetection} '
        'requested=${result.anyRequested} '
        'schedule_active=${result.scheduleActive}';
  } catch (e, st) {
    try {
      await fbg.Logger.notice(
        'SPARRC runtime_config_refresh error error=${e.runtimeType}',
      );
    } catch (_) {}
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      fatal: false,
      reason: 'runtime_config_refresh_failed',
    );
    return 'error:${e.runtimeType}';
  }
}

Future<_FbgStateSummary> _safeFbgState() async {
  try {
    final state = await fbg.BackgroundGeolocation.state;
    return _FbgStateSummary(
      enabled: state.enabled == true,
      isMoving: state.isMoving == true,
    );
  } catch (_) {
    return const _FbgStateSummary(enabled: null, isMoving: null);
  }
}

_DisableStopDetectionResult _computeDisableStopDetection({
  required Map<String, dynamic> platform,
  required Map<String, dynamic>? deviceOverride,
  required DateTime now,
}) {
  final globalRequested = platform['disable_stop_detection'] == true;
  final deviceOverrideRequested =
      deviceOverride?['disable_stop_detection_override'] == true;
  final recommendedRequested =
      deviceOverride?['recommended_disable_stop_detection'] == true;
  final deviceRequested = deviceOverrideRequested || recommendedRequested;
  final anyRequested = globalRequested || deviceRequested;

  final schedule = _asStringMap(platform['active_geo_schedule']);
  final scheduleEnabled = schedule['enabled'] == true;
  final scheduleActive =
      scheduleEnabled ? _isWithinActiveGeoSchedule(schedule, now) : true;

  // Default device overrides to active-hours-only unless explicitly false.
  final activeHoursOnly =
      deviceRequested ? (deviceOverride?['active_hours_only'] != false) : true;

  final globalEffective =
      globalRequested && (!scheduleEnabled || scheduleActive);
  final deviceEffective =
      deviceRequested &&
      (!scheduleEnabled || !activeHoursOnly || scheduleActive);
  final effectiveDisableStopDetection = globalEffective || deviceEffective;

  return _DisableStopDetectionResult(
    effectiveDisableStopDetection: effectiveDisableStopDetection,
    anyRequested: anyRequested,
    globalRequested: globalRequested,
    deviceOverrideRequested: deviceOverrideRequested,
    recommendedRequested: recommendedRequested,
    scheduleEnabled: scheduleEnabled,
    scheduleActive: scheduleActive,
    activeHoursOnly: activeHoursOnly,
    reason: deviceOverride?['reason']?.toString(),
  );
}

bool _isWithinActiveGeoSchedule(Map<String, dynamic> schedule, DateTime now) {
  final windowsRaw = schedule['windows'];
  if (windowsRaw is! List) return false;

  // Firestore examples use 1..7. Treat 1 as Monday, matching Dart weekday.
  final weekday = now.weekday;
  final minutesNow = now.hour * 60 + now.minute;

  for (final rawWindow in windowsRaw) {
    final window = _asStringMap(rawWindow);
    final days = window['days'];
    if (days is List && days.isNotEmpty) {
      final allowed = days
          .whereType<num>()
          .map((value) => value.toInt())
          .contains(weekday);
      if (!allowed) continue;
    }

    final start = _parseClockMinutes(window['start']);
    final end = _parseClockMinutes(window['end']);
    if (start == null || end == null) continue;

    if (start == end) return true;
    if (start < end) {
      if (minutesNow >= start && minutesNow < end) return true;
    } else {
      // Overnight window, for example 22:00 -> 06:00.
      if (minutesNow >= start || minutesNow < end) return true;
    }
  }

  return false;
}

int? _parseClockMinutes(dynamic raw) {
  if (raw is! String) return null;
  final parts = raw.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

Map<String, dynamic> _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

Future<void> _writeDiagnostics({
  required FirebaseFirestore fs,
  required String uid,
  required String clientTsIso,
  required _DisableStopDetectionResult result,
  required _FbgStateSummary stateBefore,
  required _FbgStateSummary stateAfter,
}) async {
  try {
    await fs
        .collection('users')
        .doc(uid)
        .collection('geo_diagnostics')
        .doc('current')
        .set({
          'runtime_config_refresh_at': FieldValue.serverTimestamp(),
          'runtime_config_refresh_client_ts_iso': clientTsIso,
          'runtime_config_refresh_source': 'foreground_refresh',
          'disable_stop_detection_refresh_effective':
              result.effectiveDisableStopDetection,
          'disable_stop_detection_refresh_requested': result.anyRequested,
          'disable_stop_detection_refresh_global_requested':
              result.globalRequested,
          'disable_stop_detection_refresh_device_override':
              result.deviceOverrideRequested,
          'disable_stop_detection_refresh_recommended':
              result.recommendedRequested,
          'disable_stop_detection_refresh_schedule_enabled':
              result.scheduleEnabled,
          'disable_stop_detection_refresh_schedule_active':
              result.scheduleActive,
          'disable_stop_detection_refresh_active_hours_only':
              result.activeHoursOnly,
          if (result.reason != null)
            'disable_stop_detection_refresh_reason': result.reason,
          'fbg_state_before_refresh_enabled': stateBefore.enabled,
          'fbg_state_before_refresh_is_moving': stateBefore.isMoving,
          'fbg_state_after_refresh_enabled': stateAfter.enabled,
          'fbg_state_after_refresh_is_moving': stateAfter.isMoving,
        }, SetOptions(merge: true));
  } catch (_) {
    // Do not fail the foreground config refresh because diagnostics failed.
  }
}

class _FbgStateSummary {
  const _FbgStateSummary({required this.enabled, required this.isMoving});

  final bool? enabled;
  final bool? isMoving;
}

class _DisableStopDetectionResult {
  const _DisableStopDetectionResult({
    required this.effectiveDisableStopDetection,
    required this.anyRequested,
    required this.globalRequested,
    required this.deviceOverrideRequested,
    required this.recommendedRequested,
    required this.scheduleEnabled,
    required this.scheduleActive,
    required this.activeHoursOnly,
    required this.reason,
  });

  final bool effectiveDisableStopDetection;
  final bool anyRequested;
  final bool globalRequested;
  final bool deviceOverrideRequested;
  final bool recommendedRequested;
  final bool scheduleEnabled;
  final bool scheduleActive;
  final bool activeHoursOnly;
  final String? reason;
}
