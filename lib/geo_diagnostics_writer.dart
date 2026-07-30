// Writes background-geolocation callbacks to structured diagnostic snapshots.
//
// This preserves the public API used by tsbg_engine.dart while writing:
//   - provider events -> geo_diagnostics/current.provider_state
//   - power events    -> geo_diagnostics/current.battery_state
//   - FBG events      -> geo_diagnostics/current.fbg_state
//   - event IDs       -> timestamp_type_randomSuffix

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

class GeoDiagnosticsWriter {
  static const _dbName = 'sparrc_offline.db';
  static const _kvTable = 'kv_store';
  static const _lastStateKey = 'geo_diag_fbg_event_last_state_v2';
  static const _identityKey = 'geo_diag_identity';

  static Future<void> storeIdentity({
    required String uid,
    required String regionId,
    String? fid,
  }) async {
    if (kIsWeb || uid.isEmpty || regionId.isEmpty) return;
    try {
      await _writeString(
        _identityKey,
        jsonEncode({
          'uid': uid,
          'region_id': regionId,
          'client_updated_at_iso': DateTime.now().toUtc().toIso8601String(),
          if (fid != null && fid.isNotEmpty) 'fid': fid,
        }),
      );
    } catch (error, stackTrace) {
      await _recordNonFatal(
        error,
        stackTrace,
        'zbg_geo_diag_store_identity_failed',
      );
    }
  }

  static Future<GeoDiagnosticsIdentity?> readIdentity() async {
    if (kIsWeb) return null;
    try {
      final raw = await _readString(_identityKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final uid = decoded['uid']?.toString() ?? '';
      final regionId = decoded['region_id']?.toString() ?? '';
      if (uid.isEmpty) return null;
      return GeoDiagnosticsIdentity(
        uid: uid,
        regionId: regionId,
        fid: decoded['fid']?.toString(),
      );
    } catch (error, stackTrace) {
      await _recordNonFatal(
        error,
        stackTrace,
        'zbg_geo_diag_read_identity_failed',
      );
      return null;
    }
  }

  static Future<void> recordProviderChange(
    fbg.ProviderChangeEvent event, {
    String? uid,
  }) async {
    await recordProviderChangeResult(event, uid: uid);
  }

  static Future<GeoDiagnosticsWriteResult> recordProviderChangeResult(
    fbg.ProviderChangeEvent event, {
    String? uid,
  }) {
    final state = <String, dynamic>{
      'location_services_enabled': event.enabled,
      'gps_provider_enabled': event.gps,
      'network_provider_enabled': event.network,
      'location_permission': _locationPermissionName(event.status),
      'location_authorization_status_code': event.status,
      'location_precise':
          event.accuracyAuthorization ==
          fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL,
      'location_accuracy_authorization_code': event.accuracyAuthorization,
    };
    return _writeEventIfChanged(
      uid: uid,
      type: 'provider_change',
      source: 'fbg_onProviderChange',
      currentState: state,
      currentSection: 'provider_state',
    );
  }

  static Future<void> recordPowerSaveChange(
    bool isPowerSave, {
    String? uid,
  }) async {
    await recordPowerSaveChangeResult(isPowerSave, uid: uid);
  }

  static Future<GeoDiagnosticsWriteResult> recordPowerSaveChangeResult(
    bool isPowerSave, {
    String? uid,
  }) {
    return _writeEventIfChanged(
      uid: uid,
      type: 'power_save_change',
      source: 'fbg_onPowerSaveChange',
      currentState: {'power_save_mode': isPowerSave},
      currentSection: 'battery_state',
    );
  }

  static Future<void> recordFbgEnabledChange(
    bool enabled, {
    String? uid,
  }) async {
    await recordFbgEnabledChangeResult(enabled, uid: uid);
  }

  static Future<GeoDiagnosticsWriteResult> recordFbgEnabledChangeResult(
    bool enabled, {
    String? uid,
  }) {
    return _writeEventIfChanged(
      uid: uid,
      type: 'fbg_enabled_change',
      source: 'fbg_onEnabledChange',
      currentState: {'enabled': enabled},
      currentSection: 'fbg_state',
    );
  }

  static Future<GeoDiagnosticsWriteResult> _writeEventIfChanged({
    required String? uid,
    required String type,
    required String source,
    required Map<String, dynamic> currentState,
    required String currentSection,
  }) async {
    if (kIsWeb) {
      return GeoDiagnosticsWriteResult.skipped(
        status: GeoDiagnosticsWriteStatus.webSkipped,
        type: type,
        source: source,
      );
    }

    final resolvedUid = _resolveUid(uid);
    if (resolvedUid == null || resolvedUid.isEmpty) {
      return GeoDiagnosticsWriteResult.skipped(
        status: GeoDiagnosticsWriteStatus.missingUid,
        type: type,
        source: source,
      );
    }

    try {
      final previous = await _readLastState();
      final namespacedState = currentState.map(
        (key, value) => MapEntry('$currentSection.$key', value),
      );
      if (!_hasChanged(previous, namespacedState)) {
        return GeoDiagnosticsWriteResult.skipped(
          status: GeoDiagnosticsWriteStatus.dedupedNoChange,
          type: type,
          source: source,
        );
      }

      final clientIso = DateTime.now().toUtc().toIso8601String();
      final fs = FirebaseFirestore.instance;
      final userRef = fs.collection('users').doc(resolvedUid);
      final eventRef = userRef
          .collection('geo_events')
          .doc(_eventDocumentId(type));
      final currentRef = userRef.collection('geo_diagnostics').doc('current');
      final batch = fs.batch();

      batch.set(eventRef, {
        'type': type,
        'source': source,
        'timestamp': FieldValue.serverTimestamp(),
        'client_ts_iso': clientIso,
        ...currentState,
      });

      batch.set(currentRef, {
        'schema_version': 2,
        currentSection: {
          ...currentState,
          'observed_at': FieldValue.serverTimestamp(),
          'client_observed_at_iso': clientIso,
          'source': source,
        },
        'last_update': {
          'observed_at': FieldValue.serverTimestamp(),
          'client_observed_at_iso': clientIso,
          'source': source,
        },
      }, SetOptions(merge: true));

      await batch.commit();
      await _writeLastState({...previous, ...namespacedState});
      return GeoDiagnosticsWriteResult.written(type: type, source: source);
    } catch (error, stackTrace) {
      await _recordNonFatal(error, stackTrace, 'zbg_geo_diag_write_failed');
      return GeoDiagnosticsWriteResult.failed(
        type: type,
        source: source,
        error: error,
      );
    }
  }

  static String _eventDocumentId(String type) {
    final compact = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:.]'),
      '',
    );
    final safeType = type.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final autoId = FirebaseFirestore.instance.collection('_event_ids').doc().id;
    return '${compact}_${safeType}_${autoId.substring(0, 6)}';
  }

  static String? _resolveUid(String? uid) {
    if (uid != null && uid.isNotEmpty) return uid;
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
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

  static bool _hasChanged(
    Map<String, dynamic> previous,
    Map<String, dynamic> current,
  ) {
    for (final entry in current.entries) {
      if (previous[entry.key] != entry.value) return true;
    }
    return false;
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
      },
    );
  }

  static Future<Map<String, dynamic>> _readLastState() async {
    try {
      final raw = await _readString(_lastStateKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeLastState(Map<String, dynamic> state) {
    return _writeString(_lastStateKey, jsonEncode(state));
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
      await db.insert(_kvTable, {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } finally {
      await db.close();
    }
  }

  static Future<void> _recordNonFatal(
    Object error,
    StackTrace stackTrace,
    String reason,
  ) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        fatal: false,
        reason: reason,
      );
    } catch (_) {}
  }
}

