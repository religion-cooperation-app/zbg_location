// lib/custom_code/geo_diagnostics_http.dart
//
// External FlutterFlow custom-code helper for HTTP-based geo diagnostics.
//
// Design:
// - Headless FBG event reaches Dart.
// - Write a tiny local SQLite marker immediately.
// - Attempt HTTP POST to geoDiagnosticsIngest.
// - Update marker status to sent/http_failed/timeout.
// - On foreground, flush unsent markers.
//
// This file intentionally does not write Firestore from headless code.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path_helper;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

class GeoDiagnosticsHttp {
  static const _dbName = 'sparrc_offline.db';
  static const _kvTable = 'kv_store';
  static const _queueTable = 'geo_diag_http_queue';
  static const _configKey = 'geo_diag_http_config';
  static const _lastSnapshotKey = 'geo_diag_last_system_snapshot';
  static const _lastProviderStateKey = 'geo_diag_last_provider_state';
  static const _lastHeartbeatCheckMsKey = 'geo_diag_last_heartbeat_check_ms';
  static const _httpTimeout = Duration(seconds: 5);
  static const _debugHeadlessReceivedEnabled = false;

  // Fallback values used when the config doc has no interval fields.
  static const _defaultFetchIntervalMinutes = 360;
  static const _defaultHeartbeatIntervalHours = 6;
  static const _defaultDailySnapshotHours = 24;

  /// Call from foreground after sign-in and after you know the active region.
  ///
  /// [endpointUrl] is the deployed Cloud Function URL for geoDiagnosticsIngest.
  /// [apiKey] should match appConfig/runtime.ingest_api_key or
  /// diagnostics_ingest_api_key, depending on the Cloud Function configuration.
  ///
  /// Interval params are sourced from appConfig/runtime in Firestore and stored
  /// in SQLite so headless tasks can read them without a network call.
  static Future<void> configure({
    required String regionId,
    required String endpointUrl,
    required String apiKey,
    int fetchIntervalMinutes = _defaultFetchIntervalMinutes,
    int heartbeatIntervalHours = _defaultHeartbeatIntervalHours,
    int dailySnapshotHours = _defaultDailySnapshotHours,
  }) async {
    if (kIsWeb) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    if (regionId.isEmpty || endpointUrl.isEmpty || apiKey.isEmpty) return;

    await _writeString(
      _configKey,
      jsonEncode({
        'uid': uid,
        'regionId': regionId,
        'endpointUrl': endpointUrl,
        'apiKey': apiKey,
        'updatedAtIso': DateTime.now().toUtc().toIso8601String(),
        'fetchIntervalMinutes': fetchIntervalMinutes.clamp(15, 1440),
        'heartbeatIntervalHours': heartbeatIntervalHours.clamp(1, 24),
        'dailySnapshotHours': dailySnapshotHours.clamp(1, 168),
      }),
    );
  }

  /// Returns the configured background_fetch minimum interval in minutes.
  /// Used by GeoDiagnosticsScheduler so it reads the same SQLite config.
  static Future<int> readFetchIntervalMinutes() async {
    final config = await _readConfig();
    return config?.fetchIntervalMinutes ?? _defaultFetchIntervalMinutes;
  }

  /// Headless/foreground FBG provider-change event.
  static Future<void> recordProviderChange(
    fbg.ProviderChangeEvent event, {
    String source = 'fbg_headless',
  }) async {
    final fbgLocationPermission = _locationPermissionName(event.status);
    final geolocatorPermission = await _safeGeolocatorPermission();
    final geolocatorServicesEnabled = await _safeLocationServicesEnabled();
    if (await _readConfig() == null) return;
    final fields = {
      'fbg_location_permission': fbgLocationPermission,
      'fbg_location_authorization_status_code': event.status,
      'fbg_location_precise': event.accuracyAuthorization ==
          fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL,
      'fbg_location_accuracy_authorization_code': event.accuracyAuthorization,
      'location_services_enabled': event.enabled,
      'gps_provider_enabled': event.gps,
      'network_provider_enabled': event.network,
      'location_permission': geolocatorPermission ?? fbgLocationPermission,
      'location_authorization_status_code': event.status,
      'location_precise': event.accuracyAuthorization ==
          fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL,
      'location_accuracy_authorization_code': event.accuracyAuthorization,
      if (geolocatorPermission != null)
        'geolocator_location_permission': geolocatorPermission,
      if (geolocatorServicesEnabled != null)
        'geolocator_location_services_enabled': geolocatorServicesEnabled,
    };

    final changed = await _stateChanged(_lastProviderStateKey, fields);
    if (!changed) return;

    await _recordAndSend(
      type: 'provider_change',
      source: source,
      fields: fields,
    );
  }

