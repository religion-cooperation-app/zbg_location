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
  static const _lastStateKey = 'geo_diag_last_state';

  static Future<void> recordProviderChange(
    fbg.ProviderChangeEvent event, {
    String? uid,
  }) async {
    final locationPermission = _locationPermissionName(event.status);
    final locationPrecise = event.accuracyAuthorization ==
        fbg.ProviderChangeEvent.ACCURACY_AUTHORIZATION_FULL;
    final state = <String, dynamic>{
      'location_services_enabled': event.enabled,
      'gps_provider_enabled': event.gps,
      'network_provider_enabled': event.network,
      'location_permission': locationPermission,
      'location_authorization_status_code': event.status,
      'location_precise': locationPrecise,
      'location_accuracy_authorization_code': event.accuracyAuthorization,
    };

    await _writeEventIfChanged(
      uid: uid,
      type: 'provider_change',
      source: 'fbg_onProviderChange',
      currentState: state,
      eventFields: state,
      currentSnapshotFields: state,
      compareKeys: state.keys.toList(),
    );
  }

  static Future<void> recordPowerSaveChange(
    bool isPowerSave, {
    String? uid,
  }) async {
    const key = 'power_save_mode';
    final state = <String, dynamic>{key: isPowerSave};
    await _writeEventIfChanged(
      uid: uid,
      type: 'power_save_change',
      source: 'fbg_onPowerSaveChange',
      currentState: state,
      eventFields: state,
      currentSnapshotFields: state,
      compareKeys: const [key],
    );
  }

  static Future<void> recordFbgEnabledChange(
    bool enabled, {
    String? uid,
  }) async {
    const key = 'fbg_enabled';
    final state = <String, dynamic>{key: enabled};
    await _writeEventIfChanged(
      uid: uid,
      type: 'fbg_enabled_change',
      source: 'fbg_onEnabledChange',
      currentState: state,
      eventFields: state,
      currentSnapshotFields: state,
      compareKeys: const [key],
    );
  }

  static Future<void> _writeEventIfChanged({
    required String? uid,
    required String type,
    required String source,
    required Map<String, dynamic> currentState,
    required Map<String, dynamic> eventFields,
    required Map<String, dynamic> currentSnapshotFields,
    required List<String> compareKeys,
  }) async {
    if (kIsWeb) return;
    final resolvedUid = _resolveUid(uid);
    if (resolvedUid == null || resolvedUid.isEmpty) return;

    try {
      final cleanState = _scalarMap(currentState);
      final previous = await _readLastState();
      if (!_hasChanged(
        previous: previous,
        current: cleanState,
        compareKeys: compareKeys,
      )) {
        return;
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();

      final userRef = firestore.collection('users').doc(resolvedUid);
      final eventRef = userRef.collection('geo_events').doc();
      batch.set(eventRef, {
        'type': type,
        'source': source,
        'timestamp': FieldValue.serverTimestamp(),
        'client_ts_iso': nowIso,
        ..._scalarMap(eventFields),
      });

      final currentRef = userRef.collection('geo_diagnostics').doc('current');
      batch.set(
        currentRef,
        {
          'updated_at': FieldValue.serverTimestamp(),
          'client_updated_at_iso': nowIso,
          'last_event_type': type,
          ..._scalarMap(currentSnapshotFields),
        },
        SetOptions(merge: true),
      );

      await batch.commit();
      await _writeLastState({...previous, ...cleanState});
    } catch (e, st) {
      await _recordNonFatal(e, st, 'zbg_geo_diag_write_failed');
    }
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
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } finally {
      await db.close();
    }
  }

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
      // Diagnostics must not affect location tracking.
    }
  }
}