enum GeoDiagnosticsWriteStatus {
  written,
  dedupedNoChange,
  missingUid,
  webSkipped,
  failed,
}

class GeoDiagnosticsWriteResult {
  const GeoDiagnosticsWriteResult._({
    required this.status,
    required this.type,
    required this.source,
    this.errorType,
    this.errorMessage,
  });

  factory GeoDiagnosticsWriteResult.written({
    required String type,
    required String source,
  }) {
    return GeoDiagnosticsWriteResult._(
      status: GeoDiagnosticsWriteStatus.written,
      type: type,
      source: source,
    );
  }

  factory GeoDiagnosticsWriteResult.skipped({
    required GeoDiagnosticsWriteStatus status,
    required String type,
    required String source,
  }) {
    return GeoDiagnosticsWriteResult._(
      status: status,
      type: type,
      source: source,
    );
  }

  factory GeoDiagnosticsWriteResult.failed({
    required String type,
    required String source,
    required Object error,
  }) {
    return GeoDiagnosticsWriteResult._(
      status: GeoDiagnosticsWriteStatus.failed,
      type: type,
      source: source,
      errorType: error.runtimeType.toString(),
      errorMessage: error.toString(),
    );
  }

  final GeoDiagnosticsWriteStatus status;
  final String type;
  final String source;
  final String? errorType;
  final String? errorMessage;

  String get statusName => status.name;
  bool get wrote => status == GeoDiagnosticsWriteStatus.written;

  Map<String, dynamic> toDebugMap() {
    return {
      'writer_status': statusName,
      'writer_type': type,
      'writer_source': source,
      if (errorType != null) 'writer_error_type': errorType,
      if (errorMessage != null) 'writer_error_message': errorMessage,
    };
  }
}

class GeoDiagnosticsIdentity {
  const GeoDiagnosticsIdentity({
    required this.uid,
    required this.regionId,
    this.fid,
  });

  final String uid;
  final String? regionId;
  final String? fid;
}