  static Future<void> recordPowerSaveChange(
    bool isPowerSave, {
    String source = 'fbg_headless',
  }) async {
    await _recordAndSend(
      type: 'power_save_change',
      source: source,
      fields: {'power_save_mode': isPowerSave},
    );
  }

  static Future<void> recordFbgEnabledChange(
    bool enabled, {
    String source = 'fbg_headless',
  }) async {
    await _recordAndSend(
      type: 'fbg_enabled_change',
      source: source,
      fields: {'fbg_enabled': enabled},
    );
  }

  /// Optional: call when any handled headless event enters Dart, before parsing.
  /// This creates proof of delivery even if the later event-specific payload
  /// fails. Keep it for diagnostics; remove if volume becomes unnecessary.
  static Future<void> recordHeadlessReceived(String eventName) async {
    if (!_debugHeadlessReceivedEnabled) return;
    await _recordAndSend(
      type: 'headless_received',
      source: 'fbg_headless',
      fields: {'event_name': eventName},
    );
  }

  /// Conservative scheduled audit. This does not request a GPS fix and does
  /// not call FBG sync. It only reads current state and sends if state changed
  /// or the daily snapshot window is due.
  static Future<bool> recordScheduledSnapshot({
    String source = 'background_fetch',
  }) async {
    return _recordCurrentSystemSnapshot(
      source: source,
      stateChangeType: 'scheduled_state_change',
    );
  }

  static Future<bool> recordHeartbeatSnapshot({
    String source = 'fbg_heartbeat',
  }) async {
    final config = await _readConfig();
    if (config == null) return false;

    final lastRaw = await _readString(_lastHeartbeatCheckMsKey);
    final lastMs = int.tryParse(lastRaw ?? '');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (lastMs != null &&
        nowMs - lastMs < config.heartbeatDiagnosticInterval.inMilliseconds) {
      return false;
    }
    await _writeString(_lastHeartbeatCheckMsKey, nowMs.toString());

    return _recordCurrentSystemSnapshot(
      source: source,
      stateChangeType: 'heartbeat_state_change',
    );
  }

  static Future<bool> _recordCurrentSystemSnapshot({
    required String source,
    required String stateChangeType,
  }) async {
    if (kIsWeb) return false;
    final config = await _readConfig();
    if (config == null) return false;

    final fields = await _buildCurrentSystemFields();
    final currentJson = jsonEncode(_sortedScalarMap(fields));
    final previousJson = await _readString(_lastSnapshotKey);

    final changed = previousJson != currentJson;
    await _writeString(_lastSnapshotKey, currentJson);
    if (!changed) return false;

    await _recordAndSend(
      type: stateChangeType,
      source: source,
      fields: {
        ...fields,
        'diagnostic_state_changed': true,
      },
    );
    return true;
  }

