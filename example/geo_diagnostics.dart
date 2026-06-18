// geo_diagnostics_external.dart
//
// Standalone app-layer helper for SPARRC lean geo diagnostics.
// Intended to be manually copied/adapted into FlutterFlow custom code, e.g.
// generated_code/lib/custom_code/geo_diagnostics.dart.
//
// This file intentionally does not live inside zbg_location. It writes to
// SPARRC-specific Firestore paths and uses the SPARRC SQLite kv_store.

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path_helper;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

class GeoDiagnostics {
  static const _dbName = 'sparrc_offline.db';
  static const _kvTable = 'kv_store';

  static const _lastStateKey = 'geo_diag_last_state';
  static const _lastDailyCheckMsKey = 'geo_diag_last_daily_check_ms';

  static const _dailyCheckInterval = Duration(hours: 24);

  static const dependencyVersions = <String, String>{
    'flutter_background_geolocation': '5.2.0',
    'sqflite': '2.3.3+1',
    'geolocator': '14.0.1',
    'permission_handler': '12.0.0+1',
    'package_info_plus': '8.3.1',
  };

  /// Writes a geo event only if any [compareKeys] changed relative to SQLite's
  /// last-known state. Also merges [currentSnapshotFields] into
  /// users/{uid}/geo_diagnostics/current when a change is detected.
  static Future<void> writeEventIfChanged({
    required String type,
    required String source,
    required Map<String, dynamic> currentState,
    Map<String, dynamic> eventFields = const {},
    List<String> compareKeys = const [],
    Map<String, dynamic> currentSnapshotFields = const {},
  }) async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final cleanState = _scalarMap(currentState);
      final cleanEventFields = _scalarMap(eventFields);
      final cleanSnapshotFields = _scalarMap(currentSnapshotFields);
      final previous = await _readLastState();

      final changed = _hasChanged(
        previous: previous,
        current: cleanState,
        compareKeys:
            compareKeys.isEmpty ? cleanState.keys.toList() : compareKeys,
      );

      if (!changed) return;

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();

      final eventRef =
          fs.collection('users').doc(uid).collection('geo_events').doc();
      batch.set(eventRef, {
        'type': type,
        'source': source,
        'timestamp': FieldValue.serverTimestamp(),
        'client_ts_iso': nowIso,
        'platform': _platformName(),
        ...cleanEventFields,
      });

      final currentRef = fs
          .collection('users')
          .doc(uid)
          .collection('geo_diagnostics')
          .doc('current');
      batch.set(
          currentRef,
          {
            'updated_at': FieldValue.serverTimestamp(),
            'client_updated_at_iso': nowIso,
            'last_event_type': type,
            ...cleanSnapshotFields,
          },
          SetOptions(merge: true));

