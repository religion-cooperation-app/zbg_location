// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/backend/schema/structs/index.dart';
import '/backend/schema/enums/enums.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'index.dart'; // Imports other custom actions
import '/flutter_flow/custom_functions.dart'; // Imports custom functions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

// FlutterFlow custom action: recordMotionSensorDiagnostics
//
// Return type: String
// Arguments: none
//
// Required pub dependencies:
//   sensors_plus: ^6.1.1
//
// Existing app dependencies used:
//   cloud_firestore
//   firebase_auth
//   device_info_plus

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sensors_plus/sensors_plus.dart';

Future<String> recordMotionSensorDiagnostics() async {
  if (kIsWeb) return 'not_applicable:web';

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return 'skipped:no_user';

  final fs = FirebaseFirestore.instance;

  final accelerometerAvailable = await _sensorStreamAvailable(
    () => accelerometerEventStream(),
  );
  final gyroscopeAvailable = await _sensorStreamAvailable(
    () => gyroscopeEventStream(),
  );

  final motionDetectionDegraded = gyroscopeAvailable == false;
  final reason = motionDetectionDegraded ? 'no_gyroscope' : null;
  final deviceFields = await _deviceFields();

  final eventFields = <String, dynamic>{
    'type': 'motion_sensor_capability',
    'source': 'foreground_sensor_check',
    'updated_at': FieldValue.serverTimestamp(),
    'client_ts_iso': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    ...deviceFields,
    'accelerometer_available': accelerometerAvailable,
    'gyroscope_available': gyroscopeAvailable,
    'motion_detection_degraded': motionDetectionDegraded,
    if (reason != null) 'motion_detection_degraded_reason': reason,
    'recommended_disable_stop_detection': motionDetectionDegraded,
  };

  final currentFields = <String, dynamic>{
    'sensors_updated_at': FieldValue.serverTimestamp(),
    'sensor_platform': Platform.operatingSystem,
    ...deviceFields.map((key, value) => MapEntry('sensor_$key', value)),
    'sensor_accelerometer_available': accelerometerAvailable,
    'sensor_gyroscope_available': gyroscopeAvailable,
    'motion_detection_degraded': motionDetectionDegraded,
    if (reason != null) 'motion_detection_degraded_reason': reason,
    'recommended_disable_stop_detection': motionDetectionDegraded,
  };

  final userRef = fs.collection('users').doc(uid);
  final sensorEventRef = userRef.collection('geo_events').doc('sensors');
  final currentRef = userRef.collection('geo_diagnostics').doc('current');

  try {
    await fs.runTransaction((tx) async {
      tx.set(sensorEventRef, eventFields, SetOptions(merge: true));
      tx.set(currentRef, currentFields, SetOptions(merge: true));
    });
  } catch (e) {
    return 'error:${e.runtimeType}';
  }

  if (motionDetectionDegraded) {
    return 'motion_detection_degraded:no_gyroscope';
  }
  return 'ok';
}

Future<bool?> _sensorStreamAvailable(
  Stream<dynamic> Function() streamFactory,
) async {
  try {
    await streamFactory().first.timeout(const Duration(seconds: 2));
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>> _deviceFields() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return {
        'device_model': android.model,
        'device_manufacturer': android.manufacturer,
        'device_brand': android.brand,
        'android_sdk': android.version.sdkInt,
        'android_release': android.version.release,
      };
    }
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return {
        'device_model': ios.utsname.machine,
        'device_name': ios.name,
        'ios_system_name': ios.systemName,
        'ios_system_version': ios.systemVersion,
      };
    }
  } catch (_) {}
  return const {};
}

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