  /// Call from HomePage foreground/init after configure().
  static Future<int> flushPending({
    int limit = 20,
    String deliverySource = 'foreground_flush',
  }) async {
    if (kIsWeb) return 0;
    final db = await _openDb();
    final rows = await db.query(
      _queueTable,
      where: 'status != ?',
      whereArgs: ['sent'],
      orderBy: 'created_at_ms ASC',
      limit: limit,
    );

    var sent = 0;
    for (final row in rows) {
      final id = row['id'] as String;
      final payloadJson = row['payload_json'] as String;
      final payload = jsonDecode(payloadJson);
      if (payload is! Map) continue;

      final ok = await _sendPayload(
        Map<String, dynamic>.from(payload),
        deliverySource: deliverySource,
        deliveryAttempt: (row['attempts'] as int? ?? 0) + 1,
      );
      await _updateMarker(
        id,
        status: ok ? 'sent' : 'http_failed',
        incrementAttempts: true,
      );
      if (ok) sent++;
    }
    return sent;
  }

  static Future<void> _recordAndSend({
    required String type,
    required String source,
    required Map<String, dynamic> fields,
  }) async {
    if (kIsWeb) return;
    final config = await _readConfig();
    if (config == null) return;

    final markerId =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}_${type}_${_safeHash(fields)}';
    final package = await _safePackageInfo();
    final payload = <String, dynamic>{
      'marker_id': markerId,
      'marker_status': 'received',
      'uid': config.uid,
      'regionId': config.regionId,
      'type': type,
      'source': source,
      'origin_source': source,
      'client_ts_iso': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      if (package != null) 'app_version': package.version,
      if (package != null) 'build_number': package.buildNumber,
      'fields': _scalarMap(fields),
    };

    await _insertMarker(markerId, payload, status: 'received');