      await batch.commit();
      await _writeLastState({...previous, ...cleanState});
    } catch (e, st) {
      await _recordNonFatal(e, st, 'geo_diag_write_event_failed');
    }
  }

  /// Merges fields into users/{uid}/geo_diagnostics/current.
  static Future<void> updateCurrent(
    Map<String, dynamic> fields, {
    String? lastEventType,
  }) async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final clean = _scalarMap(fields);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('geo_diagnostics')
          .doc('current')
          .set({
        'updated_at': FieldValue.serverTimestamp(),
        'client_updated_at_iso': nowIso,
        if (lastEventType != null) 'last_event_type': lastEventType,
        ...clean,
      }, SetOptions(merge: true));
      final previous = await _readLastState();
      await _writeLastState({...previous, ...clean});
    } catch (e, st) {
      await _recordNonFatal(e, st, 'geo_diag_update_current_failed');
    }
  }

  /// Records a geo start success/failure. Call this from geoStartFromConfig
  /// after GeoBootstrap.startFromFirestore returns or throws.
  static Future<void> writeGeoStartResult({
    required bool success,
    required String regionId,
    String? error,
    String? geoMode,
  }) async {
    if (kIsWeb) return;
    final type = success ? 'geo_start_success' : 'geo_start_failure';
    final state = <String, dynamic>{
      'geo_running': success,
      'last_geo_start_result': success ? 'success' : 'failure',
      'last_geo_error': success ? null : (error ?? 'unknown_error'),
      if (geoMode != null) 'geo_mode': geoMode,
    };

    await _writeEventAlways(
      type: type,
      source: 'geoStartFromConfig',
      eventFields: {
        'region_id': regionId,
        'result': success ? 'success' : 'failure',
        if (geoMode != null) 'geo_mode': geoMode,
        if (!success) 'error': error ?? 'unknown_error',
      },
      currentFields: {
        ...state,
        'last_geo_start_at': FieldValue.serverTimestamp(),
      },
    );

    final previous = await _readLastState();
    await _writeLastState({...previous, ..._scalarMap(state)});
  }

  /// Updates users/{uid}/versionData/current only when the metadata changed.
  ///
  /// This is intentionally separate from geo_diagnostics/current. It is a
  /// general app/client environment record useful for geo diagnostics, sync
  /// debugging, support, and release triage.
  static Future<void> updateUserClientEnvironmentIfChanged() async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final environment = await collectClientEnvironment();
      final previous = await _readLastState();
      final compareKeys = <String>[
        'app_name',
        'package_name',
        'app_version',
        'build_number',
        'installer_store',
        'platform',
        'manufacturer',
        'model',
        'os_version',
        'flutter_background_geolocation_version',
        'sqflite_version',
        'geolocator_version',
        'permission_handler_version',
        'package_info_plus_version',
      ];

      if (!_hasChanged(
        previous: previous,
        current: environment,
        compareKeys: compareKeys,
      )) {
        return;
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final fs = FirebaseFirestore.instance;
      final userRef = fs.collection('users').doc(uid);
      final versionRef = userRef.collection('versionData').doc('current');
      await versionRef.set({
        ...environment,
        'dependency_versions': dependencyVersions,
        'updated_at': FieldValue.serverTimestamp(),
        'client_updated_at_iso': nowIso,
      }, SetOptions(merge: true));
      await _writeLastState({...previous, ...environment});
    } catch (e, st) {
      await _recordNonFatal(e, st, 'geo_diag_client_environment_failed');
    }
  }

  /// Records FBG onProviderChange information. The app integration should pass
  /// normalized values from the FBG ProviderChangeEvent.
  static Future<void> recordProviderChange({
    required bool locationServicesEnabled,
    bool? gpsProviderEnabled,
    bool? networkProviderEnabled,
    String? locationPermission,
    bool? locationPrecise,
    String source = 'fbg_onProviderChange',
  }) async {
    final state = <String, dynamic>{
      'location_services_enabled': locationServicesEnabled,
      if (gpsProviderEnabled != null)
        'gps_provider_enabled': gpsProviderEnabled,
      if (networkProviderEnabled != null)
        'network_provider_enabled': networkProviderEnabled,
      if (locationPermission != null) 'location_permission': locationPermission,
      if (locationPrecise != null) 'location_precise': locationPrecise,
    };

    await writeEventIfChanged(
      type: 'provider_change',
      source: source,
      currentState: state,
      eventFields: state,
      compareKeys: state.keys.toList(),
      currentSnapshotFields: state,
    );
  }

  /// Records FBG onPowerSaveChange.
  static Future<void> recordPowerSaveChange(bool isPowerSave) async {
    final state = {'power_save_mode': isPowerSave};
    await writeEventIfChanged(
      type: 'power_save_change',
      source: 'fbg_onPowerSaveChange',
      currentState: state,
      eventFields: state,
      compareKeys: const ['power_save_mode'],
      currentSnapshotFields: state,
    );
  }

  /// Records FBG onEnabledChange.
  static Future<void> recordFbgEnabledChange(bool enabled) async {
    final state = {'fbg_enabled': enabled};
    await writeEventIfChanged(
      type: 'fbg_enabled_change',
      source: 'fbg_onEnabledChange',
      currentState: state,
      eventFields: state,
      compareKeys: const ['fbg_enabled'],
      currentSnapshotFields: state,
    );
  }

  /// Runs a full diagnostic scan at most once per 24 hours.
  ///
  /// Call from HomePage foreground/init. This is the only intentional polling
  /// path in the lean design.
  static Future<void> runDailySystemCheckIfDue() async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastMs = await _readInt(_lastDailyCheckMsKey);
      if (lastMs != null &&
          nowMs - lastMs < _dailyCheckInterval.inMilliseconds) {
        return;
      }

      final state = await collectCurrentSystemState();
      await updateUserClientEnvironmentIfChanged();
      final issues = _issueCodes(state);

      final previous = await _readLastState();
      final changed = _hasChanged(
        previous: previous,
        current: _scalarMap(state),
        compareKeys: _scalarMap(state).keys.toList(),
      );

      await _writeInt(_lastDailyCheckMsKey, nowMs);
      await _writeLastState(_scalarMap(state));

      if (!changed && issues.isEmpty) return;

      final nowIso = DateTime.now().toUtc().toIso8601String();

      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();

      final currentRef = fs
          .collection('users')
          .doc(uid)
          .collection('geo_diagnostics')
          .doc('current');
      batch.set(
          currentRef,
          {
            ...state,
            'checked_at': FieldValue.serverTimestamp(),
            'client_checked_at_iso': nowIso,
            'daily_system_check_status':
                issues.isEmpty ? 'ok' : 'issue_detected',
            'daily_system_check_issues': issues,
            'last_event_type': issues.isEmpty
                ? 'daily_snapshot'
                : 'daily_snapshot_issue_detected',
          },
          SetOptions(merge: true));

      if (issues.isNotEmpty) {
        final eventRef =
            fs.collection('users').doc(uid).collection('geo_events').doc();
        batch.set(eventRef, {
          'type': 'daily_snapshot_issue_detected',
          'source': 'daily_foreground_check',
          'timestamp': FieldValue.serverTimestamp(),
          'client_ts_iso': nowIso,
          'platform': _platformName(),
          'issues': issues,
        });
      }

      await batch.commit();
    } catch (e, st) {
      await _recordNonFatal(e, st, 'geo_diag_daily_check_failed');
    }
  }

  /// Collects current state for the daily foreground system check.
  ///
  /// This does not request a GPS fix.
  static Future<Map<String, dynamic>> collectCurrentSystemState() async {
    final state = <String, dynamic>{
      'platform': _platformName(),
      'client_checked_at_iso': DateTime.now().toUtc().toIso8601String(),
    };

    state.addAll(await collectClientEnvironment());

    if (!kIsWeb) {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final permission = await Geolocator.checkPermission();
      final accuracy = await _safeLocationAccuracy();
      final notificationStatus = await _safeNotificationStatus();
      final fbgEnabled = await _safeFbgEnabled();

      state.addAll({
        'location_services_enabled': serviceEnabled,
        'location_permission': _permissionName(permission),
        'location_precise': accuracy == null ? null : accuracy == 'full',
        'location_accuracy': accuracy ?? 'unknown',
        'notifications_enabled': notificationStatus == 'granted',
        'notification_permission': notificationStatus,
        'fbg_enabled': fbgEnabled,
      });

      // Battery optimization exemption is intentionally left unknown here
      // unless you add a reliable Android-specific implementation later.
      // Keep the key present so dashboards can distinguish unknown from false.
      if (Platform.isAndroid) {
        state['battery_optimization_status_known'] = false;
        state['battery_optimization_exempt'] = null;
      }
    }

    return _scalarMap(state);
  }

  static Future<Map<String, dynamic>> collectClientEnvironment() async {
    final device = await _deviceInfo();
    final package = await _packageInfo();
    return _scalarMap({
      'platform': _platformName(),
      ...device,
      ...package,
      'flutter_background_geolocation_version':
          dependencyVersions['flutter_background_geolocation'],
      'sqflite_version': dependencyVersions['sqflite'],
      'geolocator_version': dependencyVersions['geolocator'],
      'permission_handler_version': dependencyVersions['permission_handler'],
      'package_info_plus_version': dependencyVersions['package_info_plus'],
    });
  }

  // ---------- private Firestore helpers ----------

  static Future<void> _writeEventAlways({
    required String type,
    required String source,
    required Map<String, dynamic> eventFields,
    required Map<String, dynamic> currentFields,
  }) async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();

      final eventRef =
          fs.collection('users').doc(uid).collection('geo_events').doc();
      batch.set(eventRef, {
        'type': type,
        'source': source,
        'timestamp': FieldValue.serverTimestamp(),
        'client_ts_iso': nowIso,
        'platform': _platformName(),
        ..._scalarMap(eventFields),
      });

      final currentRef = fs
          .collection('users')
          .doc(uid)
          .collection('geo_diagnostics')
          .doc('current');
      batch.set(
          currentRef,
          {
            'updated_at': FieldValue.serverTimestamp(),
            'client_updated_at_iso': nowIso,
            'last_event_type': type,
            ...currentFields,
          },
          SetOptions(merge: true));

      await batch.commit();
    } catch (e, st) {
      await _recordNonFatal(e, st, 'geo_diag_write_event_always_failed');
    }
  }

  // ---------- private SQLite helpers ----------

  static Future<Database> _openDb() async {
    final dbPath = await getDatabasesPath();
    final fullPath = path_helper.join(dbPath, _dbName);
    return openDatabase(
      fullPath,
      version: 1,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_kvTable (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  static Future<Map<String, dynamic>> _readLastState() async {
    try {
      final raw = await _readString(_lastStateKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return _scalarMap(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeLastState(Map<String, dynamic> state) async {
    await _writeString(_lastStateKey, jsonEncode(_scalarMap(state)));
  }

  static Future<String?> _readString(String key) async {
    final db = await _openDb();
    try {
      final rows = await db.query(
        _kvTable,
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    } finally {
      await db.close();
    }
  }

  static Future<void> _writeString(String key, String value) async {
    final db = await _openDb();
    try {
      await db.insert(
          _kvTable,
          {
            'key': key,
            'value': value,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } finally {
      await db.close();
    }
  }

  static Future<int?> _readInt(String key) async {
    final raw = await _readString(key);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  static Future<void> _writeInt(String key, int value) async {
    await _writeString(key, value.toString());
  }

  // ---------- private state helpers ----------

  static bool _hasChanged({
    required Map<String, dynamic> previous,
    required Map<String, dynamic> current,
    required List<String> compareKeys,
  }) {
    for (final key in compareKeys) {
      if (previous[key] != current[key]) return true;
    }
    return false;
  }

  static Map<String, dynamic> _scalarMap(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((key, value) {
      if (value == null ||
          value is String ||
          value is bool ||
          value is int ||
          value is double) {
        out[key] = value;
      } else if (value is num) {
        out[key] = value.toDouble();
      } else if (value is List) {
        out[key] = value
            .where(
              (e) =>
                  e == null ||
                  e is String ||
                  e is bool ||
                  e is int ||
                  e is double,
            )
            .toList();
      } else {
        out[key] = value.toString();
      }
    });
    return out;
  }

  static List<String> _issueCodes(Map<String, dynamic> state) {
    final issues = <String>[];

    if (state['location_services_enabled'] == false) {
      issues.add('location_services_disabled');
    }
    final permission = state['location_permission'];
    if (permission == 'denied') {
      issues.add('permission_denied');
    } else if (permission == 'denied_forever') {
      issues.add('permission_denied_forever');
    } else if (permission != null && permission != 'always') {
      issues.add('permission_always_required');
    }
    if (state['location_precise'] == false) {
      issues.add('accuracy_reduced');
    }
    if (state['battery_optimization_exempt'] == false) {
      issues.add('battery_optimization_enabled');
    }
    if (state['notifications_enabled'] == false) {
      issues.add('notifications_disabled');
    }
    if (state['fbg_enabled'] == false) {
      issues.add('fbg_disabled');
    }
    if (state['geo_running'] == false) {
      issues.add('geo_not_running');
    }
    if (state['power_save_mode'] == true) {
      issues.add('power_save_mode_enabled');
    }

    return issues;
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  static String _permissionName(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
        return 'always';
      case LocationPermission.whileInUse:
        return 'when_in_use';
      case LocationPermission.denied:
        return 'denied';
      case LocationPermission.deniedForever:
        return 'denied_forever';
      case LocationPermission.unableToDetermine:
        return 'unknown';
    }
  }

  static Future<String?> _safeLocationAccuracy() async {
    try {
      final accuracy = await Geolocator.getLocationAccuracy();
      if (accuracy == LocationAccuracyStatus.precise) return 'full';
      if (accuracy == LocationAccuracyStatus.reduced) return 'reduced';
      return 'unknown';
    } catch (_) {
      return null;
    }
  }

  static Future<String> _safeNotificationStatus() async {
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return 'granted';
      if (status.isDenied) return 'denied';
      if (status.isPermanentlyDenied) return 'denied_forever';
      if (status.isRestricted) return 'restricted';
      if (status.isLimited) return 'limited';
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  static Future<bool?> _safeFbgEnabled() async {
    try {
      final state = await fbg.BackgroundGeolocation.state;
      return state.enabled;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _deviceInfo() async {
    if (kIsWeb) return {'platform': 'web'};
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return {
          'manufacturer': info.manufacturer,
          'model': info.model,
          'brand': info.brand,
          'device': info.device,
          'os_version': info.version.release,
          'sdk_int': info.version.sdkInt,
          'is_physical_device': info.isPhysicalDevice,
        };
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        return {
          'manufacturer': 'Apple',
          'model': info.utsname.machine,
          'device': info.name,
          'os_version': info.systemVersion,
          'is_physical_device': info.isPhysicalDevice,
        };
      }
    } catch (_) {}
    return {};
  }

  static Future<Map<String, dynamic>> _packageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return {
        'app_name': info.appName,
        'package_name': info.packageName,
        'app_version': info.version,
        'build_number': info.buildNumber,
        if ((info.installerStore ?? '').isNotEmpty)
          'installer_store': info.installerStore,
      };
    } catch (_) {
      return {
        'app_name': 'SPARRC',
        'package_name': 'unknown',
        'app_version': 'unknown',
        'build_number': 'unknown',
      };
    }
  }

  static Future<void> _recordNonFatal(
    Object error,
    StackTrace stack,
    String reason,
  ) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        fatal: false,
        reason: reason,
      );
    } catch (_) {
      // Diagnostics must never break geo tracking.
    }
  }
}