    try {
      final ok = await _sendPayload(
        payload,
        deliverySource: 'initial_send',
        deliveryAttempt: 1,
      );
      await _updateMarker(
        markerId,
        status: ok ? 'sent' : 'http_failed',
        incrementAttempts: true,
      );
    } on TimeoutException {
      await _updateMarker(markerId, status: 'timeout', incrementAttempts: true);
    } catch (_) {
      await _updateMarker(
        markerId,
        status: 'http_failed',
        incrementAttempts: true,
      );
    }
  }

  static Future<bool> _sendPayload(
    Map<String, dynamic> payload, {
    required String deliverySource,
    required int deliveryAttempt,
  }) async {
    final config = await _readConfig();
    if (config == null) return false;
    final body = Map<String, dynamic>.from(payload)
      ..['delivery_source'] = deliverySource
      ..['delivery_attempt'] = deliveryAttempt
      ..['origin_source'] = payload['origin_source'] ?? payload['source'];

    final response = await http
        .post(
          Uri.parse(config.endpointUrl),
          headers: {
            'Content-Type': 'application/json',
            'X-Api-Key': config.apiKey,
          },
          body: jsonEncode(body),
        )
        .timeout(_httpTimeout);

    return response.statusCode >= 200 && response.statusCode < 300;
  }

  /// Patches only the interval fields stored in SQLite without touching
  /// uid / regionId / endpointUrl / apiKey.
  ///
  /// Call AFTER configure() (so a valid config already exists in SQLite).
  /// Used by applyAppConfigRuntime to apply fresh Firestore-sourced values
  /// without re-running the full configure() flow.
  static Future<void> updateIntervals({
    required int fetchIntervalMinutes,
    required int heartbeatIntervalHours,
    required int dailySnapshotHours,
  }) async {
    if (kIsWeb) return;
    final existing = await _readConfig();
    if (existing == null) return; // configure() not yet called; skip silently
    await _writeString(
      _configKey,
      jsonEncode({
        'uid': existing.uid,
        'regionId': existing.regionId,
        'endpointUrl': existing.endpointUrl,
        'apiKey': existing.apiKey,
        'updatedAtIso': DateTime.now().toUtc().toIso8601String(),
        'fetchIntervalMinutes': fetchIntervalMinutes.clamp(15, 1440),
        'heartbeatIntervalHours': heartbeatIntervalHours.clamp(1, 24),
        'dailySnapshotHours': dailySnapshotHours.clamp(1, 168),
      }),
    );
  }

  static Future<_DiagHttpConfig?> _readConfig() async {
    final raw = await _readString(_configKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final uid = decoded['uid'] as String?;
      final regionId = decoded['regionId'] as String?;
      final endpointUrl = decoded['endpointUrl'] as String?;
      final apiKey = decoded['apiKey'] as String?;
      if (uid == null || uid.isEmpty) return null;
      if (regionId == null || regionId.isEmpty) return null;
      if (endpointUrl == null || endpointUrl.isEmpty) return null;
      if (apiKey == null || apiKey.isEmpty) return null;
      return _DiagHttpConfig(
        uid: uid,
        regionId: regionId,
        endpointUrl: endpointUrl,
        apiKey: apiKey,
        fetchIntervalMinutes:
            (decoded['fetchIntervalMinutes'] as num?)?.toInt() ??
                _defaultFetchIntervalMinutes,
        heartbeatIntervalHours:
            (decoded['heartbeatIntervalHours'] as num?)?.toInt() ??
                _defaultHeartbeatIntervalHours,
        dailySnapshotHours: (decoded['dailySnapshotHours'] as num?)?.toInt() ??
            _defaultDailySnapshotHours,
      );
    } catch (_) {
      return null;
    }
  }

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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_queueTable (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  static Future<void> _insertMarker(
    String id,
    Map<String, dynamic> payload, {
    required String status,
  }) async {
    final db = await _openDb();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
        _queueTable,
        {
          'id': id,
          'type': payload['type'] as String,
          'source': payload['source'] as String,
          'status': status,
          'payload_json': jsonEncode(payload),
          'created_at_ms': nowMs,
          'updated_at_ms': nowMs,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _updateMarker(
    String id, {
    required String status,
    bool incrementAttempts = false,
  }) async {
    final db = await _openDb();
    final existing = await db.query(
      _queueTable,
      columns: ['attempts'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final attempts =
        existing.isEmpty ? 0 : (existing.first['attempts'] as int? ?? 0);
    await db.update(
      _queueTable,
      {
        'status': status,
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        'attempts': incrementAttempts ? attempts + 1 : attempts,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<String?> _readString(String key) async {
    final db = await _openDb();
    final rows = await db.query(
      _kvTable,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  static Future<void> _writeString(String key, String value) async {
    final db = await _openDb();
    await db.insert(
        _kvTable,
        {
          'key': key,
          'value': value,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<PackageInfo?> _safePackageInfo() async {
    try {
      return PackageInfo.fromPlatform();
    } catch (_) {
      return null;
    }
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
      }
    });
    return out;
  }

  static Map<String, dynamic> _sortedScalarMap(Map<String, dynamic> input) {
    final scalar = _scalarMap(input);
    final keys = scalar.keys.toList()..sort();
    return {for (final key in keys) key: scalar[key]};
  }

  static int _safeHash(Map<String, dynamic> fields) {
    return jsonEncode(_scalarMap(fields)).hashCode.abs();
  }

  static Future<bool> _stateChanged(
    String key,
    Map<String, dynamic> fields,
  ) async {
    final currentJson = jsonEncode(_sortedScalarMap(fields));
    final previousJson = await _readString(key);
    await _writeString(key, currentJson);
    return previousJson != currentJson;
  }

  static String _locationPermissionName(int status) {
    switch (status) {
      case fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS:
        return 'always';
      case fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_WHEN_IN_USE:
        return 'when_in_use';
      case fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_DENIED:
        return 'denied';
      case fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_RESTRICTED:
        return 'restricted';
      case fbg.ProviderChangeEvent.AUTHORIZATION_STATUS_NOT_DETERMINED:
        return 'not_determined';
      default:
        return 'unknown';
    }
  }

  static Future<String?> _safeGeolocatorPermission() async {
    try {
      return _geolocatorPermissionName(await Geolocator.checkPermission());
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _safeLocationServicesEnabled() async {
    try {
      return Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return null;
    }
  }

  static String _geolocatorPermissionName(LocationPermission permission) {
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
        return 'unable_to_determine';
    }
  }

  static Future<Map<String, dynamic>> _buildCurrentSystemFields() async {
    final fields = <String, dynamic>{};

    final geolocatorPermission = await _safeGeolocatorPermission();
    final geolocatorServicesEnabled = await _safeLocationServicesEnabled();
    if (geolocatorPermission != null) {
      fields['geolocator_location_permission'] = geolocatorPermission;
      fields['location_permission'] = geolocatorPermission;
    }
    if (geolocatorServicesEnabled != null) {
      fields['geolocator_location_services_enabled'] =
          geolocatorServicesEnabled;
      fields['location_services_enabled'] = geolocatorServicesEnabled;
    }

    final provider = await _safeFbgProviderState();
    if (provider != null) {
      final fbgPermission = _locationPermissionName(provider.status);
      fields['fbg_location_permission'] = fbgPermission;
      fields['fbg_location_authorization_status_code'] = provider.status;
      fields['fbg_location_precise'] = provider.accuracyAuthorization ==
          fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL;
      fields['fbg_location_accuracy_authorization_code'] =
          provider.accuracyAuthorization;
      fields['gps_provider_enabled'] = provider.gps;
      fields['network_provider_enabled'] = provider.network;
      fields['fbg_location_services_enabled'] = provider.enabled;
      fields['location_permission'] =
          fields['location_permission'] ?? fbgPermission;
      fields['location_authorization_status_code'] = provider.status;
      fields['location_precise'] = provider.accuracyAuthorization ==
          fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL;
      fields['location_accuracy_authorization_code'] =
          provider.accuracyAuthorization;
    }

    final fbgEnabled = await _safeFbgEnabled();
    if (fbgEnabled != null) fields['fbg_enabled'] = fbgEnabled;

    final powerSave = await _safePowerSaveMode();
    if (powerSave != null) fields['power_save_mode'] = powerSave;

    final notificationStatus = await _safePermissionStatus(
      Permission.notification,
    );
    if (notificationStatus != null) {
      fields['notification_permission'] = notificationStatus;
      fields['notifications_enabled'] = notificationStatus == 'granted';
    }

    final batteryOptimizationStatus = await _safePermissionStatus(
      Permission.ignoreBatteryOptimizations,
    );
    if (batteryOptimizationStatus != null) {
      fields['battery_optimization_permission'] = batteryOptimizationStatus;
      fields['battery_optimization_exempt'] =
          batteryOptimizationStatus == 'granted';
    }

    return fields;
  }

  static Future<fbg.ProviderChangeEvent?> _safeFbgProviderState() async {
    try {
      return await fbg.BackgroundGeolocation.providerState;
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _safeFbgEnabled() async {
    try {
      return (await fbg.BackgroundGeolocation.state).enabled;
    } catch (_) {
      return null;
    }
  }

  static Future<bool?> _safePowerSaveMode() async {
    try {
      return await fbg.DeviceSettings.isPowerSaveMode;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _safePermissionStatus(Permission permission) async {
    try {
      return _permissionStatusName(await permission.status);
    } catch (_) {
      return null;
    }
  }

  static String _permissionStatusName(PermissionStatus status) {
    if (status.isGranted) return 'granted';
    if (status.isDenied) return 'denied';
    if (status.isPermanentlyDenied) return 'permanently_denied';
    if (status.isRestricted) return 'restricted';
    if (status.isLimited) return 'limited';
    if (status.isProvisional) return 'provisional';
    return 'unknown';
  }
}

class _DiagHttpConfig {
  const _DiagHttpConfig({
    required this.uid,
    required this.regionId,
    required this.endpointUrl,
    required this.apiKey,
    required this.fetchIntervalMinutes,
    required this.heartbeatIntervalHours,
    required this.dailySnapshotHours,
  });

  final String uid;
  final String regionId;
  final String endpointUrl;
  final String apiKey;
  final int fetchIntervalMinutes;
  final int heartbeatIntervalHours;
  final int dailySnapshotHours;

  Duration get heartbeatDiagnosticInterval =>
      Duration(hours: heartbeatIntervalHours);
}
